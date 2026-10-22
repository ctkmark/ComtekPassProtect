#!/usr/bin/env bash
# Deploy Comtek PassProtect branding ONLY on ctk-esgn.
# Backs up current image, volume, encryption-key file, and verifies both HTTPS apps.
# Keeps SSH open; never modifies Comtek Sign, its Compose project, or Nginx.
# Usage: bash deploy/apply-branding-ctk-esgn.sh
set -Eeuo pipefail

ROOT="/opt/comtek-passprotect"
BRANCH="feature/comtek-branding-and-ctk-esgn-deployment"
PROJECT="comtek-passprotect"
ENVFILE="deploy/.env.passprotect"
COMPOSE_FILE="deploy/compose.passprotect.yml"
CONTAINER="comtek-passprotect"
VOLUME="comtek-passprotect_passprotect-storage"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="/var/backups/comtek-passprotect/branding-$STAMP"
ROLLBACK_TAG="comtek/passprotect:rollback-$STAMP"
RECREATE_STARTED=0
DONE=0

compose() { sudo docker compose -p "$PROJECT" -f "$COMPOSE_FILE" --env-file "$ENVFILE" "$@"; }

echo "=== COMTEK PASSPROTECT - BRANDING DEPLOYMENT ==="
if [ "$(hostname)" != "ctk-esgn" ]; then echo "ERROR: Wrong server."; exit 1; fi
cd "$ROOT"
if [ "$(git branch --show-current)" != "$BRANCH" ]; then echo "ERROR: Incorrect Git branch."; exit 1; fi
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "ERROR: Tracked repository files changed locally."; exit 1
fi
if [ ! -s "$ENVFILE" ] || [ "$(stat -c %a "$ENVFILE")" != "600" ]; then
  echo "ERROR: Private environment file missing or has unsafe permissions."; exit 1
fi
sudo -v
compose config --quiet
if ! sudo docker inspect "$CONTAINER" >/dev/null 2>&1; then echo "ERROR: PassProtect container missing."; exit 1; fi
CURRENT_VOLUME="$(sudo docker inspect -f '{{range .Mounts}}{{if eq .Destination "/opt/PasswordPusher/storage"}}{{.Name}}{{end}}{{end}}' "$CONTAINER")"
if [ "$CURRENT_VOLUME" != "$VOLUME" ]; then echo "ERROR: Volume mismatch."; exit 1; fi
OWNER="$(sudo docker volume inspect -f '{{index .Labels "com.docker.compose.project"}}' "$VOLUME")"
if [ "$OWNER" != "$PROJECT" ]; then echo "ERROR: Volume project mismatch."; exit 1; fi
MOUNT="$(sudo docker volume inspect -f '{{.Mountpoint}}' "$VOLUME")"
if [ -z "$MOUNT" ] || [ "$MOUNT" = "/" ] || [ "$MOUNT" = "/var/lib/docker" ]; then
  echo "ERROR: Unsafe mountpoint."; exit 1
fi
OLD_IMAGE="$(sudo docker image inspect -f '{{.Id}}' comtek/passprotect:local)"
echo "Previous image retained: $OLD_IMAGE"

recover() {
  code=$?
  trap - EXIT
  if [ "$code" -ne 0 ] && [ "$RECREATE_STARTED" -eq 1 ] && [ "$DONE" -eq 0 ]; then
    echo "ERROR: Attempting to restore previous PassProtect image and start service."
    sudo docker image tag "$ROLLBACK_TAG" comtek/passprotect:local || true
    compose up -d --no-deps --no-build --force-recreate passprotect || true
  fi
  if [ "$code" -ne 0 ]; then echo "Backup (if created): $BACKUP"; fi
  exit "$code"
}
trap recover EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "=== PRESERVING OLD IMAGE ==="
sudo docker image tag "$OLD_IMAGE" "$ROLLBACK_TAG"
echo "=== BUILDING NEW BRANDING (OLD APP REMAINS RUNNING) ==="
compose build passprotect
echo "=== BACKUP OF PASSPROTECT DATA ==="
sudo install -d -m 0700 -o root -g root "$BACKUP"
echo "=== STOPPING ONLY PASSPROTECT FOR CONSISTENT BACKUP ==="
compose stop passprotect
RECREATE_STARTED=1
sudo tar -C "$MOUNT" -czf "$BACKUP/storage-before.tgz" .
sudo cp -p "$ENVFILE" "$BACKUP/.env.passprotect"
sudo chmod 0600 "$BACKUP/storage-before.tgz" "$BACKUP/.env.passprotect"
sudo test -s "$BACKUP/storage-before.tgz"
sudo test -s "$BACKUP/.env.passprotect"
echo "=== RECREATING ONLY PASSPROTECT CONTAINER ==="
compose up -d --no-deps --no-build --force-recreate passprotect

echo "=== WAITING FOR PASSProtect HEALTH ==="
HEALTHY=0
for attempt in $(seq 1 40); do
  if curl --noproxy '*' --fail --silent --max-time 5 -H 'Host: passprotect.comtek.uk.com' \
      http://127.0.0.1:15100/up >/dev/null 2>&1; then
    STATE="$(sudo docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' "$CONTAINER")"
    if [ "$STATE" = "healthy" ]; then HEALTHY=1; break; fi
  fi
  sleep 3
done
if [ "$HEALTHY" -ne 1 ]; then echo "ERROR: PassProtect health check failed."; exit 1; fi

PASSPROTECT_URL='https://passprotect.comtek.uk.com'
curl --fail --silent --show-error --max-time 15 --noproxy '*' \
  --resolve 'passprotect.comtek.uk.com:443:127.0.0.1' "$PASSPROTECT_URL/up" >/dev/null

ESIGN_STATUS="$(curl --silent --show-error --max-time 15 --noproxy '*' \
  --resolve 'esign.comtek.uk.com:443:127.0.0.1' \
  --output /dev/null --write-out '%{http_code}' 'https://esign.comtek.uk.com/')"
case "$ESIGN_STATUS" in
  2??|3??) echo "PASS: Comtek Sign still responds (HTTP $ESIGN_STATUS)" ;;
  *) echo "ERROR: Comtek Sign returned HTTP $ESIGN_STATUS"; exit 1 ;;
esac
DONE=1
compose ps
echo "SUCCESS: Branded PassProtect is healthy and Comtek Sign still responds."
echo "Rollback image: $ROLLBACK_TAG"
echo "Root-only backup: $BACKUP"
echo "Now test login, admin, recipient, 422 page and browser/PWA icons."
echo "NOTE: this branding patch does not suppress or bypass Rails CSRF checks."
