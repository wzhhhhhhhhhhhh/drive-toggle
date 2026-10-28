# demo-wake.ps1 —— 弹一个「唤醒提示」的演示窗，用假数据，不碰真实磁盘
#
# 用途：改完界面后想亲眼看效果，又不想等到真的出现唤醒、也不想挂假快照时用。
#
#   powershell -File app\demo-wake.ps1              # 6 块盘
#   powershell -File app\demo-wake.ps1 -Count 12    # 12 块盘（看滚动）
#   powershell -File app\demo-wake.ps1 -Count 1     # 1 块盘（看不滚动）
#
# 窗口点「知道了」关闭，或 10 分钟自动关；「明细见 …」可点，会打开 logs 文件夹。
# 实际逻辑都在 test-ui-stub.ps1 里（-Show），这里只是给个好记的入口。

param([int]$Count = 6)

$ErrorActionPreference = 'Stop'
$stub = Join-Path $PSScriptRoot 'test-ui-stub.ps1'
if (-not (Test-Path $stub)) {
    Write-Host "找不到 test-ui-stub.ps1，无法演示" -ForegroundColor Red
    exit 1
}

& powershell -NoProfile -ExecutionPolicy Bypass -File $stub -Count $Count -Show
exit $LASTEXITCODE
