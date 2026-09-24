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
- **Linux host** (Docker Engine 24+) **or native Windows service** (Windows Server 2022 or
  Windows 11, physical or virtual, Windows PowerShell 5.1 — no Docker, WSL or Hyper-V needed).
  See **Windows native install** below for the native path.
- **Docker Desktop on Windows Server is unsupported.** Docker Desktop on Windows 11 remains
  supported through `install.ps1` in this bundle: set it to Linux containers. Our scripts are
  not code-signed, so if PowerShell refuses to run one, start it like this instead — this
  allows the one script, and changes nothing on the machine:

      powershell -ExecutionPolicy Bypass -File .\install.ps1 -Version <version>

- **A Windows VM running Docker needs nested virtualization** on its hypervisor; without it
  Docker's Linux engine never starts (`docker login` answers `500 Internal Server Error` on
  `dockerDesktopLinuxEngine`). Use the native Windows service instead.
- **Native Windows:** the `data` folder on a BitLocker volume; endpoint-protection exclusions
  as printed by the preflight.
- The `data/` folder on an encrypted volume. It will hold patient data.
- Outbound HTTPS to AWS (Textract, Bedrock) and, unless your policy forbids it, to the licence server.
- Ports 80 and 443 free on the host — the installer-managed HTTPS proxy publishes them, so
  nothing else on the host may hold them. Port 8000 is never exposed. For a `public`
  certificate you also need a public DNS name pointing at the host.
- Your reviewers reach the portal over the LAN or VPN at `https://<hostname>`.

## Before you install: AWS and Microsoft sign-in

The installer asks for AWS keys and, if you choose Microsoft sign-in, for values from an Azure
app registration. Both live in **your** accounts, not ours. Set them up first using the steps
below. If you would rather start without them, press Enter at the AWS prompts, choose `local`
sign-in, and come back to this section later.

### AWS

The portal reads each claim with Amazon Textract. The optional vision second pass uses Amazon
Bedrock. Both run in your AWS account and bill to it. You need an AWS account and someone who
can create IAM users in it.

1. **Accept the AWS Business Associate Addendum.** Claim images are patient data. Sign in to
   the AWS console as the account's root user or an administrator, open **AWS Artifact** →
   **Agreements**, and accept the **AWS Business Associate Addendum** for this account (or for
   your organisation, if you use AWS Organizations). Do this before any real claim is processed.
2. **Choose a region.** Pick one region and use it everywhere below. It must:
   - be on AWS's list of HIPAA-eligible services for Textract, and for Bedrock if you will use
     the vision pass;
   - offer the vision model `qwen.qwen3-vl-235b-a22b`, if you will use the vision pass. To
     check, open the Bedrock console in that region → **Model catalog** and search for "Qwen3
     VL".

   Write the region code down in lower case, for example `us-east-1`. The installer asks for
   it.
3. **Create the permissions policy.** Open **IAM** → **Policies** → **Create policy** →
   **JSON**. Paste the policy below. Replace `us-east-1` in the Bedrock ARN with your region.
   Choose **Next**, name the policy `cms1500-portal`, and choose **Create policy**.

       {
         "Version": "2012-10-17",
         "Statement": [
           {
             "Sid": "ClaimTextExtraction",
             "Effect": "Allow",
             "Action": [
               "textract:DetectDocumentText",
               "textract:AnalyzeDocument"
             ],
             "Resource": "*"
           },
           {
             "Sid": "ClaimVisionSecondPass",
             "Effect": "Allow",
             "Action": [
               "bedrock:InvokeModel"
             ],
             "Resource": [
               "arn:aws:bedrock:us-east-1::foundation-model/qwen.qwen3-vl-235b-a22b"
             ]
           },
           {
             "Sid": "AdministrationCostPanelOptional",
             "Effect": "Allow",
             "Action": [
               "ce:GetCostAndUsage"
             ],
             "Resource": "*"
           }
         ]
       }

   What each part does:
   - `ClaimTextExtraction` is required, because Textract reads every claim.
   - `ClaimVisionSecondPass` is needed only if you turn on the vision pass.
   - `AdministrationCostPanelOptional` lets the Administration screen show your AWS spend. You
     can delete this block.

   After install, Administration → AWS connection → **Setup instructions** shows the exact
   policy for your saved region and model. If it ever differs from the one above, use the one
   on that screen.
