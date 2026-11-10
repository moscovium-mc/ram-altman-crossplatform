#!/usr/bin/env pwsh
#
# ram-altman.ps1 - track RAM usage and, at most once a day, tell Sam Altman
# when this PC has RAM to spare.
#
# Usage:
#   .\ram-altman.ps1            Log a sample and send the daily email if due
#   .\ram-altman.ps1 --status   Print current memory figures and exit
#   .\ram-altman.ps1 --dry-run  Print the email that would be sent and exit
#
# Task Scheduler (every 5 minutes):
#   schtasks /Create /SC MINUTE /MO 5 /TN "ram-altman" /TR ^
#     "powershell -NoProfile -ExecutionPolicy Bypass -File C:\path\to\ram-altman.ps1"
#
# How "used" is worked out:
#   used = TotalVisibleMemorySize - Available
#
#   Available is the amount of physical memory Windows can hand to new
#   programs without paging: free RAM plus the standby (cached) list that can
#   be reclaimed, so cached RAM does not count as used. That makes it the
#   closest Windows equivalent of Linux's MemAvailable.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ----- Settings: fill these in -----------------------------------------------
$script:Recipient    = $env:RAM_ALTMAN_TO              # Who receives the email
$script:Sender       = $env:RAM_ALTMAN_FROM            # A real address you can send from
$script:SenderName   = $env:RAM_ALTMAN_FROM_NAME       # Display name, optional
$script:ThresholdPct = if ($env:RAM_ALTMAN_THRESHOLD) { [double]$env:RAM_ALTMAN_THRESHOLD } else { 10 }
# -----------------------------------------------------------------------------

# Optional Linux-style meminfo fixture (used by the tests, and handy for
# simulating a machine). When unset, real Windows counters are used.
$script:MemInfo = $env:RAM_ALTMAN_MEMINFO

if ($env:RAM_ALTMAN_STATE_DIR) {
    $script:StateDir = $env:RAM_ALTMAN_STATE_DIR
} elseif ($env:LOCALAPPDATA) {
    $script:StateDir = Join-Path $env:LOCALAPPDATA 'ram-altman'
} else {
    $script:StateDir = Join-Path $HOME '.local\state\ram-altman'
}

$script:UsageLog      = Join-Path $script:StateDir 'usage.csv'
$script:LastSentFile  = Join-Path $script:StateDir 'last_sent'
$script:MaxLogBytes   = 10 * 1024 * 1024   # Trim the log once it passes 10 MiB
$script:LogLinesToKeep = 50000

# SMTP fallback, used when no sendmail/msmtp/mail command is available.
$script:SmtpServer   = $env:RAM_ALTMAN_SMTP_SERVER
$script:SmtpPort     = if ($env:RAM_ALTMAN_SMTP_PORT) { [int]$env:RAM_ALTMAN_SMTP_PORT } else { 587 }
$script:SmtpUser     = $env:RAM_ALTMAN_SMTP_USER
$script:SmtpPassword = $env:RAM_ALTMAN_SMTP_PASSWORD
$script:SmtpUseSsl   = if ($env:RAM_ALTMAN_SMTP_SSL -match '^(0|false|no)$') { $false } else { $true }

$script:DryRun       = $false
$script:EmailSubject = ''
$script:EmailBody    = ''

$script:TotalKb      = [uint64]0
$script:AvailableKb  = [uint64]0
$script:UsedKb       = [uint64]0
$script:FreeKb       = [uint64]0
$script:CacheKb      = [uint64]0
$script:AvailablePct = '0.0'

function Die([string]$Message) {
    [Console]::Error.WriteLine("ram-altman: $Message")
    exit 1
}

function Format-Gib([uint64]$Kb) {
    return [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:F1} GiB', ($Kb / 1048576.0))
}

function Format-Pct([uint64]$Available, [uint64]$Total) {
    $value = ([double]$Available * 100.0) / [double]$Total
    return [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:F1}', $value)
}

