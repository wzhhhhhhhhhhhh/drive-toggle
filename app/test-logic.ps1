# test-logic.ps1 —— 逻辑测试：用内存假盘跑完整流程，不碰真硬盘
#
# 做法：dot-source 真实脚本后，把"碰硬件"的薄接口函数替换成假实现，
#      再调用真实的 Mount-Target / Unmount-Target / Get-SystemState / 决策函数。
#
# 覆盖：挂载全分支、卸载全分支（含 64 KB/s 阈值边界）、状态汇总、切换方向、图标映射、日志埋点
# 耗时：约 3~6 秒

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$pass = 0; $fail = 0
$fails = @()
function Ok ($id, $msg) { Write-Host ("  [PASS] {0,-5} {1}" -f $id, $msg) -ForegroundColor Green; $script:pass++ }
function No ($id, $msg, $why) {
    Write-Host ("  [FAIL] {0,-5} {1}" -f $id, $msg) -ForegroundColor Red
    if ($why) { Write-Host ("         → {0}" -f $why) -ForegroundColor DarkRed }
    $script:fail++; $script:fails += "$id $msg ($why)"
}
function Eq ($id, $actual, $expected, $label) {
    if ("$actual" -eq "$expected") { Ok $id "$label = $actual" }
    else { No $id "$label 不符" "期望 [$expected]，实际 [$actual]" }
}
function Like ($id, $actual, $pattern, $label) {
    if ("$actual" -match $pattern) { Ok $id "$label" }
    else { No $id "$label 不符" "期望匹配 /$pattern/，实际 [$actual]" }
}

# ---------- 装载真实脚本 ----------
. (Join-Path $here 'dd-core.ps1')

# ---------- 假盘模型 ----------
$script:FAKE = [ordered]@{
    'FAKE-A' = @{ Number = 1; Offline = $true;  Letter = 'X'; Present = $true;  HideLetter = $false; Model = 'Fake A' }
    'FAKE-B' = @{ Number = 2; Offline = $true;  Letter = 'Y'; Present = $true;  HideLetter = $false; Model = 'Fake B' }
}
$script:CAPTURE_STEPS = New-Object System.Collections.ArrayList
$script:CAPTURE_ACTIONS = New-Object System.Collections.ArrayList
$script:FAKE_CLOSED = 0
$script:FAKE_PROCS = @()

function Get-TargetDisk {
    param($t)
    $d = $script:FAKE[$t.Serial]
    if (-not $d -or -not $d.Present) { return $null }
    [pscustomobject]@{
        Number = $d.Number; IsOffline = $d.Offline; FriendlyName = $d.Model
        SerialNumber = $t.Serial; BusType = 'SATA'
    }
}
function Get-DiskLetter {
    param([int]$Number)
    foreach ($k in $script:FAKE.Keys) {
        $d = $script:FAKE[$k]
        if ($d.Number -eq $Number) { if ($d.HideLetter) { return $null } else { return $d.Letter } }
    }
    return $null
}
function Set-Disk {
    param([int]$Number, [bool]$IsOffline)
    foreach ($k in $script:FAKE.Keys) {
        if ($script:FAKE[$k].Number -eq $Number) { $script:FAKE[$k].Offline = $IsOffline; $script:FAKE_FAIL_OFFLINE = $false }
    }
}
function Update-HostStorageCache { }
function Write-VolumeCache { param($DriveLetter) }
function Get-SmartInfo { param([int]$Number) return '假 SMART 25,000h / 10,000' }
function Enable-UsbSuspend { param([int]$Number) return 'USB 省电挂起（假）' }
function Open-ThisPC { return '（假）已打开此电脑' }
function Close-DriveWindows { param([string]$Letter) return $script:FAKE_CLOSED }
function Get-DriveProcesses { param([string]$Root) return $script:FAKE_PROCS }
function Write-StepLog {
    param([string]$Stage, [string]$Status, [string]$Detail, [string]$Disk = '')
    [void]$script:CAPTURE_STEPS.Add([pscustomobject]@{ Stage = $Stage; Status = $Status; Detail = $Detail; Disk = $Disk })
}
function Write-ActionLog {
    param([string]$LogDir, [string]$Action, $Rows, [double]$Seconds)
    foreach ($r in @($Rows)) { [void]$script:CAPTURE_ACTIONS.Add([pscustomobject]@{ Action = $Action; Row = $r }) }
}
function Get-DiskIO { param([int]$Number) return [pscustomobject]@{ Reads = 0; Writes = 0 } }
function Get-DiskIOAll { return @{} }

