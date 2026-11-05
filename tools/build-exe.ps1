# Builds FOREMAN.exe (native launcher, BW icon embedded) from tools\launcher.cs
# using the C# compiler that ships with the .NET Framework on every Windows box.
# Run:  powershell -ExecutionPolicy Bypass -File tools\build-exe.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw 'csc.exe not found — .NET Framework 4.x missing?' }

$ico = Join-Path $root 'assets\icon.ico'

# 1. the app launcher
$src = Join-Path $root 'tools\launcher.cs'
$out = Join-Path $root 'FOREMAN.exe'
& $csc /nologo /target:winexe ("/out:$out") ("/win32icon:$ico") /reference:System.Windows.Forms.dll $src
if ($LASTEXITCODE -ne 0) { throw 'csc build failed (launcher)' }
Write-Host "wrote $out ($((Get-Item $out).Length) bytes)"

# 2. the installer (clone into %LOCALAPPDATA%\Programs + shortcuts + Add/Remove entry)
$src2 = Join-Path $root 'tools\setup.cs'
$out2 = Join-Path $root 'BUSHWAR-Foreman-Setup.exe'
& $csc /nologo /target:winexe ("/out:$out2") ("/win32icon:$ico") /reference:System.Windows.Forms.dll $src2
if ($LASTEXITCODE -ne 0) { throw 'csc build failed (setup)' }
Write-Host "wrote $out2 ($((Get-Item $out2).Length) bytes)"
