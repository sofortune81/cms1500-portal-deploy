# Update the CMS-1500 review portal on Windows (Docker Desktop, Linux containers).
# Mirrors update.sh: back up the database, pull, restart, verify. [FEATURE: INSTALLER]
#
# Windows PowerShell 5.1 syntax only -- that is what a stock Windows Server runs: no `-and`
# chaining of native commands, no ternary, no null-conditional operator.
#
# Usage: .\update.ps1                  (uses the PORTAL_VERSION already in portal.env)
#        .\update.ps1 -Version 1.2.3   (also rewrites PORTAL_VERSION in portal.env)
#        .\update.ps1 -Version 1.2.3 -Tarball portal-1.2.3.tar   (air-gapped: load, no pull)
#   portal-<version>.tar in this folder is used automatically when you name that version.
param(
  [string]$Version = '',
  [string]$Tarball = ''
)
$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

# Docker Desktop ends a failed docker command with a "docker ai" upsell; silence it.
$env:DOCKER_CLI_HINTS = "false"

# Write-Error throws under $ErrorActionPreference = 'Stop', so an `exit <code>` written after
# one never runs and the documented exit codes would all collapse to 1. Writing straight to
# the error stream keeps the message and lets the exit code stand.
function Fail([string]$message, [int]$code) {
  [Console]::Error.WriteLine($message)
  exit $code
}

# 'Stop' does not see a native program's exit code -- only PowerShell errors -- so every
# docker call is followed by this. Native stderr is deliberately never redirected: under
# 'Stop' a redirected native error stream raises NativeCommandError in 5.1.
function Assert-LastExit([string]$what) {
  if ($LASTEXITCODE -ne 0) { Fail "$what failed (exit $LASTEXITCODE)" $LASTEXITCODE }
}

# Backup, load and pull run after the version pin and can fail with the old version still
# running. Left pinned, portal.env would name an image this host may not have, so every later
# `compose up` fails and the portal refuses the running version as "not newer". The unpinned
# bytes go back before Fail; the new image is on the host once these pass, so the pin stays.
function Assert-LastExitBeforeRestart([string]$what) {
  if ($LASTEXITCODE -ne 0) {
    $code = $LASTEXITCODE
    if ($null -ne $script:envBeforePin) {
      [System.IO.File]::WriteAllBytes($envPath, $script:envBeforePin)
      [Console]::Error.WriteLine('portal.env restored to the version still running.')
    }
    Fail "$what failed (exit $code)" $code
  }
}

# Compose substitutes ${PORTAL_IMAGE}:${PORTAL_VERSION} in docker-compose.yml from the process
# environment, a file literally named `.env`, or --env-file, and from nothing else. The
# service's `env_file: portal.env` populates the CONTAINER, not that substitution, and this
# bundle never creates a `.env`. Every compose call goes through here so the flag cannot be
# dropped from one of them; $LASTEXITCODE is global, so Assert-LastExit still sees the real code.
function Invoke-Compose {
  docker compose --env-file portal.env @args
}
# What to tell an operator to type; keep in step with Invoke-Compose above.
$composeCmd = 'docker compose --env-file portal.env'

# >>> shared preflight: byte-identical in install.ps1 and update.ps1, pinned by a test >>>
# Windows only checks. Docker Desktop ships the compose plugin, so unlike install.sh there is
# nothing to provision -- a Desktop without compose is simply too old.
# Native stdout is piped to Out-Null rather than redirected with *> or 2>&1: under
# $ErrorActionPreference = 'Stop', redirecting a native command's ERROR stream can raise
# NativeCommandError in 5.1, and a pipe touches only the success stream. On a failure docker's
# own message reaches the console, which is what the operator needs.
function Assert-Docker() {
  if ($null -eq (Get-Command docker -ErrorAction SilentlyContinue)) {
    Fail 'docker is not installed, or not on this shell''s PATH. Install Docker Desktop: https://docs.docker.com/desktop/install/windows-install/' 2
  }
  # Not `docker info` with a format: when Docker Desktop's engine answers 500, that call prints the
  # error yet exits 0, so the script walked on to `docker login` and failed there instead.
  # `docker version` exits non-zero on a server error; the empty-output check covers any CLI
  # that still exits 0.
  $serverVersion = docker version --format '{{.Server.Version}}'
  if ($LASTEXITCODE -ne 0 -or -not $serverVersion) {
    Fail 'the docker daemon is not reachable. Start Docker Desktop, wait for it to report Running, then check: docker info' 2
  }
  docker compose version | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Fail 'the docker compose plugin is missing. Update Docker Desktop -- every supported version ships it.' 2
  }
}

