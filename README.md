# CMS-1500 Review Portal — installation and operations

## What you receive

- A container image, `ghcr.io/sofortune81/cms1500-portal:<version>` (or a `.tar` file for hosts without registry access).
- A licence issued to your organisation, sent as text in your onboarding email. It carries an expiry date, a maintenance date, and a seat count.
- Registry credentials (a username and a token) in a separate email, unless you were sent a `.tar` file.
- This folder: `README.md`, `LICENSE.md`, `docker-compose.yml`, `portal.env.template`, `install.sh`, `install.ps1`, `update.sh`, `update.ps1`, `Caddyfile`, `caddy-tls-internal.caddy`, `caddy-tls-public.caddy`, `caddy-tls-files.caddy`.

## Requirements

- **Linux:** Docker Engine 24+, and an account that may talk to the Docker daemon
  (`docker info` works). That is all — if the host has no Docker Compose plugin (the
  `docker.io` package on Debian and Ubuntu leaves it out), `install.sh` adds it for you, taking
  it out of the portal image rather than downloading anything. It goes in your own
  `~/.docker/cli-plugins/`, so it affects nothing else on the host, and an air-gapped `.tar`
  install works the same way.
- **Windows:** Docker Desktop, set to Linux containers, and Windows PowerShell 5.1 (the
  "Windows PowerShell" that ships with Windows). Docker Desktop already includes Compose.
  Our scripts are not code-signed, so if PowerShell refuses to run `install.ps1`, start it
  like this instead — this allows the one script, and changes nothing on the machine:

      powershell -ExecutionPolicy Bypass -File .\install.ps1 -Version <version>

- The `data/` folder on an encrypted volume. It will hold patient data.
- Outbound HTTPS to AWS (Textract, Bedrock) and, unless your policy forbids it, to the licence server.
- Ports 80 and 443 free on the host — the installer-managed HTTPS proxy publishes them, so
  nothing else on the host may hold them. Port 8000 is never exposed. For a `public`
  certificate you also need a public DNS name pointing at the host.
- Your reviewers reach the portal over the LAN or VPN at `https://<hostname>`.

## First install

1. Unpack the archive from your onboarding email on the host and put the folder where you want
   it to live, for example `/opt/cms1500` on Linux or `C:\cms1500` on Windows. Everything below
   runs in that folder.
2. Run the installer for your host OS:

       sh install.sh                                 # Linux
       .\install.ps1                                 # Windows

   **If we sent you a `portal-<version>.tar` file**, leave it in this folder: the installer
   finds it, takes the version from its name, and never asks for registry credentials.

   **Otherwise** it asks for the version from your onboarding email. You can pass it instead,
   which is what a scripted install does:

       sh install.sh <version>                       # Linux
       .\install.ps1 -Version <version>              # Windows

   Naming the file explicitly still works, and must come straight after the version on Linux:

       sh install.sh <version> --tarball portal-<version>.tar
       .\install.ps1 -Version <version> -Tarball portal-<version>.tar

3. **Registry sign-in.** With no tarball to load, the installer runs `docker login ghcr.io` and asks
   for the username and token from your registry-credentials email. Paste the token at the
   password prompt; nothing is echoed as you type.

4. **The licence terms** print in full, then:

       Type ACCEPT to accept these terms on behalf of your organisation:

   Type `ACCEPT` in capitals. Anything else stops the install and writes nothing.

