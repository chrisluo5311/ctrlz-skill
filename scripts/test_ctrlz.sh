#!/bin/bash
#
# CtrlZ Skill Test Suite
# 測試所有主要功能
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTRLZ_SCRIPT="$SCRIPT_DIR/../ctrlz.sh"
TEST_DIR="/tmp/ctrlz_test_$(date +%s)"
DB_PATH="$TEST_DIR/test.db"

# 顏色輸出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASSED=0
FAILED=0

# 測試函數
run_test() {
  local test_name="$1"
  local test_cmd="$2"
  local expected_result="${3:-}"
  
  echo -n "Testing: $test_name ... "
  
  if eval "$test_cmd"; then
    echo -e "${GREEN}✓ PASSED${NC}"
    ((PASSED++))
  else
    echo -e "${RED}✗ FAILED${NC}"
    ((FAILED++))
  fi
}

# 初始化測試環境
setup() {
  echo "=== 初始化測試環境 ==="
  mkdir -p "$TEST_DIR"
  export CTRLZ_DB="$DB_PATH"
  bash "$CTRLZ_SCRIPT" init > /dev/null 2>&1
  echo "測試目錄: $TEST_DIR"
  echo "資料庫: $DB_PATH"
  echo ""
}

# 清理測試環境
teardown() {
  echo ""
  echo "=== 清理測試環境 ==="
  rm -rf "$TEST_DIR"
  echo "已清理"
}

# ============ 測試案例 ============

test_init() {
  echo "=== Test 1: 初始化資料庫 ==="
  run_test "資料庫初始化" "bash '$CTRLZ_SCRIPT' init | grep -q 'initialized'"
  run_test "資料庫檔案存在" "test -f '$DB_PATH'"
}

test_start_session() {
  echo ""
  echo "=== Test 2: 開始 Session ==="
  
  local result=$(bash "$CTRLZ_SCRIPT" start "測試 session")
  run_test "建立 session" "echo '$result' | jq -e '.session_id' > /dev/null"
  
  local session_id=$(echo "$result" | jq -r '.session_id')
  run_test "Session ID 有效" "test -n '$session_id' && test '$session_id' != 'null'"
}

test_record_file_edit() {
  echo ""
  echo "=== Test 3: 記錄檔案編輯 ==="
  
  # 建立測試檔案
  echo "原始內容" > "$TEST_DIR/test_file.txt"
  
  # 開始 session
  local session_id=$(bash "$CTRLZ_SCRIPT" start "檔案編輯測試" | jq -r '.session_id')
  
  # 記錄操作
  run_test "記錄檔案編輯" "bash '$CTRLZ_SCRIPT' record '$session_id' file_edit '$TEST_DIR/test_file.txt' | jq -e '.recorded' > /dev/null"
  
  # 修改檔案
  echo "已修改內容" > "$TEST_DIR/test_file.txt"
  
  # 驗證備份存在
  run_test "備份檔案存在" "test -f ~/.openclaw/skills/ctrlz/backups/*_test_file.txt"
}

test_undo_file_edit() {
  echo ""
  echo "=== Test 4: 撤銷檔案編輯 ==="
  
  # 建立並修改檔案
  echo "原始內容" > "$TEST_DIR/undo_test.txt"
  local session_id=$(bash "$CTRLZ_SCRIPT" start "撤銷測試" | jq -r '.session_id')
  bash "$CTRLZ_SCRIPT" record "$session_id" file_edit "$TEST_DIR/undo_test.txt" > /dev/null
  echo "修改後內容" > "$TEST_DIR/undo_test.txt"
  
  # 驗證修改
  run_test "檔案已被修改" "grep -q '修改後內容' '$TEST_DIR/undo_test.txt'"
  
  # 執行撤銷
  run_test "執行撤銷" "bash '$CTRLZ_SCRIPT' undo | jq -e '.undone' > /dev/null"
  
  # 驗證恢復
  run_test "檔案已恢復" "grep -q '原始內容' '$TEST_DIR/undo_test.txt'"
}

test_record_file_write() {
  echo ""
  echo "=== Test 5: 記錄檔案寫入 ==="
  
  local session_id=$(bash "$CTRLZ_SCRIPT" start "檔案寫入測試" | jq -r '.session_id')
  
  # 寫入新檔案
  echo "新檔案內容" > "$TEST_DIR/new_file.txt"
  
  run_test "記錄檔案寫入" "bash '$CTRLZ_SCRIPT' record '$session_id' file_write '$TEST_DIR/new_file.txt' | jq -e '.recorded' > /dev/null"
}

