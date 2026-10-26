# Docker-host update watcher for Windows (Docker Desktop): applies an update the portal
# requested. Mirrors update_watcher.sh step for step. [FEATURE: IN-APP UPDATE]
# SEARCH TAGS: update watcher, request.txt, status.txt, watcher.heartbeat, in-app update, schtasks
#
# Windows PowerShell 5.1 syntax only: no `-and` chaining of native commands, no ternary, no
# null-conditional operator.
#
# Run once a minute by Task Scheduler (install_watcher.ps1 registers the task). One tick:
# heartbeat, and if the portal wrote data\update\request.txt, run update.ps1 -Version <version>
# once and record the outcome in data\update\status.txt.
#
# request.txt is written from inside the container, so it is treated as hostile: VERSION is
# read by line prefix (never dot-sourced or evaluated), charset-checked with the same pattern
# update.ps1 applies, and handed to update.ps1 as one argument. The image name comes from
# portal.env, so a request can only pick a version of the configured image.
#
# REQUEST_ID (16-64 lowercase hex; absent from an older portal's request) is copied into every
# status.txt this tick writes for the request. The portal treats a request whose id status.txt
# carries as taken and deletes it; a request whose id is already there is never run a second
# time. This watcher never deletes a request with a valid id, only an id-less one.
#
# The run log is written only in .update-run\ in the bundle root, which the container cannot
# see; only a copy of its tail is published into data\update, as update_watcher.sh does.
#
# Mutates: data\update\{status.txt,watcher.heartbeat,last-update.log,.lock}, deletes an id-less,
# malformed or non-file data\update\request.txt, writes .update-run\, and (through update.ps1) portal.env and the
# running containers.
#
# Status exit codes: update.ps1's own, or
#   2  bad version or request id in request.txt
#   6  watcher interrupted mid-update (the run never reached its outcome, or a stale lock
#      was found with STATE=running)
$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