4. **Create the IAM user.** Open **IAM** → **Users** → **Create user**. Name it
   `cms1500-portal` and leave **Provide user access to the AWS Management Console** unticked.
   On the permissions step choose **Attach policies directly**, tick `cms1500-portal`, then
   choose **Next** → **Create user**.
5. **Create its access key.** Open the new user → **Security credentials** → **Create access
   key**. For the use case choose **Application running outside AWS**, then **Next** →
   **Create access key**. Copy the **Access key ID** and the **Secret access key** now. AWS
   shows the secret only once. Keep the key only in a password manager until you paste it into
   the installer.
6. **Vision model access (only if you will use the vision pass).** Open the Bedrock console
   in your region. If it has a **Model access** page, make sure `Qwen3 VL 235B A22B` shows
   **Access granted**, and request it if not. Newer accounts have serverless models switched on
   already. **Test connection** (step 9) confirms access either way.
7. **Cost Explorer (optional).** The Administration cost panel needs Cost Explorer. It is off
   in a new account: open **Billing and Cost Management** → **Cost Explorer** once to enable
   it. The first data appears about a day later.
8. **Set a budget alarm (recommended).** The portal bills AWS without a human click in two
   cases: the watched-folder scan, and the vision pass once it is on. Open **Billing and Cost
   Management** → **Budgets** → **Create budget** and create a monthly cost budget with an
   email alert, so an unexpected run is noticed within a day.
9. **Give the key to the portal.** Paste the key ID, secret and region at the installer's AWS
   prompts. Alternatively, press Enter there and enter them after install under
   **Administration → AWS connection → Access key**. Either way, choose **Test connection**
   on that screen after the first sign-in. It makes one real Textract call and one Bedrock
   call, costing about $0.01, and names any permission that is missing.

**Rotating the key:** create a second access key on the same IAM user and paste it under
Administration → AWS connection. Run **Test connection**, then deactivate and delete the old
key in IAM. A user can hold two keys at once, so there is no downtime.

**Running on AWS already?** If the host is an EC2 instance, you can attach the policy to the
instance's IAM role instead of creating a user and key. Leave the installer's key prompt blank,
then choose **Host credentials** under Administration → AWS connection.

### Microsoft sign-in (Entra ID)

Skip this part if you will use `local` sign-in, where accounts and passwords are managed in the
portal. For Microsoft sign-in, someone who can create app registrations in your Microsoft 365
tenant registers the portal once:

1. **Know the portal's address.** The redirect URI is `https://<hostname>/auth/callback`,
   where `<hostname>` is the name users will type (the installer asks for it). The path
   `/auth/callback` is fixed.
2. **Register the app.** Sign in to the **Microsoft Entra admin center**
   (`entra.microsoft.com`) → **Identity** → **Applications** → **App registrations** → **New
   registration**.
   - **Name:** anything your users will recognise on Microsoft's consent screen, for example
     `Claims Review Portal`.
   - **Supported account types:**
     - **Accounts in this organizational directory only (Single tenant)** is the right choice
       for almost every clinic: only your own staff can sign in.
     - **Accounts in any organizational directory (Multitenant)** is only for staff spread
       across several Microsoft 365 organisations.
   - **Redirect URI:** set the platform to **Public client/native (mobile & desktop)** — **not
     Web and not Single-page application**. Then enter `https://<hostname>/auth/callback`.
     The portal signs in without a client secret, using PKCE. With a **Web** redirect, Microsoft
     rejects the sign-in with error `AADSTS7000218`.
   - Choose **Register**.
3. **Allow public client flows.** In the new registration open **Authentication**, set **Allow
   public client flows** to **Yes**, and choose **Save**.
