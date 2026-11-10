# Ram-Altman for Windows

A PowerShell port of [`ram-altman.sh`](ram-altman.sh). It tracks RAM usage and, at most once a day, emails Sam Altman to report any RAM this PC is not using.

## What it does

- Samples total, used and available RAM.
- Counts the standby (cached) list as available, because Windows can hand it to new programs without paging. This is the closest equivalent to Linux's `MemAvailable`.
- Logs every sample to `usage.csv`.
- Sends at most one email per day, only when available RAM is above the threshold.
- Rotates subject lines, messages and sign-offs without repeating until every option has been used.
- Retries on the next run if sending fails.

## Requirements

- Windows 10 or 11 with Windows PowerShell 5.1 (built in) or PowerShell 7+.
- A way to send mail: an SMTP server, or `sendmail`/`msmtp`/`mail` on `PATH` (for example from Git Bash or msys2).

No admin rights are needed.

## Quick start

```powershell
# See the evidence against you
.\ram-altman.ps1 --status

# Preview an email without sending it
.\ram-altman.ps1 --dry-run

# Send for real
$env:RAM_ALTMAN_TO = 'recipient@example.com'
$env:RAM_ALTMAN_FROM = 'you@example.com'
$env:RAM_ALTMAN_FROM_NAME = 'Your Name'
.\ram-altman.ps1
```

If PowerShell blocks local scripts, run them with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ram-altman.ps1 --status
```

Or allow scripts for the current PowerShell window only:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\ram-altman.ps1 --status
```

## Settings

All settings are environment variables. The first three are required for a real run.

| Setting | What it does | Default |
| --- | --- | --- |
| `RAM_ALTMAN_TO` | Who receives the bad news | Required |
| `RAM_ALTMAN_FROM` | A real address you can send from | Required |
| `RAM_ALTMAN_FROM_NAME` | Your name, or your nom de RAM | Optional |
| `RAM_ALTMAN_THRESHOLD` | Email when available RAM is above this percentage | `10` |
| `RAM_ALTMAN_STATE_DIR` | Where the log and state files live | `%LOCALAPPDATA%\ram-altman` |
| `RAM_ALTMAN_SMTP_SERVER` | SMTP server used when no sendmail/msmtp/mail command exists | Not set |
| `RAM_ALTMAN_SMTP_PORT` | SMTP port | `587` |
| `RAM_ALTMAN_SMTP_USER` | SMTP username | Not set |
| `RAM_ALTMAN_SMTP_PASSWORD` | SMTP password or app password | Not set |
| `RAM_ALTMAN_SMTP_SSL` | Set to `0`, `false` or `no` to disable TLS | Enabled |
| `RAM_ALTMAN_SENDMAIL` | Path to a custom sendmail-compatible command | Not set |

### Sending through SMTP

If `sendmail`, `msmtp` and `mail` are not found, the script uses .NET's SMTP client:

```powershell
$env:RAM_ALTMAN_SMTP_SERVER = 'smtp.example.com'
$env:RAM_ALTMAN_SMTP_PORT = '587'
$env:RAM_ALTMAN_SMTP_USER = 'you@example.com'
$env:RAM_ALTMAN_SMTP_PASSWORD = 'your-app-password'
```

For a local relay on port 25 without TLS, also set:

```powershell
$env:RAM_ALTMAN_SMTP_SSL = '0'
```

Many providers (including Gmail and Outlook) require an app password rather than your normal account password.

## Scheduling with Task Scheduler

Run every five minutes:

```bat
schtasks /Create /SC MINUTE /MO 5 /TN "ram-altman" /TR "powershell -NoProfile -ExecutionPolicy Bypass -File C:\path\to\ram-altman.ps1"
```

To remove it:

```bat
schtasks /Delete /TN "ram-altman" /F
```

Task Scheduler runs the task with your user environment, so either set the settings permanently with `setx` before creating the task:

```bat
setx RAM_ALTMAN_TO "recipient@example.com"
setx RAM_ALTMAN_FROM "you@example.com"
setx RAM_ALTMAN_SMTP_SERVER "smtp.example.com"
setx RAM_ALTMAN_SMTP_USER "you@example.com"
setx RAM_ALTMAN_SMTP_PASSWORD "your-app-password"
```

or edit the settings block at the top of `ram-altman.ps1`.

`setx` changes take effect in new processes, so log out and back in (or restart Task Scheduler) if the task does not see them immediately.

## Files

By default, state lives in `%LOCALAPPDATA%\ram-altman`:

- `usage.csv` — one row per sample.
- `last_sent` — date of the last successful send.
- `bag_subject`, `bag_body`, `bag_signoff` — rotation state.
- `lock` — prevents overlapping runs from both sending.

