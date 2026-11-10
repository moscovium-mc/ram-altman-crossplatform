#!/usr/bin/env pwsh
# Exercises ram-altman.ps1 with simulated memory and a fake sendmail.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'ram-altman.ps1'
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('ram-altman-test-' + [guid]::NewGuid().ToString('N'))
$binDir = Join-Path $work 'bin'
$stateDir = Join-Path $work 'state'
New-Item -ItemType Directory -Path $binDir, $stateDir -Force | Out-Null

$outbox = Join-Path $work 'outbox'
$meminfo = Join-Path $work 'meminfo'
$failFile = Join-Path $work 'fail'
$fakeSendmail = Join-Path $binDir 'sendmail.ps1'

$fakeSendmailBody = @'
$ErrorActionPreference = 'Stop'
if ($env:RAM_ALTMAN_TEST_FAIL -and (Test-Path -LiteralPath $env:RAM_ALTMAN_TEST_FAIL)) { exit 75 }
$lines = @($input)
$text = (($lines | ForEach-Object { [string]$_ }) -join "`n")
[System.IO.File]::AppendAllText($env:RAM_ALTMAN_TEST_OUTBOX, $text + "`n=====END=====`n")
exit 0
'@
[System.IO.File]::WriteAllText($fakeSendmail, $fakeSendmailBody)

$env:PATH = "$binDir;$env:PATH"
$env:RAM_ALTMAN_TO = 'to@example.com'
$env:RAM_ALTMAN_FROM = 'from@example.com'
$env:RAM_ALTMAN_STATE_DIR = $stateDir
$env:RAM_ALTMAN_MEMINFO = $meminfo
$env:RAM_ALTMAN_SENDMAIL = $fakeSendmail
$env:RAM_ALTMAN_TEST_OUTBOX = $outbox
$env:RAM_ALTMAN_TEST_FAIL = ''

$script:Pass = 0
$script:Fail = 0

function Check([string]$Name, $Actual, $Expected) {
    if ([string]$Actual -eq [string]$Expected) {
        $script:Pass++
        Write-Host "ok    $Name"
    } else {
        $script:Fail++
        Write-Host "FAIL  $Name (expected '$Expected', got '$Actual')"
    }
}

function Get-SentCount {
    if (-not (Test-Path -LiteralPath $outbox)) { return 0 }
    $lines = [System.IO.File]::ReadAllLines($outbox)
    return @($lines | Where-Object { $_ -eq '=====END=====' }).Count
}

function Set-MemFixture([string]$Total, [string]$Free, [string]$Available, [string]$Buffers, [string]$Cached, [string]$Slab, [string]$Shmem) {
    $lines = @(
        "MemTotal:       $Total kB"
        "MemFree:        $Free kB"
    )
    if ($Available) { $lines += "MemAvailable:   $Available kB" }
    $lines += @(
        "Buffers:        $Buffers kB"
        "Cached:         $Cached kB"
        "SwapCached:     999999 kB"
        "SReclaimable:   $Slab kB"
        "Shmem:          $Shmem kB"
    )
    [System.IO.File]::WriteAllLines($meminfo, [string[]]$lines)
}

function Invoke-RamAltman([string[]]$ScriptArgs = @()) {
    $global:LASTEXITCODE = 0
    $output = & $scriptPath @ScriptArgs
    return [pscustomobject]@{ Output = @($output); ExitCode = $LASTEXITCODE }
}

