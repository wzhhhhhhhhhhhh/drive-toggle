# test.ps1 —— 冒烟测试（只读，不改任何东西）
#
# 用法：powershell -ExecutionPolicy Bypass -File test.ps1
# 返回码：0 = 全部通过；1 = 有失败项
#
# 覆盖：文件完整性 / 编码 / 语法 / 配置 / 图标覆盖 / 快捷方式与状态一致性 / 计划任务 / 日志格式

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$appDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$here   = if ((Split-Path $appDir -Leaf) -eq 'app') { Split-Path $appDir -Parent } else { $appDir }
$icons  = Join-Path $here 'icons'
$desktop = [Environment]::GetFolderPath('Desktop')
$smDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$ws = New-Object -ComObject WScript.Shell

$pass = 0; $fail = 0; $skip = 0
$fails = @()

function T-Ok   ($id, $msg) { Write-Host ("  [PASS] {0,-6} {1}" -f $id, $msg) -ForegroundColor Green; $script:pass++ }
function T-Fail ($id, $msg, $why) {
    Write-Host ("  [FAIL] {0,-6} {1}" -f $id, $msg) -ForegroundColor Red
    if ($why) { Write-Host ("         → {0}" -f $why) -ForegroundColor DarkRed }
    $script:fail++; $script:fails += "$id  $msg  ($why)"
}
function T-Skip ($id, $msg, $why) {
    Write-Host ("  [SKIP] {0,-6} {1}  ({2})" -f $id, $msg, $why) -ForegroundColor DarkGray
    $script:skip++
}

Write-Host ''
Write-Host '=== 磁盘开关 · 冒烟测试 ===' -ForegroundColor Cyan
Write-Host ''

# ---------- 1. 文件完整性 ----------
Write-Host '1) 文件完整性' -ForegroundColor White
$requiredApp = @('dd-core.ps1', 'ui-picker.xaml', 'setup.ps1', 'install.ps1',
                 'mount-all.ps1', 'unmount-all.ps1', 'toggle-all.ps1', 'test.ps1', 'test-logic.ps1', 'ui-wpf.ps1', 'ui-progress.xaml', 'ui-picker.xaml', 'ui-confirm.xaml')
foreach ($f in $requiredApp) {
    if (Test-Path (Join-Path $appDir $f)) { T-Ok 'F1' "app\$f" } else { T-Fail 'F1' "缺少 app\$f" '文件不存在' }
}
foreach ($f in 'config.json', 'README.md', 'DEVELOPING.md', 'TESTING.md', '初始化.exe') {
    if (Test-Path (Join-Path $here $f)) { T-Ok 'F1' $f } else { T-Fail 'F1' "缺少 $f" '文件不存在' }
}
if (Test-Path $appDir -PathType Container) { T-Ok 'F1' 'app\ 目录存在' } else { T-Fail 'F1' 'app\ 目录缺失' '' }

# ---------- 2. 脚本编码与语法 ----------
Write-Host ''
Write-Host '2) 编码（必须 UTF-8 BOM）与语法' -ForegroundColor White
foreach ($p in (Get-ChildItem $appDir -Filter '*.ps1')) {
    $b = [IO.File]::ReadAllBytes($p.FullName)
    $hasBom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    if ($hasBom) { T-Ok 'F2' "$($p.Name) 有 BOM" } else { T-Fail 'F2' "$($p.Name) 缺 BOM" 'PS 5.1 会按 GBK 读，中文全乱 → 语法错误' }

    $tok = $null; $err = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($p.FullName, [ref]$tok, [ref]$err)
    if ($err.Count -eq 0) { T-Ok 'F3' "$($p.Name) 语法 OK" }
    else { T-Fail 'F3' "$($p.Name) 语法错误" (($err | Select-Object -First 1).Message) }
}

