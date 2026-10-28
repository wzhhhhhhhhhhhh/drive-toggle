# 打桩测试：用假数据验证唤醒面板（不碰真实磁盘）
# 用法：powershell -File test-ui-stub.ps1 [-Count 6] [-Png 输出路径]
param([int]$Count = 6, [string]$Png = '', [switch]$Show)

$ErrorActionPreference = 'Continue'
$appDir = $PSScriptRoot
. (Join-Path $appDir 'ui-wpf.ps1')

Initialize-Wpf | Out-Null

function New-FakeWake([int]$n) {
    $list = @()
    $labels = @('D 盘','F 盘','E 盘','G 盘','H 盘','I 盘','J 盘')
    for ($i = 0; $i -lt $n; $i++) {
        $base = 10000 + $i * 137
        $list += [pscustomobject]@{
            Label          = $(if ($i -lt $labels.Count) { $labels[$i] } else { "盘$($i + 1)" })
            OfflineMinutes = 60 * ($i + 1)
            OfflineText    = ('{0} 小时' -f ($i + 1))
            StartStopDelta = 2 + $i
            PrevStartStop  = $base
            CurStartStop   = $base + 2 + $i
            LoadDelta      = 1 + $i
            PrevLoad       = $base * 2
            CurLoad        = $base * 2 + 1 + $i
        }
    }
    return $list
}

$fail = 0
function Ok($id, $msg) { Write-Host ("  [PASS] {0}  {1}" -f $id, $msg) -ForegroundColor Green }
function No($id, $msg, $detail) { $script:fail++; Write-Host ("  [FAIL] {0}  {1}   {2}" -f $id, $msg, $detail) -ForegroundColor Red }

# 把窗口内容摘出来，离屏测量（Window 不 Show 就不会布局）
function New-Panel([int]$n) {
    $win = Load-UiWindow $script:UiProgressXaml
    $panel = $win.FindName('WakePanel')
    $list  = $win.FindName('WakeList')
    $scroll= $win.FindName('WakeScroll')
    $ack   = $win.FindName('AckButton')
    $logEl = $win.FindName('WakeLog')

    # 名字解析完再摘掉内容，Window 不 Show 也能单独布局
    $root = $win.Content
    $win.Content = $null

    $panel.Visibility = 'Visible'
    $ack.Visibility   = 'Visible'
    [void](Set-WakeListContent -List $list -Items (New-FakeWake $n))

    $root.Measure([System.Windows.Size]::new(476, [double]::PositiveInfinity))
    $root.Arrange([System.Windows.Rect]::new(0, 0, 476, 4000))
    $root.UpdateLayout()

    return [pscustomobject]@{
        Root = $root; Panel = $panel; List = $list; Scroll = $scroll; Ack = $ack; Log = $logEl
        ListH = [math]::Round($list.ActualHeight)
        PanelH = [math]::Round($panel.ActualHeight)
        MaxH = [math]::Round($scroll.MaxHeight)
        Items = $n
    }
}

# ---------- 6 块盘 ----------
$p6 = New-Panel $Count

$titles = @($p6.List.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] })
$grids  = @($p6.List.Children | Where-Object { $_ -is [System.Windows.Controls.Grid] })
$seps   = @($p6.List.Children | Where-Object { $_ -is [System.Windows.Controls.Border] })

if ($titles.Count -eq $Count) { Ok 'U1' "生成了 $($titles.Count) 组盘标题" }
else { No 'U1' '盘标题数量不对' "期望 $Count，实际 $($titles.Count)" }

if ($grids.Count -eq $Count) { Ok 'U2' "生成了 $($grids.Count) 个数据网格" }
else { No 'U2' '数据网格数量不对' "期望 $Count，实际 $($grids.Count)" }

if ($seps.Count -eq $Count - 1) { Ok 'U3' "分隔线 $($seps.Count) 条（$Count 组之间）" }
else { No 'U3' '分隔线数量不对' "期望 $($Count - 1)，实际 $($seps.Count)" }

$scrollH = [math]::Round($p6.Scroll.ActualHeight)
if ($scrollH -le $p6.MaxH + 1) { Ok 'U4' "滚动区高 $scrollH ≤ 上限 $($p6.MaxH)（内容 $($p6.ListH)，盘多就滚动）" }
else { No 'U4' '滚动区没有遵守高度上限' "滚动区 $scrollH 上限 $($p6.MaxH)" }

if ($p6.PanelH -le ($p6.MaxH + 140)) { Ok 'U5' "面板高 $($p6.PanelH) 被限制住（上限约 $($p6.MaxH + 140)）" }
else { No 'U5' '面板高度失控' "实际 $($p6.PanelH)" }

