#!/usr/bin/env pwsh
# A sendmail stand-in for local testing. It writes each message to a file
# instead of sending it. Point RAM_ALTMAN_SENDMAIL at this script.
#
# Example:
#   $env:RAM_ALTMAN_SENDMAIL   = "$PWD\fake-sendmail.ps1"
#   $env:RAM_ALTMAN_FAKE_OUTBOX = "$env:TEMP\ram-altman-outbox.txt"
#
# Set RAM_ALTMAN_FAKE_FAIL=1 to simulate a failed send (exit 75).

if ($env:RAM_ALTMAN_FAKE_FAIL -eq '1') { exit 75 }

$outbox = if ($env:RAM_ALTMAN_FAKE_OUTBOX) {
    $env:RAM_ALTMAN_FAKE_OUTBOX
} else {
    Join-Path $env:TEMP 'ram-altman-outbox.txt'
}

$lines = @($input)
$text = (($lines | ForEach-Object { [string]$_ }) -join "`n")
[System.IO.File]::AppendAllText($outbox, $text + "`n=====END=====`n")
exit 0
