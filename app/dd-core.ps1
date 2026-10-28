# dd-core.ps1 —— 共用逻辑，由各入口脚本点引用
# 设计要点：每块盘独立 try/catch，一块出问题（包括根本没插）绝不影响另一块。
# 要管理哪些盘由 config.json 决定（由 setup.ps1 生成）。

$script:AppDir     = $PSScriptRoot
# 脚本放在 app\ 子目录时，根目录在上一级；放在根目录时直接用 PSScriptRoot
$script:Root       = if ((Split-Path $PSScriptRoot -Leaf) -eq 'app') { Split-Path $PSScriptRoot -Parent } else { $PSScriptRoot }
$script:ConfigPath = Join-Path $script:Root 'config.json'


# ---- 目标磁盘：从 config.json 读取（由 setup.ps1 生成） ----
$script:Targets    = @()
$script:MasterName = '硬盘开关'
$script:ConfigOk   = $false

if (Test-Path $script:ConfigPath) {
    try {
        $cfg = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.masterName) { $script:MasterName = [string]$cfg.masterName }
        foreach ($d in @($cfg.disks)) {
            if (-not $d.serial) { continue }
            $script:Targets += @{
                Key       = [string]$d.name
                Label     = [string]$d.name
                Desc      = [string]$d.desc
                Serial    = [string]$d.serial
                BusExpect = [string]$d.bus
                WaitTicks = $(if ($d.waitTicks) { [int]$d.waitTicks } else { 60 })
            }
        }
        if ($script:Targets.Count -gt 0) { $script:ConfigOk = $true }
    } catch {
        $script:ConfigOk = $false
    }
}

function Assert-Configured {
    # 没配置就别乱动磁盘，直接告诉用户去跑 setup
    if ($script:ConfigOk) { return }
    Write-Host ''
    Write-Host '  还没有配置要管理哪些磁盘。' -ForegroundColor Yellow
    Write-Host '  请先运行：' -ForegroundColor Gray
    Write-Host '     双击 setup.cmd    （或右键 install.cmd → 以管理员身份运行）' -ForegroundColor White
    Write-Host ''
    Start-Sleep -Seconds 6
    exit 1
}

function New-Result($t) {
    [pscustomobject]@{ 磁盘 = $t.Label; 设备 = $t.Desc; 结果 = ''; 说明 = ''; 健康 = '' }
}

function Get-SmartInfo {
    # 读一块盘的 SMART 摘要。需要管理员权限，USB 桥接可能读不到。
    param([int]$Number)
    try {
        $pd = Get-PhysicalDisk -ErrorAction Stop |
              Where-Object { [string]$_.DeviceId -eq [string]$Number } | Select-Object -First 1
        if (-not $pd) { return '读不到' }
        $c = $pd | Get-StorageReliabilityCounter -ErrorAction Stop
        if (-not $c) { return '读不到' }
        $parts = @()
        if ($c.PowerOnHours -gt 0)        { $parts += ('通电 {0:N0}h' -f $c.PowerOnHours) }
        if ($c.StartStopCycleCount -gt 0) { $parts += ('启停 {0:N0}' -f $c.StartStopCycleCount) }
        if ($c.Temperature -gt 0)         { $parts += ('{0}°C' -f $c.Temperature) }
        if ($parts.Count -eq 0) { return '无数据' }
        return ($parts -join ' / ')
    } catch {
        return '读不到'
    }
}

# ---- 脱机期间的唤醒哨兵 ----
# 思路：每次操作前后各记一次 SMART 累计值（启停次数 / 磁头加载次数 / 通电小时）。
# 如果上一次快照是「脱机」，而这次读到计数变大了，说明脱机期间盘被唤醒过。
#
# 注意：这只能说明「盘停转后又转起来了」，不能断言「被读了 N 次」——
# 盘自己按 APM 定时器停转、再被唤醒，计数同样会 +1。所以文案一律写「疑似被唤醒」，
# 并且把三个数一起记下来，让人自己判断。

function Get-SmartCounters {
    # 取一块盘的 SMART 累计值。需要管理员权限；USB 桥接可能读不到。
    param([int]$Number)
    try {
        $pd = Get-PhysicalDisk -ErrorAction Stop |
              Where-Object { [string]$_.DeviceId -eq [string]$Number } | Select-Object -First 1
        if (-not $pd) { return $null }
        $c = $pd | Get-StorageReliabilityCounter -ErrorAction Stop
        if (-not $c) { return $null }
        return [pscustomobject]@{
            Ok           = $true
            PowerOnHours = [int]($c.PowerOnHours)
            StartStop    = [int]($c.StartStopCycleCount)
            LoadUnload   = [int]($c.LoadUnloadCycleCount)
        }
    } catch {
        return $null
    }
}

function Read-DiskState {
    # 读快照文件，返回 hashtable（序列号 → 快照）。文件不存在或坏掉就返回空表。
    param([string]$LogDir)
    $map = @{}
    if (-not $LogDir) { return $map }
    $file = Join-Path $LogDir 'disk-state.json'
    if (-not (Test-Path $file)) { return $map }
    try {
        $j = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $j.disks.PSObject.Properties) { $map[$p.Name] = $p.Value }
    } catch { }
    return $map
}