# ---------- 1 块盘：不滚动 ----------
$p1 = New-Panel 1
if ($p1.ListH -le $p1.MaxH) { Ok 'U6' "1 块盘时内容高 $($p1.ListH) ≤ 上限，不需要滚动" }
else { No 'U6' '1 块盘就出现滚动了' "内容 $($p1.ListH)" }

# ---------- 12 块盘：仍然不超过上限 ----------
$p12 = New-Panel 12
if ($p12.PanelH -le ($p12.MaxH + 140)) { Ok 'U7' "12 块盘时面板高 $($p12.PanelH) 仍被限制" }
else { No 'U7' '12 块盘时面板过高' "实际 $($p12.PanelH)" }

# ---------- 滚动条样式：必须是细条（3px 滑块 / 8px 命中区） ----------
$bars = New-Object System.Collections.ArrayList
function Walk-Tree($el) {
    if ($null -eq $el) { return }
    if ($el -is [System.Windows.Controls.Primitives.ScrollBar]) { [void]$bars.Add($el) }
    $n = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($el)
    for ($i = 0; $i -lt $n; $i++) { Walk-Tree ([System.Windows.Media.VisualTreeHelper]::GetChild($el, $i)) }
}
Walk-Tree $p6.Root
$vbar = $bars | Where-Object { $_.Orientation -eq 'Vertical' } | Select-Object -First 1
if ($vbar -and $vbar.Width -eq 8 -and $vbar.Style -ne $null) { Ok 'U8' "纵向滚动条用了自定义细样式（宽 $($vbar.Width)）" }
elseif ($vbar) { No 'U8' '滚动条没有用上自定义样式' "宽 $($vbar.Width)，HasStyle=$($vbar.Style -ne $null)" }
else { No 'U8' '没找到纵向滚动条' '内容没超出？' }

# ---------- 日志链接：必须是可点击的按钮 ----------
$linkEl = $p6.Log
if ($linkEl -is [System.Windows.Controls.Button]) { Ok 'U9' '「明细见 …」是可点击按钮' }
else { No 'U9' '「明细见 …」不是按钮，点不了' "类型 $($linkEl.GetType().Name)" }

# ---------- -Show：真的弹一个窗出来给人试 ----------
if ($Show) {
    $win   = Load-UiWindow $script:UiProgressXaml
    $win.Title = '硬盘开关 · 演示'
    $win.WindowStartupLocation = 'CenterScreen'

    $titleEl = $win.FindName('TitleText')
    $pctEl   = $win.FindName('PercentText')
    $stEl    = $win.FindName('StatusText')
    $fillEl  = $win.FindName('ProgressFill')
    $panelEl = $win.FindName('WakePanel')
    $listEl  = $win.FindName('WakeList')
    $ackEl   = $win.FindName('AckButton')
    $footEl  = $win.FindName('FootText')

    $titleEl.Text = '已挂载'
    $pctEl.Text = '100%'
    $stEl.Text = ''
    $fillEl.Width = 380
    $footEl.Visibility = 'Collapsed'
    $panelEl.Visibility = 'Visible'
    $ackEl.Visibility = 'Visible'

    [void](Set-WakeListContent -List $listEl -Items (New-FakeWake $Count))

    $logDir = Join-Path (Split-Path $appDir -Parent) 'logs'
    [void](Set-WakeLogLink -Button $win.FindName('WakeLog') -LogDir $logDir)

    $win.SizeToContent = 'Height'

    $script:stubClosed = $false
    $ackEl.Add_Click({ $script:stubClosed = $true; try { $win.Close() } catch { } }.GetNewClosure())

    $win.Show()
    $until = (Get-Date).AddMinutes(10)
    while (-not $script:stubClosed -and $win.IsVisible -and (Get-Date) -lt $until) {
        Invoke-UiPump
        Start-Sleep -Milliseconds 30
    }
    try { if ($win.IsVisible) { $win.Close() } } catch { }
    Write-Host '演示窗已关闭' -ForegroundColor Gray
    exit 0
}

# ---------- 渲染一张图 ----------
if ($Png) {
    $h = [int]([math]::Min($p6.PanelH + 150, 620))
    $p6.Root.Measure([System.Windows.Size]::new(476, [double]::PositiveInfinity))
    $p6.Root.Arrange([System.Windows.Rect]::new(0, 0, 476, $h))
    $p6.Root.UpdateLayout()
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap 476, $h, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($p6.Root)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [IO.File]::Create($Png); $enc.Save($fs); $fs.Close()
    Write-Host "  已渲染：$Png" -ForegroundColor Gray
}

Write-Host ''
if ($fail -eq 0) { Write-Host "打桩测试全部通过（$Count 块盘）" -ForegroundColor Green; exit 0 }
else { Write-Host "失败 $fail 项" -ForegroundColor Red; exit 1 }
