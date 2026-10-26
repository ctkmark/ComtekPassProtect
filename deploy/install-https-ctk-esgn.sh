#!/usr/bin/env bash
# Comtek PassProtect: isolated Nginx + Certbot webroot setup on ctk-esgn.
# Run with: bash deploy/install-https-ctk-esgn.sh
# Does not stop or modify Documenso; rolls back this new Nginx site on failure.
set -Eeuo pipefail

DOMAIN="passprotect.comtek.uk.com"
SITE="/etc/nginx/sites-available/$DOMAIN"
LINK="/etc/nginx/sites-enabled/$DOMAIN"
WEBROOT="/var/www/comtek-passprotect-acme"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="/var/backups/comtek-hosted-apps/nginx_before_passprotect_$STAMP"
CREATED=0
COMPLETE=0
MARKER_PATH=""
PROBE_HEADERS=""
PROBE_BODY=""

cleanup() {
    rc=$?
    set +e
    if [ -n "$MARKER_PATH" ]; then sudo rm -f "$MARKER_PATH"; fi
    if [ -n "$PROBE_HEADERS" ]; then rm -f "$PROBE_HEADERS"; fi
    if [ -n "$PROBE_BODY" ]; then rm -f "$PROBE_BODY"; fi
    if [ "$CREATED" -eq 1 ] && [ "$COMPLETE" -ne 1 ]; then
        echo "WARNING: PassProtect HTTPS setup incomplete (exit $rc)."
        echo "Reverting ONLY the new PassProtect Nginx site."
        sudo rm -f "$LINK" "$SITE"
        if sudo nginx -t; then
            sudo systemctl reload nginx
        else
            echo "WARNING: Nginx syntax failed after site removal; backup: $BACKUP"
        fi
    fi
    if [ "$rc" -ne 0 ]; then
        echo "Nginx backup (if created): $BACKUP"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "=== COMTEK PASSPROTECT: HTTPS INSTALL ==="
sudo -v

echo "=== PRE-FLIGHT ==="
sudo nginx -t
sudo systemctl is-active --quiet nginx
command -v certbot >/dev/null
if sudo test -e "$SITE" || sudo test -e "$LINK" || sudo test -L "$LINK"; then
    echo "ERROR: PassProtect Nginx site already exists. Stopping without changes."
    exit 1
fi
PIP="$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}')"
EIP="$(getent ahostsv4 esign.comtek.uk.com | awk 'NR==1{print $1}')"
if [ -z "$PIP" ] || [ "$PIP" != "$EIP" ]; then
    echo "ERROR: PassProtect DNS A record does not match the existing eSign IPv4."
    exit 1
fi
if ! curl --noproxy '*' -fsS -H "Host: $DOMAIN" --max-time 10 http://127.0.0.1:15100/up >/dev/null; then
    echo "ERROR: PassProtect is not responding at 127.0.0.1:15100."
    exit 1
fi

echo "=== BACKING UP NGINX CONFIGURATION ==="
sudo install -d -m 0700 -o root -g root "$BACKUP"
sudo tar -C /etc -czf "$BACKUP/nginx-before.tar.gz" nginx
printf 'Backup: %s\n' "$BACKUP/nginx-before.tar.gz"

echo "=== INSTALLING TEMPORARY HTTP ACME SITE ==="
sudo install -d -m 0755 "$WEBROOT/.well-known/acme-challenge"
sudo tee "$SITE" >/dev/null <<'NGINX_HTTP'
server {
    listen 80;
    listen [::]:80;
    server_name passprotect.comtek.uk.com;
    access_log off;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/comtek-passprotect-acme;
        default_type text/plain;
        try_files $uri =404;
    }

    # Do not serve the application in cleartext during certificate issuance.
    location / { return 404; }
}
NGINX_HTTP
CREATED=1
sudo ln -s "$SITE" "$LINK"
sudo nginx -t
sudo systemctl reload nginx

echo "=== TESTING ACME WEBROOT ROUTE ==="
MARKER="comtek-acme-check-$(date +%s)-$"
MARKER_PATH="$WEBROOT/.well-known/acme-challenge/$MARKER"
printf '%s' "$MARKER" | sudo tee "$MARKER_PATH" >/dev/null
PROBE_HEADERS="$(mktemp)"
PROBE_BODY="$(mktemp)"
CHALLENGE_URL="http://$DOMAIN/.well-known/acme-challenge/$MARKER"
PROBE_OK=0
PROBE_STATUS="not-started"

# systemctl reload returns before all Nginx workers necessarily serve the new
# virtual host. On the first request the old default vhost can still return 301.
# Retry a strict HTTP 200 + exact-body check; never accept redirects here.
for attempt in $(seq 1 20); do
    if PROBE_STATUS="$(curl --noproxy '*' --silent --show-error --max-time 5 \
        --resolve "$DOMAIN:80:127.0.0.1" \
        -D "$PROBE_HEADERS" -o "$PROBE_BODY" -w '%{http_code}' \
        "$CHALLENGE_URL" 2>/dev/null)"; then
        if [ "$PROBE_STATUS" = "200" ] && [ "$(cat "$PROBE_BODY")" = "$MARKER" ]; then
            PROBE_OK=1
            break
        fi
    else
        PROBE_STATUS="connection-error"
    fi
    sleep 1