# ---------- 3. 配置 ----------
Write-Host ''
Write-Host '3) 配置（config.json）' -ForegroundColor White
$cfg = $null
try {
    $cfg = Get-Content (Join-Path $here 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    T-Ok 'C1' 'config.json 可解析'
} catch {
    T-Fail 'C1' 'config.json 解析失败' $_.Exception.Message
}

. (Join-Path $appDir 'dd-core.ps1')
if ($script:ConfigOk) { T-Ok 'C2' "已加载 $($Targets.Count) 块盘" } else { T-Fail 'C2' '核心没加载到配置' '检查 config.json 的 disks 数组' }

$badSerial = @($Targets | Where-Object { -not $_.Serial })
if ($badSerial.Count -eq 0) { T-Ok 'C3' '每块盘都有序列号' } else { T-Fail 'C3' '有磁盘缺序列号' "$($badSerial.Count) 块" }

$badLetter = @($Targets | Where-Object { $_.BusExpect -and $_.BusExpect -notin @('SATA', 'USB', 'NVMe', 'SCSI', 'SAS', '1394', 'SD', 'MMC') })
if ($badLetter.Count -eq 0) { T-Ok 'C4' '接口类型合法' } else { T-Fail 'C4' '有磁盘接口类型异常' (($badLetter | ForEach-Object { $_.BusExpect }) -join ',') }

# ---------- 4. 图标覆盖 ----------
Write-Host ''
Write-Host '4) 图标文件' -ForegroundColor White
foreach ($n in 'toggle-on.ico', 'toggle-off.ico') {
    if (Test-Path (Join-Path $icons $n)) { T-Ok 'I1' $n } else { T-Fail 'I1' "缺少 $n" '总开关图标' }
}
foreach ($n in 'mount-v4.ico', 'unmount-v4.ico') { 
    if (Test-Path (Join-Path $icons $n)) { T-Ok 'I2' $n } else { T-Skip 'I2' "$n 不存在" '旧的双按钮图标，可能已清理' }
}

$missing = @()
foreach ($L in [char[]]'ABCDEFGHIJKLMNOPQRSTUVWXYZ') {
    foreach ($s in 'on', 'off') {
        if (-not (Test-Path (Join-Path $icons "disks\disk-$L-$s.ico"))) { $missing += "disks\disk-$L-$s.ico" }
    }
}
if ($missing.Count -eq 0) { T-Ok 'I3' 'A–Z × on/off 共 52 个每盘图标齐全' }
else { T-Fail 'I3' "缺 $($missing.Count) 个每盘图标" (($missing | Select-Object -First 5) -join ', ') }

# ---------- 5. 快捷方式与状态一致性 ----------
Write-Host ''
Write-Host '5) 快捷方式图标是否跟得上真实状态' -ForegroundColor White

function Get-LnkIcon ($path) {
    try {
        $s = $ws.CreateShortcut($path)
        return (Split-Path $s.IconLocation -Leaf) -replace ',\d+$', ''
    } catch { return $null }
}

function Find-Lnk ($baseName) {
    foreach ($d in @($desktop, $smDir)) {
        $p = Join-Path $d ($baseName + '.lnk')
        if (Test-Path $p) { return $p }
    }
    return $null
}

$overall = Get-SystemState
$expectMaster = if ($overall.Online -gt 0) { 'toggle-on.ico' } else { 'toggle-off.ico' }
$masterLnk = Find-Lnk $script:MasterName
if ($masterLnk) {
    $icon = Get-LnkIcon $masterLnk
    if ($icon -eq $expectMaster) { T-Ok 'S1' "总开关图标正确（$icon，状态=$($overall.State)）" }
    else { T-Fail 'S1' "总开关图标与状态不符" "期望 $expectMaster，实际 $icon（状态=$($overall.State)）" }
    # 描述文字
    $desc = ($ws.CreateShortcut($masterLnk)).Description
    if ($desc -and $desc -match '在线|脱机|未连接') { T-Ok 'S2' "总开关描述：$desc" }
    else { T-Fail 'S2' '总开关描述文字缺失或格式不对' "实际：$desc" }
} else {
    T-Skip 'S1' '找不到总开关快捷方式' '没装或已删'
}

foreach ($t in $Targets) {
    $info = Get-DiskRuntimeInfo $t
    $st = if ($info.State -eq 'on') { 'on' } else { 'off' }
    $letter = if ($info.Letter) { $info.Letter.ToUpper() } else { '' }
    $expect = if ($letter) { "disk-$letter-$st.ico" } else { $(if ($st -eq 'on') { 'toggle-on.ico' } else { 'toggle-off.ico' }) }

    $lnk = Find-Lnk ("$($script:MasterName) - " + $t.Label)
    if (-not $lnk) { T-Skip 'S3' "「$($t.Label)」快捷方式不存在" '未安装'; continue }
    $icon = Get-LnkIcon $lnk
    if ($icon -eq $expect) { T-Ok 'S3' "「$($t.Label)」图标正确（$icon）" }
    else { T-Fail 'S3' "「$($t.Label)」图标与状态不符" "期望 $expect，实际 $icon（状态=$($info.State)，盘符=$letter）" }
}

# ---------- 6. 计划任务 ----------
Write-Host ''
Write-Host '6) 计划任务' -ForegroundColor White
foreach ($n in 'Disk-Mount', 'Disk-Unmount', 'Disk-Toggle') {
    $task = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
    if ($task) { T-Ok 'J1' "$n 存在（$($task.State)）" } else { T-Fail 'J1' "$n 不存在" '重跑 install.cmd' }
}
for ($i = 1; $i -le @($Targets).Count; $i++) {
    $task = Get-ScheduledTask -TaskName "Disk-Toggle-$i" -ErrorAction SilentlyContinue
    if ($task) { T-Ok 'J2' "Disk-Toggle-$i 存在" } else { T-Fail 'J2' "Disk-Toggle-$i 不存在" '配置里有这块盘，但没建任务 → 重跑 install.cmd' }
}

# J3：任务动作里引用的脚本必须真实存在（挪目录后最容易断的地方）
$deadTasks = @()
foreach ($n in @('Disk-Mount', 'Disk-Unmount', 'Disk-Toggle') + (1..@($Targets).Count | ForEach-Object { "Disk-Toggle-$_" })) {
    $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
    if (-not $t) { continue }
    $arg = ($t.Actions | Select-Object -First 1).Arguments
    if ($arg -match '-File\s+"([^"]+)"') {
        $scriptPath = $Matches[1]
        if (-not (Test-Path $scriptPath)) { $deadTasks += "$n → $scriptPath" }
    }
}
if ($deadTasks.Count -eq 0) { T-Ok 'J3' '所有计划任务指向的脚本都存在' }
else { T-Fail 'J3' '有计划任务指向不存在的脚本' (($deadTasks | Select-Object -First 3) -join ' | ') + ' —— 双击「初始化.exe」重建' }

# J4：任务动作的可执行文件必须存在，且必须是仓库自带的 初始化.exe
# （挪目录/换机器后最容易失效的一环：还指向已删除的 launcher.exe）
$badExe = @()
foreach ($n in @('Disk-Mount', 'Disk-Unmount', 'Disk-Toggle') + (1..@($Targets).Count | ForEach-Object { "Disk-Toggle-$_" })) {
    $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
    if (-not $t) { continue }
    $act = $t.Actions | Select-Object -First 1
    if (-not $act.Execute) { $badExe += "$n → 没有可执行文件"; continue }
    if (-not (Test-Path $act.Execute)) { $badExe += "$n → $(Split-Path $act.Execute -Leaf) 不存在"; continue }
    if ((Split-Path $act.Execute -Leaf) -ne '初始化.exe') { $badExe += "$n → 指向 $(Split-Path $act.Execute -Leaf)" }
}
if ($badExe.Count -eq 0) { T-Ok 'J4' '计划任务均指向仓库自带的 初始化.exe' }
else { T-Fail 'J4' '计划任务的可执行文件不对' ((($badExe | Select-Object -First 3) -join ' | ') + ' —— 双击 初始化.exe 重建') }

# ---------- 7. 日志格式 ----------
Write-Host ''
Write-Host '7) 日志' -ForegroundColor White
foreach ($spec in @(
    @{ File = 'actions.csv'; Head = '"时间","操作","磁盘","结果","说明","健康","本次耗时秒"' },
    @{ File = 'steps.csv';   Head = '"时间","会话","操作","磁盘","阶段","状态","详情"' }
)) {
    $p = Join-Path $here ('logs\' + $spec.File)
    if (-not (Test-Path $p)) { T-Skip 'L1' "$($spec.File) 还没有" '没执行过操作'; continue }
    $first = (Get-Content $p -TotalCount 1 -Encoding UTF8)
    if ($first -eq $spec.Head) { T-Ok 'L1' "$($spec.File) 表头正确" }
    else { T-Fail 'L1' "$($spec.File) 表头不对" "实际：$first" }
}

# ---------- 8. 测试文档是否跟上了代码 ----------
Write-Host ''
Write-Host '8) 测试文档同步（TESTING.md）' -ForegroundColor White

$docPath = Join-Path $here 'TESTING.md'
if (-not (Test-Path $docPath)) {
    T-Fail 'D1' 'TESTING.md 不存在' '测试用例文档必须存在'
} else {
    $doc = Get-Content $docPath -Raw -Encoding UTF8

    # D1：每个脚本都要在文档的「功能 ↔ 用例矩阵」里出现
    $noDoc = @()
    foreach ($p in (Get-ChildItem $appDir -Filter '*.ps1')) {
        if ($doc -notmatch [regex]::Escape($p.Name)) { $noDoc += $p.Name }
    }
    foreach ($n in '初始化.exe') {
        if ($doc -notmatch [regex]::Escape($n)) { $noDoc += $n }
    }
    if ($noDoc.Count -eq 0) { T-Ok 'D1' '每个脚本/入口都写进了用例矩阵' }
    else { T-Fail 'D1' '有用例矩阵里没提到的脚本' (($noDoc) -join ', ') }

    # D2：本脚本用到的所有用例编号，文档里都要有
    #     文档里可以写区间（如 C1–C4），这里会展开后再比对
    $ids = 'F1','F2','F3','C1','C2','C3','C4','I1','I2','I3','S1','S2','S3','J1','J2','L1','D1','D2','D3','D4'

    $covered = @{}
    foreach ($id in $ids) {
        if ($doc -match ('\b' + [regex]::Escape($id) + '\b')) { $covered[$id] = $true }
    }
    # 展开区间写法：X1–X4 / X1-X4
    foreach ($m in [regex]::Matches($doc, '([A-Z])(\d+)\s*[\u2013\u2014\-\uFF5E~]\s*([A-Z])(\d+)')) {
        $p1 = $m.Groups[1].Value; $n1 = [int]$m.Groups[2].Value
        $p2 = $m.Groups[3].Value; $n2 = [int]$m.Groups[4].Value
        if ($p1 -ne $p2) { continue }
        $lo = [Math]::Min($n1, $n2); $hi = [Math]::Max($n1, $n2)
        for ($k = $lo; $k -le $hi; $k++) { $covered["$p1$k"] = $true }
    }

    $missIds = @()
    foreach ($id in $ids) { if (-not $covered.ContainsKey($id)) { $missIds += $id } }
    if ($missIds.Count -eq 0) { T-Ok 'D2' '自动用例编号在文档里都有对应条目（支持区间写法）' }
    else { T-Fail 'D2' '文档里缺这些自动用例的说明' (($missIds) -join ', ') }

    # D3：改了代码就必须动 TESTING.md（哪怕只是加一行变更记录）
    $docTime = (Get-Item $docPath).LastWriteTime
    $newest = Get-ChildItem $appDir -Filter '*.ps1' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($newest -and $newest.LastWriteTime -gt $docTime.AddSeconds(2)) {
        T-Fail 'D3' '代码比测试文档新' "$($newest.Name) 改于 $($newest.LastWriteTime.ToString('MM-dd HH:mm'))，TESTING.md 停在 $($docTime.ToString('MM-dd HH:mm')) —— 请在变更记录里补一行"
    } else {
        T-Ok 'D3' '测试文档不比代码旧'
    }

    # D4：变更记录存在且至少有一条
    if ($doc -match '(?s)##\s*7?\.?\s*变更记录|## 变更记录') { T-Ok 'D4' '有变更记录章节' }
    else { T-Fail 'D4' '缺少「变更记录」章节' '每次改代码都往里加一行' }
}

# ---------- 9. 逻辑测试（内存假盘，秒级） ----------
Write-Host ''
Write-Host '9) 逻辑测试（用假盘跑完整流程）' -ForegroundColor White
$logic = Join-Path $appDir 'test-logic.ps1'
if (-not (Test-Path $logic)) {
    T-Fail 'L9' 'test-logic.ps1 不存在' '逻辑测试脚本丢了'
} else {
    $logicOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $logic 2>&1
    $logicCode = $LASTEXITCODE
    $logicSum = @($logicOut | Select-String '通过 \d+' | ForEach-Object { $_.Line.Trim() }) | Select-Object -Last 1
    if ($logicCode -eq 0) {
        T-Ok 'L9' ("逻辑用例全过（" + $logicSum + "）")
    } else {
        $bad = @($logicOut | Select-String '\[FAIL\]' | ForEach-Object { $_.Line.Trim() })
        T-Fail 'L9' '逻辑用例有失败' (($bad | Select-Object -First 3) -join ' | ')
    }
}

# ---------- 10. 单盘隔离（后台 runspace 不能丢目标） ----------
Write-Host ''
Write-Host '10) 单盘隔离：worker 只处理传入的盘' -ForegroundColor White
$wpf = Join-Path $appDir 'ui-wpf.ps1'
if (-not (Test-Path $wpf)) {
    T-Fail 'T1' 'ui-wpf.ps1 不存在' ''
} else {
    try {
        . $wpf
        $corePath = Join-Path $appDir 'dd-core.ps1'
        $all = @($Targets)
        if ($all.Count -lt 1) { throw '没有可用的目标盘' }

        # 只传第 1 块
        $w1 = New-UiWorker -CorePath $corePath -Targets @($all[0]) -Direction 'mount' -DryRun $true -LogDir '' -ActionLabel '测试'
        while (-not $w1.Sync.Done) { Start-Sleep -Milliseconds 50 }
        try { [void]$w1.PS.EndInvoke($w1.Handle) } catch { }
        $n1 = @($w1.Sync.Results).Count
        try { $w1.PS.Dispose(); $w1.Runspace.Close(); $w1.Runspace.Dispose() } catch { }

        if ($n1 -eq 1) { T-Ok 'T1' '只传 1 块盘时，worker 只处理 1 块' }
        else { T-Fail 'T1' '单盘模式失效：传 1 块却处理了多块' "实际 $n1 块（曾被 dd-core 的 \$script:Targets 覆盖）" }

        # 传全部
        $w2 = New-UiWorker -CorePath $corePath -Targets $all -Direction 'mount' -DryRun $true -LogDir '' -ActionLabel '测试'
        while (-not $w2.Sync.Done) { Start-Sleep -Milliseconds 50 }
        try { [void]$w2.PS.EndInvoke($w2.Handle) } catch { }
        $n2 = @($w2.Sync.Results).Count
        try { $w2.PS.Dispose(); $w2.Runspace.Close(); $w2.Runspace.Dispose() } catch { }

        if ($n2 -eq $all.Count) { T-Ok 'T2' "全量模式：$($all.Count) 块盘都处理" }
        else { T-Fail 'T2' '全量模式处理数量不对' "期望 $($all.Count)，实际 $n2" }
    } catch {
        T-Fail 'T1' '单盘隔离测试异常' $_.Exception.Message
    }
}

    # D5：仓库文档里不能出现本机档案中的敏感值（本机有 LOCAL.md 时才可校验）
    $localDoc = Join-Path $here 'LOCAL.md'
    if (-not (Test-Path $localDoc)) {
        T-Skip 'D5' '本机没有 LOCAL.md' '换机器/公开仓库时正常'
    } else {
        $secrets = @()
        foreach ($m in [regex]::Matches((Get-Content $localDoc -Raw -Encoding UTF8), '`([A-Z0-9]{12,})`')) {
            $secrets += $m.Groups[1].Value
        }
        $leaks = @()
        foreach ($docFile in 'README.md', 'DEVELOPING.md', 'TESTING.md') {
            $docPath = Join-Path $here $docFile
            if (-not (Test-Path $docPath)) { continue }
            $text = Get-Content $docPath -Raw -Encoding UTF8
            foreach ($s in $secrets) { if ($text.Contains($s)) { $leaks += "$docFile 含 $s" } }
        }
        if ($secrets.Count -eq 0) { T-Skip 'D5' 'LOCAL.md 里没找到可校验的敏感值' '' }
        elseif ($leaks.Count -eq 0) { T-Ok 'D5' "文档已脱敏（校验 $($secrets.Count) 个敏感值）" }
        else { T-Fail 'D5' '文档里还残留本机敏感值' ($leaks -join '; ') }
    }
# D6：界面层已全部 WPF，脚本里不得再出现 System.Windows.Forms
# （ui.ps1 删除后，残留调用会在真机上报「找不到类型」——上次初始化就是这么挂的）
$wf = @()
Get-ChildItem $appDir -Filter '*.ps1' | Where-Object { $_.Name -ne 'test.ps1' } | ForEach-Object {
    $hits = Select-String -Path $_.FullName -Pattern 'System\.Windows\.Forms'
    foreach ($h in $hits) { $wf += "$($_.Name):$($h.LineNumber)" }
}
if ($wf.Count -eq 0) { T-Ok 'D6' '界面层无 WinForms 残留' }
else { T-Fail 'D6' '还有脚本在用 WinForms（初始化会崩）' ($wf -join ', ') }
# ---------- 12. 初始化流程（沙箱：真脚本 + 桩界面，不需要管理员） ----------
Write-Host ''
Write-Host '12) 初始化流程（沙箱跑真实 setup.ps1）' -ForegroundColor White
try {
    $sb = Join-Path $env:TEMP ('dsh-setup-test-' + (Get-Random))
    $sbApp = Join-Path $sb 'app'
    New-Item -ItemType Directory -Path $sbApp -Force | Out-Null
    Copy-Item (Join-Path $appDir '*.ps1') $sbApp -Force
    $setupSb = Join-Path $sbApp 'setup.ps1'
    # 沙箱里去掉管理员要求，其余原样
    [IO.File]::WriteAllLines($setupSb,
        (Get-Content $setupSb -Encoding UTF8 | Where-Object { $_ -notmatch '^#Requires' }),
        (New-Object Text.UTF8Encoding($true)))

    $stubLines = @(
        '$global:__stubPicker = @(__PICKER__)',
        '$global:__stubConfirm = ''__CONFIRM__''',
        '$global:__stubSetupConfirm = ''__SETUP__''',
        'function Show-SetupConfirm { param($Names, $Title) return $global:__stubSetupConfirm }',
        'function Show-DiskPicker { param($Rows) return $global:__stubPicker }',
        'function Show-UiConfirm { param($Message, $Title, $Buttons) return $global:__stubConfirm }',
        'function Show-UiMessage { param($Message, $Title, $Kind) }',
        'function Show-OperationDialog { param($Title, $Direction, $Work, $CorePath, $Targets, $Force, $DryRun, $LogDir, $ActionLabel, $HoldOk, $HoldFail)',
        '    $r = @()',
        '    if ($Work) { $r = @(& $Work { param($t, $p) }) }',
        '    return [pscustomobject]@{ Error = $null; Results = $r }',
        '}'
    )
    $stubPath = Join-Path $sbApp 'ui-wpf.ps1'

    function Invoke-SetupSandbox([int[]]$picker, [string]$confirm, [string]$setupConfirm = 'reselect') {
        $code = $stubLines -join "`r`n"
        $code = $code.Replace('__PICKER__', ($picker -join ',')).Replace('__CONFIRM__', $confirm).Replace('__SETUP__', $setupConfirm)
        [IO.File]::WriteAllText($stubPath, $code, (New-Object Text.UTF8Encoding($true)))
        & powershell -NoProfile -ExecutionPolicy Bypass -File $setupSb -NoInstall *> $null
        return $LASTEXITCODE
    }

    $null = Invoke-SetupSandbox @(1) 'No'
    $cfgSb = Join-Path $sb 'config.json'
    if (-not (Test-Path $cfgSb)) {
        T-Fail 'T3' '沙箱没写出 config.json' ''
    } else {
        $j = Get-Content $cfgSb -Raw -Encoding UTF8 | ConvertFrom-Json
        if (@($j.disks).Count -eq 1) { T-Ok 'T3' '初始化为单盘时写 1 条配置' }
        else { T-Fail 'T3' '单盘配置条数不对' "实际 $(@($j.disks).Count)" }
        $d0 = $j.disks[0]
        $bad = @()
        if (-not $d0.serial) { $bad += 'serial' }
        if (-not $d0.name) { $bad += 'name' }
        if (-not $d0.bus) { $bad += 'bus' }
        if ($d0.serial -ne ([string]$d0.serial).Trim()) { $bad += 'serial 有空白' }
        if ($bad.Count -eq 0) { T-Ok 'T4' '配置字段齐全（serial/name/bus，且已 trim）' }
        else { T-Fail 'T4' '配置字段有问题' (($bad -join ', ') + ' | ' + ($j | ConvertTo-Json -Depth 5 -Compress)) }
    }

    # 勾两块
    $null = Invoke-SetupSandbox @(1, 2) 'No'
    $j2 = Get-Content $cfgSb -Raw -Encoding UTF8 | ConvertFrom-Json
    if (@($j2.disks).Count -eq 2) { T-Ok 'T5' '勾两块写 2 条配置' }
    else { T-Fail 'T5' '多选配置条数不对' "实际 $(@($j2.disks).Count)" }

    # 越界编号：不得写坏配置
    $before = Get-Content $cfgSb -Raw
    $null = Invoke-SetupSandbox @(9) 'No'
    $after = Get-Content $cfgSb -Raw
    if ($before -eq $after) { T-Ok 'T6' '越界编号被拒，配置未被写坏' }
    else { T-Fail 'T6' '越界编号仍写入了配置' '' }

    # 沿用现有配置：不重写
    $before = Get-Content $cfgSb -Raw
    $null = Invoke-SetupSandbox @(1) 'Yes' 'reuse'
    if ((Get-Content $cfgSb -Raw) -eq $before) { T-Ok 'T7' '选「沿用」不改配置' }
    else { T-Fail 'T7' '选「沿用」却改了配置' '' }

    Remove-Item $sb -Recurse -Force -ErrorAction SilentlyContinue
} catch {
    T-Fail 'T3' '初始化沙箱测试异常' $_.Exception.Message
}

# D7：同一个脚本里不得出现「只差大小写」的变量名
# PowerShell 变量名大小写不敏感，$Targets 和 $targets 是同一个变量，
# 曾经因此把「全量盘列表」覆盖成「单块盘」，导致总开关图标算错。
$collisions = @()
Get-ChildItem $appDir -Filter '*.ps1' | Where-Object { $_.Name -ne 'test.ps1' } | ForEach-Object {
    $file = $_
    $text = Get-Content $file.FullName -Raw -Encoding UTF8
    $names = [regex]::Matches($text, '\$([A-Za-z_][A-Za-z0-9_]*)') | ForEach-Object { $_.Groups[1].Value }
    $groups = $names | Group-Object { $_.ToLower() } | Where-Object { ($_.Group | Sort-Object -Unique).Count -gt 1 }
    foreach ($g in $groups) {
        $spellings = ($g.Group | Sort-Object -Unique) -join ' / '
        $collisions += "$($file.Name)：$spellings"
    }
}
if ($collisions.Count -eq 0) { T-Ok 'D7' '没有「只差大小写」的变量名冲突' }
else { T-Fail 'D7' '存在只差大小写的变量名（会互相覆盖）' (($collisions | Select-Object -First 3) -join ' | ') }

# D8：toggle-all 的「全量」与「本次目标」必须是两个变量，且都先赋全量
# （曾经把 $targets 改名时漏了非 -Only 分支，导致总开关点下去什么都不做）
$toggleSrc = Get-Content (Join-Path $appDir 'toggle-all.ps1') -Raw -Encoding UTF8
$hasAll = $toggleSrc -match '\$allTargets\s*=\s*@\(\$Targets\)'
$hasOp  = $toggleSrc -match '\$opTargets\s*=\s*@\(\$Targets\)'
if ($hasAll -and $hasOp) { T-Ok 'D8' '总开关模式的目标列表已正确初始化' }
else { T-Fail 'D8' 'toggle-all 的 $opTargets 初始化可能缺失（总开关会点不动）' "allTargets=$hasAll opTargets=$hasOp" }
# ---------- 汇总 ----------
Write-Host ''
Write-Host '=== 结果 ===' -ForegroundColor Cyan
Write-Host ("  通过 {0}　失败 {1}　跳过 {2}" -f $pass, $fail, $skip) -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) {
    Write-Host ''
    Write-Host '  失败项：' -ForegroundColor Red
    $fails | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
}
Write-Host ''
exit $(if ($fail -eq 0) { 0 } else { 1 })