test_record_dir_create() {
  echo ""
  echo "=== Test 6: 記錄目錄建立 ==="
  
  local session_id=$(bash "$CTRLZ_SCRIPT" start "目錄建立測試" | jq -r '.session_id')
  
  # 建立目錄
  mkdir -p "$TEST_DIR/new_directory"
  
  run_test "記錄目錄建立" "bash '$CTRLZ_SCRIPT' record '$session_id' dir_create '$TEST_DIR/new_directory' | jq -e '.recorded' > /dev/null"
}

test_stack_size() {
  echo ""
  echo "=== Test 7: Stack 大小設定 ==="
  
  run_test "設定 stack 大小為 3" "bash '$CTRLZ_SCRIPT' set-stack 3 | jq -e '.max_stack_size == 3' > /dev/null"
  
  local size=$(bash "$CTRLZ_SCRIPT" get-stack | jq -r '.max_stack_size')
  run_test "取得 stack 大小" "test '$size' = '3'"
  
  # 恢復預設
  bash "$CTRLZ_SCRIPT" set-stack 1 > /dev/null
}

test_multiple_undo() {
  echo ""
  echo "=== Test 8: 多次撤銷 ==="
  
  # 建立 3 個 sessions
  for i in 1 2 3; do
    local session_id=$(bash "$CTRLZ_SCRIPT" start "Session $i" | jq -r '.session_id')
    echo "內容 $i" > "$TEST_DIR/multi_$i.txt"
    bash "$CTRLZ_SCRIPT" record "$session_id" file_write "$TEST_DIR/multi_$i.txt" > /dev/null
  done
  
  # 驗證 list
  local count=$(bash "$CTRLZ_SCRIPT" list 10 | grep -c "Session")
  run_test "列出多個 sessions" "test '$count' -ge 3"
  
  # 撤銷 2 個
  run_test "撤銷 2 個 sessions" "bash '$CTRLZ_SCRIPT' undo 2 | jq -e '.undone == 2' > /dev/null"
}

test_stats() {
  echo ""
  echo "=== Test 9: 統計資訊 ==="
  
  local stats=$(bash "$CTRLZ_SCRIPT" stats)
  run_test "取得統計" "echo '$stats' | jq -e '.active_sessions' > /dev/null"
  run_test "統計包含 max_stack_size" "echo '$stats' | jq -e '.max_stack_size' > /dev/null"
}

test_clear() {
  echo ""
  echo "=== Test 10: 清空記錄 ==="
  
  # 先建立一些記錄
  local session_id=$(bash "$CTRLZ_SCRIPT" start "待清理" | jq -r '.session_id')
  bash "$CTRLZ_SCRIPT" record "$session_id" file_write "$TEST_DIR/clear_test.txt" > /dev/null
  
  # 清空
  run_test "清空所有記錄" "bash '$CTRLZ_SCRIPT' clear | jq -e '.cleared' > /dev/null"
  
  # 驗證
  local count=$(bash "$CTRLZ_SCRIPT" stats | jq -r '.total_sessions')
  run_test "記錄已清空" "test '$count' = '0'"
}

test_no_more_undo() {
  echo ""
  echo "=== Test 11: 無可撤銷時 ==="
  
  # 清空後嘗試撤銷
  bash "$CTRLZ_SCRIPT" clear > /dev/null 2>&1
  
  run_test "無可撤銷時返回錯誤" "! bash '$CTRLZ_SCRIPT' undo | jq -e '.error' > /dev/null 2>&1"
}

# ============ 主程式 ============

main() {
  echo "========================================"
  echo "     CtrlZ Skill Test Suite"
  echo "========================================"
  echo ""
  
  setup
  
  # 執行所有測試
  test_init
  test_start_session
  test_record_file_edit
  test_undo_file_edit
  test_record_file_write
  test_record_dir_create
  test_stack_size
  test_multiple_undo
  test_stats
  test_clear
  test_no_more_undo
  
  # 顯示結果
  echo ""
  echo "========================================"
  echo "           測試結果"
  echo "========================================"
  echo -e "${GREEN}通過: $PASSED${NC}"
  echo -e "${RED}失敗: $FAILED${NC}"
  echo "========================================"
  
  teardown
  
  if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}所有測試通過！${NC}"
    exit 0
  else
    echo -e "${RED}有測試失敗${NC}"
    exit 1
  fi
}

main "$@"
