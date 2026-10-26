#Requires -RunAsAdministrator
<#
  setup.ps1 —— 初始化（GUI 版）

  流程：问沿用/重选 → 选盘窗口 → 写 config.json → 建任务和快捷方式 → 结果提示
#>
param(
    [switch]$Reconfigure,
    [switch]$NoInstall
)

# ---- 全局错误捕获：弹窗 + 写日志 ----
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
            [void](Show-UiMessage -Message "初始化出错：`n`n$msg`n`n详细信息已写入：`n$rootDir\logs\ui-error.log" -Title '磁盘开关' -Kind 'error')
        }
    } catch { }
    exit 1
}

. (Join-Path $PSScriptRoot 'dd-core.ps1')
. (Join-Path $PSScriptRoot 'ui-wpf.ps1')

$root    = $script:Root
$cfgPath = Join-Path $root 'config.json'

# ---- 已有配置：问一下 ----
if ((Test-Path $cfgPath) -and -not $Reconfigure) {
    $old = $null
    try { $old = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    if ($old) {
        $names = (@($old.disks) | ForEach-Object { $_.name }) -join '、'
        $ans = Show-SetupConfirm -Names $names -Title '磁盘开关 · 初始化'
        if ($ans -eq 'cancel') { exit 0 }
        if ($ans -eq 'reuse') {
            if ($NoInstall) { exit 0 }
            # 沿用现有配置：重建任务和快捷方式，同样走进度窗（后台跑）
            $outcome = Show-OperationDialog -Title '初始化' -Direction 'setup' -HoldOk 1.6 `
                -ScriptPath (Join-Path $PSScriptRoot 'install.ps1') `
                -ScriptArgs @{ SkipSetup = $true }
            if ($outcome.Error) { exit 1 }
            exit 0
        }
    }
}

# ---- 枚举磁盘 ----
$all = @(Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem } | Sort-Object Number)
if ($all.Count -eq 0) {
    [void](Show-UiMessage -Message '没有找到可用的非系统磁盘。' -Kind 'error')
    exit 1
}

$physical = @(Get-PhysicalDisk -ErrorAction SilentlyContinue)
$rows = @()
for ($i = 0; $i -lt $all.Count; $i++) {
    $d = $all[$i]
    $parts = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter })
    $letters = if ($parts.Count -gt 0) { ($parts | ForEach-Object { $_.DriveLetter }) -join ',' } else { '—' }
    $pd = $physical | Where-Object { [string]$_.DeviceId -eq [string]$d.Number } | Select-Object -First 1
    $rows += [pscustomobject]@{
        Index   = $i + 1
        Disk    = $d
        Letters = $letters
        Model   = $d.FriendlyName
        SizeGB  = [math]::Round($d.Size / 1GB, 1)
        Bus     = $(if ($d.BusType) { [string]$d.BusType } else { '?' })
        Media   = $(if ($pd -and $pd.MediaType) { [string]$pd.MediaType } else { '?' })
    }
}

$picked = @(Show-DiskPicker -Rows $rows)
if ($picked.Count -eq 0) { exit 0 }

# 防呆：编号必须落在有效范围内（自绘窗口正常不会给出越界值，但别让坏数据进配置）
$picked = @($picked | Where-Object { $_ -ge 1 -and $_ -le $rows.Count } | Select-Object -Unique)
if ($picked.Count -eq 0) {
    [void](Show-UiMessage -Message '没有选中有效的磁盘，配置未修改。' -Kind 'error')
    exit 1
}

# ---- 写配置 ----
$diskCfg = @()
foreach ($n in $picked) {
    $r = $rows[$n - 1]
    $letter = if ($r.Letters -ne '—') { ($r.Letters -split ',')[0] } else { '' }
    $name = if ($letter) { "$letter 盘" } else { "磁盘$($r.Disk.Number)" }
    $desc = '{0} · {1} GB · {2}' -f $r.Model, $r.SizeGB, $r.Bus
    $diskCfg += [ordered]@{
        serial    = [string]$r.Disk.SerialNumber
        name      = $name
        desc      = $desc
        bus       = $r.Bus
        letter    = $letter
        waitTicks = $(if ($r.Bus -eq 'USB') { 60 } else { 30 })
    }
}

$cfg  = [ordered]@{ version = 1; masterName = '硬盘开关'; disks = $diskCfg }
$json = $cfg | ConvertTo-Json -Depth 8
$names = (@($diskCfg) | ForEach-Object { $_.name }) -join '、'

if ($NoInstall) {
    [IO.File]::WriteAllText($cfgPath, $json, (New-Object Text.UTF8Encoding($false)))
    [void](Show-UiMessage -Message "配置已保存（未创建快捷方式）。`n`n$cfgPath")
    exit 0
}

# ---- 先落配置（瞬间完成），安装步骤交给进度窗在后台跑 ----
[IO.File]::WriteAllText($cfgPath, $json, (New-Object Text.UTF8Encoding($false)))

$outcome = Show-OperationDialog -Title '初始化' -Direction 'setup' -HoldOk 1.6 `
    -ScriptPath (Join-Path $PSScriptRoot 'install.ps1') `
    -ScriptArgs @{ SkipSetup = $true }

if ($outcome.Error) { exit 1 }

