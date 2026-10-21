#!/usr/bin/env bash
# Comtek PassProtect: read-only, secrets-safe diagnosis for 422 during login.
# Never uploads data, submits credentials, modifies accounts, or logs CSRF tokens.
# Run: bash deploy/diagnose-login-422-ctk-esgn.sh
set -Eeuo pipefail

DOMAIN="passprotect.comtek.uk.com"
ROOT="/opt/comtek-passprotect"
TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

echo "=== COMTEK PASSPROTECT: LOGIN 422 DIAGNOSTIC ==="
echo "=== CONTAINER STATUS ==="
sudo docker ps --filter name=comtek-passprotect --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
echo

echo "=== HTTPS SIGN-IN PAGE (NO CREDENTIALS SUBMITTED) ==="
# Use the existing certificate and vhost; do not bypass certificate verification.
LOGIN_URL="https://$DOMAIN/users/sign_in"
if ! STATUS="$(curl --silent --show-error --location --max-redirs 3 --max-time 20 \
  --noproxy '*' --resolve "$DOMAIN:443:127.0.0.1" \
  --cookie-jar "$TMP/cookies" --cookie "$TMP/cookies" \
  --dump-header "$TMP/headers" --output "$TMP/login.html" \
  --write-out '%{http_code}' "$LOGIN_URL")"; then
  echo "ERROR: Unable to fetch the sign-in page over trusted HTTPS."
  exit 1
fi
echo "Login GET HTTP status: $STATUS"
if grep -Eq 'name="authenticity_token"|name=.authenticity_token.' "$TMP/login.html"; then
  echo "Hidden CSRF form field: present"
else
  echo "Hidden CSRF form field: MISSING"
fi
if grep -Eq 'name="csrf-token"|name=.csrf-token.' "$TMP/login.html"; then
  echo "CSRF meta tag: present"
else
  echo "CSRF meta tag: missing"
fi
if grep -q '_PasswordPusher_session' "$TMP/cookies" 2>/dev/null; then
  echo "Session cookie accepted by curl: yes"
else
  echo "Session cookie accepted by curl: no"
fi
if grep -qi '^set-cookie:.*_PasswordPusher_session=' "$TMP/headers"; then
  echo "Session Set-Cookie header: present"
else
  echo "Session Set-Cookie header: missing"
fi
if grep -qi '^set-cookie:.*_PasswordPusher_session=.*secure' "$TMP/headers"; then
  echo "Session cookie Secure flag: present"
else
  echo "Session cookie Secure flag: not confirmed"
fi
if grep -qi '^set-cookie:.*_PasswordPusher_session=.*samesite=strict' "$TMP/headers"; then
  echo "Session cookie SameSite: Strict"
fi
echo

echo "=== RECENT SERVER ERROR COUNTS (NO RAW REQUEST LOGS) ==="
# Only counts are printed, never email addresses, request URIs, cookies, tokens
# or secret-link payloads. Messages usually name the exception class.
sudo docker logs --since 90m comtek-passprotect 2>&1 | awk '
  /ActionController::InvalidAuthenticityToken/ {invalid_csrf++}
  /Can.t verify CSRF token authenticity|Invalid CSRF token|CSRF token authenticity/ {csrf_log++}
  /Origin header.*(did not match|does not match|mismatch)/ {origin++}
  /InvalidCrossOriginRequest/ {cross_origin++}
  /CookieOverflow|InvalidMessage|MessageVerifier/ {cookie++}
  /Completed 422|422 Unprocessable|status=422/ {http422++}
  END {
    printf "InvalidAuthenticityToken occurrences: %d\n", invalid_csrf+0
    printf "CSRF verification messages: %d\n", csrf_log+0
    printf "Origin-mismatch messages: %d\n", origin+0
    printf "InvalidCrossOriginRequest occurrences: %d\n", cross_origin+0
    printf "Cookie / message verification error occurrences: %d\n", cookie+0
    printf "HTTP 422 completion messages: %d\n", http422+0
  }
'
echo

echo "=== NGINX AND CERTIFICATE CHECK ==="
sudo nginx -t
curl --silent --show-error --fail --max-time 15 \
  --noproxy '*' --resolve "$DOMAIN:443:127.0.0.1" \
  "https://$DOMAIN/up" >/dev/null && echo "PassProtect HTTPS health: OK"
SIGN_STATUS="$(curl --silent --show-error --max-time 15 \
  --noproxy '*' --resolve 'esign.comtek.uk.com:443:127.0.0.1' \
  --output /dev/null --write-out '%{http_code}' 'https://esign.comtek.uk.com/')"
echo "Existing Comtek Sign HTTP status: $SIGN_STATUS"
echo
echo "=== FINISHED: no configuration or account changes made ==="
