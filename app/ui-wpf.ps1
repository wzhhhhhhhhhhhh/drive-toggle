# ui-wpf.ps1 —— WPF 界面层
#
# 本文件是唯一的界面层：
#   Show-DiskPicker        初始化选盘窗
#   Show-OperationDialog   操作进度窗
#   Show-UiMessage         提示框
#
# 关键设计：
#   磁盘操作跑在**后台 runspace**里，UI 线程只负责刷新。
#   这样窗口在干活期间依然能拖动、能响应，也不会抢在最前面（已去掉 Topmost）。

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$script:UiProgressXaml = Join-Path $PSScriptRoot 'ui-progress.xaml'
$script:UiPickerXaml   = Join-Path $PSScriptRoot 'ui-picker.xaml'
$script:UiConfirmXaml  = Join-Path $PSScriptRoot 'ui-confirm.xaml'

function Initialize-Wpf {
    if ($script:WpfReady) { return }

    # 让任务栏把窗口算作本程序（而不是 powershell.exe），图标才用我们自己的
    try {
        $exe = Join-Path (Split-Path $PSScriptRoot -Parent) '初始化.exe'
        [void][DshWin32.Api]::SetCurrentProcessExplicitAppUserModelID($exe)
    } catch { }

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

if (-not ('DshWin32' -as [type])) {
    Add-Type -Namespace DshWin32 -Name Api -MemberDefinition @'
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string AppID);
'@
}

function Set-UiAppWindow {
    # 无边框 + 透明窗口是分层窗口，默认可能不进任务栏 / Alt+Tab。
    # 显式加上 WS_EX_APPWINDOW、去掉 WS_EX_TOOLWINDOW，再刷新一次框架。
    param($Window)
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper $Window).Handle
        if ($h -eq [IntPtr]::Zero) { return }
        $ex = [DshWin32.Api]::GetWindowLong($h, -20)
        $ex = ($ex -bor 0x00040000) -band (-bnot 0x00000080)
        [void][DshWin32.Api]::SetWindowLong($h, -20, $ex)
        [void][DshWin32.Api]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 0, 0, 0x0027)
    } catch { }
}

