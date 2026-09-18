#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="$1"

RUN_ID=$(jq -r '.summary.run_id' "$LOG_FILE")
TOTAL=$(jq -r '.summary.total' "$LOG_FILE")
SUCCESS=$(jq -r '.summary.success' "$LOG_FILE")
BACKUP_FAILED=$(jq -r '.summary.backup_failed' "$LOG_FILE")
INTEGRITY_FAILED=$(jq -r '.summary.integrity_failed' "$LOG_FILE")
BINARY_BACKUP_FAILED=$(jq -r '.summary.binary_backup_failed // 0' "$LOG_FILE")
BINARY_INTEGRITY_FAILED=$(jq -r '.summary.binary_integrity_failed // 0' "$LOG_FILE")
UNREACHABLE=$(jq -r '.summary.unreachable' "$LOG_FILE")
CHANGED_COUNT=$(jq -r '.summary.changed_count' "$LOG_FILE")
BINARY_CHANGED_COUNT=$(jq -r '.summary.binary_changed_count // 0' "$LOG_FILE")
GIT_COMMITTED=$(jq -r '.summary.git_committed // false' "$LOG_FILE")
GIT_SHA=$(jq -r '.summary.git_commit_sha // "-"' "$LOG_FILE")
GIT_URL=$(jq -r '.summary.git_commit_url // ""' "$LOG_FILE")
GIT_PUSHED=$(jq -r '.summary.git_pushed // false' "$LOG_FILE")
PRUNED=$(jq -r '.summary.pruned_snapshots // 0' "$LOG_FILE")

CHANGED_LINES=$(jq -r '.summary.changed_devices[]? | "- " + . + " (backups/" + . + "/latest.rsc)"' "$LOG_FILE")
[ -z "$CHANGED_LINES" ] && CHANGED_LINES="  nenhum"

BINARY_CHANGED_LINES=$(jq -r '.summary.binary_changed_devices[]? | "- " + . + " (backups/" + . + "/latest.backup)"' "$LOG_FILE")
[ -z "$BINARY_CHANGED_LINES" ] && BINARY_CHANGED_LINES="  nenhum"

FAILED_LINES=$(jq -r '.hosts[] | select(.status != "success") | "- " + .host + ": " + .status + " (" + .error + ")"' "$LOG_FILE")
[ -z "$FAILED_LINES" ] && FAILED_LINES="  nenhum"

STATUS_LABEL="OK"
if [ "$BACKUP_FAILED" != "0" ] || [ "$INTEGRITY_FAILED" != "0" ] || [ "$BINARY_BACKUP_FAILED" != "0" ] || [ "$BINARY_INTEGRITY_FAILED" != "0" ] || [ "$UNREACHABLE" != "0" ]; then
  STATUS_LABEL="ATENÇÃO"
fi

SUBJECT="[Mikrotik Backup] ${STATUS_LABEL} - rodada ${RUN_ID} (${SUCCESS}/${TOTAL} ok)"

# Corpo do relatório (sem cabeçalhos de e-mail) - usado tanto pro log do job
# quanto pro corpo do e-mail, pra não duplicar a lógica de formatação.
BODY_FILE=$(mktemp)
trap 'rm -f "$BODY_FILE"' EXIT

{
  echo "Status geral: ${STATUS_LABEL}"
  echo "Rodada: ${RUN_ID}"
  echo "Total de hosts: ${TOTAL}"
  echo "Sucesso: ${SUCCESS}"
  echo "Falha no backup: ${BACKUP_FAILED}"
  echo "Falha de integridade: ${INTEGRITY_FAILED}"
  echo "Falha no backup binário: ${BINARY_BACKUP_FAILED}"
  echo "Falha de integridade do backup binário: ${BINARY_INTEGRITY_FAILED}"
  echo "Inacessíveis: ${UNREACHABLE}"
  echo
  echo "Commit no git: ${GIT_COMMITTED} (sha=${GIT_SHA}, push=${GIT_PUSHED})"
  if [ -n "$GIT_URL" ]; then
    echo "Ver commit: ${GIT_URL}"
  fi
  echo "Snapshots antigos podados (retenção): ${PRUNED}"
  echo
  echo "Dispositivos com configuração (.rsc) alterada nesta rodada (${CHANGED_COUNT}):"
  echo "${CHANGED_LINES}"
  echo
  echo "Dispositivos com backup binário (.backup) alterado nesta rodada (${BINARY_CHANGED_COUNT}):"
  echo "${BINARY_CHANGED_LINES}"
  echo
  echo "Hosts com problema:"
  echo "${FAILED_LINES}"
  echo
  echo "=== O que mudou ==="
  DIFF_COUNT=$(jq '.summary.diffs | length' "$LOG_FILE")
  if [ "${DIFF_COUNT:-0}" = "0" ] || [ "$DIFF_COUNT" = "null" ]; then
    echo "(nenhuma diferença de configuração nesta rodada)"
  else
    while IFS= read -r item; do
      host=$(jq -r '.host' <<< "$item")
      diff_text=$(jq -r '.diff' <<< "$item")
      echo
      echo "--- ${host} (backups/${host}/latest.rsc) ---"
      echo "${diff_text}"
    done < <(jq -c '.summary.diffs[]?' "$LOG_FILE")
  fi
} > "$BODY_FILE"

# Sempre imprime o relatório no stdout (aparece no log do job/pipeline),
# independente de NOTIFY_ENABLED - assim dá pra conferir o resultado da
# rodada direto no log, mesmo com e-mail desativado.
echo "=================== Relatório da rodada ${RUN_ID} ==================="
cat "$BODY_FILE"
echo "======================================================================"

if [ "${NOTIFY_ENABLED:-true}" != "true" ]; then
  echo "[notify] NOTIFY_ENABLED=false; notificação por e-mail desativada (relatório acima)." >&2
  exit 0
fi

if [ -z "${NOTIFY_SMTP_URL:-}" ]; then
  echo "[notify] NOTIFY_SMTP_URL não configurado; pulando notificação por e-mail (relatório acima)." >&2
  exit 0
fi

MSG_FILE=$(mktemp)
trap 'rm -f "$BODY_FILE" "$MSG_FILE"' EXIT

{
  echo "From: ${NOTIFY_SMTP_FROM}"
  echo "To: ${NOTIFY_SMTP_TO}"
  echo "Subject: ${SUBJECT}"
  echo "Content-Type: text/plain; charset=utf-8"
  echo
  cat "$BODY_FILE"
} > "$MSG_FILE"

RCPT_ARGS=()
IFS=',' read -ra RCPTS <<< "${NOTIFY_SMTP_TO}"
for r in "${RCPTS[@]}"; do
  RCPT_ARGS+=(--mail-rcpt "$(echo "$r" | xargs)")
done

curl -fsS --url "${NOTIFY_SMTP_URL}" \
  ${NOTIFY_SMTP_SSL_REQD:+--ssl-reqd} \
  --mail-from "${NOTIFY_SMTP_FROM}" \
  "${RCPT_ARGS[@]}" \
  --user "${NOTIFY_SMTP_USER}:${NOTIFY_SMTP_PASSWORD}" \
  --upload-file "$MSG_FILE" \
  && echo "[notify] e-mail enviado para ${NOTIFY_SMTP_TO}" \
  || echo "[notify] falha ao enviar e-mail (ver erro do curl acima)" >&2
