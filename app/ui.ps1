# ui.ps1 —— 轻量现代风格 GUI（WinForms，纯自绘）
# 注意：界面常量一律用「函数内局部变量 + 事件闭包捕获」，
#       不要用 $script: 作用域——WinForms 回调里取不到，会报 "brush 不能为 null"。

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Get-UIPalette {
    @{
        Card   = [System.Drawing.Color]::FromArgb(255, 255, 255)
        Ink    = [System.Drawing.Color]::FromArgb(23, 28, 38)
        Muted  = [System.Drawing.Color]::FromArgb(132, 141, 158)
        Line   = [System.Drawing.Color]::FromArgb(229, 234, 241)
        Soft   = [System.Drawing.Color]::FromArgb(246, 248, 251)
        Green  = [System.Drawing.Color]::FromArgb(16, 155, 94)
        Slate  = [System.Drawing.Color]::FromArgb(100, 116, 139)
        Blue   = [System.Drawing.Color]::FromArgb(79, 110, 247)
        Red    = [System.Drawing.Color]::FromArgb(226, 74, 74)
        Gray   = [System.Drawing.Color]::FromArgb(214, 221, 230)
        Sel    = [System.Drawing.Color]::FromArgb(235, 248, 241)
        BoxOff = [System.Drawing.Color]::FromArgb(203, 212, 224)
    }
}

function F ($size, $style = [System.Drawing.FontStyle]::Regular) {
    New-Object System.Drawing.Font('Microsoft YaHei UI', $size, $style)
}

function Get-RoundPath {
    param([System.Drawing.RectangleF]$Rect, [float]$R)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $R * 2
    $p.AddArc($Rect.X, $Rect.Y, $d, $d, 180, 90)
    $p.AddArc($Rect.Right - $d, $Rect.Y, $d, $d, 270, 90)
    $p.AddArc($Rect.Right - $d, $Rect.Bottom - $d, $d, $d, 0, 90)
    $p.AddArc($Rect.X, $Rect.Bottom - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Set-RoundRegion {
    param($Control, [int]$R = 12)
    $rect = New-Object System.Drawing.RectangleF 0, 0, $Control.Width, $Control.Height
    $p = Get-RoundPath $rect $R
    $Control.Region = New-Object System.Drawing.Region($p)
    $p.Dispose()
}

function Enable-DragWindow {
    param($Form)
    if (-not ('Win32Drag.Api' -as [type])) {
        Add-Type -Namespace Win32Drag -Name Api -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ReleaseCapture();
[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);
'@
    }
    $Form.Add_MouseDown({
        param($s, $e)
        if ($e.Button -eq 'Left') {
            [void][Win32Drag.Api]::ReleaseCapture()
            [void][Win32Drag.Api]::SendMessage($s.Handle, 0xA1, [IntPtr]2, [IntPtr]::Zero)
        }
    })
}

function New-UiButton {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 92, [int]$H = 34,
          [System.Drawing.Color]$Back, [System.Drawing.Color]$Fore, [bool]$Primary = $false)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.SetBounds($X, $Y, $W, $H)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $Back
    $b.ForeColor = $Fore
    $b.Font = F 9.5 $(if ($Primary) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular })
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    Set-RoundRegion $b 8
    return $b
}