# 测试用目标（WaitTicks=1，避免真等 15 秒）
$T1 = @{ Key = 'A'; Label = 'A 盘'; Desc = 'Fake A'; Serial = 'FAKE-A'; BusExpect = 'SATA'; WaitTicks = 1 }
$T2 = @{ Key = 'B'; Label = 'B 盘'; Desc = 'Fake B'; Serial = 'FAKE-B'; BusExpect = 'SATA'; WaitTicks = 1 }

function Reset-Fake {
    $script:FAKE['FAKE-A'].Offline = $true; $script:FAKE['FAKE-A'].Present = $true; $script:FAKE['FAKE-A'].HideLetter = $false
    $script:FAKE['FAKE-B'].Offline = $true; $script:FAKE['FAKE-B'].Present = $true; $script:FAKE['FAKE-B'].HideLetter = $false
    $script:FAKE_CLOSED = 0; $script:FAKE_PROCS = @()
    $script:CAPTURE_STEPS.Clear(); $script:CAPTURE_ACTIONS.Clear()
}

Write-Host ''
Write-Host '=== 逻辑测试（内存假盘，不碰真硬盘）===' -ForegroundColor Cyan

# ---------- 挂载 ----------
Write-Host ''
Write-Host '1) 挂载' -ForegroundColor White
Reset-Fake
$r = Mount-Target $T1
Eq 'G1' $r.结果 '已挂载' '脱机盘挂载'
Like 'G1b' $r.说明 '^X:' '返回盘符'

Reset-Fake; $script:FAKE['FAKE-A'].Offline = $false
$r = Mount-Target $T1
Eq 'G2' $r.结果 '本来就在线' '已在线盘再挂载'

Reset-Fake; $script:FAKE['FAKE-A'].Present = $false
$r = Mount-Target $T1
Eq 'G3' $r.结果 '未连接' '盘不存在'

Reset-Fake; $script:FAKE['FAKE-A'].HideLetter = $true
$r = Mount-Target $T1
Eq 'G4' $r.结果 '失败' '等不到盘符'
Like 'G4b' $r.说明 '盘符' '失败原因可读'

Reset-Fake
$r = Mount-Target $T1 -DryRun
Eq 'G5' $r.结果 '（演练）将联机' '演练模式'
Eq 'G5b' $script:FAKE['FAKE-A'].Offline $true '演练不改状态'

# ---------- 卸载 ----------
Write-Host ''
Write-Host '2) 卸载' -ForegroundColor White
Reset-Fake; $script:FAKE['FAKE-A'].Offline = $false
$io = @{ 1 = [pscustomobject]@{ Reads = 0; Writes = 4096 } }
$r = Unmount-Target $T1 -IO $io
Eq 'U1' $r.结果 '已卸载' '低写入正常卸载'

Reset-Fake; $script:FAKE['FAKE-A'].Offline = $false
$io = @{ 1 = [pscustomobject]@{ Reads = 0; Writes = 65537 } }
$r = Unmount-Target $T1 -IO $io
Eq 'U2' $r.结果 '跳过' '写入刚过 64 KB/s 阈值'
Like 'U2b' $r.说明 '64 KB/s' '说明里提到阈值'

Reset-Fake; $script:FAKE['FAKE-A'].Offline = $false
$io = @{ 1 = [pscustomobject]@{ Reads = 0; Writes = 65536 } }
$r = Unmount-Target $T1 -IO $io
Eq 'U3' $r.结果 '已卸载' '写入等于阈值不拦（边界）'

# 防回归：读再高也不拦
Reset-Fake; $script:FAKE['FAKE-A'].Offline = $false
$io = @{ 1 = [pscustomobject]@{ Reads = 99999; Writes = 2000 } }
$r = Unmount-Target $T1 -IO $io
Eq 'U4' $r.结果 '已卸载' '高读低写不拦（回归：只拦写入）'

Reset-Fake; $script:FAKE['FAKE-A'].Offline = $false
$script:FAKE_PROCS = @([pscustomobject]@{ ProcessName = 'game.exe'; Path = 'X:\game.exe' })
$r = Unmount-Target $T1
Eq 'U5' $r.结果 '跳过' '有程序占用'
Like 'U5b' $r.说明 'game\.exe' '说明里带进程名'

Reset-Fake; $script:FAKE['FAKE-A'].Offline = $true
$r = Unmount-Target $T1
Eq 'U6' $r.结果 '本来已脱机' '已脱机再卸载'