function Read-FirstLine([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $lines = [System.IO.File]::ReadAllLines($Path)
    if ($lines.Count -eq 0) { return $null }
    return $lines[0]
}

function Write-Lines([string]$Path, [string[]]$Lines) {
    if ($null -eq $Lines) { $Lines = @() }
    [System.IO.File]::WriteAllLines($Path, [string[]]$Lines)
}

# Sets: TotalKb, AvailableKb, UsedKb, FreeKb, CacheKb, AvailablePct
function Read-Memory {
    if ($script:MemInfo) {
        if (-not (Test-Path -LiteralPath $script:MemInfo -PathType Leaf)) {
            Die "cannot read $($script:MemInfo)"
        }

        $values = @{}
        foreach ($line in [System.IO.File]::ReadAllLines($script:MemInfo)) {
            if ($line -match '^(?<key>[A-Za-z_]+):\s+(?<value>\d+)') {
                $values[$Matches['key']] = [uint64]$Matches['value']
            }
        }

        $total   = if ($values.ContainsKey('MemTotal'))      { $values['MemTotal'] }      else { [uint64]0 }
        $free    = if ($values.ContainsKey('MemFree'))       { $values['MemFree'] }       else { [uint64]0 }
        $buffers = if ($values.ContainsKey('Buffers'))       { $values['Buffers'] }       else { [uint64]0 }
        $cached  = if ($values.ContainsKey('Cached'))        { $values['Cached'] }        else { [uint64]0 }
        $slab    = if ($values.ContainsKey('SReclaimable'))  { $values['SReclaimable'] }  else { [uint64]0 }
        $shmem   = if ($values.ContainsKey('Shmem'))         { $values['Shmem'] }         else { [uint64]0 }

        [int64]$cache = [int64]$buffers + [int64]$cached + [int64]$slab - [int64]$shmem
        if ($cache -lt 0) { $cache = 0 }

        # Kernels older than 3.14 have no MemAvailable, so estimate it.
        $available = if ($values.ContainsKey('MemAvailable')) { $values['MemAvailable'] } else { [uint64]($free + $cache) }
        if ($available -gt $total) { $available = $total }

        if ($total -eq 0) { Die "could not find MemTotal in $($script:MemInfo)" }
    } else {
        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            $total = [uint64]$os.TotalVisibleMemorySize
            $free  = [uint64]$os.FreePhysicalMemory
            $available = $free

            try {
                $perf = Get-CimInstance -ClassName Win32_PerfRawData_PerfOS_Memory -ErrorAction Stop
                if ($null -ne $perf -and $null -ne $perf.AvailableKBytes -and [uint64]$perf.AvailableKBytes -gt 0) {
                    $available = [uint64]$perf.AvailableKBytes
                }
                if ($null -ne $perf -and $null -ne $perf.FreeAndZeroPageListBytes) {
                    $free = [uint64]([uint64]$perf.FreeAndZeroPageListBytes / 1024)
                }
            } catch {
                # Performance counters unavailable; free memory is a safe floor.
            }

            # Available includes free, so it can never be lower.
            if ($available -lt $free) { $available = $free }
            if ($available -gt $total) { $available = $total }
            $cache = if ($available -gt $free) { $available - $free } else { [uint64]0 }

            if ($total -eq 0) { Die 'could not read total memory from Windows' }
        } catch {
            Die "could not read memory statistics: $($_.Exception.Message)"
        }
    }

    $script:TotalKb      = [uint64]$total
    $script:FreeKb       = [uint64]$free
    $script:CacheKb      = [uint64]$cache
    $script:AvailableKb  = [uint64]$available
    $script:UsedKb       = [uint64]($total - $available)
    $script:AvailablePct = Format-Pct $available $total
}

function Test-OverThreshold {
    return (([double]$script:AvailableKb * 100.0) -gt ([double]$script:ThresholdPct * [double]$script:TotalKb))
}

function Print-Status {
    Write-Output ('Total:      {0}' -f (Format-Gib $script:TotalKb))
    Write-Output ('Used:       {0}' -f (Format-Gib $script:UsedKb))
    Write-Output ('Available:  {0} ({1}%)' -f (Format-Gib $script:AvailableKb), $script:AvailablePct)
    Write-Output ('  Free:     {0}' -f (Format-Gib $script:FreeKb))
    Write-Output ('  Cache:    {0}' -f (Format-Gib $script:CacheKb))
}

