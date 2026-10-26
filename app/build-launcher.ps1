# build-launcher.ps1 —— 重新编译 初始化.exe（带应用图标）
#
# 为什么用 csc 而不是 Add-Type：Add-Type 无法嵌入 Win32 图标资源。

param([switch]$Quiet)

$root = Split-Path $PSScriptRoot -Parent
$src  = Join-Path $PSScriptRoot '_launcher_src.cs'
$ico  = Join-Path $root 'icons\app.ico'
$out  = Join-Path $root '初始化.exe'

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path $csc)) { throw '找不到 csc.exe（需要 .NET Framework 4.x）' }
if (-not (Test-Path $src)) { throw "找不到源码：$src" }
if (-not (Test-Path $ico)) { throw "找不到图标：$ico" }

Get-Process -Name '初始化' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$args = @(
    '/nologo',
    '/target:winexe',
    '/platform:anycpu',
    '/optimize+',
    "/out:$out",
    "/win32icon:$ico",
    $src
)
$log = & $csc @args 2>&1
if ($LASTEXITCODE -ne 0) {
    throw ("编译失败：`n" + ($log -join "`n"))
}
if (-not $Quiet) { Write-Host "  [OK] $out  ($([math]::Round((Get-Item $out).Length/1KB,1)) KB)" -ForegroundColor Green }