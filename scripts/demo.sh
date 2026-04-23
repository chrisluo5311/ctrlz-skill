#!/bin/bash
#
# CtrlZ Skill 簡易測試
#

CTRLZ="$HOME/.openclaw/skills/ctrlz/scripts/ctrlz.sh"
TEST_DIR="/tmp/ctrlz_demo_$$"

echo "=== CtrlZ Skill 功能測試 ==="
echo ""

# 使用獨立資料庫
export CTRLZ_DB="$TEST_DIR/undo.db"
mkdir -p "$TEST_DIR"

echo "1. 初始化資料庫..."
bash "$CTRLZ" init
echo ""

echo "2. 建立測試檔案..."
echo "這是原始內容" > "$TEST_DIR/myfile.txt"
cat "$TEST_DIR/myfile.txt"
echo ""

echo "3. 開始 Undo Session..."
SESSION=$(bash "$CTRLZ" start "修改 myfile.txt" | jq -r '.session_id')
echo "Session ID: $SESSION"
echo ""

echo "4. 記錄即將執行的操作..."
bash "$CTRLZ" record "$SESSION" file_edit "$TEST_DIR/myfile.txt"
echo ""

echo "5. 執行實際修改..."
echo "這是修改後的內容" > "$TEST_DIR/myfile.txt"
cat "$TEST_DIR/myfile.txt"
echo ""

echo "6. 查看可撤銷的操作..."
bash "$CTRLZ" list
echo ""

echo "7. 執行撤銷 (CtrlZ)..."
bash "$CTRLZ" undo
echo ""

echo "8. 驗證檔案已恢復..."
cat "$TEST_DIR/myfile.txt"
echo ""

echo "9. 查看統計..."
bash "$CTRLZ" stats
echo ""

echo "10. 設定 Stack 大小為 3..."
bash "$CTRLZ" set-stack 3
bash "$CTRLZ" get-stack
echo ""

# 清理
rm -rf "$TEST_DIR"

echo "=== 測試完成 ==="