# 脱机不生效
Reset-Fake; $script:FAKE['FAKE-A'].Offline = $false
$script:FAKE_FAIL_OFFLINE = $true
function Set-Disk { param([int]$Number, [bool]$IsOffline) }   # 什么都不做
$r = Unmount-Target $T1 -IO @{ 1 = [pscustomobject]@{ Reads = 0; Writes = 0 } }
Eq 'U7' $r.结果 '失败' '脱机不生效要报失败'
function Set-Disk {
    param([int]$Number, [bool]$IsOffline)
    foreach ($k in $script:FAKE.Keys) { if ($script:FAKE[$k].Number -eq $Number) { $script:FAKE[$k].Offline = $IsOffline } }
}

# ---------- 状态汇总 ----------
Write-Host ''
Write-Host '3) 状态汇总' -ForegroundColor White
Reset-Fake
$s = Get-SystemState -DiskList @($T1, $T2)
Eq 'S1' $s.State 'off' '全部脱机'
Reset-Fake; $script:FAKE['FAKE-B'].Offline = $false
$s = Get-SystemState -DiskList @($T1, $T2)
Eq 'S2' $s.State 'on' '任意一块在线即为 on'
Reset-Fake; $script:FAKE['FAKE-A'].Present = $false; $script:FAKE['FAKE-B'].Present = $false
$s = Get-SystemState -DiskList @($T1, $T2)
Eq 'S3' $s.State 'off' '两个都没插'

# ---------- 切换方向 ----------
Write-Host ''
Write-Host '4) 切换方向决策' -ForegroundColor White
Eq 'D1' (Get-ToggleDirection -State 'on')  'unmount' '在线 → 卸载'
Eq 'D2' (Get-ToggleDirection -State 'off') 'mount'   '脱机 → 挂载'
Eq 'D3' (Get-ToggleDirection -State 'on'  -ForceMount)    'mount'   '强制挂载优先'
Eq 'D4' (Get-ToggleDirection -State 'off' -ForceUnmount)  'unmount' '强制卸载优先'

# ---------- 图标映射 ----------
Write-Host ''
Write-Host '5) 图标映射' -ForegroundColor White
Eq 'I1' (Get-MasterIconName 'on')  'toggle-on.ico'  '总开关 on'
Eq 'I2' (Get-MasterIconName 'off') 'toggle-off.ico' '总开关 off'
Eq 'I3' (Get-DiskIconName -State 'on'  -Letter 'D') 'disk-D-on.ico'  '单盘 on（大写）'
Eq 'I4' (Get-DiskIconName -State 'off' -Letter 'f') 'disk-F-off.ico' '单盘 off（自动大写）'
Eq 'I5' (Get-DiskIconName -State 'on'  -Letter '')  'toggle-on.ico'  '无盘符退化成总开关图标'

# ---------- 日志埋点 ----------
Write-Host ''
Write-Host '6) 日志埋点' -ForegroundColor White
Reset-Fake; $script:FAKE['FAKE-A'].Offline = $false
$io = @{ 1 = [pscustomobject]@{ Reads = 0; Writes = 0 } }
[void](Unmount-Target $T1 -IO $io)
$stages = $script:CAPTURE_STEPS | ForEach-Object { $_.Stage }
foreach ($need in '定位', '关窗口', '查占用', '采样', '脱机', '复查', '完成') {
    if ($stages -contains $need) { Ok 'L1' "卸载埋点：$need" } else { No 'L1' "卸载缺埋点：$need" ($stages -join ',') }
}

Reset-Fake
[void](Mount-Target $T1)
$stages2 = $script:CAPTURE_STEPS | ForEach-Object { $_.Stage }
foreach ($need in '定位', '联机', '等盘符', 'SMART', '完成') {
    if ($stages2 -contains $need) { Ok 'L2' "挂载埋点：$need" } else { No 'L2' "挂载缺埋点：$need" ($stages2 -join ',') }
}

# 结果日志：一次卸载一块盘 = 一条 action 记录
Reset-Fake; $script:FAKE['FAKE-A'].Offline = $false
$script:CAPTURE_ACTIONS.Clear()
$io = @{ 1 = [pscustomobject]@{ Reads = 0; Writes = 0 } }
$res = Unmount-Target $T1 -IO $io
Write-ActionLog -LogDir 'x' -Action '卸载' -Rows @($res) -Seconds 1.5
Eq 'L3' $script:CAPTURE_ACTIONS.Count 1 '结果日志一条'
Eq 'L3b' $script:CAPTURE_ACTIONS[0].Row.结果 '已卸载' '日志记录结果'

