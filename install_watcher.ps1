# Install (or remove) the scheduled task that runs update_watcher.ps1 every minute, which is
# what lets the portal's Updates tab apply a new version. Mirrors install_watcher.sh.
# [FEATURE: IN-APP UPDATE]
# SEARCH TAGS: install watcher, schtasks, scheduled task, update watcher, in-app update
#
# Windows PowerShell 5.1 syntax only: no `-and` chaining of native commands, no ternary, no
# null-conditional operator.
#
# Usage: .\install_watcher.ps1            (idempotent: /f replaces the task in place)
#        .\install_watcher.ps1 -Remove
#
# The task runs as the installing user, never SYSTEM: Docker Desktop's engine belongs to the
# signed-in user, and update.ps1 is meant to run as the operator. With no stored password the
# task runs only while that user is signed in -- which is also when Docker Desktop runs.
# Mutates: the Task Scheduler entry named below, nothing else.
param(
  [switch]$Remove
)
$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

$taskName = 'CMS1500 Portal Update Watcher'

# Write-Error throws under 'Stop', so an `exit <code>` after one would never run.
function Fail([string]$message, [int]$code) {
  [Console]::Error.WriteLine($message)
  exit $code
}

# 'Stop' does not see a native program's exit code, so every schtasks call is followed by this.
function Assert-LastExit([string]$what) {
  if ($LASTEXITCODE -ne 0) { Fail "$what failed (exit $LASTEXITCODE)" $LASTEXITCODE }
}

# Asked through the ScheduledTasks module rather than `schtasks /query`, whose "not found"
# goes to native stderr -- and redirecting that under 'Stop' raises NativeCommandError in 5.1.
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

if ($Remove) {
  if ($null -eq $existing) {
    Write-Host "no update watcher task is installed ($taskName)."
    exit 0
  }
  schtasks /delete /tn $taskName /f | Out-Null
  Assert-LastExit 'schtasks /delete'
  Write-Host "removed the scheduled task: $taskName"
  exit 0
}

$watcher = Join-Path $PSScriptRoot 'update_watcher.ps1'
if (-not (Test-Path -LiteralPath $watcher)) { Fail "update_watcher.ps1 is missing from $PSScriptRoot." 2 }
if ($watcher.Contains('"')) { Fail "the bundle path contains a double quote, which a task command cannot carry: $PSScriptRoot" 2 }

$runAs = "$env:USERDOMAIN\$env:USERNAME"
# 5.1 passes an argument's embedded double quotes to a native program unescaped, so the quotes
# around the path are written as \" for schtasks' own command-line parser to unwrap.
$taskCommand = "powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File \`"$watcher\`""
# schtasks refuses a /tr longer than 261 characters.
if ($taskCommand.Length -gt 261) { Fail "the bundle path is too long for a scheduled task command; move the bundle to a shorter folder: $PSScriptRoot" 2 }

# /it: run only while $runAs is signed in, so schtasks stores no password and asks for none.
# Its output is left visible -- piping it away would also hide a prompt it was waiting on.
schtasks /create /tn $taskName /sc minute /mo 1 /it /ru $runAs /tr $taskCommand /f
Assert-LastExit 'schtasks /create'

# schtasks has no flags for these, and its defaults suit a server, not a laptop: a task that
# will not start on battery, is stopped when the power cord comes out, and is never caught up
# after a missed tick. The ScheduledTasks module ships with 5.1 on every supported Windows.
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
Set-ScheduledTask -TaskName $taskName -Settings $settings | Out-Null

Write-Host "installed the scheduled task '$taskName' for $runAs, every minute:"
Write-Host "  $taskCommand"
Write-Host 'Remove it with:  .\install_watcher.ps1 -Remove'
