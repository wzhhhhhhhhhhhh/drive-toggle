# ui-wpf.ps1 —— WPF 界面层
#
# 与 ui.ps1（WinForms 遗留：选盘窗 / 提示框）并存，逐个窗口迁移。
# 目前接管：操作进度窗 Show-OperationDialog
#
# 关键设计：
#   磁盘操作跑在**后台 runspace**里，UI 线程只负责刷新。
#   这样窗口在干活期间依然能拖动、能响应，也不会抢在最前面（已去掉 Topmost）。

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$script:UiProgressXaml = Join-Path $PSScriptRoot 'ui-progress.xaml'

function Initialize-Wpf {
    if ($script:WpfReady) { return }
    if (-not [System.Windows.Application]::Current) {
        $script:WpfApp = New-Object System.Windows.Application
        $script:WpfApp.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
    }
    $script:WpfReady = $true
}

function Invoke-UiPump {
    # 相当于 WinForms 的 DoEvents：跑一轮界面消息就返回
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $cb = [System.Action] { $frame.Continue = $false }
    [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background, $cb)
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Load-UiWindow {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "找不到界面文件：$Path" }
    $xml = [xml](Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
    $reader = New-Object System.Xml.XmlNodeReader $xml
    return [Windows.Markup.XamlReader]::Load($reader)
}

function Set-UiAccent {
    param($Window, [string]$Hex)
    $brush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
    $dot = $Window.FindName('StatusDot')
    if ($dot) { $dot.Fill = $brush }
    $fill = $Window.FindName('ProgressFill')
    if ($fill) { $fill.Background = $brush }
}

function New-UiWorker {
    # 在后台 STA runspace 里跑磁盘操作；进度通过同步哈希表回传
    param(
        [string]$CorePath,
        $Targets,
        [string]$Direction,
        [bool]$Force,
        [bool]$DryRun,
        [string]$LogDir,
        [string]$ActionLabel
    )

    $sync = [hashtable]::Synchronized(@{
        Text = ''; Pct = $null; Done = $false; Error = $null; Results = @(); Seconds = 0.0
    })

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $rs.SessionStateProxy.SetVariable('__dshSync', $sync)
    $rs.SessionStateProxy.SetVariable('__dshTargets', $Targets)
    $rs.SessionStateProxy.SetVariable('__dshCore', $CorePath)
    $rs.SessionStateProxy.SetVariable('__dshLogs', $LogDir)
    $rs.SessionStateProxy.SetVariable('__dshAction', $ActionLabel)

    $worker = {
        param($direction, $force, $dryRun)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            . $global:__dshCore
            if ($global:__dshLogs) { [void](Initialize-StepLog -Action $global:__dshAction -LogDir $global:__dshLogs) }

            $cb = {
                param($t, $p)
                if ($t) { $global:__dshSync.Text = $t }
                if ($null -ne $p) { $global:__dshSync.Pct = [double]$p }
            }
            $r = Invoke-DiskOperation -Targets $global:__dshTargets -Direction $direction -Force:$force -DryRun:$dryRun -Progress $cb
            $global:__dshSync.Results = @($r)
        } catch {
            $global:__dshSync.Error = $_.Exception.Message
        } finally {
            $sw.Stop()
            $global:__dshSync.Seconds = $sw.Elapsed.TotalSeconds
            try {
                if ($global:__dshLogs) {
                    Write-StepLog -Stage '结束' -Status 'INFO' -Detail ("用时 {0:N1} 秒" -f $sw.Elapsed.TotalSeconds)
                }
            } catch { }
            $global:__dshSync.Done = $true
        }
    }

    $handle = $ps.AddScript($worker).AddArgument($Direction).AddArgument($Force).AddArgument($DryRun).BeginInvoke()

    return [pscustomobject]@{ Sync = $sync; PS = $ps; Handle = $handle; Runspace = $rs }
}

