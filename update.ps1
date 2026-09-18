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
  docker info --format '{{.ServerVersion}}' | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Fail 'the docker daemon is not reachable. Start Docker Desktop, wait for it to report Running, then check: docker info' 2
  }
  docker compose version | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Fail 'the docker compose plugin is missing. Update Docker Desktop -- every supported version ships it.' 2
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

if ($Version -ne '') {
  # Same charset update.sh enforces before the value reaches sed, and the same one the
  # configurator validates: anything else could corrupt portal.env or the image reference.
  # \z, not $: .NET's $ also matches just before a trailing newline, which would let a
  # pasted "1.2.3`n" through here while the POSIX case pattern in update.sh rejects it.
  if ($Version -notmatch '^[0-9A-Za-z._-]+\z') { Fail "bad version: $Version" 2 }
  $lines = @(Get-Content -Path $envPath)
  # With no such line the -replace below matches nothing, and the update would report success
  # while still running the old tag. Refuse instead of updating to a version nobody set.
  if (@($lines -match '^PORTAL_VERSION=').Count -eq 0) {
    Fail "portal.env has no PORTAL_VERSION= line; cannot pin version $Version." 2
  }
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
Assert-LastExit 'database backup'

if ($Tarball -ne '') {
  Write-Host "== load $Tarball"
  docker load -i $Tarball
  Assert-LastExit 'docker load'
} else {
  Write-Host '== pull'
  Invoke-Compose pull
  Assert-LastExit 'compose pull'
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
