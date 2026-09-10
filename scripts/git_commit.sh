#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="$1"
DATA_DIR="${BACKUPS_REPO_DIR:-/app/data}"
RETENTION_DAYS="${RETENTION_DAYS:-90}"
cd "$DATA_DIR"

if [ ! -d .git ]; then
  echo "Repositório git de backups não inicializado em ${DATA_DIR}; pulando commit." >&2
  exit 0
fi

RUN_ID=$(jq -r '.summary.run_id' "$LOG_FILE")
TOTAL=$(jq -r '.summary.total' "$LOG_FILE")
SUCCESS=$(jq -r '.summary.success' "$LOG_FILE")
BACKUP_FAILED=$(jq -r '.summary.backup_failed' "$LOG_FILE")
INTEGRITY_FAILED=$(jq -r '.summary.integrity_failed' "$LOG_FILE")
UNREACHABLE=$(jq -r '.summary.unreachable' "$LOG_FILE")
INVENTORY_MODE=$(jq -r '.summary.inventory_mode' "$LOG_FILE")
CHANGED_COUNT=$(jq -r '.summary.changed_count' "$LOG_FILE")
CHANGED_DEVICES_CSV=$(jq -r '.summary.changed_devices | join(",")' "$LOG_FILE")

FAILED_HOSTS=$(jq -r '.hosts[] | select(.status != "success") | .host' "$LOG_FILE" | paste -sd ',' -)

PRUNED=$(find backups -type f -name '*.rsc' ! -name 'latest.rsc' -mtime "+${RETENTION_DAYS}" -print)
if [ -n "$PRUNED" ]; then
  echo "$PRUNED" | xargs rm -f
  PRUNED_COUNT=$(echo "$PRUNED" | grep -c .)
else
  PRUNED_COUNT=0
fi

git add -A backups/ logs/

if git diff --cached --quiet; then
  echo "nothing to commit"
  jq '.summary.git_committed = false | .summary.pruned_snapshots = '"${PRUNED_COUNT}" \
     "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
  exit 0
fi

COMMIT_MSG="backup mikrotik: ${RUN_ID} (modo=${INVENTORY_MODE}) - total=${TOTAL} ok=${SUCCESS} falha_backup=${BACKUP_FAILED} falha_integridade=${INTEGRITY_FAILED} inacessiveis=${UNREACHABLE} config_alterada=${CHANGED_COUNT} podados=${PRUNED_COUNT}"
if [ -n "${FAILED_HOSTS}" ]; then
  COMMIT_MSG="${COMMIT_MSG}
Hosts com problema: ${FAILED_HOSTS}"
fi
if [ -n "${CHANGED_DEVICES_CSV}" ] && [ "${CHANGED_DEVICES_CSV}" != "null" ]; then
  COMMIT_MSG="${COMMIT_MSG}
Configuração alterada em: ${CHANGED_DEVICES_CSV} (ver backups/<host>/latest.rsc)"
fi

git commit -q -m "${COMMIT_MSG}"
COMMIT_SHA=$(git rev-parse --short HEAD)

PUSHED=false
if git remote get-url "${GIT_REMOTE_NAME:-origin}" >/dev/null 2>&1; then
  git push -q "${GIT_REMOTE_NAME:-origin}" "${GIT_DEFAULT_BRANCH:-main}"
  PUSHED=true
else
  echo "Nenhum remote git configurado; commit feito apenas localmente." >&2
fi

jq --arg sha "$COMMIT_SHA" --argjson pushed "$PUSHED" --argjson pruned "$PRUNED_COUNT" \
   '.summary.git_committed = true | .summary.git_commit_sha = $sha | .summary.git_pushed = $pushed | .summary.pruned_snapshots = $pruned' \
   "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