function Write-DiskState {
    # 原子写：先写 .tmp 再替换，避免中途断电把快照写坏
    param([string]$LogDir, $Map)
    if (-not $LogDir) { return }
    try {
        if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        $obj = [ordered]@{ version = 1; disks = $Map }
        $json = $obj | ConvertTo-Json -Depth 8
        $file = Join-Path $LogDir 'disk-state.json'
        $tmp  = $file + '.tmp'
        [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
        Move-Item $tmp $file -Force
    } catch { }
}

function Compare-DiskSnapshot {
    # 纯函数：给上次快照和本次读数，判断脱机期间是否疑似被唤醒。
    # 返回 $null 表示没有异常（或数据不足，不该报警）。
    # 注意：不设最短间隔——只要上次快照是脱机，期间的计数增加就参与判断。
    # 但读 SMART 这个动作本身会把停转的盘唤醒（+1 次），那一次是我们自己造成的，
    # 所以默认要求增量 >= 2 才报警（见 $MinDelta）。
    param(
        $Prev,          # 上次快照（含 state / startStop / loadUnload / powerOnHours / at）
        $Cur,           # 本次读数（Get-SmartCounters 的结果）
        [datetime]$Now = (Get-Date),
        [int]$MinDelta = 2   # 我们读 SMART 本身会造成 1 次唤醒，所以要 >=2 才报警
    )
    if (-not $Prev -or -not $Cur) { return $null }
    if (-not $Cur.Ok) { return $null }
    if ([string]$Prev.state -ne 'off') { return $null }   # 上次不是脱机，谈不上"脱机期间"

    $prevAt = $null
    try { $prevAt = [datetime]::Parse([string]$Prev.at) } catch { }
    if (-not $prevAt) { return $null }

    $mins = ($Now - $prevAt).TotalMinutes

    $dStop  = [int]$Cur.StartStop    - [int]$Prev.startStop
    $dLoad  = [int]$Cur.LoadUnload   - [int]$Prev.loadUnload
    $dHours = [int]$Cur.PowerOnHours - [int]$Prev.powerOnHours

    if ($dStop -le 0 -and $dLoad -le 0) { return $null }   # 没有变化

    # 读 SMART 本身会唤醒停转的盘（+1 次），那一次是我们自己造成的，
    # 只有超过这个自行造成的增量才说明"脱机期间确实被别的动作碰过"。
    if ($dStop -lt $MinDelta -and $dLoad -lt $MinDelta) { return $null }

    return [pscustomobject]@{
        OfflineMinutes = [int]$mins
        StartStopDelta = $dStop
        LoadDelta      = $dLoad
        HoursDelta     = $dHours
        PrevStartStop  = [int]$Prev.startStop
        CurStartStop   = [int]$Cur.StartStop
    }
}

function Format-OfflineSpan {
    # 把分钟数说成人话：< 60 分钟用分钟，否则用小时
    param([int]$Minutes)
    if ($Minutes -lt 60) { return "$Minutes 分钟" }
    $h = [math]::Round($Minutes / 60.0, 1)
    if ($h -eq [math]::Floor($h)) { return ('{0:N0} 小时' -f $h) }
    return "$h 小时"
}
function Get-OfflineWakeups {
    # 在操作**开始前**调用：检查上次快照（脱机）到现在的计数变化，报告疑似唤醒。
    # 命中时写 steps.csv（阶段=唤醒/WARN）与 logs\wakeups.csv，并返回明细数组。
    param($Targets, [string]$LogDir)

    $found = @()
    if (-not $LogDir) { return $found }
    $map = Read-DiskState -LogDir $LogDir
    if ($map.Count -eq 0) { return $found }

    foreach ($t in @($Targets)) {
        $disk = $null
        try { $disk = Get-TargetDisk $t } catch { }
        if (-not $disk) { continue }

        $serial = ([string]$t.Serial).Trim()
        if (-not $map.ContainsKey($serial)) { continue }
        $prev = $map[$serial]

        $cur = Get-SmartCounters -Number $disk.Number
        if (-not $cur) {
            Write-StepLog -Disk $t.Label -Stage '唤醒' -Status 'INFO' -Detail 'SMART 累计值读不到，跳过唤醒检查'
            continue
        }

        $cmp = Compare-DiskSnapshot -Prev $prev -Cur $cur -Now (Get-Date)
        if (-not $cmp) { continue }

        $span = Format-OfflineSpan -Minutes $cmp.OfflineMinutes
        $detail = ('脱机 {0}，期间启停 +{1}（{2:N0}→{3:N0}）、磁头加载 +{4}、通电 +{5}h' -f `
                   $span, $cmp.StartStopDelta, $cmp.PrevStartStop, $cmp.CurStartStop,
                   $cmp.LoadDelta, $cmp.HoursDelta)
        Write-StepLog -Disk $t.Label -Stage '唤醒' -Status 'WARN' -Detail $detail

        # 事件明细表
        try {
            $wakeFile = Join-Path $LogDir 'wakeups.csv'
            $needHead = -not (Test-Path $wakeFile)
            [pscustomobject]@{
                时间           = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                磁盘           = $t.Label
                脱机时长分钟   = $cmp.OfflineMinutes
                启停增量       = $cmp.StartStopDelta
                磁头加载增量   = $cmp.LoadDelta
                通电小时增量   = $cmp.HoursDelta
            } | Export-Csv -Path $wakeFile -Append -NoTypeInformation -Encoding UTF8 -Force:$false
        } catch { }

        $found += [pscustomobject]@{
            Label           = $t.Label
            OfflineMinutes  = $cmp.OfflineMinutes
            OfflineText     = $span
            StartStopDelta  = $cmp.StartStopDelta
            PrevStartStop   = $cmp.PrevStartStop
            CurStartStop    = $cmp.CurStartStop
            LoadDelta       = $cmp.LoadDelta
        }
    }
    return $found
}

function Save-DiskState {
    # 在操作**结束后**调用：把每块盘的当前状态与累计值写成新快照。
    param($Targets, [string]$LogDir)
    if (-not $LogDir) { return }
    $map = Read-DiskState -LogDir $LogDir
    foreach ($t in @($Targets)) {
        $disk = $null
        try { $disk = Get-TargetDisk $t } catch { }
        if (-not $disk) { continue }
        $cur = Get-SmartCounters -Number $disk.Number
        if (-not $cur) { continue }
        $serial = ([string]$t.Serial).Trim()
        $map[$serial] = [pscustomobject]@{
            label        = $t.Label
            state        = $(if ($disk.IsOffline) { 'off' } else { 'on' })
            startStop    = $cur.StartStop
            loadUnload   = $cur.LoadUnload
            powerOnHours = $cur.PowerOnHours
            at           = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        }
    }
    Write-DiskState -LogDir $LogDir -Map $map
}

function Write-ActionLog {
    # 追加一行操作记录；文件超过 1 MB 自动轮转，只保留一份备份。
    param([string]$LogDir, [string]$Action, [array]$Rows, [double]$Seconds)
    try {
        if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        $file = Join-Path $LogDir 'actions.csv'

        if ((Test-Path $file) -and ((Get-Item $file).Length -gt 1MB)) {
            $bak = Join-Path $LogDir 'actions.1.csv'
            if (Test-Path $bak) { Remove-Item $bak -Force }
            Move-Item $file $bak -Force
        }

        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $Rows | Select-Object @{n = '时间'; e = { $stamp } },
                               @{n = '操作'; e = { $Action } },
                               @{n = '磁盘'; e = { $_.磁盘 } },
                               @{n = '结果'; e = { $_.结果 } },
                               @{n = '说明'; e = { $_.说明 } },
                               @{n = '健康'; e = { $_.健康 } },
                               @{n = '本次耗时秒'; e = { [math]::Round($Seconds, 1) } } |
                Export-Csv -Path $file -Append -NoTypeInformation -Encoding UTF8
    } catch { }
}

function Get-TargetDisk {
    param($t)
    $key = ([string]$t.Serial).Trim()
                $found = @(Get-Disk | Where-Object { ([string]$_.SerialNumber).Trim() -eq $key })
    if ($found.Count -eq 0) { return $null }
    if ($found.Count -gt 1) { throw "序列号匹配到 $($found.Count) 块盘，已中止" }
    $disk = $found[0]
    if ($disk.IsBoot -or $disk.IsSystem) { throw "这块盘是启动盘/系统盘，拒绝操作" }
    if ($disk.BusType -ne $t.BusExpect) { throw "总线类型是 $($disk.BusType)（期望 $($t.BusExpect)），可能是序列号冲突" }
    return $disk
}

function Get-DiskLetter {
    param([int]$Number)
    $p = Get-Partition -DiskNumber $Number -ErrorAction SilentlyContinue |
         Where-Object { $_.DriveLetter } | Select-Object -First 1
    if ($p) { return [string]$p.DriveLetter }
    return $null
}

function Get-DiskIO {
    param([int]$Number)
    $reads = 0.0; $writes = 0.0
    try {
        $s = Get-Counter -Counter '\PhysicalDisk(*)\Disk Reads/sec', '\PhysicalDisk(*)\Disk Write Bytes/sec' `
                         -SampleInterval 1 -MaxSamples 2 -ErrorAction Stop
        foreach ($set in $s) {
            foreach ($cs in $set.CounterSamples) {
                if ($cs.InstanceName -match ("^\s*" + [string]$Number + "\s")) {
                    if ($cs.Path -match 'Reads') { $reads += $cs.CookedValue } else { $writes += $cs.CookedValue }
                }
            }
        }
    } catch { }
    [pscustomobject]@{ Reads = [math]::Round($reads / 2, 1); Writes = [math]::Round($writes / 2, 0); Ok = ($reads + $writes) -gt -1 }
}

function Get-DiskIOAll {
    # 一次采样，同时拿到所有物理盘的读写速率 —— 多块盘共用一个 2 秒窗口，
    # 不用一块一块排队等。DiskList 只是保留参数（采样本来就覆盖全部物理盘）。
    param($DiskList = $null)
    $map = @{}
    try {
        $s = Get-Counter -Counter '\PhysicalDisk(*)\Disk Reads/sec', '\PhysicalDisk(*)\Disk Write Bytes/sec' `
                         -SampleInterval 1 -MaxSamples 2 -ErrorAction Stop
        $acc = @{}
        foreach ($set in $s) {
            foreach ($cs in $set.CounterSamples) {
                if ($cs.InstanceName -match '^\s*(\d+)\s') {
                    $n = [int]$Matches[1]
                    if (-not $acc.ContainsKey($n)) { $acc[$n] = @{ R = 0.0; W = 0.0 } }
                    if ($cs.Path -match 'Reads') { $acc[$n]['R'] += $cs.CookedValue } else { $acc[$n]['W'] += $cs.CookedValue }
                }
            }
        }
        foreach ($k in @($acc.Keys)) {
            $map[$k] = [pscustomobject]@{
                Reads  = [math]::Round($acc[$k]['R'] / 2, 1)
                Writes = [math]::Round($acc[$k]['W'] / 2, 0)
            }
        }
    } catch { }
    return $map
}

function Enable-UsbSuspend {
    param([int]$Number)
    # USB 硬盘盒不会因为"脱机"断电；只有允许系统挂起该设备，盒子才可能让盘停转。
    $dd = Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue |
          Where-Object { $_.Index -eq $Number } | Select-Object -First 1
    if (-not $dd) { return '找不到磁盘设备' }
    $parent = (Get-PnpDeviceProperty -InstanceId $dd.PNPDeviceID -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue).Data
    if (-not $parent) { return '找不到 USB 父设备' }
    $items = @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue |
               Where-Object { $_.InstanceName -like ($parent + '*') })
    if ($items.Count -eq 0) { return '驱动不支持电源管理项' }
    $changed = 0
    foreach ($x in $items) {
        if (-not $x.Enable) {
            Set-CimInstance -InputObject $x -Property @{ Enable = $true } -ErrorAction Stop
            $changed++
        }
    }
    if ($changed -gt 0) { return '已开启 USB 省电挂起（停转的关键）' }
    return 'USB 省电挂起本来就是开的'
}

function Open-ThisPC {
    # 打开「此电脑」；如果已经开着，就把它切到前台，而不是再开一个窗口。
    # 用 Win32 枚举窗口标题，而不是 Shell COM —— Win11 多标签资源管理器下
    # COM 的 Name/LocationURL 全都拿不到「此电脑」，只有窗口标题里带着它。
    try {
        if (-not ('DDWin' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class DDWin {
    private delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr lp);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] private static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

    public static long[] Find(string cls, string titlePart) {
        var hits = new List<long>();
        EnumWindows((h, l) => {
            var cn = new StringBuilder(256); GetClassNameW(h, cn, 256);
            if (cn.ToString() == cls) {
                var t = new StringBuilder(512); GetWindowTextW(h, t, 512);
                if (t.ToString().IndexOf(titlePart, StringComparison.OrdinalIgnoreCase) >= 0)
                    hits.Add(h.ToInt64());
            }
            return true;
        }, IntPtr.Zero);
        return hits.ToArray();
    }

    public static void Activate(long hwnd) {
        IntPtr h = new IntPtr(hwnd);
        ShowWindow(h, 9);          // SW_RESTORE：最小化的也能还原

        // 脚本进程此刻不在前台，Windows 会忽略 SetForegroundWindow。
        // 把本线程挂到当前前台窗口的输入队列上，再抢前台就有效了。
        uint pid;
        uint fg = GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        uint me = GetCurrentThreadId();
        bool attached = false;
        if (fg != 0 && fg != me) { attached = AttachThreadInput(me, fg, true); }
        try {
            BringWindowToTop(h);
            SetForegroundWindow(h);
        } finally {
            if (attached) { AttachThreadInput(me, fg, false); }
        }
    }
}
'@
        }

        $hit = $null
        foreach ($t in @('此电脑', 'This PC')) {
            $found = [DDWin]::Find('CabinetWClass', $t)
            if ($found -and $found.Count -gt 0) { $hit = $found[0]; break }
        }

        if ($hit) {
            [DDWin]::Activate($hit)
            return '已把「此电脑」切到前台'
        }

        Start-Process explorer.exe -ArgumentList 'shell:MyComputerFolder'
        # 新开的窗口也不一定抢到前台，等一下再切一次
        Start-Sleep -Milliseconds 900
        foreach ($t in @('此电脑', 'This PC')) {
            $found = [DDWin]::Find('CabinetWClass', $t)
            if ($found -and $found.Count -gt 0) {
                [DDWin]::Activate($found[0])
                return '已打开「此电脑」'
            }
        }
        return '已打开「此电脑」'
    } catch {
        try { Start-Process explorer.exe -ArgumentList 'shell:MyComputerFolder' } catch { }
        return '已打开「此电脑」'
    }
}

function Mount-Target {
    param($t, [switch]$DryRun, [scriptblock]$Progress)
    $r = New-Result $t
    try {
        $disk = Get-TargetDisk $t
        if (-not $disk) {
            $r.结果 = '未连接'
            $r.说明 = '没插上，已跳过（不影响其他盘）'
            Write-StepLog -Disk $t.Label -Stage '定位' -Status 'SKIP' -Detail '没有连接（可能没插）'
            return $r
        }
        Write-StepLog -Disk $t.Label -Stage '定位' -Status 'OK' -Detail ("Disk {0} {1}，脱机={2}" -f $disk.Number, $disk.FriendlyName, $disk.IsOffline)

        $wasOffline = $disk.IsOffline
        if ($wasOffline) {
            if ($DryRun) {
                # 演练不真的联机，所以也不该去等盘符
                $r.结果 = '（演练）将联机'
                $r.说明 = '当前是脱机状态'
                return $r
            }
            if ($Progress) { & $Progress ("正在给 $($t.Label) 通电联机…") }
            Write-Host ("  [{0}] 联机中，盘要转起来..." -f $t.Label) -ForegroundColor Yellow
            Set-Disk -Number $disk.Number -IsOffline $false
            Update-HostStorageCache -ErrorAction SilentlyContinue
            Write-StepLog -Disk $t.Label -Stage '联机' -Status 'OK' -Detail 'Set-Disk -IsOffline false'
        }

        if ($Progress) { & $Progress ("等待 $($t.Label) 分配盘符…") }
        if ($wasOffline -and -not $DryRun) { Write-Host ("  [{0}] 等系统分配盘符..." -f $t.Label) -ForegroundColor Yellow }
        $letter = $null
        for ($i = 0; $i -lt $t.WaitTicks; $i++) {
            $letter = Get-DiskLetter $disk.Number
            if ($letter) { break }
            Start-Sleep -Milliseconds 500
        }
        if (-not $letter) {
            $r.结果 = '失败'
            $r.说明 = '已联机，但系统没分配盘符'
            Write-StepLog -Disk $t.Label -Stage '等盘符' -Status 'FAIL' -Detail ("轮询 {0} 次仍无盘符" -f $t.WaitTicks)
            return $r
        }
        Write-StepLog -Disk $t.Label -Stage '等盘符' -Status 'OK' -Detail ($letter + ':')

        if ($wasOffline -and -not $DryRun) {
            if ($Progress) { & $Progress ("读取 $($t.Label) 健康信息…") }
            Write-Host ("  [{0}] 读健康信息..." -f $t.Label) -ForegroundColor DarkGray
            $r.健康 = Get-SmartInfo -Number $disk.Number
            Write-StepLog -Disk $t.Label -Stage 'SMART' -Status 'INFO' -Detail $r.健康
        }

        $r.结果 = if ($wasOffline) { '已挂载' } else { '本来就在线' }
        $r.说明 = $letter + ':\'
        Write-StepLog -Disk $t.Label -Stage '完成' -Status 'OK' -Detail $r.结果
        # 不自动弹资源管理器：挂载只负责把盘带回来，窗口你自己开（避免一次蹦出两个）
    } catch {
        $r.结果 = '失败'
        $r.说明 = $_.Exception.Message
    }
    return $r
}

function Unmount-Target {
    param($t, [switch]$Force, [switch]$DryRun, $IO, [scriptblock]$Progress)
    $r = New-Result $t
    try {
        $disk = Get-TargetDisk $t
        if (-not $disk) {
            $r.结果 = '未连接'
            $r.说明 = '没插上，已跳过（不影响其他盘）'
            Write-StepLog -Disk $t.Label -Stage '定位' -Status 'SKIP' -Detail '没有连接（可能没插）'
            return $r
        }
        if ($disk.IsOffline) {
            $r.结果 = '本来已脱机'
            $r.说明 = '无需操作'
            Write-StepLog -Disk $t.Label -Stage '定位' -Status 'SKIP' -Detail '本来就是脱机状态'
            return $r
        }
        Write-StepLog -Disk $t.Label -Stage '定位' -Status 'OK' -Detail ("Disk {0} {1}" -f $disk.Number, $disk.FriendlyName)

        $letter = Get-DiskLetter $disk.Number
        $root = if ($letter) { $letter + ':\' } else { $null }

        if ($Progress) { & $Progress ("检查 $($t.Label) 的窗口与占用…") }
        Write-Host ("  [{0}] 检查窗口和占用..." -f $t.Label) -ForegroundColor Yellow

        # 1. 关掉指向这个盘的资源管理器窗口
        $closed = Close-DriveWindows -Letter $letter
        Write-StepLog -Disk $t.Label -Stage '关窗口' -Status 'OK' -Detail ("关闭了 {0} 个指向 {1}: 的资源管理器窗口" -f $closed, $letter)

        # 2. 有没有程序从这个盘跑
        if ($root) {
            $procs = @(Get-DriveProcesses -Root $root)
            if ($procs.Count -gt 0 -and -not $Force) {
                $r.结果 = '跳过'
                $r.说明 = '有程序正从它运行：' + (($procs | Select-Object -ExpandProperty ProcessName -Unique) -join ', ')
                Write-StepLog -Disk $t.Label -Stage '查占用' -Status 'SKIP' -Detail $r.说明
                return $r
            }
            Write-StepLog -Disk $t.Label -Stage '查占用' -Status 'OK' -Detail '没有程序从这块盘运行'
        }

        # 3. I/O —— 如果调用方已经统一采过样，就直接用那份数据
        if ($IO -and $IO.ContainsKey([int]$disk.Number)) {
            $io = $IO[[int]$disk.Number]
        } else {
            if ($Progress) { & $Progress ("采样 $($t.Label) 读写（2 秒）…") }
            Write-Host ("  [{0}] 采样读写 2 秒..." -f $t.Label) -ForegroundColor DarkGray
            $io = Get-DiskIO -Number $disk.Number
        }
        # 只有「写」才拦。读不影响安全性：脱机不会损坏正在被读的文件，
        # 最多让那个读取者报错；而刚挂载时系统扫描/缩略图会产生上千次读，
        # 按读拦截会导致「第一次只卸掉一个盘」。
        # 阈值 64 KB/s：系统元数据噪声通常 2~8 KB/s，真正的文件写入是 MB/s 级。
        if (($io.Writes -gt 65536) -and -not $Force) {
            $r.结果 = '跳过'
            $r.说明 = ("正在写入（{0} 字节/秒，超过 64 KB/s 阈值），等它写完" -f $io.Writes)
            Write-StepLog -Disk $t.Label -Stage '采样' -Status 'SKIP' -Detail $r.说明
            return $r
        }
        Write-StepLog -Disk $t.Label -Stage '采样' -Status 'OK' -Detail ("读 {0}/秒，写 {1} 字节/秒（写入阈值 64 KB/s）" -f $io.Reads, $io.Writes)

        # 3.5 演练到这里就停（不写任何设置）
        if ($DryRun) {
            $r.结果 = '（演练）将脱机'
            $r.说明 = if ($closed -gt 0) { "会先关掉 $closed 个窗口" } else { '无窗口占用' }
            return $r
        }

        # 4. USB 盘：先允许系统挂起它
        $usbNote = ''
        if ($t.BusExpect -eq 'USB') {
            if ($Progress) { & $Progress ("允许系统挂起 $($t.Label)…") }
            try { $usbNote = Enable-UsbSuspend -Number $disk.Number }
            catch { $usbNote = '开启 USB 省电挂起失败：' + $_.Exception.Message }
            Write-StepLog -Disk $t.Label -Stage 'USB挂起' -Status 'INFO' -Detail $usbNote
        }

        # 5. 刷缓存 + 脱机
        if ($Progress) { & $Progress ("刷写缓存并把 $($t.Label) 脱机…") }
        Write-Host ("  [{0}] 刷写缓存并脱机..." -f $t.Label) -ForegroundColor Yellow
        if ($root -and (Test-Path $root)) {
            Write-VolumeCache -DriveLetter $letter -ErrorAction SilentlyContinue
        }
        Set-Disk -Number $disk.Number -IsOffline $true
        Write-StepLog -Disk $t.Label -Stage '脱机' -Status 'OK' -Detail 'Set-Disk -IsOffline true 已下达'

        # 轮询确认脱机：通常 0.2 秒就好了，不必死等 1 秒
        if ($Progress) { & $Progress ("复查 $($t.Label) 是否已脱机…") }
        $after = $null
        for ($i = 0; $i -lt 20; $i++) {
            $after = Get-TargetDisk $t
            if ($after -and $after.IsOffline) { break }
            Start-Sleep -Milliseconds 100
        }
        if (-not $after -or -not $after.IsOffline) {
            $r.结果 = '失败'
            $r.说明 = '脱机没生效，可能还有程序占着'
            Write-StepLog -Disk $t.Label -Stage '复查' -Status 'FAIL' -Detail '轮询后仍未脱机'
            return $r
        }
        Write-StepLog -Disk $t.Label -Stage '复查' -Status 'OK' -Detail ("已确认脱机，盘符存在={0}" -f (Test-Path $root))
        if ($root -and (Test-Path $root)) {
            for ($i = 0; $i -lt 10 -and (Test-Path $root); $i++) { Start-Sleep -Milliseconds 100 }
            if (Test-Path $root) {
                $r.结果 = '失败'
                $r.说明 = '盘符还在，有进程占用'
                return $r
            }
        }

        $r.结果 = '已卸载'
        $r.说明 = (@($usbNote) | Where-Object { $_ }) -join '; '
        Write-StepLog -Disk $t.Label -Stage '完成' -Status 'OK' -Detail $r.结果
    } catch {
        $r.结果 = '失败'
        $r.说明 = $_.Exception.Message
    }
    return $r
}

function Get-SystemState {
    # 汇总目标盘的状态；不传 DiskList 就是全部配置的盘。
    # 规则：只要有一块在线就算「已挂载」（on），否则算「已卸载」（off）。
    param($DiskList = $null)
    $list = if ($DiskList) { @($DiskList) } else { $Targets }
    $on = 0; $off = 0; $absent = 0
    $detail = @()
    foreach ($t in $list) {
        $disk = $null
        try { $disk = Get-TargetDisk $t } catch { }
        if (-not $disk) {
            $absent++
            $detail += "$($t.Label)=未连接"
            continue
        }
        if ($disk.IsOffline) {
            $off++
            $detail += "$($t.Label)=脱机"
        } else {
            $on++
            $detail += "$($t.Label)=在线"
        }
    }
    $state = if ($on -gt 0) { 'on' } else { 'off' }
    [pscustomobject]@{
        State   = $state
        Online  = $on
        Offline = $off
        Absent  = $absent
        Detail  = ($detail -join ' / ')
    }
}

function Get-ShortcutCandidates {
    # 同一个快捷方式可能在桌面，也可能在开始菜单（或两处都有），全部返回
    param([string]$BaseName)
    @(
        (Join-Path ([Environment]::GetFolderPath('Desktop')) ($BaseName + '.lnk')),
        (Join-Path $env:APPDATA ('Microsoft\Windows\Start Menu\Programs\' + $BaseName + '.lnk'))
    )
}

function Update-ShortcutIcon {
    # 通用：把一组快捷方式的图标和描述改成指定值（谁存在改谁）
    param(
        [string[]]$LnkPath,
        [string]$IconPath,
        [string]$Description
    )
    try {
        if (-not (Test-Path $IconPath)) { return "找不到图标 $IconPath" }
        $ws = New-Object -ComObject WScript.Shell
        $done = @()
        foreach ($p in @($LnkPath)) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            if (-not (Test-Path $p)) { continue }
            $lnk = $ws.CreateShortcut($p)
            $lnk.IconLocation = $IconPath + ',0'
            $lnk.Description = $Description
            $lnk.Save()
            $done += (Split-Path $p -Parent | Split-Path -Leaf)
        }
        if ($done.Count -eq 0) { return '没找到快捷方式，已跳过' }
        return "图标/描述已更新（$([System.IO.Path]::GetFileName($IconPath)) → $($done -join ' / ')）"
    } catch {
        return "更新快捷方式失败：$($_.Exception.Message)"
    }
}

function Get-MasterDescription {
    # 总开关的悬停描述：说清当前状态，以及点下去会发生什么
    param($State)
    $on = [int]$State.Online
    $off = [int]$State.Offline
    $absent = [int]$State.Absent
    $total = $on + $off + $absent
    $suffix = if ($State.State -eq 'on') { '点击将全部断开' } else { '点击将全部接入' }

    if ($on -eq $total -and $total -gt 0) { return "当前：全部在线 · $suffix" }
    if ($on -eq 0 -and $off -gt 0 -and $absent -eq 0) { return "当前：全部脱机 · $suffix" }
    if ($on -eq 0 -and $off -eq 0) { return "当前：未连接 · $suffix" }

    $part = "$on 在线 / $off 脱机"
    if ($absent -gt 0) { $part += " / $absent 未连接" }
    return "当前：$part · $suffix"
}
function Update-ToggleShortcut {
    # 总开关：按当前状态切换图标和描述
    # $State 可以是 'on'/'off'，也可以是 Get-SystemState 返回的对象（带计数）
    param(
        $State,
        [string[]]$LnkPath,
        [string]$IconDir
    )
    if ($State -is [string]) {
        $s = $State
        $desc = if ($s -eq 'on') { '当前：已挂载 · 点击将断开' } else { '当前：已卸载 · 点击将接入' }
    } else {
        $s = $State.State
        $desc = Get-MasterDescription -State $State
    }
    $icon = Get-IconPath $IconDir (Get-MasterIconName $s)
    return Update-ShortcutIcon -LnkPath $LnkPath -IconPath $icon -Description $desc
}

function Update-DiskShortcut {
    # 单盘开关：图标按「当前盘符 + 状态」选，盘符变了也能自动跟上
    param(
        [string]$State,      # on / off
        [string]$Letter,     # 盘符字母，如 D
        [string]$Name,       # 显示名，如 "D 盘"
        [string]$IconDir
    )
    try {
        $base = "$($script:MasterName) - $Name"
        $upper = if ($Letter) { $Letter.ToUpper() } else { '' }
        $icon = Get-IconPath $IconDir (Get-DiskIconName -State $State -Letter $upper)
        if (-not (Test-Path $icon)) { $icon = Get-IconPath $IconDir (Get-MasterIconName $State) }
        $tag = if ($upper) { "$upper`: 盘" } else { $Name }
        $desc = if ($State -eq 'on') { "当前：已挂载 · 点击将断开（$tag）" } else { "当前：已卸载 · 点击将接入（$tag）" }
        return Update-ShortcutIcon -LnkPath (Get-ShortcutCandidates $base) -IconPath $icon -Description $desc
    } catch {
        return "更新单盘快捷方式失败：$($_.Exception.Message)"
    }
}

function Get-ConfigLetter {
    # 取配置里记录的盘符（脱机时拿不到真实盘符，用它兜底）
    param([string]$Serial)
    try {
        if (-not (Test-Path $script:ConfigPath)) { return $null }
        $cfg = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($d in @($cfg.disks)) {
            if ($d.serial -eq $Serial -and $d.letter) { return [string]$d.letter }
        }
    } catch { }
    return $null
}

function Set-ConfigLetter {
    # 盘符变了就回写配置，下次脱机时图标还能用对
    param([string]$Serial, [string]$Letter)
    try {
        if (-not $Letter) { return }
        if (-not (Test-Path $script:ConfigPath)) { return }
        $cfg = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $changed = $false
        foreach ($d in @($cfg.disks)) {
            if ($d.serial -eq $Serial -and ([string]$d.letter) -ne $Letter) {
                $d.letter = $Letter
                $changed = $true
            }
        }
        if ($changed) {
            $json = $cfg | ConvertTo-Json -Depth 8
            [IO.File]::WriteAllText($script:ConfigPath, $json, (New-Object Text.UTF8Encoding($false)))
        }
    } catch { }
}

function Get-DiskRuntimeInfo {
    # 单块盘的运行时状态（含当前盘符）；脱机时盘符取配置里的记录
    param($t)
    $disk = $null
    try { $disk = Get-TargetDisk $t } catch { }
    if (-not $disk) {
        return [pscustomobject]@{
            Name = $t.Label; State = 'absent'; Letter = (Get-ConfigLetter $t.Serial); Online = $false
        }
    }
    if ($disk.IsOffline) {
        return [pscustomobject]@{
            Name = $t.Label; State = 'off'; Letter = (Get-ConfigLetter $t.Serial); Online = $false
        }
    }
    $letter = Get-DiskLetter $disk.Number
    if ($letter) { Set-ConfigLetter -Serial $t.Serial -Letter $letter }
    return [pscustomobject]@{
        Name = $t.Label; State = 'on'; Letter = $(if ($letter) { $letter } else { Get-ConfigLetter $t.Serial }); Online = $true
    }
}

function Initialize-StepLog {
    # 每次操作开始时调用一次，建立会话号；之后 Write-StepLog 的每行都带这个会话号
    param([string]$Action, [string]$LogDir)
    $script:StepLogDir  = $LogDir
    $script:StepSession = (Get-Date -Format 'HHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 4))
    $script:StepAction  = $Action
    Write-StepLog -Stage '开始' -Status 'INFO' -Detail ("会话开始 · 操作={0}" -f $Action)
    return $script:StepSession
}

function Write-StepLog {
    # 过程日志：每行一个阶段。和 actions.csv 的结果汇总并存。
    param(
        [string]$Stage,
        [string]$Status,
        [string]$Detail,
        [string]$Disk = ''
    )
    try {
        if (-not $script:StepLogDir) { return }
        $dir = $script:StepLogDir
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $file = Join-Path $dir 'steps.csv'

        if ((Test-Path $file) -and ((Get-Item $file).Length -gt 1MB)) {
            $bak = Join-Path $dir 'steps.1.csv'
            if (Test-Path $bak) { Remove-Item $bak -Force }
            Move-Item $file $bak -Force
        }

        [pscustomobject]@{
            时间   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')
            会话   = $script:StepSession
            操作   = $script:StepAction
            磁盘   = $Disk
            阶段   = $Stage
            状态   = $Status
            详情   = $Detail
        } | Export-Csv -Path $file -Append -NoTypeInformation -Encoding UTF8
    } catch { }
}

# ---- 可替换的薄接口（测试时会被替换成假实现） ----

function Close-DriveWindows {
    # 关掉指向某个盘符的资源管理器窗口，返回关了几个
    param([string]$Letter)
    if (-not $Letter) { return 0 }
    $closed = 0
    try {
        $shell = New-Object -ComObject Shell.Application
        foreach ($w in @($shell.Windows())) {
            if ($w.LocationURL -like ("file:///" + $Letter + ":*")) { $w.Quit(); $closed++ }
        }
    } catch { }
    if ($closed -gt 0) { Start-Sleep -Milliseconds 300 }
    return $closed
}

function Get-DriveProcesses {
    # 有哪些进程正从这块盘上运行
    param([string]$Root)
    if (-not $Root) { return @() }
    return @(Get-Process | Where-Object { $_.Path -like ($Root + '*') })
}

# ---- 纯函数：图标与方向决策（不碰磁盘，便于测试） ----

function Get-IconPath {
    # 图标布局：总开关在 icons\，单盘在 icons\disks\
    param([string]$IconDir, [string]$Name)
    if ($Name -like 'disk-*') { return (Join-Path (Join-Path $IconDir 'disks') $Name) }
    return (Join-Path $IconDir $Name)
}
function Get-MasterIconName {
    # 总开关图标名
    param([string]$State)
    if ($State -eq 'on') { return 'toggle-on.ico' }
    return 'toggle-off.ico'
}

function Get-DiskIconName {
    # 单盘图标名：有盘符用 disk-<字母>-<状态>.ico，没有就退化成总开关图标
    param([string]$State, [string]$Letter)
    $st = if ($State -eq 'on') { 'on' } else { 'off' }
    if ($Letter) { return ("disk-{0}-{1}.ico" -f $Letter.ToUpper(), $st) }
    return (Get-MasterIconName $State)
}

function Get-ToggleDirection {
    # 决定这次是挂载还是卸载：
    #   显式 -Mount / -Unmount 优先；否则「已挂载就卸载，已卸载就挂载」
    param([string]$State, [switch]$ForceMount, [switch]$ForceUnmount)
    if ($ForceMount) { return 'mount' }
    if ($ForceUnmount) { return 'unmount' }
    if ($State -eq 'on') { return 'unmount' }
    return 'mount'
}

function Invoke-DiskOperation {
    # 统一的磁盘操作执行体（GUI 和命令行都调它）。
    # Progress：回调 param($text, $percent)，每推进一步报告一次。
    #
    # 注意：$emit 里必须用 $global: 显式引用外层的回调。
    # PowerShell 脚本块是动态作用域，若这里写裸 $Progress，会被下层
    # Mount/Unmount-Target 的同名参数覆盖，导致 $emit 调用自己 → 栈溢出。
    param(
        $Targets,
        [string]$Direction,        # mount / unmount
        [switch]$Force,
        [switch]$DryRun,
        [scriptblock]$Progress
    )

    $count = [math]::Max(1, @($Targets).Count)
    $stepsPerDisk = if ($Direction -eq 'mount') { 3 } else { 6 }

    $global:__dsUserProgress = $Progress
    $global:__dsStepDone     = 0
    $global:__dsStepTotal    = ($count * $stepsPerDisk)

    $emit = {
        param([string]$text)
        $global:__dsStepDone = [math]::Min($global:__dsStepTotal, $global:__dsStepDone + 1)
        $pct = [int](100.0 * $global:__dsStepDone / $global:__dsStepTotal)
        if ($global:__dsUserProgress) { & $global:__dsUserProgress $text $pct }
    }

    $results = @()
    if ($Direction -eq 'mount') {
        foreach ($t in $Targets) {
            & $emit "正在挂载 $($t.Label)…"
            $results += (Mount-Target $t -DryRun:$DryRun -Progress $emit)
        }
    } else {
        & $emit '采样当前读写（2 秒）…'
        $io = Get-DiskIOAll -DiskList $Targets
        foreach ($t in $Targets) {
            & $emit "正在卸载 $($t.Label)…"
            $results += (Unmount-Target $t -Force:$Force -DryRun:$DryRun -IO $io -Progress $emit)
        }
    }
    if ($global:__dsUserProgress) { & $global:__dsUserProgress '完成' 100 }
    return $results
}
