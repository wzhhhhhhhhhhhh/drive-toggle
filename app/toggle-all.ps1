#Requires -RunAsAdministrator
<#
  toggle-all.ps1 —— 切换（GUI 版）

  用法：
    toggle-all.ps1              总开关：全部盘一起
    toggle-all.ps1 -Only 2      只操作第 2 块
    -Mount / -Unmount           强制方向
    -Force / -DryRun            跳过占用检查 / 只看不动手
#>
param(
    [switch]$Mount,
    [switch]$Unmount,
    [switch]$Force,
    [switch]$DryRun,
    [int]$Only = 0
)

# ---- 全局错误捕获：弹窗 + 写日志，不静默失败 ----
trap {
    $msg    = $_.Exception.Message
    $detail = $_.ScriptStackTrace
    $rootDir = if ((Split-Path $PSScriptRoot -Leaf) -eq 'app') { Split-Path $PSScriptRoot -Parent } else { $PSScriptRoot }
    try {
        $logDir = Join-Path $rootDir 'logs'
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        ("=== {0} ===`r`n{1}`r`n{2}`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg, $detail) |
            Add-Content -LiteralPath (Join-Path $logDir 'ui-error.log') -Encoding UTF8
    } catch { }
    try {
        # 界面层可能还没加载（比如 dd-core 就失败了），这里兜底加载一次
        $uiPath = Join-Path $PSScriptRoot 'ui-wpf.ps1'
        if (Test-Path $uiPath) { . $uiPath }
        if (Get-Command Show-UiMessage -ErrorAction SilentlyContinue) {
            [void](Show-UiMessage -Message "出错了：`n`n$msg`n`n详细信息已写入：`n$rootDir\logs\ui-error.log" -Title '磁盘开关' -Kind 'error')
        }
    } catch { }
    exit 1
}

. (Join-Path $PSScriptRoot 'dd-core.ps1')
. (Join-Path $PSScriptRoot 'ui-wpf.ps1')

if (-not $script:ConfigOk) {
    [void](Show-UiMessage -Message "还没有配置要管理哪些磁盘。`n`n请先双击「初始化」。" -Kind 'warn')
    exit 1
}

# ---- 选目标 ----
$targets = $Targets
$single = $null
if ($Only -gt 0) {
    if ($Only -gt @($Targets).Count) {
        [void](Show-UiMessage -Message "没有第 $Only 块盘（配置里只有 $(@($Targets).Count) 块）。" -Kind 'error')
        exit 1
    }
    $single = @($Targets)[$Only - 1]
    $targets = @($single)
}
$title = if ($single) { "$($script:MasterName) - $($single.Label)" } else { $script:MasterName }

# ---- 单实例 ----
$mutex = New-Object System.Threading.Mutex($false, 'Local\DriveToggle')
if (-not $mutex.WaitOne(0)) {
    [void](Show-UiMessage -Message '已经有一次磁盘操作在运行，这次跳过。' -Kind 'warn')
    exit 0
}

try {
    $logs = Join-Path $script:Root 'logs'
    $sw = [Diagnostics.Stopwatch]::StartNew()

    $before = Get-SystemState -DiskList $targets
    $dir = Get-ToggleDirection -State $before.State -ForceMount:$Mount -ForceUnmount:$Unmount
    $dirCN = if ($dir -eq 'mount') { '挂载' } else { '卸载' }
    $tag = if ($DryRun) { '切换(演练)' } else { "切换(→$dirCN)" }
    if ($single) { $tag = "$tag·$($single.Label)" }

    # 磁盘操作交给 UI 的后台 runspace 跑（步骤日志也由它在那边初始化），
    # 这样窗口在干活期间仍可拖动、可被别的窗口盖住。
    $dialog = Show-OperationDialog -Title $title -Direction $dir `
        -CorePath (Join-Path $PSScriptRoot 'dd-core.ps1') `
        -Targets $targets -Force:$Force -DryRun:$DryRun `
        -LogDir $logs -ActionLabel $tag

    if ($dialog.Error) {
        Write-StepLog -Stage '异常' -Status 'FAIL' -Detail $dialog.Error
        Write-ActionLog -LogDir $logs -Action $tag -Rows @() -Seconds $sw.Elapsed.TotalSeconds
        exit 1
    }

    if ($dir -eq 'mount' -and -not $DryRun) {
        if (@($dialog.Results | Where-Object { $_.结果 -eq '已挂载' }).Count -gt 0) {
            [void](Open-ThisPC)
        }
    }

    if (-not $DryRun) {
        $icons = Join-Path $script:Root 'icons'
        $overall = Get-SystemState
        [void](Update-ToggleShortcut -State $overall.State -LnkPath (Get-ShortcutCandidates $script:MasterName) -IconDir $icons)
        foreach ($t in $Targets) {
            $info = Get-DiskRuntimeInfo $t
            $st = if ($info.State -eq 'on') { 'on' } else { 'off' }
            [void](Update-DiskShortcut -State $st -Letter $info.Letter -Name $info.Name -IconDir $icons)
        }
        try { ie4uinit.exe -show | Out-Null } catch { }
    }

    $sw.Stop()
    Write-ActionLog -LogDir $logs -Action $tag -Rows $dialog.Results -Seconds $sw.Elapsed.TotalSeconds
}
finally {
    [void]$mutex.ReleaseMutex()
}
