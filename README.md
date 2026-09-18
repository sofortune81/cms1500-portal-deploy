# CMS-1500 Review Portal — installation and operations

## What you receive

- A container image, `ghcr.io/sofortune81/cms1500-portal:<version>` (or a `.tar` file for hosts without registry access).
- A licence issued to your organisation, sent as text in your onboarding email for you to save as `portal.lic`. It carries an expiry date, a maintenance date, and a seat count.
- This folder: `docker-compose.yml`, `portal.env.template`, `update.sh`, `Caddyfile`.

## Requirements

- One Linux or Windows host with Docker Engine 24+ and Docker Compose v2.
- The `data/` folder on an encrypted volume. It will hold patient data.
- Outbound HTTPS to AWS (Textract, Bedrock) and, unless your policy forbids it, to the licence server.
- Port 443 reachable by your reviewers over the LAN or VPN. Port 8000 is never exposed.

## First install

1. Copy this folder to the host, for example `/opt/cms1500`.
2. `cp portal.env.template portal.env` and fill in the AWS keys and `AUTH_MODE`. To manage the AWS keys on the Administration screen instead (AWS connection), set `PORTAL_SECRET_KEY` as the template describes.
3. `mkdir data`. Copy the licence out of your onboarding email — everything between the two marker lines, but not the marker lines themselves — and save it as `data/portal.lic`.
4. Registry: `docker login ghcr.io` with the token we sent you. Tarball: `docker load -i portal-<version>.tar`.
5. `docker compose up -d`
6. `curl http://127.0.0.1:8000/health` returns `{"status":"ok"}`.
7. Install Caddy, copy `Caddyfile`, edit the hostname and the `remote_ip` ranges, start it.
8. Create the first administrator:
   `docker compose exec portal python -m dev_tools.portal_user_admin --db /data/runtime/review_portal/review_portal.db create <id> "<Name>" --role admin`
9. Sign in at `https://<hostname>/app`.

## Updating

We announce a version. Then, on the host:

    sh update.sh <version>

The script backs up the database to `data/backups/`, pulls the image, restarts, and waits for the health check. Downtime is under a minute. If the health check fails, the previous version is still on the host: put the old version back in `portal.env` and run `docker compose up -d`.

For a tarball delivery, `docker load -i portal-<version>.tar` first, then run the same command.

## Licence

The Administration screen shows who the portal is licensed to, the expiry date, and seats in use.

- Expiry: a banner appears when the licence has expired. You have 30 days of normal use to install a renewal. After that the portal refuses claim work until a renewed `portal.lic` is uploaded on the Administration screen, or copied over `data/portal.lic` and the container restarted.
- Seats: the number of active user accounts. Deactivate an account to free a seat. Some licences have no seat cap; the Administration screen then reads "unlimited seats".
- Maintenance date: versions released after it will not start. Renew maintenance to receive updates.
- Check-in: once a day the portal sends its licence id, an anonymous install id, and its version number to our licence server. No claim data or user data is ever sent. If the server is unreachable the portal keeps working.
- `LICENSE_MODE` stays unset in a customer installation: the portal must always run licensed. (`off` exists for developer machines only and is not a supported customer configuration.)

## Backups

`update.sh` backs up before every update. For nightly backups, schedule on the host:

    docker compose exec -T portal python -m dev_tools.db_backup --db /data/runtime/review_portal/review_portal.db --out /data/backups --keep 14

Copy `data/backups/` to your off-host encrypted storage; it contains patient data.

## Getting help

Send us the output of `docker compose logs --tail 200 portal`. It contains no claim contents.