# Paths are absolute: .NET's working directory is the process's, not Set-Location's.
$updateDir = Join-Path $PSScriptRoot 'data\update'
$lockDir = Join-Path $updateDir '.lock'
$requestPath = Join-Path $updateDir 'request.txt'
$statusPath = Join-Path $updateDir 'status.txt'
$heartbeatPath = Join-Path $updateDir 'watcher.heartbeat'
$logPath = Join-Path $updateDir 'last-update.log'
# The run log's home: the bundle root, outside the container's /data mount.
$runDir = Join-Path $PSScriptRoot '.update-run'
# Lines of the run log published into data\update\last-update.log for the portal.
$publishedLogLines = 200
$updateScript = Join-Path $PSScriptRoot 'update.ps1'
$lockPidPath = Join-Path $lockDir 'pid'
# A lock is stale when the watcher PID it records is gone. With no readable PID (a tick killed
# between creating the lock and writing the PID) it is stale past this age instead.
$staleLockMinutes = 30
# PID-reuse backstop: past this age a lock is stale even when its PID is alive, since after a
# reboot that number can belong to an unrelated process. No update runs for 6 hours.
$lockCeilingHours = 6
# status.txt EXIT_CODE for an update the watcher did not see to the end.
$interruptedExitCode = '6'
# The one version charset, case-sensitive (-cmatch): under the default case-insensitive match
# .NET folds the Kelvin sign and dotted I into [A-Za-z]. No leading -, like the sh watcher.
$versionPattern = '^[0-9A-Za-z._-]+\z'
# The request id the portal writes, matched with -cmatch for the same reason: lowercase hex only.
$requestIdPattern = '^[0-9a-f]{16,64}\z'
# The container reads these files: UTF-8 without a BOM (a BOM would land in the first key).
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-UtcStamp() {
  return [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
}

# Every name under data\update may be a link (symlink or junction) planted from inside the
# container, aimed at a file this account owns. Nothing here writes through, appends through,
# or reads through a name it has not checked, and removal never follows one.

# The attributes of $path itself -- GetAttributes does not follow a link -- or $null when
# nothing is there. A dangling link still has attributes, which Test-Path would miss.
function Get-OwnAttributes([string]$path) {
  try {
    return [System.IO.File]::GetAttributes($path)
  } catch [System.IO.FileNotFoundException] {
    return $null
  } catch [System.IO.DirectoryNotFoundException] {
    return $null
  }
}

function Test-HasAttribute($attrs, [System.IO.FileAttributes]$flag) {
  return ([int]($attrs -band $flag) -ne 0)
}

# True for a regular file: neither a link (ReparsePoint) nor a directory.
function Test-PlainFile([string]$path) {
  $attrs = Get-OwnAttributes $path
  if ($null -eq $attrs) { return $false }
  if (Test-HasAttribute $attrs ([System.IO.FileAttributes]::ReparsePoint)) { return $false }
  return (-not (Test-HasAttribute $attrs ([System.IO.FileAttributes]::Directory)))
}

# True for a real directory, not a link to one.
function Test-PlainDirectory([string]$path) {
  $attrs = Get-OwnAttributes $path
  if ($null -eq $attrs) { return $false }
  if (Test-HasAttribute $attrs ([System.IO.FileAttributes]::ReparsePoint)) { return $false }
  return (Test-HasAttribute $attrs ([System.IO.FileAttributes]::Directory))
}

# Removes $path itself, never what a link points at: a link to a file or a directory is
# deleted as a link, and a real directory is emptied entry by entry the same way.
# Remove-Item -Recurse is not used: 5.1 walks into a junction inside the tree and deletes the
# target's contents.
function Remove-NoFollow([string]$path) {
  $attrs = Get-OwnAttributes $path
  if ($null -eq $attrs) { return }
  $isLink = Test-HasAttribute $attrs ([System.IO.FileAttributes]::ReparsePoint)
  $isDir = Test-HasAttribute $attrs ([System.IO.FileAttributes]::Directory)
  if ($isDir -and -not $isLink) {
    foreach ($entry in [System.IO.Directory]::GetFileSystemEntries($path)) { Remove-NoFollow $entry }
    [System.IO.Directory]::Delete($path, $false)
  } elseif ($isDir) {
    [System.IO.Directory]::Delete($path, $false)
  } else {
    [System.IO.File]::Delete($path)
  }
}

# Content goes to a fresh, randomly named file created with FileMode.CreateNew, which fails
# rather than open anything already at that name, so a planted temp name is never written
# through. A planted link at $path is removed first, so the rename replaces the name. The
# portal reads these files at any moment and must never see one half-written. LF endings,
# like the sh watcher writes.
function Write-Atomic([string]$path, [string]$content) {
  $tmp = "$path.tmp." + [System.IO.Path]::GetRandomFileName()
  $bytes = $utf8NoBom.GetBytes($content)
  $stream = New-Object System.IO.FileStream($tmp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
  try {
    $stream.Write($bytes, 0, $bytes.Length)
  } finally {
    $stream.Dispose()
  }
  $attrs = Get-OwnAttributes $path
  if ($null -ne $attrs) {
    if (Test-HasAttribute $attrs ([System.IO.FileAttributes]::ReparsePoint)) { Remove-NoFollow $path }
  }
  Move-Item -Force -LiteralPath $tmp -Destination $path
}

function Write-Status([string]$state, [string]$version, [string]$exitCode, [string]$startedAt, [string]$finishedAt, [string]$requestId) {
  $body = "STATE=$state`nVERSION=$version`nEXIT_CODE=$exitCode`nSTARTED_AT=$startedAt`nFINISHED_AT=$finishedAt`nREQUEST_ID=$requestId`n"
  Write-Atomic $statusPath $body
}

# The run log: a fresh, randomly named file in $runDir, created with FileMode.CreateNew and
# written through one handle for the whole run.
$runLog = ''
$logWriter = $null
function Open-RunLog() {
  $script:runLog = Join-Path $runDir ('run.' + [System.IO.Path]::GetRandomFileName())
  $stream = New-Object System.IO.FileStream($script:runLog, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
  $script:logWriter = New-Object System.IO.StreamWriter($stream, $utf8NoBom)
}

function Add-LogLine([string]$line) {
  if ($null -ne $script:logWriter) {
    $script:logWriter.Write($line + "`n")
    $script:logWriter.Flush()
  }
}

function Close-RunLog() {
  if ($null -ne $script:logWriter) {
    $script:logWriter.Dispose()
    $script:logWriter = $null
  }
}

# Publish the tail of run log $path for the portal, then keep the whole of it as last-run.log.
# The published copy is replaced, never appended to, so nothing is ever opened for writing at
# a name the container controls. Nothing reads the published copy back.
function Publish-RunLog([string]$path) {
  if ($path -eq '') { return }
  if (-not (Test-PlainFile $path)) { return }
  $tail = @([System.IO.File]::ReadAllLines($path) | Select-Object -Last $publishedLogLines)
  Write-Atomic $logPath (($tail -join "`n") + "`n")
  Move-Item -Force -LiteralPath $path -Destination (Join-Path $runDir 'last-run.log')
}

# The first value of $key in status.txt, or ''. Read as text, like request.txt.
function Get-StatusValue([string[]]$lines, [string]$key) {
  foreach ($line in $lines) {
    if ($line.StartsWith("$key=")) { return $line.Substring($key.Length + 1) }
  }
  return ''
}

# The first value of $key in the status.txt on disk now, or '' when there is none to read.
function Get-CurrentStatusValue([string]$key) {
  if (-not (Test-PlainFile $statusPath)) { return '' }
  return (Get-StatusValue ([System.IO.File]::ReadAllLines($statusPath)) $key)
}

# A request with a valid REQUEST_ID is the portal's to delete, once status.txt carries the id.
# A removal by name here could take a NEWER request: between this tick's read and the removal,
# the portal may discard the consumed one and accept the next. Only an older portal's id-less
# request, which nothing else would ever remove, is deleted here.
function Clear-LegacyRequest() {
  if ($script:requestId -eq '') { Remove-NoFollow $requestPath }
}

# A watcher killed mid-update left STATE=running behind; without this the portal would show
# the update as running forever. VERSION and STARTED_AT are carried over only when they still
# look like what this script writes. That watcher's run log is published too.
function Set-InterruptedIfRunning() {
  if (-not (Test-PlainFile $statusPath)) { return }
  $lines = [System.IO.File]::ReadAllLines($statusPath)
  if ((Get-StatusValue $lines 'STATE') -cne 'running') { return }
  $oldVersion = Get-StatusValue $lines 'VERSION'
  if (($oldVersion -cnotmatch $versionPattern) -or $oldVersion.StartsWith('-')) { $oldVersion = '' }
  $oldStarted = Get-StatusValue $lines 'STARTED_AT'
  if ($oldStarted -cnotmatch '^[0-9TZ:-]*\z') { $oldStarted = '' }
  $oldRequestId = Get-StatusValue $lines 'REQUEST_ID'
  if ($oldRequestId -cnotmatch $requestIdPattern) { $oldRequestId = '' }
  Write-Status 'failed' $oldVersion $interruptedExitCode $oldStarted (Get-UtcStamp) $oldRequestId
  $orphan = Get-ChildItem -LiteralPath $runDir -Filter 'run.*' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($null -ne $orphan) { Publish-RunLog $orphan.FullName }
}

# The run folder lives in the bundle root, which only the operator writes, but gets the same
# link check as everything else.
if (($null -ne (Get-OwnAttributes $runDir)) -and -not (Test-PlainDirectory $runDir)) {
  Remove-NoFollow $runDir
}
New-Item -ItemType Directory -Force -Path $runDir | Out-Null

# data\ is the container's /data, so the update folder itself can be swapped for a link.
if (($null -ne (Get-OwnAttributes $updateDir)) -and -not (Test-PlainDirectory $updateDir)) {
  Remove-NoFollow $updateDir
}
New-Item -ItemType Directory -Force -Path $updateDir | Out-Null

# True when something sits at the lock's name that no live watcher holds. An update may
# legitimately outlast $staleLockMinutes (a slow pull), so a live holder keeps its lock until
# the ceiling. A link or a file there is never a lock this script took. The holder's PID lands
# in $lockPid -- never $pid, which is PowerShell's own read-only $PID.
function Test-LockStale() {
  if ($null -eq (Get-OwnAttributes $lockDir)) { return $false }
  if (-not (Test-PlainDirectory $lockDir)) { return $true }
  $lockWritten = [System.IO.Directory]::GetLastWriteTime($lockDir)
  if ($lockWritten -lt (Get-Date).AddHours(-$lockCeilingHours)) { return $true }
  $pidText = ''
  if (Test-PlainFile $lockPidPath) {
    try {
      $pidText = [System.IO.File]::ReadAllText($lockPidPath).Trim()
    } catch {
      $pidText = ''
    }
  }
  $lockPid = 0
  if ((-not [int]::TryParse($pidText, [ref]$lockPid)) -or ($lockPid -le 0)) {
    return ($lockWritten -lt (Get-Date).AddMinutes(-$staleLockMinutes))
  }
  $holder = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
  if ($null -eq $holder) { return $true }
  # A reused PID: only a powershell started no later than the lock was last written (the PID
  # write) can be the watcher that took it. An unreadable StartTime is not that watcher, which
  # runs as this same account.
  if ($holder.ProcessName -ne 'powershell') { return $true }
  try {
    $holderStarted = $holder.StartTime
  } catch {
    return $true
  }
  if ($holderStarted -gt $lockWritten) { return $true }
  return $false
}

if (Test-LockStale) {
  if (Test-PlainDirectory $lockDir) { Set-InterruptedIfRunning }
  Remove-NoFollow $lockDir
}
# Creating a directory that exists throws: exactly one tick gets the lock; any other one
# exits quietly.
try {
  New-Item -ItemType Directory -Path $lockDir | Out-Null
} catch {
  exit 0
}

# Set once this tick has written STATE=running and cleared once it has written the outcome; a
# run that leaves the try block in between (an exception, Ctrl+C) is recorded as interrupted.
$runInFlight = $false
$requestId = ''
try {
  # Atomic, so a tick judging the lock never reads half a PID.
  Write-Atomic $lockPidPath "$PID`n"
  Write-Atomic $heartbeatPath ((Get-UtcStamp) + "`n")

  if ($null -eq (Get-OwnAttributes $requestPath)) {
    # Nothing requested; this tick was the heartbeat.
  } elseif (-not (Test-PlainFile $requestPath)) {
    # A link could aim the read at any file this account can see; anything but a plain file
    # is discarded as hostile, never followed.
    $startedAt = Get-UtcStamp
    Write-Status 'failed' '' '2' $startedAt (Get-UtcStamp) ''
    Remove-NoFollow $requestPath
  } else {
    $requestLines = @([System.IO.File]::ReadAllLines($requestPath))
    # Exactly one VERSION= line, matching the sh watcher, where two lines join with a newline
    # that its charset refuses.
    $versionLines = @($requestLines | Where-Object { $_.StartsWith('VERSION=') })
    $version = ''
    if ($versionLines.Count -eq 1) { $version = $versionLines[0].Substring(8) }
    # No REQUEST_ID line is an older portal's request and runs as before; two lines, or a value
    # outside the charset, is refused like a bad version and not echoed into status.txt.
    $idLines = @($requestLines | Where-Object { $_.StartsWith('REQUEST_ID=') })
    $idValid = ($idLines.Count -le 1)
    if ($idLines.Count -eq 1) { $requestId = $idLines[0].Substring(11) }
    if (($requestId -ne '') -and ($requestId -cnotmatch $requestIdPattern)) { $idValid = $false }

    if (-not $idValid) {
      # Removing it here is safe: the portal reads a request it cannot see consumed as pending,
      # so it never writes over one.
      $requestId = ''
      $startedAt = Get-UtcStamp
      Write-Status 'failed' '' '2' $startedAt (Get-UtcStamp) ''
      Remove-NoFollow $requestPath
    } elseif (($requestId -ne '') -and ((Get-CurrentStatusValue 'REQUEST_ID') -ceq $requestId)) {
      # Already taken: status.txt carrying this id means it ran, or is running. Never twice, and
      # left for the portal to remove (see Clear-LegacyRequest).
    } elseif (($version -cnotmatch $versionPattern) -or $version.StartsWith('-')) {
      # \z, not $: .NET's $ also matches just before a trailing newline. Empty and a leading -
      # are refused as in the sh watcher. The rejected value is not echoed into status.txt,
      # where it could forge a line.
      $startedAt = Get-UtcStamp
      Write-Status 'failed' '' '2' $startedAt (Get-UtcStamp) $requestId
      Clear-LegacyRequest
    } else {
      $startedAt = Get-UtcStamp
      Write-Status 'running' $version '' $startedAt '' $requestId
      $runInFlight = $true
      Open-RunLog
      Add-LogLine "== $startedAt update to $version requested"
      # Consumed before the run, not after: should this tick lose its lock mid-run (the 6-hour
      # ceiling, or the PID-less age fallback), the tick that takes over must not start a second
      # update.ps1 alongside this one. With an id, status.txt already says running with it, so
      # that tick's id check skips the request; an id-less one is removed here.
      Clear-LegacyRequest
      # update.ps1 runs in its own powershell.exe, not in-process with its streams redirected
      # to the log: in 5.1 that redirection reaches the docker calls inside update.ps1, whose 'Stop'
      # preference turns compose's progress on stderr into a terminating NativeCommandError.
      # Here stderr is merged only at this level, under 'Continue', and each line is appended
      # as UTF-8 (5.1's >> would write UTF-16). Nothing may run between the call and reading
      # $LASTEXITCODE.
      $ErrorActionPreference = 'Continue'
      & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $updateScript -Version $version 2>&1 | ForEach-Object { Add-LogLine ("$_") }
      $exitCode = $LASTEXITCODE
      $ErrorActionPreference = 'Stop'

      $state = 'failed'
      if ($exitCode -eq 0) { $state = 'ok' }
      Write-Status $state $version ([string]$exitCode) $startedAt (Get-UtcStamp) $requestId
      $runInFlight = $false
      Add-LogLine ("== " + (Get-UtcStamp) + " update to $version finished: $state (exit $exitCode)")
      # Closed before publishing: the read needs the writer's handle gone.
      Close-RunLog
      Publish-RunLog $runLog
      $runLog = ''
    }
  }
} finally {
  if ($runInFlight) {
    # Best effort: the lock must still come off if this write fails too.
    try {
      Write-Status 'failed' $version $interruptedExitCode $startedAt (Get-UtcStamp) $requestId
    } catch {
      [Console]::Error.WriteLine("could not record the interrupted update: $_")
    }
  }
  Close-RunLog
  # A run that never reached its own publish (an exception, Ctrl+C) still shows its log.
  try {
    Publish-RunLog $runLog
  } catch {
    [Console]::Error.WriteLine("could not publish the update log: $_")
  }
  try {
    Remove-NoFollow $lockDir
  } catch {
    [Console]::Error.WriteLine("could not remove the update lock: $_")
  }
}
