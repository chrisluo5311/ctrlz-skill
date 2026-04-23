#!/bin/bash
#
# CtrlZ - AI Operation Undo System
# 記錄和撤銷 AI 執行的所有改動
#

set -e

DB_PATH="${CTRLZ_DB:-$HOME/.openclaw/skills/ctrlz/undo.db}"
MAX_STACK="${CTRLZ_STACK_SIZE:-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 初始化資料庫
init_db() {
  mkdir -p "$(dirname "$DB_PATH")"
  sqlite3 "$DB_PATH" << 'EOF'
-- 撤銷單位（每個對話回合一個）
CREATE TABLE IF NOT EXISTS undo_sessions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_key TEXT NOT NULL,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  description TEXT,
  status TEXT DEFAULT 'active' -- active, undone, expired
);

-- 具體操作記錄
CREATE TABLE IF NOT EXISTS undo_operations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id INTEGER NOT NULL,
  type TEXT NOT NULL, -- file_write, file_edit, file_delete, dir_create, exec_install, etc.
  target_path TEXT NOT NULL,
  backup_path TEXT, -- 備份檔案路徑（如果適用）
  original_content BLOB, -- 原始內容（用於文字檔案）
  metadata TEXT, -- JSON 格式額外資訊
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (session_id) REFERENCES undo_sessions(id) ON DELETE CASCADE
);

-- 索引加速查詢
CREATE INDEX IF NOT EXISTS idx_session_key ON undo_sessions(session_key);
CREATE INDEX IF NOT EXISTS idx_session_status ON undo_sessions(status);
CREATE INDEX IF NOT EXISTS idx_op_session ON undo_operations(session_id);

-- 設定表（儲存 stack 大小等配置）
CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT
);

-- 初始化預設 stack 大小
INSERT OR IGNORE INTO settings (key, value) VALUES ('max_stack_size', '1');
EOF
}

# 取得設定
get_setting() {
  local key="$1"
  sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key = '$key';"
}

# 設定配置
set_setting() {
  local key="$1"
  local value="$2"
  sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO settings (key, value) VALUES ('$key', '$value');"
}

# 開始一個新的 undo session
start_session() {
  local session_key="$1"
  local description="${2:-}"
  
  # 清理舊的過期 sessions（超過 max_stack）
  cleanup_old_sessions
  
  # 建立新 session
  local session_id=$(sqlite3 "$DB_PATH" "INSERT INTO undo_sessions (session_key, description) VALUES ('$session_key', '$description'); SELECT last_insert_rowid();")
  echo "$session_id"
}

# 記錄檔案操作
record_operation() {
  local session_id="$1"
  local op_type="$2"
  local target_path="$3"
  local backup_path="${4:-}"
  local metadata="${5:-}"
  
  # 如果是編輯操作，嘗試讀取原始內容備份
  local original_content=""
  if [[ "$op_type" == "file_edit" && -f "$target_path" ]]; then
    original_content=$(cat "$target_path" | base64 -w 0)
  fi
  
  # 處理特殊字元
  target_path=$(echo "$target_path" | sed "s/'/''/g")
  backup_path=$(echo "$backup_path" | sed "s/'/''/g")
  metadata=$(echo "$metadata" | sed "s/'/''/g")
  original_content=$(echo "$original_content" | sed "s/'/''/g")
  
  sqlite3 "$DB_PATH" << EOF
INSERT INTO undo_operations (session_id, type, target_path, backup_path, original_content, metadata)
VALUES ($session_id, '$op_type', '$target_path', '$backup_path', '$original_content', '$metadata');
EOF
}

# 清理舊 sessions（保持 stack 大小）
cleanup_old_sessions() {
  local max_size=$(get_setting 'max_stack_size')
  max_size="${max_size:-1}"
  
  # 保留最近的 N 個 active sessions，其他的標記為 expired
  sqlite3 "$DB_PATH" << EOF
UPDATE undo_sessions 
SET status = 'expired' 
WHERE id IN (
  SELECT id FROM undo_sessions 
  WHERE status = 'active' 
  ORDER BY created_at DESC 
  LIMIT -1 OFFSET $max_size
);

-- 刪除 expired sessions 的操作記錄
DELETE FROM undo_operations 
WHERE session_id IN (
  SELECT id FROM undo_sessions WHERE status = 'expired'
);

-- 刪除 expired sessions
DELETE FROM undo_sessions WHERE status = 'expired';
EOF
}