done

if [ "$PROBE_OK" -ne 1 ]; then
    echo "ERROR: ACME challenge did not serve the expected marker after 20 retries."
    echo "Last HTTP status: $PROBE_STATUS"
    echo "Last HTTP response status / redirect (safe to share):"
    grep -iE '^(HTTP/|location:|server:)' "$PROBE_HEADERS" | tr -d '\r' || true
    echo "Possible causes: Nginx configuration not yet activated, wrong HTTP server block,"
    echo "or a conflicting port 80 hostname route. Certbot has NOT been run."
    exit 1
fi
sudo rm -f "$MARKER_PATH"
MARKER_PATH=""
rm -f "$PROBE_HEADERS" "$PROBE_BODY"
PROBE_HEADERS=""
PROBE_BODY=""
echo "PASS: ACME test marker served correctly over HTTP."

echo "=== OBTAINING A SEPARATE LET'S ENCRYPT CERTIFICATE ==="
sudo certbot certonly --webroot --webroot-path "$WEBROOT" \
    --cert-name "$DOMAIN" -d "$DOMAIN" \
    --non-interactive --agree-tos --keep-until-expiring
sudo test -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
sudo test -s "/etc/letsencrypt/live/$DOMAIN/privkey.pem"

echo "=== INSTALLING PASSPROTECT HTTPS SITE ==="
sudo tee "$SITE" >/dev/null <<'NGINX_HTTPS'
server {
    listen 80;
    listen [::]:80;
    server_name passprotect.comtek.uk.com;
    access_log off;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/comtek-passprotect-acme;
        default_type text/plain;
        try_files $uri =404;
    }

    location / { return 301 https://$host$request_uri; }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name passprotect.comtek.uk.com;

    ssl_certificate /etc/letsencrypt/live/passprotect.comtek.uk.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/passprotect.comtek.uk.com/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    # URLs contain bearer tokens: don't save those paths in access logs.
    access_log off;
    client_max_body_size 2m;
    # Avoid Origin: null on same-origin HTML form POSTs (Rails rejects this).
    # Referrers carry only the HTTPS origin, never secret-share URL paths.
    add_header Referrer-Policy "strict-origin" always;
    add_header X-Content-Type-Options "nosniff" always;

    location / {
        proxy_pass http://127.0.0.1:15100;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port 443;
        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
    }
}
NGINX_HTTPS
sudo nginx -t
sudo systemctl reload nginx

echo "=== VERIFYING BOTH HOSTNAMES ==="
HTTPS_OK=0
for attempt in $(seq 1 20); do
    if curl --noproxy '*' --silent --show-error --fail --max-time 5 \
        --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/up" >/dev/null 2>&1; then
        HTTPS_OK=1
        break
    fi
    sleep 1
done
if [ "$HTTPS_OK" -ne 1 ]; then
    echo "ERROR: HTTPS verification failed after Nginx reload."
    echo "Check Nginx errors, DNS, and the PassProtect certificate (do not use curl -k)."
    exit 1
fi
echo "PASS: Comtek PassProtect HTTPS /up"
ESIGN_STATUS="$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' \
    --max-time 15 --resolve 'esign.comtek.uk.com:443:127.0.0.1' \
    'https://esign.comtek.uk.com/')"
case "$ESIGN_STATUS" in
    2??|3??) echo "PASS: Comtek Sign still responds (HTTP $ESIGN_STATUS)" ;;
    *) echo "ERROR: Comtek Sign unexpected HTTP status $ESIGN_STATUS"; exit 1 ;;
esac

echo "=== CONFIGURING RENEWAL RELOAD HOOK ==="
HOOK="/etc/letsencrypt/renewal-hooks/deploy/comtek-passprotect-nginx-reload.sh"
sudo install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
if sudo test -e "$HOOK"; then
    echo "Existing renewal hook not overwritten: $HOOK"
else
    sudo tee "$HOOK" >/dev/null <<'RENEWAL_HOOK'
#!/bin/sh
set -eu
# Reload Nginx only when the PassProtect certificate is renewed.
if [ "${RENEWED_LINEAGE:-}" = "/etc/letsencrypt/live/passprotect.comtek.uk.com" ]; then
    /usr/sbin/nginx -t
    /usr/bin/systemctl reload nginx
fi
RENEWAL_HOOK
    sudo chmod 755 "$HOOK"
fi

COMPLETE=1
printf '\nSUCCESS: https://%s\n' "$DOMAIN"
printf 'Rollback archive: %s/nginx-before.tar.gz\n' "$BACKUP"
printf '\nNEXT: Test Certbot renewal separately: sudo certbot renew --dry-run --cert-name passprotect.comtek.uk.com\n'
