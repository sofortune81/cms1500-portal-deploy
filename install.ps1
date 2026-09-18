# First install of the CMS-1500 review portal on Windows (Docker Desktop, Linux containers).
# Mirrors install.sh step for step. [FEATURE: INSTALLER]
#
# Windows PowerShell 5.1 syntax only -- that is what a stock Windows Server runs: no `-and`
# chaining of native commands, no ternary, no null-conditional operator.
#
# Usage: .\install.ps1                        (uses the portal-*.tar in this folder, else asks)
#        .\install.ps1 -Version 1.4.0
#        .\install.ps1 -Version 1.4.0 -Tarball portal-1.4.0.tar
#        any of the above, plus -ConfiguratorArgs '--auth-mode','entra'
#
# -Version is deliberately NOT Mandatory: PowerShell would prompt for it itself, with a bare
# "Version:" and no explanation, before a line of this script had run.
param(
  [string]$Version = '',
  [string]$Tarball = '',
  [string[]]$ConfiguratorArgs = @()
)
$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

# Docker Desktop ends a failed docker command with a "docker ai" upsell; silence it.
$env:DOCKER_CLI_HINTS = "false"

# Write-Error throws under $ErrorActionPreference = 'Stop', so an `exit <code>` written after
# one never runs and the documented exit codes would all collapse to 1. Writing straight to
# the error stream keeps the message and lets the exit code stand. `exit` inside a function
# ends the whole script, which is what every call site wants.
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

# portal.env doubles as the "this host is installed" sentinel; re-running would regenerate
# PORTAL_SECRET_KEY and make the stored AWS-connection secret unreadable with no recovery.
if (Test-Path portal.env) {
  Fail 'portal.env exists; this host is installed. Use: .\update.ps1 -Version <version>' 3
}
# -- what to install, and where the image comes from. A customer runs .\install.ps1 with
# nothing else, so resolve in this order: -Version; the single portal-<version>.tar in this
# folder; a prompt, when there is a console to prompt on.
if ($Tarball -eq '') {
  if ($Version -ne '') {
    # A tarball customer has no registry credentials, so sending them to `docker login`
    # because they left the flag off is a dead end. A tar for any OTHER version is ignored.
    if (Test-Path "portal-$Version.tar") {
      $Tarball = "portal-$Version.tar"
      Write-Host "Using $Tarball found in this folder."
    }
  } else {
    $tars = @(Get-ChildItem -Path . -Filter 'portal-*.tar' -File)
    if ($tars.Count -gt 1) {
      [Console]::Error.WriteLine('more than one portal-*.tar in this folder, so which version is not obvious:')
      foreach ($tar in $tars) { [Console]::Error.WriteLine('  ' + $tar.Name) }
      Fail 'Name the one you want:  .\install.ps1 -Version <version>' 2
    }
    if ($tars.Count -eq 1) {
      $Tarball = $tars[0].Name
      $Version = ($Tarball -replace '^portal-', '') -replace '\.tar\z', ''
      Write-Host "Using $Tarball found in this folder (version $Version)."
    }
  }
}
if ($Version -eq '') {
  if (-not [Console]::IsInputRedirected) {
    $Version = Read-Host 'Version to install (from your onboarding email)'
  }
}
if ($Version -eq '') {
  [Console]::Error.WriteLine('usage: .\install.ps1 [-Version <version>] [-Tarball <file>] [-ConfiguratorArgs ...]')
  [Console]::Error.WriteLine('  With no version: put portal-<version>.tar in this folder, or run this in a')
  Fail '  console and it will ask. The version is in your onboarding email.' 2
}
# The same charset check whether the version was typed, passed, or read off a file name.
# \z, not $: .NET's $ also matches just before a trailing newline, which would let a
# pasted "1.4.0`n" through here while the POSIX case pattern in install.sh rejects it.
if ($Version -notmatch '^[0-9A-Za-z._-]+\z') { Fail "bad version: $Version" 2 }

