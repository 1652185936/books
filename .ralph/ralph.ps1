# Ralph 自主循环 (PowerShell 版) —— 在 ralph worktree 内反复拉起全新上下文的 Claude。
# 用法: powershell -File .ralph\ralph.ps1 [最大轮数，默认 30]
$ErrorActionPreference = "Continue"
Set-Location (Split-Path $PSScriptRoot -Parent)
$max = if ($args[0]) { [int]$args[0] } else { 30 }
$i = 0
Write-Host "[ralph] 启动 worktree=$(Get-Location) 分支=$(git rev-parse --abbrev-ref HEAD) 上限 $max 轮"
while (-not (Test-Path ".ralph\STOP") -and $i -lt $max) {
  $i++
  Write-Host "===================== Ralph #$i  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ====================="
  Get-Content ".ralph\PROMPT.md" -Raw | claude -p --dangerously-skip-permissions --max-turns 120 --model claude-opus-4-8
  if ($LASTEXITCODE -ne 0) { Write-Host "[ralph] 迭代 $i 退出码 $LASTEXITCODE，停止。"; break }
  Start-Sleep 2
}
if (Test-Path ".ralph\STOP") { Write-Host "[ralph] 检测到 .ralph\STOP —— backlog 已清空，正常收尾。" }
Write-Host "[ralph] 结束，共执行 $i 轮。"