The log is trimmed to its header plus the most recent 50,000 rows once it exceeds 10 MiB.

## Audit yourself

```powershell
$rows = Import-Csv "$env:LOCALAPPDATA\ram-altman\usage.csv"
$used = ($rows | Measure-Object -Property used_kb -Sum).Sum
$total = ($rows | Measure-Object -Property total_kb -Sum).Sum
'{0:F1}% of samples were RAM in use (the claim: maybe 5%)' -f ($used * 100 / $total)
```

## Tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\test-ram-altman.ps1
```

The tests use a simulated `meminfo` fixture and a fake sendmail, so they never touch a real inbox. They cover the cache accounting, the threshold boundary, daily deduplication, failed-send retries, the old-kernel fallback, rotation without repeats, and missing configuration.

Testing requires no internet access: `--status` reads local Windows counters, `--dry-run` only prints, and the tests use a local fake sendmail. Only a real send (SMTP or a mail command) uses the network.

## Test locally without sending a live email

### Preview only

```powershell
.\ram-altman.ps1 --dry-run
```

This prints the exact email and does not touch the network or the state directory. If your real machine is below the threshold, it will print `No email: ...` instead. To force a preview with simulated figures, use a `meminfo` fixture:

```powershell
@'
MemTotal:       16000000 kB
MemFree:        300000 kB
MemAvailable:   9000000 kB
Buffers:        200000 kB
Cached:         8000000 kB
SReclaimable:   500000 kB
Shmem:          100000 kB
'@ | Set-Content "$env:TEMP\ram-altman-meminfo"

$env:RAM_ALTMAN_MEMINFO = "$env:TEMP\ram-altman-meminfo"
$env:RAM_ALTMAN_TO = 'to@example.com'
$env:RAM_ALTMAN_FROM = 'from@example.com'
.\ram-altman.ps1 --dry-run
```

### Exercise the full send path safely

Use the included fake sendmail, which appends messages to a file, and a temporary state directory so your real `last_sent` file is untouched:

```powershell
$env:RAM_ALTMAN_SENDMAIL   = "$PWD\fake-sendmail.ps1"
$env:RAM_ALTMAN_FAKE_OUTBOX = "$env:TEMP\ram-altman-outbox.txt"
$env:RAM_ALTMAN_STATE_DIR  = "$env:TEMP\ram-altman-test-state"
$env:RAM_ALTMAN_MEMINFO    = "$env:TEMP\ram-altman-meminfo"
$env:RAM_ALTMAN_TO         = 'to@example.com'
$env:RAM_ALTMAN_FROM       = 'from@example.com'

# First run: should "send" one message
.\ram-altman.ps1

# Second run: same day, should not send again
.\ram-altman.ps1

# Inspect what would have been sent
Get-Content "$env:TEMP\ram-altman-outbox.txt"
```

To simulate a failed send and verify the retry behavior, run with:

```powershell
$env:RAM_ALTMAN_FAKE_FAIL = '1'
.\ram-altman.ps1   # exits 1, does not update last_sent
Remove-Item Env:RAM_ALTMAN_FAKE_FAIL
.\ram-altman.ps1   # retries and succeeds
```

Clean up afterwards:

```powershell
Remove-Item "$env:TEMP\ram-altman-test-state" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:TEMP\ram-altman-outbox.txt" -Force -ErrorAction SilentlyContinue
Remove-Item Env:RAM_ALTMAN_SENDMAIL, Env:RAM_ALTMAN_FAKE_OUTBOX, Env:RAM_ALTMAN_STATE_DIR, Env:RAM_ALTMAN_MEMINFO, Env:RAM_ALTMAN_TO, Env:RAM_ALTMAN_FROM -ErrorAction SilentlyContinue
```

### Run the automated tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\test-ram-altman.ps1
```

The suite already uses a temporary state directory and its own fake sendmail, so it never sends anything or touches your real state.

## Differences from the Linux version

- Memory figures come from `Win32_OperatingSystem` and `Win32_PerfRawData_PerfOS_Memory` instead of `/proc/meminfo`.
- Available RAM includes the standby/cached list; `Free` is the free and zero-page list.
- State defaults to `%LOCALAPPDATA%\ram-altman` instead of `~/.local/state/ram-altman`.
- Scheduling uses Task Scheduler instead of cron.
- Email can be sent through SMTP directly, since Windows has no built-in `sendmail`.
- `RAM_ALTMAN_MEMINFO` still works as a test/simulation hook: point it at a Linux-style `meminfo` file to reproduce the original numbers.

## Please be a good neighbour

One email a day from one person is a joke. Ten thousand is a denial-of-service attack with better material. Use `--dry-run`, use your own real address, and stop if anyone asks you to.