# ---------- 7) Invoke-DiskOperation 串联（防递归 / 防参数名遮蔽） ----------
Write-Host ''
Write-Host '7) 操作串联与进度回调' -ForegroundColor White
Reset-Fake
$script:PROG = New-Object System.Collections.ArrayList
$cb = { param($text, $pct) [void]$script:PROG.Add([pscustomobject]@{ Text = $text; Pct = $pct }) }

$res = Invoke-DiskOperation -Targets @($T1, $T2) -Direction 'mount' -Progress $cb
Eq 'P1' @($res).Count 2 '挂载：两块盘都有结果'
Eq 'P1b' @($res | Where-Object { $_.结果 -eq '已挂载' }).Count 2 '挂载：两块都成功'
if (@($script:PROG).Count -ge 6) { Ok 'P2' "挂载进度回调 $($script:PROG.Count) 次" }
else { No 'P2' '挂载进度回调太少' $script:PROG.Count }
if (@($script:PROG | Where-Object { $_.Pct -eq 100 }).Count -gt 0) { Ok 'P3' '挂载进度最终到 100%' }
else { No 'P3' '挂载进度没到 100%' '' }

Reset-Fake
$script:FAKE['FAKE-A'].Offline = $false
$script:FAKE['FAKE-B'].Offline = $false
$script:PROG.Clear()
$res2 = Invoke-DiskOperation -Targets @($T1, $T2) -Direction 'unmount' -Progress $cb
Eq 'P4' @($res2).Count 2 '卸载：两块盘都有结果'
Eq 'P4b' @($res2 | Where-Object { $_.结果 -eq '已卸载' }).Count 2 '卸载：两块都成功'
if (@($script:PROG | Where-Object { $_.Pct -eq 100 }).Count -gt 0) { Ok 'P5' '卸载进度最终到 100%' }
else { No 'P5' '卸载进度没到 100%' '' }

# 回调文字要能说清当前在做什么
$texts = @($script:PROG | ForEach-Object { $_.Text })
if ($texts -match '正在卸载') { Ok 'P6' '回调文字包含具体动作' } else { No 'P6' '回调文字太笼统' ($texts -join ' | ') }
# ---------- 8) 混合状态（一块在线一块脱机） ----------
Write-Host ''
Write-Host '8) 混合状态语义' -ForegroundColor White

$mixed = [pscustomobject]@{ State = 'on'; Online = 1; Offline = 1; Absent = 0; Detail = 'A=在线 / B=脱机' }
Eq 'X1' (Get-MasterIconName $mixed.State) 'toggle-on.ico' '一块在线时总开关图标仍是「开」'
Eq 'X2' (Get-ToggleDirection -State $mixed.State) 'unmount' '一块在线时点总开关 = 全部断开'
$d = Get-MasterDescription -State $mixed
if ($d -like '*1 在线 / 1 脱机*' -and $d -like '*全部断开*') { Ok 'X3' "混合状态描述：$d" }
else { No 'X3' "混合状态描述不对：$d" '' }

$allOff = [pscustomobject]@{ State = 'off'; Online = 0; Offline = 2; Absent = 0; Detail = '' }
Eq 'X4' (Get-MasterIconName $allOff.State) 'toggle-off.ico' '全部脱机时总开关图标是「关」'
Eq 'X5' (Get-ToggleDirection -State $allOff.State) 'mount' '全部脱机时点总开关 = 全部接入'
if ((Get-MasterDescription -State $allOff) -like '*全部脱机*') { Ok 'X6' '全部脱机描述正确' }
else { No 'X6' '全部脱机描述不对' (Get-MasterDescription -State $allOff) }
# ---------- 9) 唤醒哨兵（纯函数，不碰真实磁盘） ----------
Write-Host ''
Write-Host '9) 唤醒哨兵' -ForegroundColor White

$tmp = Join-Path $env:TEMP ('dsh-wake-' + (Get-Random))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

# 9.1 快照读写往返
$snap = @{}
$snap['SN-A'] = [pscustomobject]@{ label = 'A 盘'; state = 'off'; startStop = 100; loadUnload = 200; powerOnHours = 300; at = '2026-01-01 00:00:00' }
Write-DiskState -LogDir $tmp -Map $snap
$back = Read-DiskState -LogDir $tmp
if ($back.ContainsKey('SN-A') -and [int]$back['SN-A'].startStop -eq 100) { Ok 'W1' '快照读写往返正常' }
else { No 'W1' '快照读写失败' ($back | ConvertTo-Json -Depth 4 -Compress) }

# 9.2 首次运行（没有上次快照）→ 不告警
$cur = [pscustomobject]@{ Ok = $true; PowerOnHours = 300; StartStop = 102; LoadUnload = 205 }
Eq 'W2' (Compare-DiskSnapshot -Prev $null -Cur $cur) $null '首次运行不告警'

