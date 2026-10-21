# Comtek PassProtect — ctk-esgn installation

**Application:** Comtek PassProtect  
**URL:** https://passprotect.comtek.uk.com  
**Server:** ctk-esgn, shared with the existing Documenso/Comtek Sign installation  
**Repository:** https://github.com/ctkmark/ComtekPassProtect

This is a deployment runbook, **not a script to change production unattended**. Inspect the existing host first. Do not stop, replace, reconfigure, or prune Documenso. This project is independently deployed.

## 1. DNS

Create an **A record** named `passprotect` under `comtek.uk.com`, with the **same public IPv4** as `esign.comtek.uk.com`. Initial TTL: 300 seconds. No SRV record is necessary. If using Cloudflare, initially leave it DNS-only until HTTPS/proxying is verified.

Confirm from a workstation:
```bash
dig +short passprotect.comtek.uk.com A
dig +short esign.comtek.uk.com A
```
Check records match. Never replace or remove the existing eSign record.

## 2. Non-destructive read-only server inspection (SSH)

Run on **ctk-esgn** with a user permitted to query Docker and read proxy configuration:

```bash
hostname
id
pwd
docker version
docker compose version
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}'
sudo ss -lntp
systemctl is-active nginx caddy traefik apache2 2>/dev/null || true
command -v nginx && sudo nginx -t
```

**Stop and resolve if port 15100 is in use.** Determine whether the existing proxy is nginx, Caddy, Traefik, or Nginx Proxy Manager and whether it runs as a host process or Docker container. Docker-container proxies generally cannot reach the host's loopback address; in that case connect services via a suitable private Docker network instead. Do not copy the example nginx config without adapting it.

Record the existing Documenso Compose/config paths and take a restorable backup or snapshot of its configuration and persistent data before any production work.

## 3. Install and configure in a separate directory

Use a deployment directory outside the Documenso installation:

```bash
sudo mkdir -p /opt/comtek-passprotect
sudo chown "$USER":"$USER" /opt/comtek-passprotect
git clone https://github.com/ctkmark/ComtekPassProtect.git /opt/comtek-passprotect
cd /opt/comtek-passprotect
git checkout master
cp deploy/.env.passprotect.example deploy/.env.passprotect
chmod 600 deploy/.env.passprotect
openssl rand -hex 64
openssl rand -hex 32
```

**Paste the first generated value into** `PASS_PROTECT_SECRET_KEY_BASE`, **and the second into** `PASS_PROTECT_MASTER_KEY` in `deploy/.env.passprotect`. Never post the values in chat, logs, tickets, or GitHub. Securely back up the file separately from the database. These keys must persist across updates.

On a host where the latest branded changes are on a PR branch, do not use master until that PR has been reviewed, tested and merged.

## 4. Run PassProtect separately

Run **only after** inspection confirms loopback port 15100 is free and the chosen proxy design supports this binding:

```bash
cd /opt/comtek-passprotect
docker compose -f deploy/compose.passprotect.yml --env-file deploy/.env.passprotect config --quiet
docker compose -f deploy/compose.passprotect.yml --env-file deploy/.env.passprotect up -d --build
docker compose -f deploy/compose.passprotect.yml --env-file deploy/.env.passprotect ps
curl -fsS http://127.0.0.1:15100/up >/dev/null && echo 'PassProtect healthy'
```

The container listens on internal port **5100**, exposed on host **127.0.0.1:15100**. It must not claim host 80 or 443, which belong to the existing reverse proxy. Persistent SQLite data and uploads live in a named Docker volume mounted on `/opt/PasswordPusher/storage` (not `/opt/PasswordPusher/db` — the latter hides migrations).

The image is built **from your fork**. Do not switch to `pglombardo/pwpush:latest` or you'll lose custom branding.

## 5. Configure the EXISTING HTTPS reverse proxy

Create a separate hostname route for `passprotect.comtek.uk.com` to PassProtect's internal HTTP service, leaving all Documenso routes unchanged.