# ---------------------------------------------------------------- 操作进度窗
# 两种用法：
#   1) -CorePath -Targets -Direction  → 后台 runspace 执行（界面全程可拖动）
#   2) -Work <scriptblock>            → 同步执行（初始化这类短流程）
function Show-OperationDialog {
    param(
        [string]$Title,
        [string]$Direction,          # mount / unmount / setup
        [scriptblock]$Work,
        [string]$CorePath,
        $Targets,
        [switch]$Force,
        [switch]$DryRun,
        [string]$LogDir,
        [string]$ActionLabel = '切换',
        [double]$HoldOk = 1.6,
        [double]$HoldFail = 3.5
    )

    Initialize-Wpf

    $accent = switch ($Direction) {
        'unmount' { '#64748B' }
        'setup'   { '#4F6EF7' }
        default   { '#109B5E' }
    }

    $win = Load-UiWindow $script:UiProgressXaml
    $win.Title = $Title
    Set-UiAccent -Window $win -Hex $accent

    $lblTitle = $win.FindName('TitleText')
    $lblStatus = $win.FindName('StatusText')
    $lblPct = $win.FindName('PercentText')
    $fill = $win.FindName('ProgressFill')
    $track = $win.FindName('TrackGrid')
    $lblFoot = $win.FindName('FootText')

    $lblTitle.Text = switch ($Direction) {
        'unmount' { '正在卸载…' }
        'setup'   { '正在初始化…' }
        default   { '正在挂载…' }
    }

    # 无边框窗口可拖动（无 Topmost，点别的窗口就能把它压下去）
    $win.Add_MouseLeftButtonDown({ try { $win.DragMove() } catch { } })

    $barW = 0
    $shown = 0.0
    $target = 0.0
    $hasPct = $false

    $render = {
        if ($barW -le 0 -and $track) { $barW = [double]$track.ActualWidth }
        if ($barW -le 0) { $barW = 360 }
        if ($hasPct) {
            $diff = $target - $shown
            if ([math]::Abs($diff) -gt 0.4) { $shown += $diff * 0.30 } else { $shown = $target }
            $fill.Width = [math]::Max(0, $barW * $shown / 100.0)
            $lblPct.Text = ('{0}%' -f [int]$target)
        } else {
            $fill.Width = $barW * 0.28
            $lblPct.Text = ''
        }
    }

    $win.Show()
    Invoke-UiPump
    & $render

    $err = $null
    $results = @()
    $worker = $null

    try {
        if ($CorePath -and $Targets) {
            # ---- 后台执行 ----
            $worker = New-UiWorker -CorePath $CorePath -Targets $Targets -Direction $Direction `
                                   -Force ([bool]$Force) -DryRun ([bool]$DryRun) `
                                   -LogDir $LogDir -ActionLabel $ActionLabel
            $sync = $worker.Sync

            while (-not $sync.Done -and $win.IsVisible) {
                if ($sync.Text -and $lblStatus.Text -ne $sync.Text) { $lblStatus.Text = $sync.Text }
                if ($null -ne $sync.Pct) { $hasPct = $true; $target = [double]$sync.Pct }
                & $render
                Invoke-UiPump
                Start-Sleep -Milliseconds 16
            }

            # 用户可能中途关掉窗口——作业仍在跑，必须等它完成，
            # 否则调用方会拿着"半截状态"去刷图标、写日志。
            $waitUntil = (Get-Date).AddSeconds(180)
            while (-not $sync.Done -and (Get-Date) -lt $waitUntil) {
                Start-Sleep -Milliseconds 50
            }

            try { [void]$worker.PS.EndInvoke($worker.Handle) } catch { }
            try { $worker.PS.Dispose() } catch { }
            try { $worker.Runspace.Close(); $worker.Runspace.Dispose() } catch { }

            $err = $sync.Error
            $results = @($sync.Results)
        } else {
            # ---- 同步执行（短流程） ----
            $progress = {
                param([string]$text, $pct = $null)
                if ($text) { $lblStatus.Text = $text }
                if ($null -ne $pct) { $hasPct = $true; $target = [double]$pct }
                & $render
                Invoke-UiPump
            }
            $results = @(& $Work $progress)
        }
    } catch {
        $err = $_.Exception.Message
    }

    # ---- 收尾 ----
    $hasPct = $true
    $target = 100.0
    $shown = 100.0
    & $render
    Invoke-UiPump

    if ($err) {
        $lblTitle.Text = '出错了'
        $lblTitle.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#E24A4A'))
        $lblStatus.Text = ''
        $lblFoot.Text = $err
        Set-UiAccent -Window $win -Hex '#E24A4A'
    } else {
        $lblTitle.Text = switch ($Direction) {
            'unmount' { '已卸载' }
            'setup'   { '初始化完成' }
            default   { '已挂载' }
        }
        $lblStatus.Text = ''
        if (@($results).Count -gt 0 -and (@($results)[0].PSObject.Properties.Name -contains '磁盘')) {
            $lblFoot.Text = (@($results | ForEach-Object { '{0}  {1}' -f $_.磁盘, $_.结果 }) -join '        ')
        }
    }
    Invoke-UiPump

    $until = (Get-Date).AddSeconds($(if ($err) { $HoldFail } else { $HoldOk }))
    while ((Get-Date) -lt $until -and $win.IsVisible) {
        Invoke-UiPump
        Start-Sleep -Milliseconds 30
    }

    try { $win.Close() } catch { }
    return [pscustomobject]@{ Error = $err; Results = $results }
}
