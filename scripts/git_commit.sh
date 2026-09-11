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
BINARY_CHANGED_COUNT=$(jq -r '.summary.binary_changed_count // 0' "$LOG_FILE")
BINARY_CHANGED_DEVICES_CSV=$(jq -r '.summary.binary_changed_devices // [] | join(",")' "$LOG_FILE")

FAILED_HOSTS=$(jq -r '.hosts[] | select(.status != "success") | .host' "$LOG_FILE" | paste -sd ',' -)

PRUNED=$(find backups -type f \( -name '*.rsc' -o -name '*.backup' \) ! -name 'latest.rsc' ! -name 'latest.backup' -mtime "+${RETENTION_DAYS}" -print)
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

# Diff calculado ignorando a 1a linha (timestamp do /export, que muda sempre e
# não é uma mudança de configuração real) - usa `diff` sobre conteudo normalizado
# em vez de `git diff` puro no arquivo inteiro.
DIFF_MAX_LINES="${NOTIFY_DIFF_MAX_LINES:-300}"
DIFFS_JSON="[]"
while IFS= read -r dev; do
  [ -z "$dev" ] && continue
  DIFF_TMP=$(mktemp)
  OLD_TMP=$(mktemp)
  NEW_TMP=$(mktemp)
  git show "HEAD:backups/${dev}/latest.rsc" 2>/dev/null | tail -n +2 > "$OLD_TMP" || true
  tail -n +2 "backups/${dev}/latest.rsc" > "$NEW_TMP"
  FULL_DIFF=$(diff -u "$OLD_TMP" "$NEW_TMP" | tail -n +3 || true)
  echo "$FULL_DIFF" | head -n "$DIFF_MAX_LINES" > "$DIFF_TMP"
  TOTAL_DIFF_LINES=$(echo "$FULL_DIFF" | grep -c . || true)
  if [ "${TOTAL_DIFF_LINES:-0}" -gt "$DIFF_MAX_LINES" ]; then
    echo "... (diff truncado, ${TOTAL_DIFF_LINES} linhas no total, mostrando as primeiras ${DIFF_MAX_LINES})" >> "$DIFF_TMP"
  fi
  DIFFS_JSON=$(jq --arg host "$dev" --rawfile diff "$DIFF_TMP" '. + [{host: $host, diff: $diff}]' <<< "$DIFFS_JSON")
  rm -f "$DIFF_TMP" "$OLD_TMP" "$NEW_TMP"
done < <(jq -r '.summary.changed_devices[]?' "$LOG_FILE")

COMMIT_MSG="backup mikrotik: ${RUN_ID} (modo=${INVENTORY_MODE}) - total=${TOTAL} ok=${SUCCESS} falha_backup=${BACKUP_FAILED} falha_integridade=${INTEGRITY_FAILED} inacessiveis=${UNREACHABLE} config_alterada=${CHANGED_COUNT} backup_binario_alterado=${BINARY_CHANGED_COUNT} podados=${PRUNED_COUNT}"
if [ -n "${FAILED_HOSTS}" ]; then
  COMMIT_MSG="${COMMIT_MSG}
Hosts com problema: ${FAILED_HOSTS}"
fi
if [ -n "${CHANGED_DEVICES_CSV}" ] && [ "${CHANGED_DEVICES_CSV}" != "null" ]; then
  COMMIT_MSG="${COMMIT_MSG}
Configuração alterada em: ${CHANGED_DEVICES_CSV} (ver backups/<host>/latest.rsc)"
fi
if [ -n "${BINARY_CHANGED_DEVICES_CSV}" ] && [ "${BINARY_CHANGED_DEVICES_CSV}" != "null" ]; then
  COMMIT_MSG="${COMMIT_MSG}
Backup binário atualizado em: ${BINARY_CHANGED_DEVICES_CSV} (ver backups/<host>/latest.backup)"
fi

git commit -q -m "${COMMIT_MSG}"
COMMIT_SHA=$(git rev-parse --short HEAD)
COMMIT_SHA_FULL=$(git rev-parse HEAD)

PUSHED=false
if git remote get-url "${GIT_REMOTE_NAME:-origin}" >/dev/null 2>&1; then
  git push -q "${GIT_REMOTE_NAME:-origin}" "${GIT_DEFAULT_BRANCH:-main}"
  PUSHED=true
else
  echo "Nenhum remote git configurado; commit feito apenas localmente." >&2
fi

# Converte a URL do remote (SSH ou HTTPS) para uma URL web clicavel, ex.:
# git@github.com:org/repo.git -> https://github.com/org/repo
# https://gitlab.exemplo.com/org/repo.git -> https://gitlab.exemplo.com/org/repo
COMMIT_URL=""
REMOTE_URL=$(git remote get-url "${GIT_REMOTE_NAME:-origin}" 2>/dev/null || true)
if [ -n "$REMOTE_URL" ]; then
  WEB_URL=$(echo "$REMOTE_URL" | sed -E 's#^git@([^:]+):(.+)\.git$#https://\1/\2#; s#\.git$##')
  if echo "$WEB_URL" | grep -qE '^https?://'; then
    COMMIT_URL="${WEB_URL}/commit/${COMMIT_SHA_FULL}"
  fi
fi

DIFFS_TMP=$(mktemp)
echo "$DIFFS_JSON" > "$DIFFS_TMP"

jq --arg sha "$COMMIT_SHA" --arg url "$COMMIT_URL" --argjson pushed "$PUSHED" --argjson pruned "$PRUNED_COUNT" --slurpfile diffs "$DIFFS_TMP" \
   '.summary.git_committed = true | .summary.git_commit_sha = $sha | .summary.git_commit_url = $url | .summary.git_pushed = $pushed | .summary.pruned_snapshots = $pruned | .summary.diffs = $diffs[0]' \
   "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
rm -f "$DIFFS_TMP"
