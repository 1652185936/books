#!/usr/bin/env bash
# Ralph 自主循环 —— 在 ralph worktree 内反复拉起全新上下文的 Claude 啃 BACKLOG。
# 用法: bash .ralph/ralph.sh [最大轮数，默认 30]
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
MAX="${1:-30}"
i=0
echo "[ralph] 启动，worktree=$(pwd)，分支=$(git rev-parse --abbrev-ref HEAD)，上限 $MAX 轮"
while [ ! -f .ralph/STOP ] && [ "$i" -lt "$MAX" ]; do
  i=$((i+1))
  echo "===================== Ralph #$i  $(date '+%F %T') ====================="
  claude -p "$(cat .ralph/PROMPT.md)" \
    --dangerously-skip-permissions \
    --max-turns 120 \
    --model claude-opus-4-8
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "[ralph] 迭代 $i 退出码 $rc，停止循环。"
    break
  fi
  sleep 2
done
if [ -f .ralph/STOP ]; then
  echo "[ralph] 检测到 .ralph/STOP —— backlog 已清空，正常收尾。"
fi
echo "[ralph] 结束，共执行 $i 轮。用 'git -C \"$(pwd)\" log --oneline' 查看产出。"