function Get-UiIcon {
    # 任务栏 / 标题栏用的应用图标。
    # 坑：BitmapImage 读 .ico 只拿**第一帧**（我们的是 16px），系统再把它塞进
    # 32/40px 的图标位，内容只占四成——这就是「图标看着特别小」的真正原因。
    # 改用 BitmapDecoder 取最大的一帧，交给系统去缩。
    $p = Join-Path (Split-Path $PSScriptRoot -Parent) 'icons\app.ico'
    if (-not (Test-Path $p)) { return $null }
    $stream = $null
    try {
        $stream = [IO.File]::OpenRead($p)
        $dec = [System.Windows.Media.Imaging.BitmapDecoder]::Create(
            $stream,
            [System.Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache,
            [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $frame = $dec.Frames | Sort-Object PixelWidth -Descending | Select-Object -First 1
        if (-not $frame) { return $null }
        $frame.Freeze()
        return $frame
    } catch { return $null }
    finally { if ($stream) { $stream.Dispose() } }
}
function Load-UiWindow {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "找不到界面文件：$Path" }
    $xml = [xml](Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
    $reader = New-Object System.Xml.XmlNodeReader $xml
    $win = [Windows.Markup.XamlReader]::Load($reader)
    $ico = Get-UiIcon
    if ($ico) { $win.Icon = $ico }
    # 窗口创建后重新登记为「应用窗口」，否则任务栏 / Alt+Tab 里看不到
    $win.Add_SourceInitialized({ param($s, $e) Set-UiAppWindow -Window $s })
    return $win
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
        Text = ''; Pct = $null; Done = $false; Error = $null; Results = @(); Seconds = 0.0; Wake = @()
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

            # 操作前：检查上一段脱机期间盘有没有被唤醒
            try {
                if ($global:__dshLogs) {
                    $global:__dshSync.Wake = @(Get-OfflineWakeups -Targets $global:__dshTargets -LogDir $global:__dshLogs)
                }
            } catch { }

            $cb = {
                param($t, $p)
                if ($t) { $global:__dshSync.Text = $t }
                if ($null -ne $p) { $global:__dshSync.Pct = [double]$p }
            }
            $r = Invoke-DiskOperation -Targets $global:__dshTargets -Direction $direction -Force:$force -DryRun:$dryRun -Progress $cb
            $global:__dshSync.Results = @($r)

            # 操作后：把当前状态与 SMART 累计值写成新快照
            try {
                if ($global:__dshLogs) { Save-DiskState -Targets $global:__dshTargets -LogDir $global:__dshLogs }
            } catch { }
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

# ---------------------------------------------------------------- 选盘窗口
function New-ScriptWorker {
    # 在后台 STA runspace 里跑任意脚本（脚本需支持 -Progress 参数），进度回传
    param(
        [string]$ScriptPath,
        [hashtable]$ScriptArgs = @{},
        [string]$WorkDir
    )

    $sync = [hashtable]::Synchronized(@{
        Text = ''; Pct = $null; Done = $false; Error = $null; Results = @()
    })

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $rs.SessionStateProxy.SetVariable('__dshSync', $sync)
    $rs.SessionStateProxy.SetVariable('__dshScript', $ScriptPath)
    $rs.SessionStateProxy.SetVariable('__dshScriptArgs', $ScriptArgs)
    $rs.SessionStateProxy.SetVariable('__dshWorkDir', $WorkDir)

    $worker = {
        try {
            if ($global:__dshWorkDir) { Set-Location $global:__dshWorkDir }
            $cb = {
                param($t, $p)
                if ($t) { $global:__dshSync.Text = $t }
                if ($null -ne $p) { $global:__dshSync.Pct = [double]$p }
            }
            $sp = @{}
            if ($global:__dshScriptArgs) {
                foreach ($k in $global:__dshScriptArgs.Keys) { $sp[$k] = $global:__dshScriptArgs[$k] }
            }
            $sp['Progress'] = $cb
            $global:__dshSync.Results = @(& $global:__dshScript @sp)
        } catch {
            $global:__dshSync.Error = $_.Exception.Message
        } finally {
            $global:__dshSync.Done = $true
        }
    }

    $handle = $ps.AddScript($worker).BeginInvoke()
    return [pscustomobject]@{ Sync = $sync; PS = $ps; Handle = $handle; Runspace = $rs }
}

# Rows: 每项需含 Index / Letters / Model / SizeGB / Bus / Media
# 返回被勾选的 Index 数组（按行序）
function Show-DiskPicker {
    param($Rows)

    Initialize-Wpf

    $rows = @($Rows)
    if ($rows.Count -eq 0) { return @() }

    $win = Load-UiWindow $script:UiPickerXaml
    $rowHost = $win.FindName('RowHost')
    $countText = $win.FindName('CountText')
    $okBtn = $win.FindName('OkBtn')
    $cancelBtn = $win.FindName('CancelBtn')
    $closeX = $win.FindName('CloseX')

    $ink    = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#171C26'))
    $muted  = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#848D9E'))
    $soft   = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#F6F8FB'))
    $selBg  = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#EBF8F1'))
    $line   = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#E5EAF1'))
    $green  = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#109B5E'))

    # 行高随数量自适应：超过 6 行出滚动条
    $perRow = 74
    $win.Height = [math]::Min(700, 250 + [math]::Min($rows.Count, 6) * $perRow)

    $global:__dsPickerChecks = New-Object System.Collections.ArrayList
    foreach ($r in $rows) {
        $border = New-Object System.Windows.Controls.Border
        $border.CornerRadius = New-Object System.Windows.CornerRadius 10
        $border.Padding = New-Object System.Windows.Thickness 16, 12, 16, 12
        $border.Margin = New-Object System.Windows.Thickness 0, 0, 0, 8
        $border.Background = $soft
        $border.BorderBrush = $line
        $border.BorderThickness = New-Object System.Windows.Thickness 1
        $border.Cursor = [System.Windows.Input.Cursors]::Hand

        $grid = New-Object System.Windows.Controls.Grid
        foreach ($w in 'Auto', 'Auto', '*', 'Auto') {
            $col = New-Object System.Windows.Controls.ColumnDefinition
            $col.Width = if ($w -eq 'Auto') { [System.Windows.GridLength]::Auto } elseif ($w -eq '*') { New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star) } else { [System.Windows.GridLength]::Auto }
            $grid.ColumnDefinitions.Add($col)
        }

        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Style = $win.FindResource('RowCheck')
        $cb.Tag = $r.Index
        [System.Windows.Controls.Grid]::SetColumn($cb, 0)
        $grid.Children.Add($cb) | Out-Null

        $letter = if ($r.Letters -ne '—') { ($r.Letters -split ',')[0] + ':' } else { '—' }
        $tbLetter = New-Object System.Windows.Controls.TextBlock
        $tbLetter.Text = $letter
        $tbLetter.FontSize = 18
        $tbLetter.FontWeight = [System.Windows.FontWeights]::SemiBold
        $tbLetter.Foreground = $ink
        $tbLetter.VerticalAlignment = 'Center'
        $tbLetter.Margin = New-Object System.Windows.Thickness 18, 0, 0, 0
        $tbLetter.MinWidth = 46
        [System.Windows.Controls.Grid]::SetColumn($tbLetter, 1)
        $grid.Children.Add($tbLetter) | Out-Null

        $stack = New-Object System.Windows.Controls.StackPanel
        $stack.VerticalAlignment = 'Center'
        $tbModel = New-Object System.Windows.Controls.TextBlock
        $tbModel.Text = $r.Model
        $tbModel.FontSize = 13
        $tbModel.Foreground = $ink
        $tbModel.TextTrimming = 'CharacterEllipsis'
        $tbMeta = New-Object System.Windows.Controls.TextBlock
        $tbMeta.Text = ('{0}{1}' -f $r.Bus, $(if ($r.Media -eq 'SSD') { ' · 固态盘' } elseif ($r.Bus -eq 'USB') { ' · 移动硬盘' } else { '' }))
        $tbMeta.FontSize = 11
        $tbMeta.Foreground = $muted
        $tbMeta.Margin = New-Object System.Windows.Thickness 0, 3, 0, 0
        $stack.Children.Add($tbModel) | Out-Null
        $stack.Children.Add($tbMeta) | Out-Null
        [System.Windows.Controls.Grid]::SetColumn($stack, 2)
        $grid.Children.Add($stack) | Out-Null

        $tbSize = New-Object System.Windows.Controls.TextBlock
        $tbSize.Text = ('{0} GB' -f $r.SizeGB)
        $tbSize.FontSize = 12
        $tbSize.Foreground = $muted
        $tbSize.VerticalAlignment = 'Center'
        $tbSize.Margin = New-Object System.Windows.Thickness 16, 0, 0, 0
        [System.Windows.Controls.Grid]::SetColumn($tbSize, 3)
        $grid.Children.Add($tbSize) | Out-Null

        $border.Child = $grid
        $rowHost.Children.Add($border) | Out-Null

        # 点整行也能勾选
        $border.Add_MouseLeftButtonUp({
            param($s, $e)
            $cb.IsChecked = -not $cb.IsChecked
        }.GetNewClosure())
        $cb.Add_Checked({
            param($s, $e)
            $border.Background = $selBg
            $border.BorderBrush = $green
            $n = @($global:__dsPickerChecks | Where-Object { $_.IsChecked }).Count
            $countText.Text = "已选 $n 块"
            $okBtn.IsEnabled = ($n -gt 0)
        }.GetNewClosure())
        $cb.Add_Unchecked({
            param($s, $e)
            $border.Background = $soft
            $border.BorderBrush = $line
            $n = @($global:__dsPickerChecks | Where-Object { $_.IsChecked }).Count
            $countText.Text = if ($n -eq 0) { '尚未选择' } else { "已选 $n 块" }
            $okBtn.IsEnabled = ($n -gt 0)
        }.GetNewClosure())

        [void]$global:__dsPickerChecks.Add($cb)
    }

    $global:__dsPickerResult = $null
    $okBtn.Add_Click({ $global:__dsPickerResult = 'ok'; $win.Close() }.GetNewClosure())
    $cancelBtn.Add_Click({ $global:__dsPickerResult = 'cancel'; $win.Close() }.GetNewClosure())
    $closeX.Add_MouseLeftButtonUp({ $global:__dsPickerResult = 'cancel'; $win.Close() }.GetNewClosure())
    $win.Add_MouseLeftButtonDown({ try { $win.DragMove() } catch { } })

    $win.ShowDialog() | Out-Null

    $picked = @()
    if ($global:__dsPickerResult -eq 'ok') {
        foreach ($cb in $global:__dsPickerChecks) { if ($cb.IsChecked) { $picked += [int]$cb.Tag } }
    }
    try { $win.Close() } catch { }
    return $picked
}

# ---------------------------------------------------------------- 初始化确认窗
# 语义化的三选一：沿用现有配置 / 重新选盘 / 取消
# 返回 'reuse' / 'reselect' / 'cancel'
function Show-SetupConfirm {
    param(
        [string]$Names,
        [string]$Title = '磁盘开关 · 初始化'
    )

    Initialize-Wpf

    $win = Load-UiWindow $script:UiConfirmXaml
    $win.Title = $Title

    $win.FindName('TitleText').Text = '已经配置过了'
    $win.FindName('MessageText').Text = "当前管理：$Names`n`n要沿用这组配置，还是重新选择磁盘？"
    $mainBtn = $win.FindName('MainBtn')
    $altBtn = $win.FindName('AltBtn')
    $cancelBtn = $win.FindName('CancelBtn')
    $mainBtn.Content = '沿用现有配置'
    $altBtn.Content = '重新选盘'
    $cancelBtn.Content = '取消'

    $global:__dsConfirmResult = 'cancel'
    $mainBtn.Add_Click({ $global:__dsConfirmResult = 'reuse'; $win.Close() }.GetNewClosure())
    $altBtn.Add_Click({ $global:__dsConfirmResult = 'reselect'; $win.Close() }.GetNewClosure())
    $cancelBtn.Add_Click({ $global:__dsConfirmResult = 'cancel'; $win.Close() }.GetNewClosure())
    $win.Add_MouseLeftButtonDown({ try { $win.DragMove() } catch { } })

    $win.ShowDialog() | Out-Null
    $r = $global:__dsConfirmResult
    try { $win.Close() } catch { }
    return $r
}
# ---------------------------------------------------------------- 提示框
function Show-UiMessage {
    param([string]$Message, [string]$Title = '磁盘开关', [string]$Kind = 'info')
    Initialize-Wpf
    $icon = switch ($Kind) {
        'error' { [System.Windows.MessageBoxImage]::Error }
        'warn'  { [System.Windows.MessageBoxImage]::Warning }
        default { [System.Windows.MessageBoxImage]::Information }
    }
    [void][System.Windows.MessageBox]::Show($Message, $Title, [System.Windows.MessageBoxButton]::OK, $icon)
}
function Wait-UiWorker {
    # 用嵌套消息循环等后台作业：消息全速处理（拖动跟手），定时器负责刷新界面。
    # 关键：界面对象、函数、状态全部通过 $Ctx 以参数传入，回调里不读自由变量
    #（PowerShell 脚本块是动态作用域，自由变量会被调用方的同名变量顶掉）。
    param($Window, $Sync, [scriptblock]$OnTick, $Ctx)

    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $poll = New-Object System.Windows.Threading.DispatcherTimer
    $poll.Interval = [TimeSpan]::FromMilliseconds(16)
    $poll.Add_Tick({
        & $OnTick $Ctx $Sync
        if ($Sync.Done -or -not $Window.IsVisible) {
            $poll.Stop()
            $frame.Continue = $false
        }
    }.GetNewClosure())
    $poll.Start()
    try {
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    } finally {
        $poll.Stop()
    }
}

# ---------------------------------------------------------------- 操作进度窗
# 三种用法：
#   1) -CorePath -Targets -Direction  → 后台跑磁盘操作
#   2) -ScriptPath                    → 后台跑某个脚本（初始化用 install.ps1）
function Set-WakeLogLink {
    # 把「明细见 logs\wakeups.csv」做成可点击：打开文件夹并选中文件，没有文件就打开文件夹
    param($Button, [string]$LogDir)
    if (-not $Button) { return }
    $dir = $LogDir
    $Button.Add_Click({
        try {
            $csv = if ($dir) { Join-Path $dir 'wakeups.csv' } else { '' }
            if ($csv -and (Test-Path $csv)) {
                Start-Process explorer.exe -ArgumentList ('/select,"' + $csv + '"')
            } elseif ($dir -and (Test-Path $dir)) {
                Start-Process explorer.exe -ArgumentList $dir
            }
        } catch { }
    }.GetNewClosure())
}
function Set-WakeListContent {
    # 把唤醒明细铺进一个 StackPanel：每块盘一组（标题 + 两行对齐的数据），组间一条细线。
    # 抽成独立函数是为了能用假数据打桩测试（盘多时是否出现滚动、量取高度是否合理）。
    param($List, $Items)

    if (-not $List) { return }

    $brushGrey  = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#848D9E'))
    $brushDark  = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#171C26'))
    $brushGreen = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#109B5E'))
    $brushLine  = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#E5EAF1'))

    $cAuto = [System.Windows.GridLength]::Auto
    $c18   = New-Object System.Windows.GridLength 18
    $cStar = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)

    $n = 0
    foreach ($w in @($Items)) {
        $span = if ($w.OfflineText) { $w.OfflineText } else { ('{0} 分钟' -f $w.OfflineMinutes) }

        if ($n -gt 0) {
            $sep = New-Object System.Windows.Controls.Border
            $sep.Height = 1
            $sep.Background = $brushLine
            $sep.Margin = New-Object System.Windows.Thickness 0,12,0,12
            [void]$List.Children.Add($sep)
        }

        $blkTitle = New-Object System.Windows.Controls.TextBlock
        $blkTitle.Text = ('{0} · 脱机 {1}' -f $w.Label, $span)
        $blkTitle.FontSize = 13
        $blkTitle.FontWeight = 'SemiBold'
        $blkTitle.Foreground = $brushDark
        $blkTitle.Margin = New-Object System.Windows.Thickness 0,0,0,8
        [void]$List.Children.Add($blkTitle)

        $g = New-Object System.Windows.Controls.Grid
        foreach ($cw in @($cAuto, $c18, $cAuto, $cStar, $cAuto)) {
            $cd = New-Object System.Windows.Controls.ColumnDefinition
            $cd.Width = $cw
            [void]$g.ColumnDefinitions.Add($cd)
        }
        for ($k = 0; $k -lt 2; $k++) {
            $rd = New-Object System.Windows.Controls.RowDefinition
            [void]$g.RowDefinitions.Add($rd)
        }

        $cells = @(
            @('启停次数', ('{0:N0} → {1:N0}' -f $w.PrevStartStop, $w.CurStartStop), ('+{0}' -f $w.StartStopDelta)),
            @('磁头加载', ('{0:N0} → {1:N0}' -f $w.PrevLoad, $w.CurLoad),     ('+{0}' -f $w.LoadDelta))
        )

        $row = 0
        foreach ($c in $cells) {
            $lab = New-Object System.Windows.Controls.TextBlock
            $lab.Text = $c[0]; $lab.FontSize = 12; $lab.Foreground = $brushGrey
            $lab.HorizontalAlignment = 'Right'
            $lab.Margin = New-Object System.Windows.Thickness 0,0,0,$(if ($row -eq 0) { 7 } else { 0 })
            [System.Windows.Controls.Grid]::SetRow($lab, $row); [System.Windows.Controls.Grid]::SetColumn($lab, 0)
            [void]$g.Children.Add($lab)

            $val = New-Object System.Windows.Controls.TextBlock
            $val.Text = $c[1]; $val.FontSize = 12; $val.Foreground = $brushDark
            $val.Margin = New-Object System.Windows.Thickness 0,0,0,$(if ($row -eq 0) { 7 } else { 0 })
            [System.Windows.Controls.Grid]::SetRow($val, $row); [System.Windows.Controls.Grid]::SetColumn($val, 2)
            [void]$g.Children.Add($val)

            $del = New-Object System.Windows.Controls.TextBlock
            $del.Text = $c[2]; $del.FontSize = 12; $del.FontWeight = 'SemiBold'; $del.Foreground = $brushGreen
            $del.Margin = New-Object System.Windows.Thickness 12,0,0,$(if ($row -eq 0) { 7 } else { 0 })
            [System.Windows.Controls.Grid]::SetRow($del, $row); [System.Windows.Controls.Grid]::SetColumn($del, 4)
            [void]$g.Children.Add($del)

            $row++
        }

        [void]$List.Children.Add($g)
        $n++
    }
}

function Show-OperationDialog {
    param(
        [string]$Title,
        [string]$Direction,          # mount / unmount / setup
        [string]$CorePath,
        $Targets,
        [switch]$Force,
        [switch]$DryRun,
        [string]$LogDir,
        [string]$ScriptPath,
        [hashtable]$ScriptArgs = @{},
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

    # 所有界面对象 + 进度状态 + 渲染函数装进一个哈希表，回调只通过它取东西
    $ctx = @{
        lblTitle  = $win.FindName('TitleText')
        lblStatus = $win.FindName('StatusText')
        lblPct    = $win.FindName('PercentText')
        fill      = $win.FindName('ProgressFill')
        track     = $win.FindName('TrackGrid')
        lblFoot   = $win.FindName('FootText')
        ack       = $win.FindName('AckButton')
        wakePanel = $win.FindName('WakePanel')
        wakeList  = $win.FindName('WakeList')
        wakeScroll= $win.FindName('WakeScroll')
        wakeLog   = $win.FindName('WakeLog')
        st        = @{ barW = 0.0; shown = 0.0; target = 0.0; hasPct = $false }
    }

    $ctx.render = {
        param($c)
        if ($c.st.barW -le 0 -and $c.track) { $c.st.barW = [double]$c.track.ActualWidth }
        if ($c.st.barW -le 0) { $c.st.barW = 360 }
        if ($c.st.hasPct) {
            $diff = $c.st.target - $c.st.shown
            if ([math]::Abs($diff) -gt 0.4) { $c.st.shown += $diff * 0.30 } else { $c.st.shown = $c.st.target }
            $c.fill.Width = [math]::Max(0, $c.st.barW * $c.st.shown / 100.0)
            $c.lblPct.Text = ('{0}%' -f [int]$c.st.target)
        } else {
            $c.fill.Width = $c.st.barW * 0.28
            $c.lblPct.Text = ''
        }
    }

    $ctx.lblTitle.Text = switch ($Direction) {
        'unmount' { '正在卸载…' }
        'setup'   { '正在初始化…' }
        default   { '正在挂载…' }
    }

    # 无边框窗口可拖动（无 Topmost，点别的窗口就能把它压下去）
    $win.Add_MouseLeftButtonDown({ try { $win.DragMove() } catch { } })

    $win.Show()
    Invoke-UiPump
    & $ctx.render $ctx

    $err = $null
    $results = @()

    try {
        if ($ScriptPath -or ($CorePath -and $Targets)) {
            # ---- 后台作业（界面线程全程空闲） ----
            if ($ScriptPath) {
                $worker = New-ScriptWorker -ScriptPath $ScriptPath -ScriptArgs $ScriptArgs `
                                           -WorkDir (Split-Path $ScriptPath -Parent)
            } else {
                $worker = New-UiWorker -CorePath $CorePath -Targets $Targets -Direction $Direction `
                                       -Force ([bool]$Force) -DryRun ([bool]$DryRun) `
                                       -LogDir $LogDir -ActionLabel $ActionLabel
            }
            $sync = $worker.Sync

            Wait-UiWorker -Window $win -Sync $sync -Ctx $ctx -OnTick {
                param($c, $s)
                if ($s.Text -and $c.lblStatus.Text -ne $s.Text) { $c.lblStatus.Text = $s.Text }
                if ($null -ne $s.Pct) { $c.st.hasPct = $true; $c.st.target = [double]$s.Pct }
                & $c.render $c
            }

            # 用户可能中途关窗口——作业还在跑，等它结束再返回
            $waitUntil = (Get-Date).AddSeconds(300)
            while (-not $sync.Done -and (Get-Date) -lt $waitUntil) { Start-Sleep -Milliseconds 50 }

            try { [void]$worker.PS.EndInvoke($worker.Handle) } catch { }
            try { $worker.PS.Dispose() } catch { }
            try { $worker.Runspace.Close(); $worker.Runspace.Dispose() } catch { }

            $err = $sync.Error
            $results = @($sync.Results)
        }
        else {
            throw 'Show-OperationDialog 需要 -ScriptPath 或 -CorePath/-Targets'
        }
    } catch {
        $err = $_.Exception.Message
    }

    # ---- 收尾 ----
    $ctx.st.hasPct = $true
    $ctx.st.target = 100.0
    $ctx.st.shown = 100.0
    & $ctx.render $ctx
    Invoke-UiPump

    if ($err) {
        $ctx.lblTitle.Text = '出错了'
        $ctx.lblTitle.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#E24A4A'))
        $ctx.lblStatus.Text = ''
        $ctx.lblFoot.Text = $err
        Set-UiAccent -Window $win -Hex '#E24A4A'
    } else {
        $ctx.lblTitle.Text = switch ($Direction) {
            'unmount' { '已卸载' }
            'setup'   { '初始化完成' }
            default   { '已挂载' }
        }
        $ctx.lblStatus.Text = ''
        if (@($results).Count -gt 0 -and (@($results)[0].PSObject.Properties.Name -contains '磁盘')) {
            $ctx.lblFoot.Text = (@($results | ForEach-Object { '{0}  {1}' -f $_.磁盘, $_.结果 }) -join '        ')
        }

        # 脱机期间检测到唤醒：逐块盘列出（盘多时可滚动），并要求点「知道了」才关窗
        if ($sync -and $sync.Wake) { $wake = @($sync.Wake) }
        if ($wake.Count -gt 0) {
            $ctx.lblFoot.Visibility = 'Collapsed'
            $ctx.wakePanel.Visibility = 'Visible'
            $ctx.ack.Visibility = 'Visible'

            [void](Set-WakeListContent -List $ctx.wakeList -Items $wake)

            # 「明细见 logs\wakeups.csv」点一下打开所在文件夹并选中该文件
            [void](Set-WakeLogLink -Button $ctx.wakeLog -LogDir $LogDir)

            # 窗口高度跟着内容长，但不超过屏幕；盘多时由 ScrollViewer 接管
            $win.SizeToContent = 'Height'
        }
    }

    Invoke-UiPump

    if ($wake.Count -gt 0 -and -not $err) {
        # 自动化（测试/无人值守）时：logs\.no-ack 存在就不等人点，短暂停留后自动关
        $autoAck = $false
        try { if ($LogDir -and (Test-Path (Join-Path $LogDir '.no-ack'))) { $autoAck = $true } } catch { }

        if ($autoAck) {
            $until = (Get-Date).AddSeconds($HoldOk)
            while ((Get-Date) -lt $until -and $win.IsVisible) {
                Invoke-UiPump
                Start-Sleep -Milliseconds 30
            }
        } else {
            # 必须点「知道了」才关窗（最多等 10 分钟，防止无人值守时卡死）
            $global:__dsAckDone = $false
            $ctx.ack.Add_Click({ $global:__dsAckDone = $true }.GetNewClosure())
            $until = (Get-Date).AddMinutes(10)
            while (-not $global:__dsAckDone -and $win.IsVisible -and (Get-Date) -lt $until) {
                Invoke-UiPump
                Start-Sleep -Milliseconds 30
            }
        }
    } else {
        $until = (Get-Date).AddSeconds($(if ($err) { $HoldFail } else { $HoldOk }))
        while ((Get-Date) -lt $until -and $win.IsVisible) {
            Invoke-UiPump
            Start-Sleep -Milliseconds 30
        }
    }

    try { $win.Close() } catch { }
    return [pscustomobject]@{ Error = $err; Results = $results }
}
