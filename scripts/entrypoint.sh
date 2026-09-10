#!/usr/bin/env bash
set -euo pipefail

cd /app

BACKUPS_REPO_DIR="${BACKUPS_REPO_DIR:-/app/data}"

mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/known_hosts
for h in $(echo "${GIT_KNOWN_HOSTS:-github.com}" | tr ',' ' '); do
  if ! ssh-keygen -F "$h" >/dev/null 2>&1; then
    ssh-keyscan -H "$h" >> ~/.ssh/known_hosts 2>/dev/null || true
  fi
done

git config --global --add safe.directory "${BACKUPS_REPO_DIR}"
if [ -n "${GIT_USER_NAME:-}" ]; then git config --global user.name "${GIT_USER_NAME}"; fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then git config --global user.email "${GIT_USER_EMAIL}"; fi

mkdir -p cache "${BACKUPS_REPO_DIR}/backups" "${BACKUPS_REPO_DIR}/logs"

if [ ! -d "${BACKUPS_REPO_DIR}/.git" ]; then
  echo "[AVISO] ${BACKUPS_REPO_DIR} não é um repositório git (esperado o volume do repo de backups montado ali)." >&2
fi

case "${1:-cron}" in
  cron)
    # /etc/environment não é confiável aqui (cron minimalista, sem PAM), então
    # dumpamos o ambiente atual para um arquivo que o job do cron faz "source"
    # antes de rodar o backup. Usa `export NAME=valor` (POSIX) em vez de
    # `declare -x` (só existe em bash) - o job do cron roda por padrão em
    # /bin/sh (dash), que não entende `declare`.
    : > /app/.cron_env
    for var_name in $(compgen -e | grep -E '^(NETBOX_|GIT_|BACKUP_|MIKROTIK_|BACKUPS_REPO_DIR|RETENTION_DAYS|NOTIFY_)'); do
      printf 'export %s=%q\n' "$var_name" "${!var_name}" >> /app/.cron_env
    done
    CRON_SCHEDULE="${CRON_SCHEDULE:-0 23 * * *}"
    {
      echo "SHELL=/bin/bash"
      echo "${CRON_SCHEDULE} . /app/.cron_env; cd /app && INVENTORY_MODE=netbox TARGET=all /app/scripts/run_backup.sh >> ${BACKUPS_REPO_DIR}/logs/cron.log 2>&1"
    } | crontab -
    echo "[entrypoint] cron instalado (CRON_SCHEDULE='${CRON_SCHEDULE}'), aguardando próxima execução."
    cron -f
    ;;
  run)
    shift
    exec /app/scripts/run_backup.sh "$@"
    ;;
  shell)
    exec bash
    ;;
  *)
    exec "$@"
    ;;
esac