# 9.3 上次不是脱机 → 不告警
$prevOn = [pscustomobject]@{ state = 'on'; startStop = 100; loadUnload = 200; powerOnHours = 300; at = (Get-Date).AddHours(-2).ToString('yyyy-MM-dd HH:mm:ss') }
Eq 'W3' (Compare-DiskSnapshot -Prev $prevOn -Cur $cur) $null '上次在线时不判定'

# 9.4 不设最短间隔：哪怕只过 2 分钟，只要增量达到阈值也判定
$prevFresh = [pscustomobject]@{ state = 'off'; startStop = 100; loadUnload = 200; powerOnHours = 300; at = (Get-Date).AddMinutes(-2).ToString('yyyy-MM-dd HH:mm:ss') }
$n0 = Compare-DiskSnapshot -Prev $prevFresh -Cur $cur
if ($n0 -and $n0.StartStopDelta -eq 2) { Ok 'W4' '间隔很短也照样判定（无最短间隔限制）' }
else { No 'W4' '短间隔没有被判定' ($n0 | ConvertTo-Json -Compress) }

# 9.5 计数没变 → 不告警
$prevOff = [pscustomobject]@{ state = 'off'; startStop = 102; loadUnload = 205; powerOnHours = 300; at = (Get-Date).AddHours(-2).ToString('yyyy-MM-dd HH:mm:ss') }
Eq 'W5' (Compare-DiskSnapshot -Prev $prevOff -Cur $cur) $null '计数没变不告警'

# 9.6 启停 +2 → 告警
$prevLow = [pscustomobject]@{ state = 'off'; startStop = 100; loadUnload = 205; powerOnHours = 300; at = (Get-Date).AddHours(-2).ToString('yyyy-MM-dd HH:mm:ss') }
$n = Compare-DiskSnapshot -Prev $prevLow -Cur $cur
if ($n -and $n.StartStopDelta -eq 2 -and $n.PrevStartStop -eq 100 -and $n.CurStartStop -eq 102) { Ok 'W6' '启停增加时给出明细' }
else { No 'W6' '启停增加没被判出来' ($n | ConvertTo-Json -Compress) }

# 9.7 只有磁头加载增加 → 也告警
$prevLoad = [pscustomobject]@{ state = 'off'; startStop = 102; loadUnload = 200; powerOnHours = 300; at = (Get-Date).AddHours(-2).ToString('yyyy-MM-dd HH:mm:ss') }
$n2 = Compare-DiskSnapshot -Prev $prevLoad -Cur $cur
if ($n2 -and $n2.LoadDelta -eq 5) { Ok 'W7' '只有磁头加载增加也会告警' }
else { No 'W7' '磁头加载增加没被判出来' ($n2 | ConvertTo-Json -Compress) }

# 9.8 读不到 SMART → 不告警（否则会误报）
$curBad = [pscustomobject]@{ Ok = $false; PowerOnHours = 0; StartStop = 0; LoadUnload = 0 }
Eq 'W8' (Compare-DiskSnapshot -Prev $prevLow -Cur $curBad) $null 'SMART 读不到时不告警'

# 9.9 快照文件损坏 → 读成空表，不抛异常
Set-Content -Path (Join-Path $tmp 'disk-state.json') -Value '{ 这不是 json' -Encoding UTF8
$broken = Read-DiskState -LogDir $tmp
if ($broken.Count -eq 0) { Ok 'W9' '快照损坏时安全降级' } else { No 'W9' '损坏快照没被忽略' '' }

# 9.10 只 +1 次（我们自己读 SMART 造成的）→ 不报警
$prevOne = [pscustomobject]@{ state = 'off'; startStop = 100; loadUnload = 200; powerOnHours = 300; at = (Get-Date).AddHours(-2).ToString('yyyy-MM-dd HH:mm:ss') }
$curOne = [pscustomobject]@{ Ok = $true; StartStop = 101; LoadUnload = 201; PowerOnHours = 300 }
Eq 'W10' (Compare-DiskSnapshot -Prev $prevOne -Cur $curOne) $null '只 +1（自身唤醒）不报警'

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

# ---------- 汇总 ----------
Write-Host ''
Write-Host '=== 逻辑测试结果 ===' -ForegroundColor Cyan
Write-Host ("  通过 {0}　失败 {1}" -f $pass, $fail) -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { $fails | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red } }
Write-Host ''
exit $(if ($fail -eq 0) { 0 } else { 1 })