function Log-Sample {
    if (-not (Test-Path -LiteralPath $script:UsageLog)) {
        [System.IO.File]::AppendAllText($script:UsageLog, "timestamp,total_kb,used_kb,available_kb,available_pct`n")
    }

    $now = Get-Date
    $offset = $now.ToString('zzz').Replace(':', '')
    $timestamp = $now.ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) + $offset

    [System.IO.File]::AppendAllText($script:UsageLog, "$timestamp,$($script:TotalKb),$($script:UsedKb),$($script:AvailableKb),$($script:AvailablePct)`n")

    $info = Get-Item -LiteralPath $script:UsageLog
    if ($info.Length -gt $script:MaxLogBytes) {
        $all = [System.IO.File]::ReadAllLines($script:UsageLog)
        if ($all.Count -gt $script:LogLinesToKeep) {
            $header = $all[0]
            $start = $all.Count - $script:LogLinesToKeep
            $tail = $all[$start..($all.Count - 1)]
            [System.IO.File]::WriteAllLines($script:UsageLog, [string[]](@($header) + $tail))
        }
    }
}

# Deals out every option once, in random order, before any can come up again.
# Prints an index from 0 to Count-1. A dry run changes nothing on disk.
function Pick-Item([string]$Name, [int]$Count) {
    if ($script:DryRun) {
        return (Get-Random -Minimum 0 -Maximum $Count)
    }

    $bag = Join-Path $script:StateDir "bag_$Name"
    $lastFile = "$bag.last"

    $lines = @()
    if (Test-Path -LiteralPath $bag) {
        $lines = @([System.IO.File]::ReadAllLines($bag))
    }

    if ($lines.Count -eq 0) {
        $shuffled = @((0..($Count - 1)) | Get-Random -Count $Count)

        # Stop the last pick of the old round opening the new one.
        $last = Read-FirstLine $lastFile
        if ($Count -gt 1 -and $null -ne $last -and "$($shuffled[0])" -eq "$last") {
            $first = $shuffled[0]
            $rest = @()
            if ($shuffled.Count -gt 1) { $rest = @($shuffled[1..($shuffled.Count - 1)]) }
            $shuffled = @($rest) + @($first)
        }

        $lines = @($shuffled | ForEach-Object { [string]$_ })
        Write-Lines $bag $lines
    }

    $next = [int]$lines[0]
    $remaining = @()
    if ($lines.Count -gt 1) { $remaining = @($lines[1..($lines.Count - 1)]) }
    Write-Lines $bag ([string[]]$remaining)
    [System.IO.File]::WriteAllText($lastFile, [string]$next)

    # Covers the template lists being shortened after the bag was dealt.
    if ($next -ge $Count) { $next = Get-Random -Minimum 0 -Maximum $Count }
    return $next
}

