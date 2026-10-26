#!/usr/bin/env bash
# Comtek PassProtect ONLY — guarded first-run reset on ctk-esgn.
# WARNING: deletes all app records/secrets in the dedicated application volume.
# Creates root-only restore backup; does not touch Documenso or Nginx.
# Usage: bash deploy/reset-passprotect-first-run-ctk-esgn.sh --reset
set -Eeuo pipefail

ROOT="/opt/comtek-passprotect"
COMPOSE_PATH="deploy/compose.passprotect.yml"
ENV_PATH="deploy/.env.passprotect"
PROJECT="comtek-passprotect"
CONTAINER="comtek-passprotect"
EXPECTED_VOLUME="comtek-passprotect_passprotect-storage"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="/var/backups/comtek-passprotect/reset-$STAMP"
BACKED_UP=0
RESET_STARTED=0
RESET_DONE=0

compose() { sudo docker compose -p "$PROJECT" -f "$COMPOSE_PATH" --env-file "$ENV_PATH" "$@"; }

echo "=== COMTEK PASSPROTECT - FIRST-RUN RESET ==="
echo "WARNING: all PassProtect users, pushes and application records will be deleted."
echo "Documenso and the PassProtect encryption key file stay untouched."
if [ "$#" -ne 1 ] || [ "$1" != "--reset" ]; then
  echo "No changes made. To reset PassProtect, run with --reset."
  exit 2
fi
if [ "$(hostname)" != "ctk-esgn" ]; then
  echo "ERROR: This script is authorised only for ctk-esgn."
  exit 1
fi
cd "$ROOT"
if [ ! -s "$ENV_PATH" ] || [ "$(stat -c %a "$ENV_PATH")" != "600" ]; then
  echo "ERROR: Private PassProtect environment file absent or permissions not 600."
  exit 1
fi
sudo -v
compose config --quiet

VOLUME="$(sudo docker inspect -f '{{range .Mounts}}{{if eq .Destination "/opt/PasswordPusher/storage"}}{{.Name}}{{end}}{{end}}' "$CONTAINER")"
if [ "$VOLUME" != "$EXPECTED_VOLUME" ]; then
  echo "ERROR: Wrong PassProtect volume ($VOLUME). No changes."
  exit 1
fi
OWNER="$(sudo docker volume inspect -f '{{index .Labels "com.docker.compose.project"}}' "$VOLUME")"
if [ "$OWNER" != "$PROJECT" ]; then
  echo "ERROR: Volume ownership label mismatch ($OWNER). No changes."
  exit 1
fi
MOUNT="$(sudo docker volume inspect -f '{{.Mountpoint}}' "$VOLUME")"
if [ -z "$MOUNT" ] || [ "$MOUNT" = "/" ] || [ "$MOUNT" = "/var/lib/docker" ] || [ "$MOUNT" = "/var/lib/docker/volumes" ]; then
  echo "ERROR: Invalid mount path. No changes."
  exit 1
fi
if ! sudo test -d "$MOUNT"; then
  echo "ERROR: Volume mountpoint missing. No changes."
  exit 1
fi
echo "Verified application-only storage: $VOLUME"

recover() {
  rc=$?
  trap - EXIT
  if [ "$rc" -ne 0 ] && [ "$RESET_STARTED" -eq 1 ] && [ "$BACKED_UP" -eq 1 ] && [ "$RESET_DONE" -eq 0 ]; then
    echo "ERROR: Reset failed; attempting restoration of PassProtect-only backup."
    compose stop passprotect >/dev/null 2>&1 || true
    if sudo test -d "$MOUNT"; then
      sudo find "$MOUNT" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + || true
      sudo tar -C "$MOUNT" -xzf "$BACKUP/storage-before.tgz" || true
    fi
    compose up -d --no-build --no-deps passprotect || true
  fi
  if [ "$rc" -ne 0 ]; then echo "Root-only backup directory: $BACKUP"; fi
  exit "$rc"
}
trap recover EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

sudo install -d -m 0700 -o root -g root "$BACKUP"
echo "=== STOPPING PASSPROTECT ONLY ==="
compose stop passprotect
echo "=== BACKING UP STORAGE AND EXISTING ENCRYPTION KEYS ==="
sudo tar -C "$MOUNT" -czf "$BACKUP/storage-before.tgz" .
sudo cp -p "$ENV_PATH" "$BACKUP/.env.passprotect"
sudo chmod 0600 "$BACKUP/storage-before.tgz" "$BACKUP/.env.passprotect"
sudo test -s "$BACKUP/storage-before.tgz"
sudo test -s "$BACKUP/.env.passprotect"
BACKED_UP=1
echo "Backup complete: $BACKUP"

echo "=== CLEARING PASSPROTECT-OWNED VOLUME ONLY ==="
RESET_STARTED=1
sudo find "$MOUNT" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +

echo "=== STARTING PASSPROTECT AND APPLYING MIGRATIONS ==="
compose up -d --no-build --no-deps passprotect
echo "=== VERIFYING LOCAL HEALTH ==="
OK=0
for attempt in $(seq 1 40); do
  if curl --noproxy '*' -fsS --max-time 4 -H "Host: passprotect.comtek.uk.com" \
      http://127.0.0.1:15100/up >/dev/null 2>&1; then
    STATUS="$(sudo docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' "$CONTAINER")"
    if [ "$STATUS" = "healthy" ]; then OK=1; break; fi
  fi
  sleep 3
done
if [ "$OK" -ne 1 ]; then
  echo "ERROR: PassProtect is not healthy; automatic rollback will be attempted."
  exit 1
fi
RESET_DONE=1
compose ps
echo "SUCCESS: PassProtect application storage reset. First-run setup is ready."
echo "Visit https://passprotect.comtek.uk.com and follow first-run administrator setup."
echo "Boot code is in the container logs. Never share it in chat."
echo "Backup: $BACKUP"
echo "NOTE: Reset does NOT resolve the independently observed 422/CSRF issue."