# [FEATURE: IN-APP UPDATE] The scheduled task that lets the portal's Updates tab apply a version
# (install_watcher.ps1). Called last, once the portal answers. Never fatal: a host whose Task
# Scheduler refuses still runs the portal and still updates by hand, so a refusal is a warning
# naming the retry. update.ps1 calls it too, which is how a bundle that predates the watcher
# gains it. The installer's own refusals are `exit`, which ends only that script.
# Mutates: the Task Scheduler entry install_watcher.ps1 names.
function Install-UpdateWatcher() {
  $installer = Join-Path $PSScriptRoot 'install_watcher.ps1'
  if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
    [Console]::Error.WriteLine('warning: install_watcher.ps1 is not in this folder, so the in-app update watcher was not installed.')
    return
  }
  Write-Host '== update watcher'
  $installed = $false
  try {
    & $installer
    $installed = ($LASTEXITCODE -eq 0)
  } catch {
    [Console]::Error.WriteLine("install_watcher.ps1 stopped: $($_.Exception.Message)")
  }
  if (-not $installed) {
    [Console]::Error.WriteLine('warning: the in-app update watcher was not installed; the portal runs, but its Updates tab cannot apply a version.')
    [Console]::Error.WriteLine('  Fix the cause above, then run:  .\install_watcher.ps1')
  }
}
# <<< shared preflight <<<

Assert-Docker

# A tarball host was installed with -Tarball and cannot reach the registry at all, so a pull
# there fails AFTER the backup and strands the operator mid-update. Checked before any write.
if ($Tarball -ne '') {
  if (-not (Test-Path $Tarball)) { Fail "no such tarball: $Tarball" 2 }
}
# Named a version and its tarball is right here: use it. An offline host has no registry
# credentials, so pulling because the flag was left off is a dead end. A bare .\update.ps1
# keeps its meaning -- re-apply the version already in portal.env -- and never guesses.
if ($Tarball -eq '' -and $Version -ne '') {
  if (Test-Path "portal-$Version.tar") {
    $Tarball = "portal-$Version.tar"
    Write-Host "Using $Tarball found in this folder."
  }
}

$envPath = Join-Path $PSScriptRoot 'portal.env'
if (-not (Test-Path $envPath)) {
  Fail 'portal.env is missing; this host is not installed. Use: .\install.ps1 -Version <version>' 2
}

# The unpinned portal.env, kept so a failure before the restart can put it back
# (Assert-LastExitBeforeRestart). $null when no version was pinned.
$envBeforePin = $null

if ($Version -ne '') {
  # Same charset update.sh enforces before the value reaches sed, and the same one the
  # configurator validates: anything else could corrupt portal.env or the image reference.
  # \z, not $: .NET's $ also matches just before a trailing newline, which would let a
  # pasted "1.2.3`n" through here while the POSIX case pattern in update.sh rejects it.
  # -cnotmatch: a case-insensitive match folds the Kelvin sign and dotted I into [A-Za-z].
  if ($Version -cnotmatch '^[0-9A-Za-z._-]+\z') { Fail "bad version: $Version" 2 }
  $lines = @(Get-Content -Path $envPath)
  # With no such line the -replace below matches nothing, and the update would report success
  # while still running the old tag. Refuse instead of updating to a version nobody set.
  if (@($lines -match '^PORTAL_VERSION=').Count -eq 0) {
    Fail "portal.env has no PORTAL_VERSION= line; cannot pin version $Version." 2
  }
  $envBeforePin = [System.IO.File]::ReadAllBytes($envPath)
  $lines = $lines -replace '^PORTAL_VERSION=.*$', "PORTAL_VERSION=$Version"
  # Set-Content in Windows PowerShell 5.1 writes the ANSI code page (or UTF-16 via Out-File)
  # with CRLF line endings. Compose reads portal.env as a literal env file: a trailing
  # CR ends up inside the value and a BOM ends up inside the first key's name. So the rewrite
  # goes through .NET as UTF-8 without BOM, LF-terminated. The path must be absolute -- .NET's
  # working directory is the process's, not the one Set-Location moved PowerShell to.
  [System.IO.File]::WriteAllText($envPath, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

New-Item -ItemType Directory -Force -Path (Join-Path $PSScriptRoot 'data\backups') | Out-Null

Write-Host '== backup'
# Before the pull, so a bad image never leaves the previous schema unbacked-up. -T because
# db_backup never prompts and a scheduled run has no tty.
Invoke-Compose exec -T portal python -m dev_tools.db_backup --db /data/runtime/review_portal/review_portal.db --out /data/backups --keep 14
Assert-LastExitBeforeRestart 'database backup'

if ($Tarball -ne '') {
  Write-Host "== load $Tarball"
  docker load -i $Tarball
  Assert-LastExitBeforeRestart 'docker load'
} else {
  Write-Host '== pull'
  Invoke-Compose pull
  Assert-LastExitBeforeRestart 'compose pull'
}

Write-Host '== restart'
Invoke-Compose up -d
Assert-LastExit 'compose up'

Write-Host '== health'
# Invoke-WebRequest ships with Windows PowerShell, so the health wait needs no curl.
$up = $false
for ($i = 0; $i -lt 30; $i++) {
  try {
    Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:8000/health' | Out-Null
    $up = $true
    break
  } catch {
    Start-Sleep -Seconds 2
  }
}
if (-not $up) { Fail "portal did not come up; see: $composeCmd logs portal" 1 }

Write-Host 'portal is up'

Install-UpdateWatcher