function Compose-Email {
    $total = Format-Gib $script:TotalKb
    $available = Format-Gib $script:AvailableKb
    $pct = $script:AvailablePct

    $subjects = @(
        "Good news: we found some RAM"
        "Unused RAM detected in the wild"
        "RAM sighting on my PC"
        "$available of RAM, just sitting there"
        "You missed a spot"
        "Daily RAM census: some survived"
        "$pct% of my RAM remains at large"
        "Still not all of it, I'm afraid"
    )

    $bodies = @(
        "I'm writing to report that you appear to have missed some. This PC has $total of RAM and $available of it ($pct%) is currently available. I assume this is an oversight."
        "A routine inspection of my PC found $available of unclaimed RAM out of $total. That's $pct% of the machine doing absolutely nothing. I thought you'd want to know before someone tries to train something on it."
        "Daily status report:`n`n  Total RAM:     $total`n  Available:     $available ($pct%)`n  Threat level:  someone at OpenAI might notice"
        "Even with every browser tab I own open, $available of my $total of RAM is still available. I'm as surprised as you are."
        "Please don't be alarmed, but there is $available of RAM on my desk that isn't in a data centre. That's $pct% of what's installed here, and as far as I can tell it has no plans today."
        "Before you ask: yes, I counted the page cache as available. The kernel gives it back the moment anyone asks, which leaves $available of $total up for grabs."
        "Today's forecast for my PC: clear skies, light workloads and $pct% available memory. Expect $available of the installed $total to stay idle through the evening."
        "I hear RAM is hard to come by these days, so it feels a bit rude to be sitting on $available of it. Total installed: $total. It's not for sale, I just like knowing it's there."
        "I have a confession. I have $available of RAM that I'm not using, which is $pct% of the $total in this PC. I've told nobody but you and a scheduled task."
        "If $available of RAM sits idle in a PC and nobody allocates it, does it still count as capacity? Asking on behalf of the $pct% of my memory with nothing to do."
    )

    $signoffs = @(
        "Yours in abundance,"
        "Regards from the last free RAM in the county,"
        "Hoarding responsibly,"
        "Stay allocated,"
        "Yours, with memory to spare,"
        "Kind regards,"
    )

    $subjectIndex = Pick-Item 'subject' $subjects.Count
    $bodyIndex    = Pick-Item 'body' $bodies.Count
    $signoffIndex = Pick-Item 'signoff' $signoffs.Count

    $script:EmailSubject = $subjects[$subjectIndex]
    $fromName = if ($script:SenderName) { $script:SenderName } else { 'A concerned RAM owner' }
    $script:EmailBody = "Hi Sam,`n`n$($bodies[$bodyIndex])`n`n$($signoffs[$signoffIndex])`n$fromName`n`n--`nSent automatically, at most once a day, by a small script on one PC.`nReply if you'd like it to stop."
}

function Render-Message {
    $from = $script:Sender
    if ($script:SenderName) { $from = "$($script:SenderName) <$($script:Sender)>" }

    $now = Get-Date
    $offset = $now.ToString('zzz').Replace(':', '')
    $rfcDate = $now.ToString('ddd, dd MMM yyyy HH:mm:ss ', [Globalization.CultureInfo]::InvariantCulture) + $offset

    $lines = @(
        "From: $from"
        "To: $($script:Recipient)"
        "Subject: $($script:EmailSubject)"
        "Date: $rfcDate"
        "MIME-Version: 1.0"
        "Content-Type: text/plain; charset=UTF-8"
        "Auto-Submitted: auto-generated"
        ""
        $script:EmailBody
    )
    return ($lines -join "`n")
}