5. **The settings**, in this order. Press Enter to take the value in brackets.

   - `AWS access key id — paste it now, or press Enter to set it up later on the Administration
     screen` — both are fully supported. Pressing Enter leaves the keys blank and you enter
     them later, signed in, under Administration → AWS connection.
   - `AWS_SECRET_ACCESS_KEY` — asked only when you pasted a key id. The secret is not echoed.
   - `AWS_REGION [us-east-1]` — the region of the AWS account covered by your BAA, lower case.
   - `HTTPS — internal = certificate from the portal's own CA (any LAN name; browsers warn until
     you trust it), public = Let's Encrypt (needs public DNS and inbound ports 80 and 443),
     files = your own certificate in certs/, none = no HTTPS proxy (you provide TLS yourself)
     (internal/public/files/none) [internal]` — asked before the sign-in questions, because the
     Microsoft redirect URI default is built from the hostname. The installer starts a second
     container, the HTTPS proxy, that terminates TLS and is the only part of the portal the
     network can reach; the portal itself stays on `127.0.0.1:8000`.
     - `internal` (the default) works with any name, including `.lan` names no public
       certificate authority will issue for. Browsers warn until the portal's own root
       certificate is trusted — see **TLS** below. This is the right choice for almost every
       install on a private network.
     - `public` gets a real certificate from Let's Encrypt. Choose it only when a public DNS
       name points at this host and inbound ports 80 and 443 reach it from the internet. There
       is no client-side trust step.
     - `files` is for a certificate you already have (for example from your organisation's CA).
       Put `certs/fullchain.pem` and `certs/privkey.pem` in the `certs/` folder before the
       install finishes starting the proxy.
     - `none` leaves the portal on `127.0.0.1:8000` and puts no proxy in front of it — choose
       this only when you will terminate TLS yourself.
   - `Hostname users will type, e.g. portal.yourclinic.lan` — asked whenever the mode is not
     `none`; no answer, no install. It sets `PORTAL_HOSTNAME` in `portal.env` and is the
     hostname in the default Microsoft redirect URI.
   - `Networks allowed to reach the portal, space-separated
     [10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10]` — the proxy answers every other
     address with 403. Press Enter to allow the usual private ranges and the CGNAT range VPN
     overlays use; list your own CIDRs to narrow it. **On Windows this question is not asked:**
     Docker Desktop NATs every inbound connection, so all clients reach the proxy from one
     address and a network list can only block everyone or no one. The installer writes
     `0.0.0.0/0 ::/0` instead, says so, and tells you to use the Windows firewall.
   - `Sign-in — local = accounts and passwords managed in the portal, entra = sign in with
     Microsoft (needs an Azure app registration) (local/entra) [local]` — `local` gives password
     accounts that you manage on the Administration screen. `entra` is Microsoft sign-in, and
     then asks for three more values, all from one Azure app registration. Type `back` at any of
     the three to return to this question and choose `local` instead; Ctrl-C cancels the whole
     installer and writes nothing.
     The app registration is **yours, not ours** — the redirect URI is your host, so you create
     it in your own Azure tenant.
     - `Application (client) ID from the Azure app registration (a GUID)`
     - `Directory (tenant) ID` — one of three:
       - a **tenant GUID**: only that one organisation can sign in. Register the app for
         "Accounts in this organizational directory only".
       - `'organizations'`: any work or school account, from any organisation.
       - `'common'`: the same, plus personal Microsoft accounts.
       The last two are multi-tenant, are typed exactly as quoted, and need the app registered
       for "Accounts in any organizational directory".
     - `Allowed tenant GUIDs, comma-separated` — asked only after `organizations` or `common`.
       **Leaving it blank lets any organisation's accounts reach the sign-in screen**, and the
       admin-activation step is then the only thing keeping them out: a first Microsoft sign-in
       creates an *inactive* account that an administrator must activate. List the tenant GUIDs
       you expect unless you mean to allow all of them.
     - `Redirect URI — https://<your portal host>/auth/callback, registered on that app
       registration` — the `/auth/callback` path is fixed; register that exact URL in Azure or
       Microsoft refuses the sign-in before the portal ever sees it. For a local http test
       before you have a hostname, the portal's own default is
       `http://localhost:8000/auth/callback`.
       With the Azure CLI (`az login` first), look at both platforms — the existing URIs may be
       under `web` or under `publicClient`, and the new one goes on the same list as theirs.
       Each `update` replaces that platform's whole list, so repeat every URI the `show` prints:

           az ad app show --id <application-client-id> \
             --query "{web:web.redirectUris, publicClient:publicClient.redirectUris}"
           az ad app update --id <application-client-id> --public-client-redirect-uris \
             "http://localhost:8000/auth/callback" "https://<your portal host>/auth/callback" \
             <every other URI from the show>

       Moving an existing install between http and https (either direction) means adding the
       new URI here as well — the old one may stay; both keep working.
   - `Allow the daily licence check-in? The portal works either way [Y/n]` — `y` unless your
     network policy forbids it; see **Licence** below for what is sent.

6. **Your licence.** Easiest: **before you run the installer, save the licence from your
   onboarding email as a file ending `.lic` in this folder** — the block between the marker
   lines, starting with a `{`. Marker lines may be left in; the installer strips them. It then
   finds the file on its own and says so:

       Using licence file acme.lic found in this folder.

   If the folder holds more than one `.lic` file it asks which; `--licence-file <name>` names one
   outright (a relative name is looked for in this folder).

   With no `.lic` file it falls back to asking you to paste the block. Note that the `LIC-…`
   **licence ID is not the licence** — the licence is the JSON block, and pasting the ID alone is
   refused with that explanation.

   Either way your own file stays where you put it; the installer writes its own copy to
   `data/portal.lic`, which is the one the portal reads.

7. The installer writes `portal.env` (your settings, readable only by you) and `data/portal.lic`
   (your licence), starts the portal, and waits for it to answer. **`portal.env` is also how the
   host remembers it is installed: running the installer again refuses with "portal.env exists"
   rather than overwriting your settings.** Use `update.sh` / `update.ps1` after this.

8. **The first administrator.** The installer asks for a sign-in id and a display name — and, if
   you chose `entra`, that person's **Microsoft sign-in address** as well. It creates the account,
   and with `entra` also binds it to that address, so their Microsoft sign-in lands on it.

   - **`local` sign-in:** it prints a one-time **activation token** and then says the token is
     single-use and expires in 48 hours. Copy it now; it is never shown again.
   - **`entra` sign-in:** no activation token is shown — the portal refuses passwords in that
     mode, so it would be a credential nobody can use. It names the address the account is
     bound to instead.

   If the install stopped before this point, or a step failed, the installer prints the exact
   command or commands that finish the job. Run those rather than re-running the installer.

9. **HTTPS.** The installer has already started it — the last thing it prints is
   `The portal is served at https://<hostname>`. In `internal` mode it also prints where the
   root certificate is: `caddy-data/caddy/pki/authorities/local/root.crt`. Import that on each
   client before anyone signs in (see **TLS** below); until it is trusted, browsers warn.

10. **First sign-in.** Open `https://<hostname>/app`.

    - **`local`:** enter the administrator's sign-in id, choose a password, then open
      **First sign-in? Enter your activation token** and paste the token from step 8.
    - **`entra`:** choose **Sign in with Microsoft** as the bound person. There is no password
      and no token.

    The first administrator to sign in is then shown the **licence terms** and must tick
    "I accept these terms on behalf of my organisation" and choose **Accept and continue** before
    the portal can be used. Anyone else who signs in first sees "An administrator must accept the
    licence terms" and cannot go further.

**If the Microsoft binding was skipped** — you ran the installer non-interactively, or the
binding step failed — do it before that person signs in. An unbound Microsoft sign-in creates a
second, inactive account, and no active administrator is left to activate it:

    docker compose --env-file portal.env exec -T portal python -m dev_tools.portal_user_admin \
      --db /data/runtime/review_portal/review_portal.db set-upn <sign-in-id> <name@your-domain>

## TLS

Do not try the portal over plain `http://` first. `SESSION_COOKIE_SECURE=1` in `portal.env` means
the browser drops the session cookie over http, so a sign-in appears to succeed and the very next
click is signed out again. Set up TLS first — the installer already did.

**What the installer set up.** A second container, `cms1500-proxy`, runs beside the portal as a
compose service named `proxy` (compose profile `tls`, switched on by `COMPOSE_PROFILES=tls` in
`portal.env`). It is a copy of Caddy pinned by us, it publishes ports 80 and 443 on the host, and
it is the only part of the portal the network can reach: it terminates TLS for
`PORTAL_HOSTNAME`, refuses every address outside `PORTAL_ALLOWED_RANGES` with 403, and forwards
to the portal, which still listens on `127.0.0.1:8000` only. The two talk over a private compose
network with a fixed address for the proxy (`PROXY_SUBNET`, `PROXY_IP` in `portal.env`); the
portal believes forwarded client addresses only from that one address (`FORWARDED_ALLOW_IPS`).
The proxy writes its access log to stdout — `docker compose --env-file portal.env logs proxy`.

**Trusting the internal root certificate** (`internal` mode). Until each client trusts the
portal's own certificate authority, browsers warn. The root certificate is
`caddy-data/caddy/pki/authorities/local/root.crt` in this folder (created on first start). To
import it:

- **Windows:** copy the file to the PC, double-click it, choose **Install Certificate** →
  **Local Machine** → **Place all certificates in the following store** → **Trusted Root
  Certification Authorities** → **Finish**. Or, from an elevated prompt in the folder holding
  the file: `certutil -addstore -f ROOT root.crt`. Restart the browser.
- **macOS:** copy the file to the Mac and run
  `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain root.crt`,
  or open **Keychain Access**, drag the file into the **System** keychain, double-click the
  imported certificate, and set **Trust** to **Always Trust**. Restart the browser.

**Switching TLS mode or hostname later.** Edit `PORTAL_TLS_MODE` and/or `PORTAL_HOSTNAME` in
`portal.env`, then run `docker compose --env-file portal.env up -d` — compose recreates the
proxy with the new values. Switching to or from `none` also means setting `COMPOSE_PROFILES` to
`tls` or empty in the same file. Do not edit `Caddyfile` or the `caddy-tls-*.caddy` files: they
read everything from `portal.env`.

**Renewing a `files`-mode certificate.** Replace `certs/fullchain.pem` and
`certs/privkey.pem` with the renewed files, then run
`docker compose --env-file portal.env restart proxy`. There is nothing else to renew — the
portal never holds the certificate. Replacement private key files should be readable only by
you: `chmod 600 certs/privkey.pem`.

**Allowed networks.** `PORTAL_ALLOWED_RANGES` in `portal.env` is the space-separated list of
CIDRs the proxy answers; every other address gets 403. The installer set it to your answer —
`10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10` when you pressed Enter, which covers the
usual private ranges and VPN overlays. Narrow it to your LAN or VPN, or widen it, by editing the
line and running `docker compose --env-file portal.env up -d`. **On Windows the installer wrote
`0.0.0.0/0 ::/0` instead** — Docker Desktop NATs every inbound connection, so all clients reach
the proxy from one address and a network list can only block everyone or no one. Restrict who can
reach the portal there with Windows Defender Firewall: allow inbound TCP 443, and TCP 80 as well
while the certificate is `public`.

**Reading the proxy's view of clients.** Reviewers' PCs reach the proxy with their real LAN
addresses, but a request made from the host itself reaches the proxy from `172.30.250.1` — the
docker gateway address, not `127.0.0.1` — so the access log and any 403 troubleshooting look
different from the host than from a client PC. The shipped default ranges already cover
`172.30.250.1`.

## If the install stops

Nothing is written, started or changed unless the installer says so. It ends with one of:

| Exit | Meaning | What to do |
|---|---|---|
| 1 | Could not write `portal.env` / `data/portal.lic`, or the portal did not come up, or the administrator could not be created or bound | Check that you can write in this folder and that `data/` is not owned by another user. If the portal started but has no administrator, run the command(s) the installer printed — do not re-run the installer. |
| 2 | Something was missing or an answer was rejected — Docker not installed or not running, the wrong folder, a bad AWS region, a licence that did not parse, or the compose plugin could not be put in place | The message names it and the one command that fixes it. Fix, then run the installer again. |
| 3 | `portal.env` exists: this host is already installed | Use `update.sh` / `update.ps1`. |
| 4 | The licence terms were not accepted | Nothing was written. Run the installer again and type `ACCEPT`. |
| 2 | `port 80 is already in use by another container` (or `port 443`) — the proxy publishes both, and another container already holds one | `docker ps` shows which container; stop it or remove its port binding, then run the installer again. If the host must keep that service, answer `none` at the HTTPS question and terminate TLS yourself. |
| 1 | `the HTTPS proxy did not come up` | `docker compose --env-file portal.env logs proxy`. If the log says a port is already in use, a non-Docker service on the host (a web server, an appliance agent) holds 80 or 443 — stop it or answer `none` and re-run. |

Three exit-2 messages are worth knowing in advance, all from the compose-plugin step on Linux:

- *"cannot create …/cli-plugins"* — a root-owned `~/.docker`, usually left by an earlier
  `sudo docker`. The message gives the `chown` that fixes it.
- *"wrong architecture: the image is … this host is …"* — the image is built for another CPU.
  Ask us for a build that matches.
- *"neither DOCKER_CONFIG nor HOME is set"* — the shell has no home directory, so there is
  nowhere Docker looks for a plugin. Re-run with `HOME` set.

## Updating

We announce a version. Then, on the host, in this folder:

    sh update.sh <version>          # Linux
    .\update.ps1 -Version <version> # Windows

If we sent you `portal-<version>.tar`, leave it in this folder and run exactly the same
command: the update loads it instead of pulling.

The script backs up the database to `data/backups/`, sets the new version in `portal.env`, pulls
the image, restarts, and waits for the health check. Downtime is under a minute. The host needs
no `curl`: the health check runs inside the container.

**Offline (`.tar`) hosts.** Put the file we send you in this folder and name it in the command.
The version comes first:

    sh update.sh <version> --tarball portal-<version>.tar          # Linux
    .\update.ps1 -Version <version> -Tarball portal-<version>.tar  # Windows

The script then loads that file instead of pulling, and nothing contacts the registry. It checks
the file is there before it backs anything up, so a mistyped name costs you nothing.

## Rollback

The previous image is still on the host. Set `PORTAL_VERSION` in `portal.env` back to the old
version and run:

    docker compose --env-file portal.env up -d

The backup the update took first is in `data/backups/`. Talk to us before restoring one — put
the old version back first, and we will walk you through the rest.

## Backups

`update.sh` / `update.ps1` back up before every update. For nightly backups, schedule on the host:

    docker compose --env-file portal.env exec -T portal python -m dev_tools.db_backup --db /data/runtime/review_portal/review_portal.db --out /data/backups --keep 14

Copy `data/backups/` to your off-host encrypted storage; it contains patient data.

## Licence

The Administration screen shows who the portal is licensed to, the expiry date, and seats in use.

- Expiry: a banner appears when the licence has expired. You have 30 days of normal use to install a renewal. After that the portal refuses claim work until a renewed `portal.lic` is uploaded on the Administration screen, or copied over `data/portal.lic` and the container restarted.
- Seats: the number of active user accounts. Deactivate an account to free a seat. Some licences have no seat cap; the Administration screen then reads "unlimited seats".
- Maintenance date: versions released after it will not start. Renew maintenance to receive updates.
- Check-in: once a day the portal sends its licence id, an anonymous install id, its version number, and which licence terms version was accepted to our licence server. No claim data or user data is ever sent. If the server is unreachable the portal keeps working. Answering `n` at the check-in prompt, or emptying `LICENSE_SERVER_URL` in `portal.env`, switches it off.
- `LICENSE_MODE` stays unset in a customer installation: the portal must always run licensed. (`off` exists for developer machines only and is not a supported customer configuration.)
- Terms: `LICENSE.md` in this folder is the licence terms text. The first administrator to sign in accepts them once; a release that changes the terms (a new `Version` line in `LICENSE.md`) asks an administrator to accept again before anyone can use the portal.

## Manual install

An air-gapped or scripted site that cannot run the installer does the same steps by hand. Read
`LICENSE.md` first: installing the portal accepts those terms either way.

1. Put this folder on the host, for example `/opt/cms1500`.
2. `cp portal.env.template portal.env`, then edit it:
   - `PORTAL_VERSION=<version>` — the template ships an old value and Compose uses it literally.
   - `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`.
   - `PORTAL_SECRET_KEY` — `openssl rand -base64 32`. Required if you plan to enter the AWS keys
     on the Administration screen instead; harmless otherwise. Never change it afterwards.
   - `AUTH_MODE`, plus `ENTRA_CLIENT_ID`, `ENTRA_TENANT_ID` and `ENTRA_REDIRECT_URI` for `entra`.
   - The HTTPS proxy, five keys together — set them to start the same proxy the installer would:
     `COMPOSE_PROFILES=tls`, `PORTAL_HOSTNAME` (the DNS name users type),
     `PORTAL_TLS_MODE` (`internal`, `public` or `files`), `PORTAL_ALLOWED_RANGES`
     (space-separated CIDRs; on Windows leave the template's `0.0.0.0/0 ::/0` — Docker Desktop
     NATs every client to one address — and use the Windows firewall), and
     `FORWARDED_ALLOW_IPS`, which must equal `PROXY_IP` (`172.30.250.6` in the template). Leave
     `COMPOSE_PROFILES` empty and skip the rest to install without the proxy and terminate TLS
     yourself. `files` mode also needs `certs/fullchain.pem` and `certs/privkey.pem` in `certs/`
     before the proxy starts (step 6).
   Keep the file readable only by you: `chmod 600 portal.env`.
3. `mkdir data`. Copy the licence out of your onboarding email — everything between the two marker lines, but not the marker lines themselves — and save it as `data/portal.lic`.
4. Registry: `docker login ghcr.io` with the credentials we sent you, then
   `docker pull ghcr.io/sofortune81/cms1500-portal:<version>`. Tarball: `docker load -i portal-<version>.tar`.
5. If `docker compose version` fails, this host has no Compose plugin. Either install your
   distribution's package (`sudo apt-get install docker-compose-plugin`), or take the copy
   inside the portal image, which needs no network:

       mkdir -p ~/.docker/cli-plugins
       CID=$(docker create ghcr.io/sofortune81/cms1500-portal:<version>)
       docker cp $CID:/opt/compose/docker-compose ~/.docker/cli-plugins/docker-compose
       docker rm -f $CID
       chmod +x ~/.docker/cli-plugins/docker-compose
       docker compose version

   The plugin belongs to the user who ran those commands. If you run Docker under `sudo`, run
   them under `sudo` too, so the copy lands in root's home where root's docker will look.
6. `docker compose --env-file portal.env up -d`

   Every Compose command needs `--env-file portal.env`. Without it Compose cannot fill in the
   image name and fails with "invalid reference format".
7. `curl http://127.0.0.1:8000/health` returns `{"status":"ok"}`. With the proxy on, the portal
   is also reachable at `https://<hostname>` from a client PC. In `internal` mode the root
   certificate appears at `caddy-data/caddy/pki/authorities/local/root.crt` once the proxy has
   run — import it on each client as in **TLS** above.
8. Create the first administrator and keep the activation token it prints:

       docker compose --env-file portal.env exec -T portal python -m dev_tools.portal_user_admin \
         --db /data/runtime/review_portal/review_portal.db create <id> "<Name>" --role admin

   With `AUTH_MODE=entra`, ignore that token and run this second command as well, before that
   person signs in:

       docker compose --env-file portal.env exec -T portal python -m dev_tools.portal_user_admin \
         --db /data/runtime/review_portal/review_portal.db set-upn <id> <name@your-domain>

9. Sign in at `https://<hostname>/app` as in **First install**, step 10.

## Getting help

Send us the output of `docker compose --env-file portal.env logs --tail 200 portal` and, when
the HTTPS proxy is on, `docker compose --env-file portal.env logs --tail 200 proxy`. They contain
no claim contents.