4. **Leave everything else alone.** Do not create a client secret or certificate: the portal
   never uses one. The default **Microsoft Graph → User.Read** permission is enough. The portal
   asks only for `openid profile email`. Also skip app roles unless you want them (see
   *Roles from Entra* below).
5. **Copy two values** from the registration's **Overview** page:
   - **Application (client) ID**, a GUID. The installer asks for it.
   - **Directory (tenant) ID**, a GUID. For a single-tenant registration, this is what you
     type at the installer's `Directory (tenant) ID` prompt. For a multitenant one, type
     `organizations` there instead, and list the tenant GUIDs you expect at the next prompt.
     Another organisation's tenant GUID is public. It is the GUID in the `issuer` value at
     `https://login.microsoftonline.com/<their-email-domain>/.well-known/openid-configuration`.
6. **Consent.** The first person from each organisation to sign in sees Microsoft's
   permission prompt for the app (sign-in and basic profile). If your tenant blocks user
   consent, an administrator opens the registration → **API permissions** → **Grant admin
   consent for <your organisation>** once.
7. **Who gets in.** Signing in with Microsoft does not by itself give access. The installer
   binds the first administrator to their Microsoft address. Anyone else's first Microsoft
   sign-in creates an **inactive** account, and an administrator activates it and sets its
   role under Administration → Users. To restrict sign-in further at Microsoft's end, open
   **Enterprise applications** → your app → **Properties** and set **Assignment required** to
   **Yes**. Then assign users or groups under **Users and groups**.

**Adding another address later** (for example moving from `http://localhost:8000` testing to
`https://<hostname>`): open the registration → **Authentication** and add the new URI under the
same **Mobile and desktop applications** platform. Old and new URIs both keep working.

**Roles from Entra (optional, single-tenant only).** To manage portal roles in Entra instead of
on the Administration screen:
1. In the registration → **App roles**, create roles with the values `Admin`, `Reviewer` and
   `Billing`.
2. Assign them to users under **Enterprise applications** → your app → **Users and groups**.
3. Add `ENTRA_ROLE_SOURCE=claims` to `portal.env` and restart the portal.

Each sign-in then takes its role from Entra, and someone with no role is refused. The portal
refuses to start in this mode with a multitenant `ENTRA_TENANT_ID`.

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
     them later, signed in, under Administration → AWS connection. How to create the key:
     **Before you install → AWS**.
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
     it in your own Azure tenant. Step by step: **Before you install → Microsoft sign-in**.
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

## Windows native install

Skip this section for Docker Desktop hosts — use **First install** above. This path installs
the portal and its HTTPS proxy as two Windows services, natively: no Docker, WSL, Hyper-V, or
typed command. Check the hash, double-click, follow the wizard, finish on the portal's address.

1. **Check the download.** Beside `CMS1500-Setup-<version>.exe` is a `.sha256` file (we also
   send `portal-<version>-windows.zip` and its own `.sha256` — see the fallback at the end of
   this section). In PowerShell, from the folder holding the exe and its `.sha256`:

       Get-FileHash CMS1500-Setup-<version>.exe -Algorithm SHA256

   The hash it prints must match the one in the `.sha256` file. If it does not, download again
   and do not run it.

2. **Double-click `CMS1500-Setup-<version>.exe`.** It is not code-signed for this pilot, so
   Windows shows a SmartScreen warning that it is from an unrecognized publisher. Click
   **More info**, then **Run anyway**. Setup asks Windows for administrator rights next.

3. **Follow the wizard.** It asks the same questions the installer always asked, one page at a
   time — Welcome, Licence terms, Licence file (browse to the `.lic` file saved from your
   onboarding email), Folders (install and patient-data folders; both must be new or empty),
   Sign-in (local accounts or Microsoft/Entra ID; also collects the first administrator), AWS
   (paste the access key and secret, or tick **Enter the keys later in the portal (Administration
   → AWS connection)** — a rejected key never blocks the install; Setup says so and leaves the
   fields blank instead), Network (the hostname other PCs will use, defaulting to this PC's own
   name, and the allowed CIDRs), Ready (a summary — nothing is written before this page),
   Install, Finish. If the patient-data drive is not BitLocker-protected, Setup stops here and
   asks you to confirm it is encrypted some other way before continuing.

