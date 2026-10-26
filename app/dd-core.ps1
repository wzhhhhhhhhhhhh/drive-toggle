# dd-core.ps1 —— 共用逻辑，由各入口脚本点引用
# 设计要点：每块盘独立 try/catch，一块出问题（包括根本没插）绝不影响另一块。
# 要管理哪些盘由 config.json 决定（由 setup.ps1 生成）。

$script:AppDir     = $PSScriptRoot
# 脚本放在 app\ 子目录时，根目录在上一级；放在根目录时直接用 PSScriptRoot
$script:Root       = if ((Split-Path $PSScriptRoot -Leaf) -eq 'app') { Split-Path $PSScriptRoot -Parent } else { $PSScriptRoot }
$script:ConfigPath = Join-Path $script:Root 'config.json'

function Focus-Console {
    # 把脚本窗口提到最前面。任务计划启动的窗口默认是在后台冒出来的，
    # 不给它抢焦点的话，你会觉得"点了没反应"，然后过一会儿窗口才闪一下。
    try {
        if (-not ('Win32.ConsoleWin' -as [type])) {
            Add-Type -Namespace Win32 -Name ConsoleWin -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
        }
        $h = [Win32.ConsoleWin]::GetConsoleWindow()
        if ($h -ne [IntPtr]::Zero) {
            [void][Win32.ConsoleWin]::ShowWindow($h, 9)      # SW_RESTORE
            [void][Win32.ConsoleWin]::SetForegroundWindow($h)
        }
    } catch { }
}

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
    $found = @(Get-Disk | Where-Object { $_.SerialNumber -like ('*' + $t.Serial + '*') })
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
        BringWindowToTop(h);
        SetForegroundWindow(h);
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

function Update-ToggleShortcut {
    # 总开关：按当前状态切换图标和描述
    param(
        [string]$State,
        [string[]]$LnkPath,
        [string]$IconDir
    )
    $icon = Join-Path $IconDir (Get-MasterIconName $State)
    $desc = if ($State -eq 'on') { '当前：已挂载 · 点击将断开' } else { '当前：已卸载 · 点击将接入' }
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
        $icon = Join-Path $IconDir (Get-DiskIconName -State $State -Letter $upper)
        if (-not (Test-Path $icon)) { $icon = Join-Path $IconDir (Get-MasterIconName $State) }
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
