#Requires -RunAsAdministrator
# mount-all.ps1 —— 强制挂载全部盘（内部转给 toggle-all，界面一致）
param([switch]$Force, [switch]$DryRun)
& (Join-Path $PSScriptRoot 'toggle-all.ps1') -Mount -Force:$Force -DryRun:$DryRun