4. **Finish page.** Shows the portal's address, then any preflight warnings underneath. With
   local sign-in it also shows the first administrator's one-time **activation token** — copy it
   now, it is never shown again. On a fresh install only, an unticked **Trust the portal
   certificate on this PC** option adds the certificate to the signed-in Windows account's own
   store (not the machine's) so that account's browser stops warning; tick it if you plan to
   sign in from this PC.

5. **Existing install.** Point Setup at a PC that already has the portal and it skips straight to
   an update — no licence, sign-in, AWS or network pages, since it already has that information.
   An older Setup than the version already installed is refused; use **Roll back to previous
   version** in the Start menu instead of an older installer.

6. **Uninstall.** Apps & features → CMS-1500 Review Portal → Uninstall stops and removes both
   Windows services and the firewall rules. **It never removes the patient-data folder** and
   tells you where it is — back it up first if you mean to keep it. Reinstalling into the same
   install folder is refused until that folder is deleted.

7. **Start menu.** Open portal, Restart portal, Portal status (prints the logs path — there is no
   separate Logs folder shortcut, since the logs are readable only by Administrators and
   SYSTEM), Back up now, Roll back to previous version.

8. **If your site's policy blocks unsigned executables.** We also send
   `portal-<version>-windows.zip` and its own `.sha256`. Unpack it somewhere only administrators
   can write, then double-click `Install.cmd` (or `Update.cmd` on a PC that already has the
   portal) at its root instead of the exe — each asks Windows for administrator rights, then runs
   the same install through console prompts. Ctrl+V does not paste into those prompts; right-click
   to paste instead.

`LICENSE.md` (inside the zip, or shown by the wizard) is the licence terms; installing accepts
them either way. Configuration and operation below — TLS, licensing, troubleshooting — apply to
both install paths; only the service registration and file layout differ.

**Scripted or repeat installs.** `install.ps1`, `update.ps1`, `rollback.ps1` and `backup.ps1`
inside the zip are the engine the wizard and the `.cmd` launchers both drive unattended; an
elevated PowerShell prompt can still call them directly with flags (`-InstallRoot`, `-DataRoot`,
`-AllowedRanges`, `-ServiceAccount`, `-AnswersFile`, `-CheckOnly`) to provision several hosts
without answering the wizard's pages each time. Logs land in
`<InstallRoot>\logs\portal\` and `<InstallRoot>\logs\proxy\`. Schedule `backup.ps1` nightly,
elevated, with `<InstallRoot>` filled in:

    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
                 -Argument '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "<InstallRoot>\scripts\backup.ps1"'
    $trigger = New-ScheduledTaskTrigger -Daily -At 1:30am
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName 'CMS-1500 portal backup' -Action $action -Trigger $trigger -Principal $principal

Run the task as `SYSTEM`, as above, only if the install used `-GrantSystem`; otherwise SYSTEM
cannot read `<DataRoot>` and the task must run as a member of the local Administrators group
instead (`-UserId '<domain>\<account>' -LogonType Password`). This backup is local only — copy
`<DataRoot>\backups\` to your own off-host encrypted storage; nothing here ships a copy off-host.
**Never delete `<DataRoot>` without a backup** — it holds the licence and the patient database.

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

### Windows native preflight

Every check below runs inside the setup wizard, and stops it on a blocker with the message and
fix in plain English on the Ready or Install page. The same checks are also available directly:
`install.ps1 -CheckOnly` (and the checks `update.ps1` repeats) print one line per check, then on
any failure a message and the one fix, and exit. Nothing is written until every check passes.

| Exit | Check fails with | Fix |
|---|---|---|
| 2 | `bundle-integrity`: `manifest.cms1500.json` is missing, empty, or files do not match it | Delete the folder, check the zip's hash against the separately sent `.sha256`, unpack again. |
| 2 | `bundle-location`: the unpacked folder is writable by a standard user | Unpack under a folder only Administrators can write. |
| 2 | `os`: `<Caption> build <n> is not supported` | Use 64-bit Windows Server 2022 (build 20348+) or Windows 11 (build 22000+). |
| 2 | `admin`: this console is not elevated | `Start-Process powershell -Verb RunAs` |
| 2 | `ports`: port 80 or 443 is held by HTTP.sys (IIS, WinRM or another Windows web service) | `netsh http show servicestate`, then stop the service it names (e.g. `Stop-Service W3SVC`). |
| 2 | `ports`: port 80 or 443 is held by another process | `Stop-Process -Id <pid>`, then free the port. |
| 2 | `egress`: Textract is not reachable over HTTPS | `Test-NetConnection <host> -Port 443`; allow outbound 443 to it. |
| 2 | `disk`: the install or data folder is a UNC path, not a local fixed disk, not NTFS, or has too little free space | Choose a folder on a local NTFS volume, with enough free space, via `-InstallRoot` / `-DataRoot`. |
| 2 | `bitlocker`: the data volume is not BitLocker-protected | `Enable-BitLocker -MountPoint <drive> -RecoveryPasswordProtector`, or re-run with `-AcceptUnencryptedDataVolume` if the disk is encrypted below Windows. |
| 2 | `service-account`: `-ServiceAccount` does not resolve to an account | Create the account first, or omit the flag to use the built-in virtual account. |
| 2 | `firewall`: Group Policy ignores local firewall rules | Ask your domain administrator for a GPO rule allowing inbound TCP 443 (and 80). |
| 2 | `firewall`: the inbound rule for TCP 80,443 is missing (`update.ps1` only) | `New-NetFirewallRule -DisplayName 'CMS-1500 Review Portal (HTTPS proxy)' -Direction Inbound -Protocol TCP -LocalPort 80,443 -Action Allow` |
| 2 | `vcredist`: the VC++ 2015–2022 x64 runtime is missing | `.\runtime\redist\vc_redist.x64.exe /install /quiet /norestart`, then re-run. |
| 2 | `media-foundation`: `Server-Media-Foundation` is not installed (Server SKUs only) | `Install-WindowsFeature Server-Media-Foundation`, then restart and re-run. |
| 2 | `data-root-path`: the data folder is a UNC path, a mapped drive, or too long for Windows' 260-character path limit | Choose a shorter, local `-DataRoot`. |
| 2 | `python-selftest` / `tesseract-selftest`: the bundled interpreter or Tesseract is missing, or its self-test failed | Add the exclusion paths the antivirus check printed to your endpoint protection, unpack the zip again, and re-run. A failed Python self-test naming a `cv2` import means the `vcredist` or `media-foundation` fix above instead. |
| 2 | No install folder given on a redirected (non-interactive) console | Run the installer interactively, or pass `-InstallRoot` and `-AllowedRanges` as flags. |
| 1 | The portal did not come up | `<InstallRoot>\logs\portal\cms1500-portal.out.log` and `.err.log` |
| 1 | (update) `<version> did not come up`; the host is put back on the version it ran before, automatically | `<InstallRoot>\logs\` — the failed version stays on disk for us to look at. |
| 3 | This host already holds an installed portal | Use `.\update.ps1` instead. |

**Warning, not a failure:** `bedrock-runtime…` is not reachable — the install continues. Allow
outbound TCP 443 to that host before switching on the vision second pass; the Administration
screen shows the same notice until it is reachable.

## Updating

This section, **Rollback** and **Backups** below are the Docker path (`update.ps1` here is the
Docker Desktop script, unchanged). Windows native: run the new `CMS1500-Setup-<version>.exe` (it
detects the existing install and updates it), or use the Start menu's **Roll back to previous
version** / **Back up now** — see **Windows native install** above.

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
