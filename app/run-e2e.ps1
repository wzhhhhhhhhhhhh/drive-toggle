# run-e2e.ps1 —— 端到端测试：真实挂载/卸载，覆盖 M 系列里能自动化的全部用例
#
# 用法（不需要管理员，脚本通过计划任务触发提权）：
#   powershell -ExecutionPolicy Bypass -File run-e2e.ps1
#   powershell -ExecutionPolicy Bypass -File run-e2e.ps1 -KeepState   结束时恢复初始状态
#
# 会真的开关磁盘 6~7 次，约 2~3 分钟。每块盘每次 = 一次启停循环。
#
# 覆盖：M8 M9 M12 M13 M14 M15 M16 M17 M18 M19 M22 M23 M24
# 不适合自动化的：M1-M4（向导交互）、M10（物理拔盘）、M11（重启）、X1-X2（需要人为制造负载）

param(
    [switch]$KeepState,
    [int]$TimeoutSec = 90
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$appDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$here   = if ((Split-Path $appDir -Leaf) -eq 'app') { Split-Path $appDir -Parent } else { $appDir }
$logs   = Join-Path $here 'logs'
$desktop = [Environment]::GetFolderPath('Desktop')
$smDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$ws = New-Object -ComObject WScript.Shell

$pass = 0; $fail = 0
$fails = @()
function Ok ($id, $msg) { Write-Host ("  [PASS] {0,-5} {1}" -f $id, $msg) -ForegroundColor Green; $script:pass++ }
function No ($id, $msg, $why) {
    Write-Host ("  [FAIL] {0,-5} {1}" -f $id, $msg) -ForegroundColor Red
    if ($why) { Write-Host ("         → {0}" -f $why) -ForegroundColor DarkRed }
    $script:fail++; $script:fails += "$id $msg ($why)"
}

. (Join-Path $here 'dd-core.ps1')
if (-not $script:ConfigOk) { Write-Host '没有配置，先跑 setup.cmd' -ForegroundColor Red; exit 1 }

# ---------- 工具 ----------
function Get-StateMap {
    $m = [ordered]@{}
    foreach ($t in $Targets) {
        $i = Get-DiskRuntimeInfo $t
        $m[$t.Label] = $i.State
    }
    return $m
}

function Wait-State {
    param([hashtable]$Expect, [int]$Timeout = $TimeoutSec)
    $deadline = (Get-Date).AddSeconds($Timeout)
    while ((Get-Date) -lt $deadline) {
        $now = Get-StateMap
        $ok = $true
        foreach ($k in $Expect.Keys) { if ($now[$k] -ne $Expect[$k]) { $ok = $false; break } }
        if ($ok) { return $true }
        Start-Sleep -Milliseconds 800
    }
    return $false
}

function Get-OwnState {
    $s = Get-SystemState
    return $s.State
}

function Get-LnkIcon {
    param([string]$baseName)
    foreach ($d in @($desktop, $smDir)) {
        $p = Join-Path $d ($baseName + '.lnk')
        if (Test-Path $p) {
            try {
                $sc = $ws.CreateShortcut($p)
                return ((Split-Path $sc.IconLocation -Leaf) -replace ',\d+$', '')
            } catch { return $null }
        }
    }
    return $null
}

function Invoke-Toggle {
    param([string]$TaskName)
    $before = (Get-Content (Join-Path $logs 'actions.csv') -ErrorAction SilentlyContinue | Measure-Object).Count
    & schtasks /run /tn $TaskName | Out-Null
    Start-Sleep -Seconds 2
    return $before
}

function Wait-LogGrow {
    param([int]$Before, [int]$Timeout = $TimeoutSec)
    $deadline = (Get-Date).AddSeconds($Timeout)
    while ((Get-Date) -lt $deadline) {
        $now = (Get-Content (Join-Path $logs 'actions.csv') -ErrorAction SilentlyContinue | Measure-Object).Count
        if ($now -gt $Before) { return $true }
        Start-Sleep -Milliseconds 700
    }
    return $false
}

function Expect-All {
    param([string]$Id, [string]$Title, [string]$State)
    $exp = @{}
    foreach ($t in $Targets) { $exp[$t.Label] = $State }
    if (Wait-State -Expect $exp) {
        Ok $Id "$Title：状态 = $State"
    } else {
        $now = Get-StateMap
        No $Id "$Title 超时" (($now.Keys | ForEach-Object { "$_=$($now[$_])" }) -join ' ')
    }
}

function Expect-One {
    param([string]$Id, [string]$Title, [hashtable]$Expect)
    if (Wait-State -Expect $Expect) {
        Ok $Id "$Title"
    } else {
        $now = Get-StateMap
        No $Id "$Title 不符" ("期望 " + (($Expect.Keys | ForEach-Object { "$_=$($Expect[$_])" }) -join ' ') + "，实际 " + (($now.Keys | ForEach-Object { "$_=$($now[$_])" }) -join ' '))
    }
}

function Expect-MasterIcon {
    param([string]$Id, [string]$State)
    $want = if ($State -eq 'on') { 'toggle-on.ico' } else { 'toggle-off.ico' }
    $got = Get-LnkIcon $script:MasterName
    if (-not $got) { No $Id '找不到总开关快捷方式' '未安装'; return }
    if ($got -eq $want) { Ok $Id "总开关图标 = $want" }
    else { No $Id '总开关图标不对' "期望 $want，实际 $got（状态=$State）" }
}

function Expect-DiskIcon {
    param([string]$Id, [string]$DiskName, [string]$State)
    $t = @($Targets | Where-Object { $_.Label -eq $DiskName })[0]
    if (-not $t) { No $Id "配置里没有 $DiskName" ''; return }
    $info = Get-DiskRuntimeInfo $t
    $letter = if ($info.Letter) { $info.Letter.ToUpper() } else { '' }
    $want = if ($letter) { "disk-$letter-$State.ico" } else { if ($State -eq 'on') { 'toggle-on.ico' } else { 'toggle-off.ico' } }
    $got = Get-LnkIcon ("$($script:MasterName) - " + $DiskName)
    if (-not $got) { No $Id "$DiskName 快捷方式不存在" '未安装'; return }
    if ($got -eq $want) { Ok $Id "$DiskName 图标 = $want" }
    else { No $Id "$DiskName 图标不对" "期望 $want，实际 $got" }
}

# ---------- 开始 ----------
Write-Host ''
Write-Host '=== 端到端测试（会真实开关磁盘）===' -ForegroundColor Cyan
$names = @($Targets | ForEach-Object { $_.Label })
Write-Host ("  目标盘：{0}" -f ($names -join '、')) -ForegroundColor Gray
Write-Host ''

$initial = (Get-StateMap).GetEnumerator() | ForEach-Object { $_.Value } | Select-Object -First 1
Write-Host ("  初始状态：{0}" -f (Get-OwnState)) -ForegroundColor DarkGray
Write-Host ''

# 场景 0：统一基线 —— 全部脱机
Write-Host '0) 基线：先让全部脱机' -ForegroundColor White
if ((Get-OwnState) -eq 'on') {
    $n = Invoke-Toggle 'Disk-Toggle'
    if (-not (Wait-LogGrow $n)) { No 'E0' '卸载没写日志' '任务可能没跑起来' }
}
Expect-All 'E0' '基线全部脱机' 'off'

# 场景 1：总开关挂载
Write-Host ''
Write-Host '1) 总开关：挂载（M8 / M12 / M18 / M22 / M23）' -ForegroundColor White
$n = Invoke-Toggle 'Disk-Toggle'
$grown = Wait-LogGrow $n
Expect-All 'E1' '全部盘联机' 'on'
if ($grown) { Ok 'E1b' 'actions.csv 有新记录' } else { No 'E1b' 'actions.csv 没增长' '日志没写' }
Expect-MasterIcon 'E1c' 'on'
foreach ($dn in $names) { Expect-DiskIcon 'E1d' $dn 'on' }

# 场景 2：总开关卸载
Write-Host ''
Write-Host '2) 总开关：卸载（M9 / M12 / M24）' -ForegroundColor White
$n = Invoke-Toggle 'Disk-Toggle'
$grown = Wait-LogGrow $n
Expect-All 'E2' '全部盘脱机' 'off'
Expect-MasterIcon 'E2b' 'off'
foreach ($dn in $names) { Expect-DiskIcon 'E2c' $dn 'off' }

if ($names.Count -ge 2) {
    $d1 = $names[0]; $d2 = $names[1]

    # 场景 3：单盘挂载第一块 —— 总开关应转绿（之前的 bug）
    Write-Host ''
    Write-Host "3) 单盘挂载「$d1」→ 总开关应变绿（M13）" -ForegroundColor White
    $n = Invoke-Toggle 'Disk-Toggle-1'
    if (-not (Wait-LogGrow $n)) { No 'E3' '没写日志' 'Disk-Toggle-1 可能不存在' }
    $exp = @{}; foreach ($dn in $names) { $exp[$dn] = if ($dn -eq $d1) { 'on' } else { 'off' } }
    Expect-One 'E3' "只有 $d1 在线" $exp
    Expect-MasterIcon 'E3b' 'on'          # ← 回归重点
    Expect-DiskIcon 'E3c' $d1 'on'
    Expect-DiskIcon 'E3d' $d2 'off'

    # 场景 4：单盘挂载第二块
    Write-Host ''
    Write-Host "4) 单盘挂载「$d2」（M14）" -ForegroundColor White
    $n = Invoke-Toggle 'Disk-Toggle-2'
    [void](Wait-LogGrow $n)
    $exp = @{}; foreach ($dn in $names) { $exp[$dn] = 'on' }
    Expect-One 'E4' '两块都在线' $exp
    Expect-DiskIcon 'E4b' $d2 'on'

    # 场景 5：单盘卸载第一块 —— 总开关应保持绿
    Write-Host ''
    Write-Host "5) 单盘卸载「$d1」→ 总开关应保持绿（M15）" -ForegroundColor White
    $n = Invoke-Toggle 'Disk-Toggle-1'
    [void](Wait-LogGrow $n)
    $exp = @{}; foreach ($dn in $names) { $exp[$dn] = if ($dn -eq $d1) { 'off' } else { 'on' } }
    Expect-One 'E5' "$d1 脱机、$d2 在线" $exp
    Expect-MasterIcon 'E5b' 'on'
    Expect-DiskIcon 'E5c' $d1 'off'

    # 场景 6：单盘卸载第二块 —— 全部脱机，总开关转灰
    Write-Host ''
    Write-Host "6) 单盘卸载「$d2」→ 全部脱机，总开关转灰（M16）" -ForegroundColor White
    $n = Invoke-Toggle 'Disk-Toggle-2'
    [void](Wait-LogGrow $n)
    Expect-All 'E6' '全部盘脱机' 'off'
    Expect-MasterIcon 'E6b' 'off'

    # 场景 7：混合状态下点总开关 —— 应全部卸载
    Write-Host ''
    Write-Host '7) 混合状态点总开关 → 应全部卸载（M17）' -ForegroundColor White
    $n = Invoke-Toggle 'Disk-Toggle-1'
    [void](Wait-LogGrow $n)
    [void](Wait-State -Expect (@{ $d1 = 'on' }))
    $n = Invoke-Toggle 'Disk-Toggle'
    [void](Wait-LogGrow $n)
    Expect-All 'E7' '点总开关后全部脱机' 'off'
} else {
    Write-Host ''
    Write-Host '  只配置了一块盘，跳过单盘组合用例（E3–E7）' -ForegroundColor DarkGray
}

# ---------- 恢复 ----------
if ($KeepState -and $initial -eq 'on') {
    Write-Host ''
    Write-Host '恢复初始状态（联机）' -ForegroundColor Gray
    $n = Invoke-Toggle 'Disk-Toggle'
    [void](Wait-LogGrow $n)
    Expect-All 'E9' '恢复到联机' 'on'
}

# ---------- 汇总 ----------
Write-Host ''
Write-Host '=== 结果 ===' -ForegroundColor Cyan
Write-Host ("  通过 {0}　失败 {1}" -f $pass, $fail) -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) {
    Write-Host ''
    $fails | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
}
Write-Host ''
exit $(if ($fail -eq 0) { 0 } else { 1 })
