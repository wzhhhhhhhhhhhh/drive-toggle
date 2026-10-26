#Requires -RunAsAdministrator
<#
  install.ps1 —— 按 config.json 建计划任务和快捷方式

  做这些事：
    1. 没有 config.json 就先跑 setup.ps1（选盘向导）
    2. 建任务：
         Disk-Mount / Disk-Unmount / Disk-Toggle     （总开关）
         Disk-Toggle-1 … Disk-Toggle-N                （每盘一个）
    3. 在桌面放快捷方式：
         「硬盘开关」              总开关
         「硬盘开关 - D 盘」…      每盘一个
       不往开始菜单装东西——想固定到开始屏幕，自己从桌面右键固定。
    4. 清掉上一次安装留下、但这次配置里已经没有的每盘任务/快捷方式

  卸载：删掉上述任务和快捷方式即可，删任务不影响磁盘状态。
#>
param([switch]$SkipSetup, [scriptblock]$Progress = $null)

$ErrorActionPreference = 'Stop'
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$root    = if ((Split-Path $here -Leaf) -eq 'app') { Split-Path $here -Parent } else { $here }
$cfgPath = Join-Path $root 'config.json'
$psExe   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$me      = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$desktop = [Environment]::GetFolderPath('Desktop')
$smDir   = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$icons   = Join-Path $root 'icons'

# ---- 0. 确保有配置 ----
if (-not (Test-Path $cfgPath)) {
    if ($SkipSetup) {
        Write-Host ''
        Write-Host '  没有 config.json，无法安装。请先运行 setup.cmd 选择磁盘。' -ForegroundColor Red
        Start-Sleep -Seconds 6
        exit 1
    }
    & (Join-Path $here 'setup.ps1')
    exit
}

. (Join-Path $here 'dd-core.ps1')
Assert-Configured

$master = $script:MasterName
$list   = @($Targets)

Write-Host ''
Write-Host "=== 安装 $master ===" -ForegroundColor Cyan
Write-Host "  程序目录：$here"
Write-Host "  快捷方式：$desktop"
Write-Host "  管理磁盘：$(($list | ForEach-Object { $_.Label }) -join '、')"
Write-Host ''

# ---- 1. 清理遗留 ----
if ($Progress) { & $Progress '准备安装…' 4 }
if ($Progress) { & $Progress '清理旧任务与旧快捷方式…' 12 }
foreach ($n in 'D-Mount', 'D-Unmount', 'F-Mount', 'F-Unmount') {
    $task = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "  已移除遗留任务 $n" -ForegroundColor DarkGray
    }
}

$validNames = @('Disk-Mount', 'Disk-Unmount', 'Disk-Toggle')
for ($i = 1; $i -le $list.Count; $i++) { $validNames += "Disk-Toggle-$i" }
Get-ScheduledTask -TaskName 'Disk-Toggle-*' -ErrorAction SilentlyContinue | ForEach-Object {
    if ($validNames -notcontains $_.TaskName) {
        Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "  已移除多余任务 $($_.TaskName)" -ForegroundColor DarkGray
    }
}

foreach ($n in '挂载 D 盘', '卸载 D 盘', '挂载 F 盘', '卸载 F 盘', '挂载硬盘', '卸载硬盘') {
    foreach ($dir in @($smDir, $desktop)) {
        $p = Join-Path $dir ($n + '.lnk')
        if (Test-Path $p) {
            Remove-Item -LiteralPath $p -Force
            Write-Host "  已移除旧快捷方式 $p" -ForegroundColor DarkGray
        }
    }
}

# ---- 2. 建任务 ----
function New-DiskTask {
    param([string]$Name, [string]$Script, [string]$Arguments, [string]$Description)
    # 用 launcher.exe 代跑 powershell：它是 GUI 子系统程序，会以 CreateNoWindow 方式拉起脚本，
    # 所以点图标时不会闪任何控制台窗口。
    $taskRun = 'run "' + $Script + '"'
    if ($Arguments) { $taskRun += ' ' + $Arguments }
    $action    = New-ScheduledTaskAction -Execute (Join-Path $root '初始化.exe') -Argument $taskRun -WorkingDirectory $root
    $principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                                              -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $Name -Action $action -Principal $principal `
                           -Settings $settings -Description $Description -Force | Out-Null
}

if ($Progress) { & $Progress '重建计划任务（总开关 + 每盘）…' 35 }
New-DiskTask -Name 'Disk-Mount'   -Script 'mount-all.ps1'   -Arguments '' -Description '挂载全部磁盘'
New-DiskTask -Name 'Disk-Unmount' -Script 'unmount-all.ps1' -Arguments '' -Description '卸载全部磁盘'
New-DiskTask -Name 'Disk-Toggle'  -Script 'toggle-all.ps1'  -Arguments '' -Description "$master（总开关）"
for ($i = 1; $i -le $list.Count; $i++) {
    if ($Progress) { & $Progress ("重建每盘任务 $i / $($list.Count)…") ([int](35 + 30 * $i / [math]::Max(1, $list.Count))) }
    New-DiskTask -Name "Disk-Toggle-$i" -Script 'toggle-all.ps1' -Arguments "-Only $i" `
                 -Description "$master - $($list[$i-1].Label)"
}
Write-Host "  [OK] 任务：Disk-Mount / Disk-Unmount / Disk-Toggle + $($list.Count) 个每盘任务" -ForegroundColor Green