try {
    # Mostly page cache: little is free, but plenty is available.
    Set-MemFixture 16000000 300000 9000000 200000 8000000 500000 100000
    Invoke-RamAltman | Out-Null
    Check 'cache counts as available: email sent' (Get-SentCount) 1
    Invoke-RamAltman | Out-Null
    Invoke-RamAltman | Out-Null
    Check 'second and third run same day: no more email' (Get-SentCount) 1

    $csv = [System.IO.File]::ReadAllLines((Join-Path $stateDir 'usage.csv'))
    Check 'used = total - available' (($csv[$csv.Count - 1] -split ',')[2]) 7000000
    Check 'three samples logged' ($csv.Count - 1) 3

    # Next day, tight on memory.
    [System.IO.File]::WriteAllText((Join-Path $stateDir 'last_sent'), '2000-01-01')
    Set-MemFixture 16000000 300000 1000000 100000 800000 100000 100000
    Invoke-RamAltman | Out-Null
    Check '6.2% available: no email' (Get-SentCount) 1

    # Exactly 10% is not over 10%.
    Set-MemFixture 16000000 300000 1600000 100000 800000 100000 100000
    Invoke-RamAltman | Out-Null
    Check 'exactly 10%: no email' (Get-SentCount) 1

    Set-MemFixture 16000000 300000 1600001 100000 800000 100000 100000
    Invoke-RamAltman | Out-Null
    Check 'just over 10%: email sent' (Get-SentCount) 2

    # A failed send is retried, and only recorded once it works.
    [System.IO.File]::WriteAllText((Join-Path $stateDir 'last_sent'), '2000-01-01')
    [System.IO.File]::WriteAllText($failFile, '')
    $env:RAM_ALTMAN_TEST_FAIL = $failFile
    $failed = Invoke-RamAltman
    Check 'failed send exits non-zero' $failed.ExitCode 1
    Check 'failed send not recorded' ([System.IO.File]::ReadAllText((Join-Path $stateDir 'last_sent'))) '2000-01-01'
    Remove-Item -LiteralPath $failFile -Force
    $env:RAM_ALTMAN_TEST_FAIL = ''
    Invoke-RamAltman | Out-Null
    Check 'retry succeeds' (Get-SentCount) 3

    # Old kernel with no MemAvailable: free + buffers + cached + slab - shmem.
    # SwapCached in the fixture must not be picked up as Cached.
    Set-MemFixture 16000000 1000000 '' 200000 3000000 500000 700000
    $status = Invoke-RamAltman -ScriptArgs @('--status')
    $availLine = @($status.Output | Where-Object { $_ -like 'Available:*' })[0]
    $parts = $availLine -split '\s+'
    Check 'fallback estimate' ("$($parts[1]) $($parts[2])") '3.8 GiB'

    # Variety: 10 bodies should all appear across 10 days, with no back-to-back repeat.
    Remove-Item -LiteralPath $outbox -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $stateDir -Filter 'bag_*' | Remove-Item -Force
    Set-MemFixture 16000000 300000 9000000 200000 8000000 500000 100000
    for ($i = 0; $i -lt 40; $i++) {
        [System.IO.File]::WriteAllText((Join-Path $stateDir 'last_sent'), '2000-01-01')
        Invoke-RamAltman | Out-Null
    }

    $text = [System.IO.File]::ReadAllText($outbox)
    $messages = $text -split '=====END====='
    $bodies = @()
    foreach ($message in $messages) {
        $lines = $message -split "`r?`n"
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -eq 'Hi Sam,' -and ($i + 2) -lt $lines.Count) {
                $bodies += $lines[$i + 2]
                break
            }
        }
    }
    Check 'all opening lines used' (@($bodies | Select-Object -First 10 | Sort-Object -Unique).Count) 10

    $dupes = 0
    for ($i = 1; $i -lt $bodies.Count; $i++) {
        if ($bodies[$i] -eq $bodies[$i - 1]) { $dupes++ }
    }
    Check 'no back-to-back repeat' $dupes 0

    # Config errors.
    $savedTo = $env:RAM_ALTMAN_TO
    $env:RAM_ALTMAN_TO = ''
    $missing = Invoke-RamAltman
    Check 'missing recipient refused' $missing.ExitCode 1
    $env:RAM_ALTMAN_TO = $savedTo

    Write-Host ''
    Write-Host "$($script:Pass) passed, $($script:Fail) failed"

    Write-Host ''
    Write-Host '--- real machine status ---'
    $env:RAM_ALTMAN_MEMINFO = ''
    Invoke-RamAltman -ScriptArgs @('--status') | ForEach-Object { $_.Output }

    Write-Host ''
    Write-Host '--- sample dry run ---'
    $env:RAM_ALTMAN_MEMINFO = $meminfo
    Set-MemFixture 16000000 300000 9000000 200000 8000000 500000 100000
    Invoke-RamAltman -ScriptArgs @('--dry-run') | ForEach-Object { $_.Output }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

exit $script:Fail
