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
# Until the PR is merged, check out the Comtek branded deployment branch.
git switch --track origin/feature/comtek-branding-and-ctk-esgn-deployment
# Keep this file private and do not print keys or share them in chat.
umask 077
if [ ! -e deploy/.env.passprotect ]; then
  {
    printf 'PASS_PROTECT_SECRET_KEY_BASE=%s\n' "$(openssl rand -hex 64)"
    printf 'PASS_PROTECT_MASTER_KEY=%s\n' "$(openssl rand -hex 32)"
  } > deploy/.env.passprotect
  chmod 600 deploy/.env.passprotect
fi
```

The commands create both encryption keys directly inside the protected `deploy/.env.passprotect` file; they must never be printed into the shell transcript or chat. If you have previously displayed a key, treat it as exposed and generate a **new** key before using PassProtect with real secrets. Securely back up the environment file separately from the database. These keys must persist across updates.

On a host where the latest branded changes are on a PR branch, do not use master until that PR has been reviewed, tested and merged.

## 4. Run PassProtect separately

Run **only after** inspection confirms loopback port 15100 is free and the chosen proxy design supports this binding:

```bash
cd /opt/comtek-passprotect
sudo docker compose -p comtek-passprotect -f deploy/compose.passprotect.yml --env-file deploy/.env.passprotect config --quiet
sudo docker compose -p comtek-passprotect -f deploy/compose.passprotect.yml --env-file deploy/.env.passprotect up -d --build
sudo docker compose -p comtek-passprotect -f deploy/compose.passprotect.yml --env-file deploy/.env.passprotect ps
curl -fsS -H 'Host: passprotect.comtek.uk.com' http://127.0.0.1:15100/up >/dev/null && echo 'PassProtect healthy'
```

Both the container and host health checks send `Host: passprotect.comtek.uk.com`. A plain `curl http://127.0.0.1:15100/up` returns a **403 Blocked host** by design; do not relax `PWP__ALLOWED_HOSTS` to fix this. The container listens on internal port **5100**, exposed on host **127.0.0.1:15100**. It must not claim host 80 or 443, which belong to the existing reverse proxy. Persistent SQLite data and uploads live in a named Docker volume mounted on `/opt/PasswordPusher/storage` (not `/opt/PasswordPusher/db` — the latter hides migrations).

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
sudo docker compose -p comtek-passprotect -f deploy/compose.passprotect.yml --env-file deploy/.env.passprotect logs --tail=120 passprotect
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
sudo docker compose -p comtek-passprotect -f deploy/compose.passprotect.yml --env-file deploy/.env.passprotect stop passprotect
```

Do **not** run `docker compose down -v`, `docker system prune`, or remove shared networks. Roll back new proxy changes after checking syntax; leave Documenso untouched.

On upgrades, back up storage and keys, pin and record the Git commit and image version, update the PassProtect source, then rebuild this stack only. Re-test first-run/session behavior, anonymous retrieval, secrets encryption, and eSign. **Never rotate the master key casually**; it protects stored secrets.

## Security and licensing

This deployment is based on the Apache 2.0-licensed Password Pusher project. Preserve its licence and attribution notices. Branding in the UI is Comtek PassProtect, but the upstream author must remain properly credited. Recipient links are bearer secrets: anyone possessing a live URL can redeem it, subject to expiry and optional passphrase.

This runbook does not assert any production change was made or any functionality was tested on the live host.

---

## Verified ctk-esgn HTTPS setup (after healthy local container)

This host has Nginx installed directly, an existing `esign.comtek.uk.com` virtual host, and a separate PassProtect container listening on `127.0.0.1:15100`. The tested **local** Docker health check returns healthy. HTTPS must use a separate site and certificate; do not edit the existing eSign vhost.

The repository includes a **guarded, server-specific** installer, `deploy/install-https-ctk-esgn.sh`. It:
- checks DNS and the local PassProtect health endpoint;
- creates a root-only, timestamped archive of the existing Nginx configuration;
- creates a temporary HTTP-01 challenge route, preserving the eSign site;
- obtains a separate Let's Encrypt certificate using Certbot's webroot authenticator;
- installs HTTPS reverse proxying to `127.0.0.1:15100`, with access logging disabled for bearer secret URLs and a strict-origin response policy (privacy-safe and compatible with Rails CSRF origin validation);
- validates both new PassProtect HTTPS and existing eSign HTTPS;
- adds a dedicated certificate-renewal Nginx reload hook;
- removes **only the newly created** Nginx site and reloads the original configuration on error.

Run from the host's SSH session (do not run with `sudo bash`; the script uses `sudo` only for privileged operations):

```bash
cd /opt/comtek-passprotect
git pull --ff-only
bash -n deploy/install-https-ctk-esgn.sh
bash deploy/install-https-ctk-esgn.sh
```

**The installer intentionally stops if the PassProtect Nginx site already exists.** Inspect it rather than overwriting any existing configuration. Keep the printed backup location. The script cannot guarantee that upstream networking permits ACME validation, so a certificate challenge may fail and cause the new Nginx site to be rolled back automatically; it does not stop Documenso.

Once successful, verify the external URL in a browser and test certificate renewal (a dry-run does not replace the live certificate):

```bash
sudo certbot certificates
sudo certbot renew --dry-run --cert-name passprotect.comtek.uk.com
```

Create the initial administrator via the first-run page, taking the **boot code from server logs only**. Never paste boot codes, app secrets, or real password-share URLs into chat or tickets.

---

## Staff accounts, logout and authenticator setup

This Comtek deployment disables public self-registration. After this patch, an
existing administrator can visit Administration Center > Staff Accounts, and
create a Standard user or Administrator using a unique initial password.
These are admin-provisioned accounts; no SMTP invite email is sent.
Share the password securely and have the recipient immediately change it in
Account > Edit Login Details. Never send passwords in GitHub or an SSH log.

Microsoft Authenticator works with the built-in TOTP QR enrollment:
Account > Edit Login Details > Set up two-factor authentication >
Save backup codes > Continue to verify > Enter the six-digit code.
This is not Microsoft Entra SSO; that is a separate Pro-edition capability.

The observed failures included 13 InvalidAuthenticityToken exceptions.
The patch removes an extra custom cookie/session reset on logout,
uses full-page navigation for logout and authenticator enrollment,
and marks authentication and 2FA response pages as no-store.
CSRF protection stays enabled. These are targeted mitigations for
potential stale-token flows; confirm them with browser tests.

### Deployment

Run from the SSH session on ctk-esgn:

    cd /opt/comtek-passprotect
    git pull --ff-only
    bash -n deploy/apply-branding-ctk-esgn.sh
    bash deploy/apply-branding-ctk-esgn.sh

The script backs up the PassProtect volume and key file, preserves the prior
image for rollback, and verifies both PassProtect and Comtek Sign.
Do not run a factory reset for this upgrade.

### Acceptance test

1. Existing admin: sign in, log out, sign in again without HTTP 422.
2. Enrol Microsoft Authenticator, use a new six-digit code, save backup
   codes, log out and verify that MFA is required next time.
3. As admin create one Standard user and one Administrator; use unique
   initial passwords. Verify their respective access restrictions.
4. Confirm standard user cannot create staff or reach admin pages.
5. Confirm anonymous recipients can still open test secret links.
6. Confirm Comtek Sign continues to work with document signing.
7. Inspect only sanitized error categories if CSRF failures continue.

Testing note: the new integration and browser regression tests are committed
but have not been run against the live host. Do not declare the 422 resolved
until browser checks pass.

---

## ctk-esgn root-cause fix for HTTP 422: Referrer-Policy

Production logs showed Rails `ActionController::InvalidAuthenticityToken` with
`The browser returned a 'null' origin` on login and authenticator POSTs.
The original PassProtect HTTPS vhost set `Referrer-Policy: no-referrer`.
That policy makes browsers emit `Origin: null` for normal HTML form POSTs.
Rails rejects that origin before a valid CSRF token can be considered.

Use `Referrer-Policy: strict-origin` instead. It exposes only
`https://passprotect.comtek.uk.com` as referrer when permitted, not
password-sharing URL paths or secret tokens. CSRF origin checking
and CSRF authenticity tokens remain enabled. Never fix this by disabling
`forgery_protection_origin_check` or request forgery protection.

On ctk-esgn, after the Docker image deployment completes, apply the
dedicated Nginx-only patch (it backs up and can restore the vhost):

    cd /opt/comtek-passprotect
    git pull --ff-only
    bash -n deploy/fix-422-referrer-policy-ctk-esgn.sh
    bash deploy/fix-422-referrer-policy-ctk-esgn.sh

The script validates the PassProtect site symlink, replaces exactly the
expected policy, verifies the served HTTPS headers and the health of both
Comtek PassProtect and Comtek Sign, and restores the old site on failure.
It does not rebuild any image, rotate keys, or change the eSign site.

After success, open a completely fresh PassProtect sign-in page in a new
private tab. Verify: login, logout/login, authenticator enrollment and
staff-account creation. A page loaded before the header correction still
has its old policy and must be reloaded.

Technical reference: MDN Referrer-Policy > Effect on the Origin header;
Rails 8.1 ActionController::RequestForgeryProtection#valid_request_origin?.
