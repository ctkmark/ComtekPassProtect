#!/usr/bin/env bash
# Fix PassProtect's Referrer-Policy -> Origin:null -> Rails HTTP 422 issue.
# Only modifies the already-installed PASSProtect vhost; leaves eSign alone.
# Keep your SSH session open: bash deploy/fix-422-referrer-policy-ctk-esgn.sh
set -Eeuo pipefail

DOMAIN="passprotect.comtek.uk.com"
SITE="/etc/nginx/sites-available/$DOMAIN"
ENABLED="/etc/nginx/sites-enabled/$DOMAIN"
EXPECTED_OLD='add_header Referrer-Policy "no-referrer" always;'
EXPECTED_NEW='add_header Referrer-Policy "strict-origin" always;'
BACKUP="/var/backups/comtek-hosted-apps/passprotect-referrer-$(date +%Y%m%d_%H%M%S)"
TEMP="$(mktemp -d)"
CHANGED=0
DONE=0

recover() {
  code=$?
  trap - EXIT
  if [ "$code" -ne 0 ] && [ "$CHANGED" -eq 1 ] && [ "$DONE" -eq 0 ]; then
    echo "ERROR: PassProtect Nginx policy verification failed; restoring the original site."
    sudo cp -p "$BACKUP/passprotect-site.before" "$SITE" || true
    if sudo nginx -t; then
      sudo systemctl reload nginx || true
    else
      echo "WARNING: Nginx syntax invalid after restore; inspect manually."
    fi
  fi
  rm -rf "$TEMP"
  if [ "$code" -ne 0 ]; then
    echo "Backup directory (if created): $BACKUP"
  fi
  exit "$code"
}
trap recover EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "=== COMTEK PASSPROTECT - FIX NULL ORIGIN / LOGIN 422 ==="
if [ "$(hostname)" != "ctk-esgn" ]; then
  echo "ERROR: This patch is only approved for ctk-esgn."
  exit 1
fi
sudo -v
sudo nginx -t
sudo systemctl is-active --quiet nginx

if ! sudo test -f "$SITE" || ! sudo test -L "$ENABLED"; then
  echo "ERROR: Expected dedicated PassProtect Nginx site is missing."
  exit 1
fi
LINK_TARGET="$(sudo readlink -f "$ENABLED")"
if [ "$LINK_TARGET" != "$SITE" ]; then
  echo "ERROR: PassProtect site-enabled symlink does not point to expected file."
  exit 1
fi

OLD_COUNT="$(sudo grep -Fc "$EXPECTED_OLD" "$SITE" || true)"
NEW_COUNT="$(sudo grep -Fc "$EXPECTED_NEW" "$SITE" || true)"
if [ "$OLD_COUNT" = "0" ] && [ "$NEW_COUNT" = "1" ]; then
  echo "PassProtect already configured with strict-origin. Verifying live header."
elif [ "$OLD_COUNT" = "1" ] && [ "$NEW_COUNT" = "0" ]; then
  echo "=== SAVING ROLLBACK COPY OF PASSPROTECT VHOST ==="
  sudo install -d -m 0700 -o root -g root "$BACKUP"
  sudo cp -p "$SITE" "$BACKUP/passprotect-site.before"
  sudo chmod 0600 "$BACKUP/passprotect-site.before"
  sudo test -s "$BACKUP/passprotect-site.before"
  CHANGED=1

  echo "=== CHANGING ONLY THE PASSPROTECT REFERRER POLICY ==="
  sudo sed -i 's/add_header Referrer-Policy "no-referrer" always;/add_header Referrer-Policy "strict-origin" always;/' "$SITE"
  if [ "$(sudo grep -Fc "$EXPECTED_NEW" "$SITE" || true)" != "1" ]; then
    echo "ERROR: Policy substitution did not produce exactly one target header."
    exit 1
  fi

  sudo nginx -t
  sudo systemctl reload nginx
else
  echo "ERROR: Unexpected policy configuration; refusing to alter Nginx."
  echo "Count of old policy lines: $OLD_COUNT"
  echo "Count of new policy lines: $NEW_COUNT"
  exit 1
fi

echo "=== VERIFYING HEADER OVER LOCAL TLS VHOST ==="
OK=0
for attempt in $(seq 1 15); do
  if curl --noproxy '*' --silent --show-error --max-time 6 \
    --resolve "$DOMAIN:443:127.0.0.1" \
    --dump-header "$TEMP/headers" --output /dev/null "https://$DOMAIN/users/sign_in" >/dev/null 2>&1; then
    if grep -Eiq '^referrer-policy:[[:space:]]*strict-origin[[:space:]]*\r?$' "$TEMP/headers" \
      && ! grep -Eiq '^referrer-policy:[[:space:]]*no-referrer' "$TEMP/headers"; then
      OK=1
      break
    fi
  fi
  sleep 1
done
if [ "$OK" -ne 1 ]; then
  echo "ERROR: Live PassProtect response does not have the expected single strict-origin policy."
  echo "Referrer-Policy header names/values only:"
  grep -i '^referrer-policy:' "$TEMP/headers" 2>/dev/null | tr -d '\r' || true
  exit 1
fi
echo "PASS: PassProtect Referrer-Policy: strict-origin"

echo "=== VERIFYING PASSPROTECT AND COMTEK SIGN ==="
curl --noproxy '*' --fail --silent --show-error --max-time 15 \
  --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/up" >/dev/null
echo "PASS: Comtek PassProtect HTTPS health"
SIGN_STATUS="$(curl --noproxy '*' --silent --show-error --max-time 15 \
  --resolve "esign.comtek.uk.com:443:127.0.0.1" \
  -o /dev/null -w '%{http_code}' 'https://esign.comtek.uk.com/')"
case "$SIGN_STATUS" in
  2??|3??) echo "PASS: Comtek Sign still responds (HTTP $SIGN_STATUS)" ;;
  *) echo "ERROR: Comtek Sign unexpected HTTP $SIGN_STATUS"; exit 1 ;;
esac

DONE=1
echo "SUCCESS: PassProtect Nginx header corrected without rebuilding Docker."
if [ "$CHANGED" = "1" ]; then echo "Rollback copy: $BACKUP/passprotect-site.before"; fi
echo "Reload https://$DOMAIN/users/sign_in in a fresh private window, then test login/logout and TOTP."
