#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

INVENTORY_MODE="${INVENTORY_MODE:-netbox}"
TARGET="${TARGET:-all}"
BATCH_SIZE="${BACKUP_BATCH_SIZE:-10}"
BATCH_PAUSE_SECONDS="${BACKUP_BATCH_PAUSE_SECONDS:-5}"
CACHE_FILE="cache/last_netbox_inventory.yml"
CACHE_META="cache/last_netbox_inventory.meta"
CACHE_MAX_AGE_DAYS="${NETBOX_CACHE_MAX_AGE_DAYS:-7}"

INVENTORY_ARG=""

resolve_target_hosts() {
  if [ "$TARGET" = "all" ]; then
    echo "mikrotik"
  else
    echo "$TARGET"
  fi
}

if [ "$INVENTORY_MODE" = "local" ]; then
  echo "[inventário] modo local (sem NetBox), usando inventory/local/hosts.yml"
  INVENTORY_ARG="inventory/local/hosts.yml"
  export INVENTORY_MODE="local"
else
  echo "[inventário] verificando disponibilidade do NetBox..."
  mkdir -p cache

  # netbox.netbox.nb_inventory nao aplica Jinja em api_endpoint (so em
  # token), entao usamos o fallback nativo do plugin via env var NETBOX_API.
  export NETBOX_API="${NETBOX_URL:-}"

  # Tokens "scoped" do NetBox 4.x (formato key.secret, com ponto) exigem
  # 'Authorization: Bearer'; tokens classicos usam 'Authorization: Token'.
  if [[ "${NETBOX_TOKEN:-}" == *.* ]]; then
    NETBOX_AUTH_HEADER="Bearer ${NETBOX_TOKEN:-}"
  else
    NETBOX_AUTH_HEADER="Token ${NETBOX_TOKEN:-}"
  fi

  NETBOX_UP=0
  if curl -fsS --max-time 8 -H "Authorization: ${NETBOX_AUTH_HEADER}" \
       "${NETBOX_URL%/}/api/status/" > /dev/null 2>cache/last_netbox_error.log; then
    NETBOX_UP=1
  fi

  INVENTORY_OK=0
  if [ "$NETBOX_UP" = "1" ]; then
    if ansible-inventory -i inventory/netbox.yml --list --yaml > "${CACHE_FILE}.tmp" 2>cache/last_netbox_error.log \
       && ansible-inventory -i "${CACHE_FILE}.tmp" --list 2>/dev/null | jq -e '._meta.hostvars | length > 0' > /dev/null 2>&1; then
      INVENTORY_OK=1
    fi
  fi

  if [ "$INVENTORY_OK" = "1" ]; then
    mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
    date -u +%Y-%m-%dT%H:%M:%SZ > "$CACHE_META"
    echo "[inventário] NetBox OK, cache atualizado em ${CACHE_META}"
    INVENTORY_ARG="inventory/netbox.yml"
    export INVENTORY_MODE="netbox"
  else
    rm -f "${CACHE_FILE}.tmp"
    if [ "$NETBOX_UP" = "1" ]; then
      echo "[AVISO] NetBox respondeu, mas o inventário veio vazio/inválido (ver cache/last_netbox_error.log e o filtro em inventory/netbox.yml)." >&2
    else
      echo "[inventário] NetBox indisponível (ver cache/last_netbox_error.log)"
    fi
    if [ -f "$CACHE_FILE" ]; then
      CACHE_DATE=$(cat "$CACHE_META" 2>/dev/null || echo "desconhecida")
      echo "[inventário] usando cache local de inventário gerado em: ${CACHE_DATE}"
      if command -v python3 >/dev/null 2>&1 && [ -f "$CACHE_META" ]; then
        AGE_DAYS=$(python3 -c "
import datetime
d = datetime.datetime.strptime(open('$CACHE_META').read().strip(), '%Y-%m-%dT%H:%M:%SZ')
print((datetime.datetime.utcnow() - d).days)
" || echo 0)
        if [ "${AGE_DAYS:-0}" -gt "$CACHE_MAX_AGE_DAYS" ]; then
          echo "[AVISO] cache de inventário tem ${AGE_DAYS} dias (limite ${CACHE_MAX_AGE_DAYS}); pode estar desatualizado." >&2
        fi
      fi
      INVENTORY_ARG="$CACHE_FILE"
      export INVENTORY_MODE="netbox_cache_fallback"
    else
      echo "[ERRO] NetBox indisponível e nenhum cache de inventário encontrado. Abortando." >&2
      exit 1
    fi
  fi
fi

TARGET_HOSTS="$(resolve_target_hosts)"

ansible-playbook -i "$INVENTORY_ARG" playbooks/backup.yml \
  --extra-vars "target_hosts=${TARGET_HOSTS} batch_size=${BATCH_SIZE} batch_pause_seconds=${BATCH_PAUSE_SECONDS}" \
  "$@"
