# Maintainer tool: download the diagnostics builders' Foreman sent on Doctor (v0.28).
# Each Doctor press pushes refs/diag/<name>/<yyyyMMdd-HHmmss> to the map repo on GitHub:
# doctor.txt (the Doctor report), addons.txt (every addon folder Workbench/Foreman can see)
# and workbench-logs/ (the last few Workbench log folders, big logs trimmed head+tail).
#
#   powershell -File tools\get-diagnostics.ps1 -Repo C:\path\to\fireforce            # newest per person
#   powershell -File tools\get-diagnostics.ps1 -Repo C:\path\to\fireforce -Who emu   # that person's newest
#   ... -All                                                                          # every report
#
# Output goes to .\diagnostics\<name>\<stamp>\ (opened in Explorer when done).
param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [string]$Who = '',
    [switch]$All,
    [string]$Out = (Join-Path (Get-Location) 'diagnostics'),
    [switch]$NoOpen
)
$ErrorActionPreference = 'Stop'
$prefix = 'refs/diag'

& git -C $Repo fetch --quiet --prune origin "+${prefix}/*:${prefix}/*"
if ($LASTEXITCODE -ne 0) { throw "git fetch of $prefix failed" }
$refs = @(& git -C $Repo for-each-ref --sort=-refname --format='%(refname)' "$prefix/")
if ($refs.Count -eq 0) { Write-Host 'No diagnostics on GitHub yet.'; return }

$byPerson = @{}
foreach ($r in $refs) {
    $parts = $r.Substring($prefix.Length + 1) -split '/'
    if ($parts.Count -lt 2) { continue }
    $name = $parts[0]; $stamp = $parts[1]
    if ($Who -and $name -notlike "*$Who*") { continue }
    if (-not $byPerson.ContainsKey($name)) { $byPerson[$name] = @() }
    $byPerson[$name] += @{ Ref = $r; Stamp = $stamp }
}
if ($byPerson.Count -eq 0) { Write-Host "No diagnostics match '$Who'. People: $((@($refs | ForEach-Object { ($_.Substring($prefix.Length + 1) -split '/')[0] }) | Select-Object -Unique) -join ', ')"; return }

foreach ($name in ($byPerson.Keys | Sort-Object)) {
    $list = @($byPerson[$name] | Sort-Object { $_.Stamp } -Descending)
    if (-not $All) { $list = @($list[0]) }
    foreach ($e in $list) {
        $dest = Join-Path (Join-Path $Out $name) $e.Stamp
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        # git archive -> zip -> expand: keeps the bytes exactly as sent
        $zip = Join-Path $env:TEMP "foreman-diag-$name-$($e.Stamp).zip"
        & git -C $Repo archive --format=zip -o $zip $e.Ref
        if ($LASTEXITCODE -ne 0) { throw "git archive $($e.Ref) failed" }
        Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force
        Remove-Item -LiteralPath $zip -Force
        Write-Host "$name $($e.Stamp) -> $dest"
    }
}
if (-not $NoOpen) { try { Invoke-Item $Out } catch { } }