# ---------------------------------------------------------------- 选盘窗口
function Show-DiskPicker {
    param($Rows)

    $global:__dsUI = Get-UIPalette
    $listH = [math]::Min([math]::Max(@($Rows).Count, 3), 6) * 56
    $W = 700; $H = 96 + $listH + 96

    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = 'None'
    $form.StartPosition = 'CenterScreen'
    $form.Width = $W; $form.Height = $H
    $form.BackColor = $global:__dsUI.Card
    $form.Text = '磁盘开关 · 初始化'
    $form.Font = F 9
    Set-RoundRegion $form 14
    Enable-DragWindow $form

    $form.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = 'AntiAlias'
        $rect = New-Object System.Drawing.RectangleF 0.5, 0.5, ($s.Width - 1.5), ($s.Height - 1.5)
        $p = Get-RoundPath $rect 14
        $pen = New-Object System.Drawing.Pen $global:__dsUI.Line, 1
        $g.DrawPath($pen, $p)
        $pen.Dispose(); $p.Dispose()
    })

    $title = New-Object System.Windows.Forms.Label
    $title.Text = '要管理哪些磁盘'
    $title.Font = F 15 ([System.Drawing.FontStyle]::Bold)
    $title.ForeColor = $global:__dsUI.Ink
    $title.SetBounds(28, 24, 400, 32)
    $form.Controls.Add($title)

    $sub = New-Object System.Windows.Forms.Label
    $sub.Text = '勾选后点「确定」，可多选。系统盘不在列表里。'
    $sub.Font = F 9
    $sub.ForeColor = $global:__dsUI.Muted
    $sub.SetBounds(30, 58, 500, 20)
    $form.Controls.Add($sub)

    $close = New-Object System.Windows.Forms.Label
    $close.Text = '✕'
    $close.Font = F 11
    $close.ForeColor = $global:__dsUI.Muted
    $close.TextAlign = 'MiddleCenter'
    $close.SetBounds($W - 46, 20, 26, 26)
    $close.Cursor = [System.Windows.Forms.Cursors]::Hand
    $close.Add_Click({ $form.DialogResult = 'Cancel'; $form.Close() })
    $form.Controls.Add($close)

    $list = New-Object System.Windows.Forms.ListBox
    $list.SetBounds(28, 94, $W - 56, $listH)
    $list.BorderStyle = 'None'
    $list.DrawMode = 'OwnerDrawFixed'
    $list.ItemHeight = 56
    $list.SelectionMode = 'MultiSimple'
    $list.BackColor = $global:__dsUI.Soft
    $list.Font = F 9.5
    $list.IntegralHeight = $false
    Set-RoundRegion $list 12
    foreach ($r in $Rows) { [void]$list.Items.Add($r) }

    $list.Add_DrawItem({
        param($s, $e)
        if ($e.Index -lt 0) { return }
        $g = $e.Graphics
        $g.SmoothingMode = 'AntiAlias'
        $row = $list.Items[$e.Index]
        $selected = $list.SelectedIndices.Contains($e.Index)

        $bg = if ($selected) { $global:__dsUI.Sel } else { $global:__dsUI.Soft }
        $brush = New-Object System.Drawing.SolidBrush $bg
        $g.FillRectangle($brush, $e.Bounds)
        $brush.Dispose()

        $bx = $e.Bounds.X + 18; $by = $e.Bounds.Y + 16; $bs = 22
        $rect = New-Object System.Drawing.RectangleF $bx, $by, $bs, $bs
        $p = Get-RoundPath $rect 6
        if ($selected) {
            $fill = New-Object System.Drawing.SolidBrush $global:__dsUI.Green
            $g.FillPath($fill, $p); $fill.Dispose()
            $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 2.2
            $g.DrawLines($pen, @(
                (New-Object System.Drawing.PointF ($bx + 5), ($by + 11)),
                (New-Object System.Drawing.PointF ($bx + 9), ($by + 15)),
                (New-Object System.Drawing.PointF ($bx + 17), ($by + 6))
            ))
            $pen.Dispose()
        } else {
            $pen = New-Object System.Drawing.Pen $global:__dsUI.BoxOff, 1.6
            $g.DrawPath($pen, $p); $pen.Dispose()
        }
        $p.Dispose()

        $letter = if ($row.Letters -ne '—') { ($row.Letters -split ',')[0] + ':' } else { '—' }
        $f1 = F 11 ([System.Drawing.FontStyle]::Bold)
        $b1 = New-Object System.Drawing.SolidBrush $global:__dsUI.Ink
        $g.DrawString($letter, $f1, $b1, ($bx + 36), ($e.Bounds.Y + 8))
        $b1.Dispose(); $f1.Dispose()

        $f2 = F 9
        $b2 = New-Object System.Drawing.SolidBrush $global:__dsUI.Ink
        $g.DrawString($row.Model, $f2, $b2, ($bx + 36), ($e.Bounds.Y + 30))
        $b2.Dispose(); $f2.Dispose()

        $tag = '{0} GB   {1}{2}' -f $row.SizeGB, $row.Bus, $(if ($row.Media -eq 'SSD') { '   · 固态盘' } elseif ($row.Bus -eq 'USB') { '   · 移动硬盘' } else { '' })
        $f3 = F 8.5
        $b3 = New-Object System.Drawing.SolidBrush $global:__dsUI.Muted
        $sz = $g.MeasureString($tag, $f3)
        $g.DrawString($tag, $f3, $b3, ($e.Bounds.Right - $sz.Width - 18), ($e.Bounds.Y + 20))
        $b3.Dispose(); $f3.Dispose()
    })

    $lblCount = New-Object System.Windows.Forms.Label
    $lblCount.Text = '尚未选择'
    $lblCount.Font = F 9
    $lblCount.ForeColor = $global:__dsUI.Muted
    $lblCount.SetBounds(30, 94 + $listH + 12, 200, 22)
    $form.Controls.Add($lblCount)

    $ok = New-UiButton -Text '确定' -X ($W - 214) -Y (94 + $listH + 8) -W 88 -H 36 `
        -Back $global:__dsUI.Gray -Fore ([System.Drawing.Color]::White) -Primary $true
    $ok.Enabled = $false
    $ok.DialogResult = 'OK'
    $form.Controls.Add($ok)

    $cancel = New-UiButton -Text '取消' -X ($W - 116) -Y (94 + $listH + 8) -W 88 -H 36 -Back $global:__dsUI.Soft -Fore $global:__dsUI.Ink
    $cancel.DialogResult = 'Cancel'
    $form.Controls.Add($cancel)

    $list.Add_SelectedIndexChanged({
        $n = $list.SelectedIndices.Count
        $lblCount.Text = if ($n -eq 0) { '尚未选择' } else { "已选 $n 块" }
        $ok.Enabled = ($n -gt 0)
        $ok.BackColor = if ($n -gt 0) { $global:__dsUI.Green } else { $global:__dsUI.Gray }
        $list.Invalidate()
        $form.Refresh()
    })
    $list.Add_MouseUp({ $list.Invalidate() })
    $list.Add_KeyUp({ $list.Invalidate() })
    $form.Controls.Add($list)

    $form.AcceptButton = $ok
    $form.CancelButton = $cancel

    $res = $form.ShowDialog()
    $picked = @()
    if ($res -eq 'OK') { foreach ($i in $list.SelectedIndices) { $picked += $Rows[$i].Index } }
    $form.Dispose()
    return $picked
}

# ---------------------------------------------------------------- 提示
function Show-UiMessage {
    param([string]$Message, [string]$Title = '磁盘开关', [string]$Kind = 'info')
    $icon = if ($Kind -eq 'error') { 'Error' } elseif ($Kind -eq 'warn') { 'Warning' } else { 'Information' }
    [void][System.Windows.Forms.MessageBox]::Show($Message, $Title, 'OK', $icon)
}