if ($Progress) { & $Progress '生成桌面快捷方式…' 70 }
# ---- 3. 建快捷方式 ----
$ws = New-Object -ComObject WScript.Shell

function New-DiskShortcut {
    param([string]$Label, [string]$TaskName, [string]$IconPath, [string]$Description)
    $lnkPath = Join-Path $desktop ($Label + '.lnk')
    $lnk = $ws.CreateShortcut($lnkPath)
    $lnk.TargetPath       = Join-Path $root '初始化.exe'
    $lnk.Arguments        = 'task "' + $TaskName + '"'
    $lnk.WorkingDirectory = $here
    if (Test-Path $IconPath) { $lnk.IconLocation = $IconPath + ',0' } else { $lnk.IconLocation = 'shell32.dll,21' }
    $lnk.Description      = $Description
    $lnk.Save()
    Write-Host "  [OK] 快捷方式「$Label」" -ForegroundColor Green
}

$sysState   = Get-SystemState
$masterIcon = Get-IconPath $icons (Get-MasterIconName $sysState.State)
$masterDesc = Get-MasterDescription -State $sysState
New-DiskShortcut -Label $master -TaskName 'Disk-Toggle' -IconPath $masterIcon -Description $masterDesc

for ($i = 1; $i -le $list.Count; $i++) {
    if ($Progress) { & $Progress ("生成快捷方式 $i / $($list.Count)…") ([int](70 + 18 * $i / [math]::Max(1, $list.Count))) }
    $t = $list[$i - 1]
    $info = Get-DiskRuntimeInfo $t
    $st = if ($info.State -eq 'on') { 'on' } else { 'off' }
    $letter = if ($info.Letter) { $info.Letter.ToUpper() } else { '' }
    $icon = Get-IconPath $icons (Get-DiskIconName -State $st -Letter $letter)
    if (-not (Test-Path $icon)) { $icon = Get-IconPath $icons (Get-MasterIconName $st) }
    $tag = if ($letter) { "$letter`: 盘" } else { $t.Label }
    $desc = if ($st -eq 'on') { "当前：已挂载 · 点击将断开（$tag）" } else { "当前：已卸载 · 点击将接入（$tag）" }
    New-DiskShortcut -Label ("$master - " + $t.Label) -TaskName "Disk-Toggle-$i" -IconPath $icon -Description $desc
}

# 清掉配置里已经没有的每盘快捷方式
$keep = @($master)
for ($i = 1; $i -le $list.Count; $i++) { $keep += ("$master - " + $list[$i - 1].Label) }
Get-ChildItem $desktop -Filter '*.lnk' -ErrorAction SilentlyContinue | Where-Object {
    $_.BaseName -like "$master - *" -and $keep -notcontains $_.BaseName
} | ForEach-Object {
    Remove-Item -LiteralPath $_.FullName -Force
    Write-Host "  已移除多余快捷方式 $($_.BaseName)" -ForegroundColor DarkGray
}

Write-Host ''
Write-Host "安装完成。桌面上有 $($list.Count + 1) 个快捷方式：" -ForegroundColor Cyan
Write-Host "  「$master」  ← 所有盘一起开关" -ForegroundColor Gray
foreach ($t in $list) { Write-Host "  「$master - $($t.Label)」  ← 只开关这一块" -ForegroundColor Gray }
Write-Host ''
Write-Host '  想放到开始屏幕：右键快捷方式 → 固定到“开始”屏幕' -ForegroundColor DarkGray
Write-Host ("  当前状态：" + $sysState.Detail) -ForegroundColor DarkGray
Write-Host ''
Start-Sleep -Seconds 6

if ($Progress) { & $Progress '创建初始化入口…' 90 }
# ---- 清理旧版「初始化.lnk」（现在 初始化.exe 自己就是入口） ----
$oldSetupLnk = Join-Path $root '初始化.lnk'
if (Test-Path $oldSetupLnk) {
    Remove-Item -LiteralPath $oldSetupLnk -Force
    Write-Host "  已移除旧入口 初始化.lnk（改用 初始化.exe）" -ForegroundColor DarkGray
}