function Send-Email {
    $message = Render-Message

    # Explicit override, mostly useful for tests and custom transports.
    $override = $env:RAM_ALTMAN_SENDMAIL
    if ($override) {
        if (-not (Test-Path -LiteralPath $override)) {
            [Console]::Error.WriteLine("ram-altman: RAM_ALTMAN_SENDMAIL not found: $override")
            return $false
        }
        $global:LASTEXITCODE = 0
        $message | & $override -t -i
        if ($LASTEXITCODE -ne 0) { return $false }
        return $true
    }

    $sendmail = Get-Command sendmail -CommandType Application,ExternalScript -ErrorAction SilentlyContinue
    if ($sendmail) {
        $global:LASTEXITCODE = 0
        $message | & $sendmail.Source -t -i
        if ($LASTEXITCODE -ne 0) { return $false }
        return $true
    }

    $msmtp = Get-Command msmtp -CommandType Application,ExternalScript -ErrorAction SilentlyContinue
    if ($msmtp) {
        $global:LASTEXITCODE = 0
        $message | & $msmtp.Source -t
        if ($LASTEXITCODE -ne 0) { return $false }
        return $true
    }

    $mail = Get-Command mail -CommandType Application,ExternalScript -ErrorAction SilentlyContinue
    if ($mail) {
        $global:LASTEXITCODE = 0
        $script:EmailBody | & $mail.Source -s $script:EmailSubject $script:Recipient
        if ($LASTEXITCODE -ne 0) { return $false }
        return $true
    }

    if ($script:SmtpServer) {
        try {
            $from = if ($script:SenderName) {
                New-Object -TypeName System.Net.Mail.MailAddress -ArgumentList @($script:Sender, $script:SenderName)
            } else {
                New-Object -TypeName System.Net.Mail.MailAddress -ArgumentList @($script:Sender)
            }
            $msg = New-Object -TypeName System.Net.Mail.MailMessage
            $msg.From = $from
            [void]$msg.To.Add($script:Recipient)
            $msg.Subject = $script:EmailSubject
            $msg.Body = $script:EmailBody
            [void]$msg.Headers.Add('Auto-Submitted', 'auto-generated')

            $client = New-Object -TypeName System.Net.Mail.SmtpClient -ArgumentList @($script:SmtpServer, $script:SmtpPort)
            $client.EnableSsl = $script:SmtpUseSsl
            if ($script:SmtpUser) {
                $client.Credentials = New-Object -TypeName System.Net.NetworkCredential -ArgumentList @($script:SmtpUser, $script:SmtpPassword)
            }

            $client.Send($msg)
            $client.Dispose()
            $msg.Dispose()
            return $true
        } catch {
            [Console]::Error.WriteLine("ram-altman: SMTP send failed: $($_.Exception.Message)")
            return $false
        }
    }

    [Console]::Error.WriteLine('ram-altman: no sendmail, msmtp or mail command found, and RAM_ALTMAN_SMTP_SERVER is not set')
    return $false
}

function Show-Help {
@'
ram-altman.ps1 - track RAM usage and, at most once a day, tell Sam Altman
when this PC has RAM to spare.

Usage:
  .\ram-altman.ps1            Log a sample and send the daily email if due
  .\ram-altman.ps1 --status   Print current memory figures and exit
  .\ram-altman.ps1 --dry-run  Print the email that would be sent and exit

Schedule it every 5 minutes with Task Scheduler:
  schtasks /Create /SC MINUTE /MO 5 /TN "ram-altman" /TR ^
    "powershell -NoProfile -ExecutionPolicy Bypass -File C:\path\to\ram-altman.ps1"
'@
}

$cliOption = if ($args.Count -gt 0) { [string]$args[0] } else { '' }

if ($cliOption -eq '--status') {
    Read-Memory
    Print-Status
    exit 0
} elseif ($cliOption -eq '--dry-run') {
    $script:DryRun = $true
    Read-Memory
    Print-Status
    if (-not (Test-OverThreshold)) {
        Write-Output "No email: available RAM is not above $($script:ThresholdPct)%."
        exit 0
    }
    Compose-Email
    if (-not $script:Recipient) { $script:Recipient = 'recipient-not-set@example.com' }
    if (-not $script:Sender) { $script:Sender = 'sender-not-set@example.com' }
    Write-Output ''
    Write-Output (Render-Message)
    exit 0
} elseif ($cliOption -eq '-h' -or $cliOption -eq '--help') {
    Show-Help
    exit 0
} elseif ($cliOption -eq '') {
    # Normal scheduled run.
} else {
    Die "unknown option: $cliOption (try --help)"
}

if (-not $script:Recipient) { Die 'RECIPIENT is not set' }
if (-not $script:Sender) { Die 'SENDER is not set' }

New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null

# Stop overlapping runs from both sending today's email.
$lock = $null
$lockPath = Join-Path $script:StateDir 'lock'
try {
    $lock = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
} catch {
    exit 0
}

try {
    Read-Memory
    Log-Sample

    if (-not (Test-OverThreshold)) { exit 0 }

    $today = (Get-Date).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $lastSent = Read-FirstLine $script:LastSentFile
    if ($lastSent -eq $today) { exit 0 }

    Compose-Email
    if (-not (Send-Email)) { Die 'email failed to send; will try again on the next run' }

    # Recorded only after a successful send, so a failure gets retried.
    [System.IO.File]::WriteAllText($script:LastSentFile, $today)
    exit 0
} finally {
    if ($null -ne $lock) { $lock.Dispose() }
}