# Compose substitutes ${PORTAL_IMAGE}:${PORTAL_VERSION} in docker-compose.yml from the process
# environment, a file literally named `.env`, or --env-file, and from nothing else. The
# service's `env_file: portal.env` populates the CONTAINER, not that substitution, and this
# bundle never creates a `.env`. Without the flag `up` dies on "invalid reference format"
# AFTER the configurator has written portal.env, at which point install.ps1 refuses to re-run
# and the host is wedged. Every compose call goes through here so the flag cannot be dropped
# from one of them; $LASTEXITCODE is global, so Assert-LastExit still sees the real code.
function Invoke-Compose {
  docker compose --env-file portal.env @args
}
# What to tell an operator to type; keep in step with Invoke-Compose above.
$composeCmd = 'docker compose --env-file portal.env'

if (-not (Test-Path portal.env.template)) {
  Fail 'portal.env.template is missing; run this from the unpacked deployment bundle.' 2
}
$imageLine = Select-String -Path portal.env.template -Pattern '^PORTAL_IMAGE=(.*)$' | Select-Object -First 1
if ($null -eq $imageLine) {
  Fail 'no PORTAL_IMAGE= line in portal.env.template; run this from the unpacked bundle.' 2
}
$image = $imageLine.Matches[0].Groups[1].Value.Trim()

# -- get the image (the one step a licence-gated download would replace)
if ($Tarball -ne '') {
  if (-not (Test-Path $Tarball)) { Fail "no such tarball: $Tarball" 2 }
  Write-Host "== load $Tarball"
  docker load -i $Tarball
  Assert-LastExit 'docker load'
} else {
  Write-Host '== registry sign-in (username and token from your second onboarding email)'
  docker login ghcr.io
  Assert-LastExit 'docker login'
  docker pull "${image}:${Version}"
  Assert-LastExit 'docker pull'
}

# The configurator takes the licence from a *.lic file in this folder when there is one, and
# otherwise reads a pasted one from stdin. `docker run -t` needs a console; a scripted install
# (answers as flags, licence via --licence-file or a pipe) has none, and -t would fail with
# "the input device is not a TTY" instead of reading the pipe.
if ([Console]::IsInputRedirected) { $ttyFlags = @('-i') } else { $ttyFlags = @('-i', '-t') }

Write-Host '== configure'
# "${PWD}:/work" is the bind-mount form Docker Desktop takes: after Set-Location, $PWD is the
# bundle folder and stringifies to a Windows path such as C:\portal-bundle, which the daemon
# accepts with its backslashes. There is no --user counterpart to install.sh here and none is
# needed: NTFS carries no POSIX mode, so files written through the mount come back owned by
# the signed-in Windows user whatever uid the container used.
# The image sets PYTHONPATH=/app, so -m resolves from WORKDIR /data; it has a CMD and no
# ENTRYPOINT, so --entrypoint python replaces the whole command.
docker run --rm @ttyFlags -v "${PWD}:/work" --entrypoint python "${image}:${Version}" -m dev_tools.install_configurator --version $Version --host-os windows @ConfiguratorArgs
# 2 invalid input, 3 already installed, 4 licence terms declined. Nothing was written and
# nothing is started; the configurator printed its own reason above.
Assert-LastExit 'configuration (nothing was written, the portal was not started); it'

# Read as text, never dot-sourced: portal.env holds the AWS secret and PORTAL_SECRET_KEY.
# Compose reads the file itself through --env-file; these three reads decide whether the
# proxy is expected and what to say about it.
$profilesLine = Select-String -Path portal.env -Pattern '^COMPOSE_PROFILES=(.*)$' | Select-Object -First 1
$profiles = ''
if ($null -ne $profilesLine) { $profiles = $profilesLine.Matches[0].Groups[1].Value.Trim() }
$hostnameLine = Select-String -Path portal.env -Pattern '^PORTAL_HOSTNAME=(.*)$' | Select-Object -First 1
$hostnameSet = ''
if ($null -ne $hostnameLine) { $hostnameSet = $hostnameLine.Matches[0].Groups[1].Value.Trim() }
$tlsModeLine = Select-String -Path portal.env -Pattern '^PORTAL_TLS_MODE=(.*)$' | Select-Object -First 1
$tlsMode = ''
if ($null -ne $tlsModeLine) { $tlsMode = $tlsModeLine.Matches[0].Groups[1].Value.Trim() }