* **Host-installed nginx**: use `deploy/nginx-passprotect.conf.example` only as a starting point. Provide TLS using your existing Certbot/ACME process, then verify with `sudo nginx -t` before reloading.
* **Docker-managed reverse proxy**: join PassProtect to the proxy's private network and route by its service/container name, at port **5100**, rather than `127.0.0.1:15100` inside the proxy container. Apply minimal network changes to your Compose file and verify that services are isolated.
* **Caddy, Traefik, Nginx Proxy Manager**: use that proxy's existing hostname and certificate-management workflow, not a parallel nginx or Caddy instance.

Confirm that the proxy sets `Host`, `X-Forwarded-Proto`, `X-Forwarded-For`, and appropriate trusted-proxy settings; do not blindly trust user-supplied forwarding headers. Ensure public HTTP redirects to HTTPS, and test cookie/session behavior. Do not enable Password Pusher's standalone `TLS_DOMAIN`/443 mapping when an existing proxy handles TLS.

## 6. First-run administration

Visit `https://passprotect.comtek.uk.com` after TLS works. A new database redirects to the first-run administrator setup.

On SSH run:
```bash
cd /opt/comtek-passprotect
docker compose -f deploy/compose.passprotect.yml --env-file deploy/.env.passprotect logs --tail=120 passprotect
```

Obtain the one-time **Boot Code** from the logs, and create an administrator using your Comtek email and a strong **email/password** combination. The boot code is only for first-run setup; public self-registration is disabled by deployment configuration. After first-run, test staff sign-in, then configure additional staff accounts using the admin/user-management facilities available in the application. Do not enable public sign-ups merely to add staff.

**Important:** Password reset/account recovery email features require working SMTP and explicit `PWP__ENABLE_USER_ACCOUNT_EMAILS=true` configuration. These are NOT enabled by this deployment. Record administrator credentials in your company password manager.

## 7. Required acceptance checks

1. Main application at HTTPS displays **Comtek PassProtect**, charcoal Comtek / purple PassProtect and the purple shield mark, no default Password Pusher logo, and a white-first interface.
2. Staff can sign in with email/password; arbitrary public registration is unavailable.
3. Signed-in staff can create a **secret** with 3 views / 7 days as defaults (adjustable within configured limits).
4. In a separate private/incognito browser **without a login**, the recipient can open the generated secret link. Test retrieval step, view exhaustion, expiry, passphrase, and deletion as applicable.
5. In that same unsigned browser, **GET the creator screen and POST a creation attempt**; both should be blocked by authentication. Verify the v1 and v2 JSON create endpoints cannot create as anonymous. JSON retrieval remains possible as designed.
6. Generated URLs start with `https://passprotect.comtek.uk.com`. The form controls and secret value are not present in browser access logs, proxy logs or analytics.
7. Verify the Comtek icon/branding on login, dashboard, receipt and expired views; test mobile display and light mode.
8. Confirm `https://esign.comtek.uk.com` still functions, including creating and signing documents. Confirm existing certificates renew.
9. Confirm the container starts following reboot (do not actually reboot production just to test without a maintenance window).
10. Configure monitored, access-restricted **backups** of the data volume AND the two keys; test recovery offline. Do not store sensitive backups in Git.

## 8. Rollback and ongoing maintenance

If the PassProtect site fails, remove/disable **only** its new reverse-proxy route, then stop **only** the PassProtect service:

```bash
cd /opt/comtek-passprotect
docker compose -f deploy/compose.passprotect.yml --env-file deploy/.env.passprotect stop passprotect
```

Do **not** run `docker compose down -v`, `docker system prune`, or remove shared networks. Roll back new proxy changes after checking syntax; leave Documenso untouched.

On upgrades, back up storage and keys, pin and record the Git commit and image version, update the PassProtect source, then rebuild this stack only. Re-test first-run/session behavior, anonymous retrieval, secrets encryption, and eSign. **Never rotate the master key casually**; it protects stored secrets.

## Security and licensing

This deployment is based on the Apache 2.0-licensed Password Pusher project. Preserve its licence and attribution notices. Branding in the UI is Comtek PassProtect, but the upstream author must remain properly credited. Recipient links are bearer secrets: anyone possessing a live URL can redeem it, subject to expiry and optional passphrase.

This runbook does not assert any production change was made or any functionality was tested on the live host.
