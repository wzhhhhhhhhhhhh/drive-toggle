#Requires -RunAsAdministrator
# unmount-all.ps1 —— 强制卸载全部盘（内部转给 toggle-all，界面一致）
param([switch]$Force, [switch]$DryRun)
& (Join-Path $PSScriptRoot 'toggle-all.ps1') -Unmount -Force:$Force -DryRun:$DryRun