# Port preflight, only when the proxy will run: it publishes 80 and 443, so a container
# already holding either would fail `up` after everything else succeeded. Only docker-held
# ports are visible here; a non-docker listener is caught by the HTTPS wait below.
if ($profiles -eq 'tls') {
  foreach ($p in 80, 443) {
    $held = docker ps --format '{{.Ports}}' | Select-String -Pattern "[:.]$p->"
    if ($null -ne $held) {
      [Console]::Error.WriteLine("port $p is already in use by another container; free it or re-run with --tls-mode none")
      exit 2
    }
  }
}

Write-Host '== start'
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

if ($profiles -eq 'tls') {
  Write-Host '== https'
  $proxyUp = $false
  for ($i = 0; $i -lt 30; $i++) {
    Invoke-Compose exec -T proxy wget -q -O /dev/null http://portal:8000/health
    if ($LASTEXITCODE -eq 0) { $proxyUp = $true; break }
    Start-Sleep -Seconds 2
  }
  if (-not $proxyUp) {
    [Console]::Error.WriteLine("the HTTPS proxy did not come up; see: $composeCmd logs proxy")
    [Console]::Error.WriteLine('(if it says a port is already in use, another web server holds 80 or 443)')
    exit 1
  }
  Write-Host "The portal is served at https://$hostnameSet"
  if ($tlsMode -eq 'internal') {
    Write-Host "Browsers will warn until they trust the portal's own certificate authority:"
    Write-Host '  caddy-data/caddy/pki/authorities/local/root.crt   (import it as a trusted root on each PC)'
  }
}

# portal.env exists from here on, so install.ps1 refuses to run again. Every way this step can
# fail therefore has to hand the operator the one command that finishes the job. Defined
# before the prompts because a function only exists once its definition has been executed.
# Read as text, never sourced. In entra mode a password is refused for every id but the
# break-glass one (review_portal/auth.py, ENTRA_REQUIRED_CODE), so the activation token that
# `create` prints is useless and the account must be pre-bound to the administrator's Microsoft
# address -- otherwise their first Microsoft sign-in creates a SECOND, inactive account and no
# active admin is left who could activate it.
$authLine = Select-String -Path portal.env -Pattern '^AUTH_MODE=(.*)$' | Select-Object -First 1
$authMode = ''
if ($null -ne $authLine) { $authMode = $authLine.Matches[0].Groups[1].Value.Trim() }
$adminDb = '/data/runtime/review_portal/review_portal.db'

function Write-AdminRetryHint() {
  [Console]::Error.WriteLine('The portal is installed and running, but it has no administrator and install.ps1')
  [Console]::Error.WriteLine('will now refuse to re-run. Create the first administrator with:')
  [Console]::Error.WriteLine("  $composeCmd exec -T portal python -m dev_tools.portal_user_admin --db $adminDb create <sign-in-id> '<display name>' --role admin")
  if ($authMode -eq 'entra') {
    [Console]::Error.WriteLine("  $composeCmd exec -T portal python -m dev_tools.portal_user_admin --db $adminDb set-upn <sign-in-id> <user@domain>")
    [Console]::Error.WriteLine('  Both are needed in entra mode: the second binds the account to the Microsoft')
    [Console]::Error.WriteLine('  address, so signing in lands on it instead of creating a new inactive account.')
  }
}

Write-Host '== first administrator'
# Read-Host raises a terminating error at end-of-input under 'Stop'; catching it keeps the
# retry hint reachable on a host with no console.
$adminId = ''
$adminName = ''
$adminUpn = ''
try {
  $adminId = Read-Host 'Administrator sign-in id'
  $adminName = Read-Host 'Administrator display name'
  if ($authMode -eq 'entra') {
    $adminUpn = Read-Host 'Administrator Microsoft sign-in address (user@domain)'
  }
} catch {
  Write-Host 'no console to prompt on.'
}