# 列出可撤銷的 sessions
list_undoable() {
  local limit="${1:-10}"
  sqlite3 "$DB_PATH" << EOF
.headers on
.mode column
SELECT 
  id,
  datetime(created_at, 'localtime') as time,
  substr(description, 1, 50) as description,
  (SELECT COUNT(*) FROM undo_operations WHERE session_id = undo_sessions.id) as operations
FROM undo_sessions 
WHERE status = 'active' 
ORDER BY created_at DESC 
LIMIT $limit;
EOF
}

# 取得 session 詳細資訊
get_session_details() {
  local session_id="$1"
  sqlite3 "$DB_PATH" << EOF
SELECT 
  id,
  type,
  target_path,
  metadata
FROM undo_operations 
WHERE session_id = $session_id
ORDER BY id;
EOF
}

# 執行撤銷
undo() {
  local count="${1:-1}"
  local undone_count=0
  local packages_to_remove=()
  
  for i in $(seq 1 $count); do
    # 取得最新的 active session
    local session_id=$(sqlite3 "$DB_PATH" "SELECT id FROM undo_sessions WHERE status = 'active' ORDER BY created_at DESC LIMIT 1;")
    
    if [[ -z "$session_id" ]]; then
      echo "{\"error\": \"No more operations to undo\", \"undone\": $undone_count}"
      return 1
    fi
    
    # 取得該 session 的所有操作
    local ops=$(sqlite3 "$DB_PATH" "SELECT type, target_path, backup_path, original_content FROM undo_operations WHERE session_id = $session_id ORDER BY id DESC;")
    
    # 執行每個操作的撤銷
    while IFS='|' read -r op_type target_path backup_path original_content; do
      case "$op_type" in
        file_write|file_edit)
          if [[ -n "$backup_path" && -f "$backup_path" ]]; then
            cp "$backup_path" "$target_path"
          elif [[ -n "$original_content" ]]; then
            echo "$original_content" | base64 -d > "$target_path"
          else
            # 如果沒有備份，刪除檔案
            rm -f "$target_path"
          fi
          ;;
        file_delete)
          # 還原被刪除的檔案（如果有備份）
          if [[ -n "$backup_path" && -f "$backup_path" ]]; then
            cp "$backup_path" "$target_path"
          fi
          ;;
        dir_create)
          # 刪除建立的目錄
          if [[ -d "$target_path" ]]; then
            rm -rf "$target_path"
          fi
          ;;
        exec_install|package_install)
          # 收集需要移除的套件，稍後統一詢問
          packages_to_remove+=("$target_path")
          ;;
      esac
    done <<< "$ops"
    
    # 標記 session 為已撤銷
    sqlite3 "$DB_PATH" "UPDATE undo_sessions SET status = 'undone' WHERE id = $session_id;"
    undone_count=$((undone_count + 1))
  done
  
  # 如果有套件安裝，列出並詢問用戶
  if [[ ${#packages_to_remove[@]} -gt 0 ]]; then
    echo "" >&2
    echo "📦 以下套件安裝無法自動撤銷：" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    local idx=1
    for pkg in "${packages_to_remove[@]}"; do
      echo "  $idx. $pkg" >&2
      ((idx++))
    done
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo "" >&2
    echo "💡 如需移除，請手動執行：" >&2
    for pkg in "${packages_to_remove[@]}"; do
      # 解析套件類型
      if [[ "$pkg" == npm:* ]]; then
        echo "   npm uninstall ${pkg#npm:}" >&2
      elif [[ "$pkg" == pip:* ]]; then
        echo "   pip uninstall ${pkg#pip:}" >&2
      elif [[ "$pkg" == apt:* ]]; then
        echo "   sudo apt remove ${pkg#apt:}" >&2
      else
        echo "   # 套件: $pkg" >&2
      fi
    done
    echo "" >&2
  fi
  
  echo "{\"undone\": $undone_count, \"message\": \"Successfully undone $undone_count operation(s)\"}"
}

# 顯示統計
stats() {
  local active=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM undo_sessions WHERE status = 'active';")
  local total=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM undo_sessions;")
  local operations=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM undo_operations;")
  local max_stack=$(get_setting 'max_stack_size')
  
  echo "{\"active_sessions\": $active, \"total_sessions\": $total, \"total_operations\": $operations, \"max_stack_size\": $max_stack}"
}

# 備份檔案（在修改前調用）
backup_file() {
  local file_path="$1"
  local backup_dir="$HOME/.openclaw/skills/ctrlz/backups"
  mkdir -p "$backup_dir"
  
  if [[ -f "$file_path" ]]; then
    local backup_name="$(date +%s)_$(basename "$file_path" | tr '/' '_')"
    local backup_path="$backup_dir/$backup_name"
    cp "$file_path" "$backup_path"
    echo "$backup_path"
  else
    echo ""
  fi
}

# 清空所有記錄
clear_all() {
  sqlite3 "$DB_PATH" "DELETE FROM undo_operations; DELETE FROM undo_sessions;"
  rm -rf "$HOME/.openclaw/skills/ctrlz/backups"
  echo "{\"cleared\": true}"
}

# CLI 主程式
main() {
  init_db
  
  local cmd="${1:-help}"
  shift || true
  
  case "$cmd" in
    init)
      # 初始化資料庫（已自動執行）
      echo "{\"initialized\": true, \"db_path\": \"$DB_PATH\"}"
      ;;
      
    start)
      # 開始新 session
      local session_key="${1:-default}"
      local description="${2:-}"
      local session_id=$(start_session "$session_key" "$description")
      echo "{\"session_id\": $session_id, \"status\": \"started\"}"
      ;;
      
    record)
      # 記錄操作
      local session_id="$1"
      local op_type="$2"
      local target_path="$3"
      shift 3 || true
      local metadata="${*:-}"
      
      # 備份檔案（如果是檔案操作）
      local backup_path=""
      if [[ "$op_type" =~ ^file_ && -f "$target_path" ]]; then
        backup_path=$(backup_file "$target_path")
      fi
      
      record_operation "$session_id" "$op_type" "$target_path" "$backup_path" "$metadata"
      echo "{\"recorded\": true, \"type\": \"$op_type\", \"target\": \"$target_path\"}"
      ;;
      
    undo)
      # 撤銷操作
      local count="${1:-1}"
      undo "$count"
      ;;
      
    list)
      # 列出可撤銷的 sessions
      local limit="${1:-10}"
      list_undoable "$limit"
      ;;
      
    details)
      # 顯示 session 詳細資訊
      local session_id="$1"
      get_session_details "$session_id"
      ;;
      
    set-stack)
      # 設定 stack 大小
      local size="${1:-1}"
      set_setting 'max_stack_size' "$size"
      echo "{\"max_stack_size\": $size}"
      ;;
      
    get-stack)
      # 取得 stack 大小
      local size=$(get_setting 'max_stack_size')
      echo "{\"max_stack_size\": ${size:-1}}"
      ;;
      
    stats)
      stats
      ;;
      
    clear)
      clear_all
      ;;
      
    help|*)
      cat << 'HELP'
CtrlZ - AI Operation Undo System

Usage: ctrlz <command> [args]

Commands:
  init                    初始化資料庫
  start <key> [desc]      開始新的 undo session
  record <sid> <type> <path> [metadata]  記錄操作
  undo [count]            撤銷最近 N 個 session（預設1）
  list [limit]            列出可撤銷的 sessions
  details <session_id>    顯示 session 詳細資訊
  set-stack <size>        設定 stack 大小（預設1）
  get-stack               取得目前 stack 大小
  stats                   顯示統計資訊
  clear                   清空所有記錄

Environment Variables:
  CTRLZ_DB                資料庫路徑（預設 ~/.openclaw/skills/ctrlz/undo.db）
  CTRLZ_STACK_SIZE        預設 stack 大小

Examples:
  ctrlz start my-session "修改 config 檔案"
  ctrlz record 1 file_edit /path/to/config.json
  ctrlz undo
  ctrlz undo 3
  ctrlz list
  ctrlz set-stack 5
HELP
      ;;
  esac
}

main "$@"