if ($adminId.Trim() -eq '') {
  [Console]::Error.WriteLine('no administrator sign-in id given.')
  Write-AdminRetryHint
  exit 1
}
if ($adminName.Trim() -eq '') {
  [Console]::Error.WriteLine('no administrator display name given.')
  Write-AdminRetryHint
  exit 1
}

# Checked BEFORE create, so entra mode never leaves a created-but-unbound account behind.
if ($authMode -eq 'entra') {
  if ($adminUpn -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+\z') {
    [Console]::Error.WriteLine('AUTH_MODE=entra needs the administrator''s Microsoft address, like admin@clinic.com.')
    Write-AdminRetryHint
    exit 1
  }
}

# -T: neither subcommand prompts, so no tty is needed.
if ($authMode -eq 'entra') {
  # `create` always mints an activation token and prints it as its last two lines. In entra
  # mode it can never be used -- auth.py refuses passwords for every id but break-glass -- so
  # showing it puts a live credential on screen that nobody will ever type. Only stdout is
  # captured (never a stderr redirect, which can raise NativeCommandError under 'Stop' in
  # 5.1), so a real error still reaches the console, and the capture is shown in full if the
  # command fails.
  $adminOut = @(Invoke-Compose exec -T portal python -m dev_tools.portal_user_admin --db $adminDb create $adminId $adminName --role admin)
  if ($LASTEXITCODE -ne 0) {
    foreach ($line in $adminOut) { [Console]::Error.WriteLine($line) }
    [Console]::Error.WriteLine("creating the administrator failed (exit $LASTEXITCODE).")
    Write-AdminRetryHint
    exit $LASTEXITCODE
  }
  $cut = $adminOut.Count
  for ($i = 0; $i -lt $adminOut.Count; $i++) {
    if ($adminOut[$i] -like 'activation token for *') { $cut = $i; break }
  }
  for ($i = 0; $i -lt $cut; $i++) { Write-Host $adminOut[$i] }
} else {
  Invoke-Compose exec -T portal python -m dev_tools.portal_user_admin --db $adminDb create $adminId $adminName --role admin
  if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("creating the administrator failed (exit $LASTEXITCODE).")
    Write-AdminRetryHint
    exit $LASTEXITCODE
  }
}

if ($authMode -eq 'entra') {
  Invoke-Compose exec -T portal python -m dev_tools.portal_user_admin --db $adminDb set-upn $adminId $adminUpn
  if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("the administrator account was created but could not be bound to $adminUpn (exit $LASTEXITCODE).")
    [Console]::Error.WriteLine("  Retry just the binding:")
    [Console]::Error.WriteLine("  $composeCmd exec -T portal python -m dev_tools.portal_user_admin --db $adminDb set-upn $adminId $adminUpn")
    exit $LASTEXITCODE
  }
  Write-Host ''
  Write-Host "$adminId is bound to $adminUpn -- have them open the portal and Sign in with Microsoft."
} else {
  Write-Host ''
  Write-Host 'The activation token printed above is single-use and expires in 48 hours. Give it to'
  Write-Host "$adminId out of band; they enter it with a new password at the portal's sign-in screen."
}

if ($profiles -eq 'tls') {
  Write-Host "Portal $Version is running at https://$hostnameSet."
  Write-Host 'Allow inbound TCP 443 (and 80 for public certificates) in Windows Defender Firewall.'
} else {
  Write-Host "Portal $Version is running on 127.0.0.1:8000."
  Write-Host "You chose no HTTPS proxy: put your own TLS in front before users sign in (README.md, 'TLS')."
}
Write-Host "Do not try it over plain http first -- README.md, 'TLS', explains why the first click"
Write-Host "after a successful sign-in looks signed out."
