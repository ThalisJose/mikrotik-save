# Backup automatizado de Mikrotiks (Ansible + Git + Docker)

Backup diário (ou sob demanda) de 130+ Mikrotiks, com teste de conectividade prévio,
checagem de integridade, execução em lotes, dedup por conteúdo, retenção e
notificação por e-mail. Inventário via NetBox em produção, com fallback em cache
local se o NetBox cair.

## Dois repositórios distintos

- **Código** (este repositório) — Ansible, Docker, scripts. Ex.: `mikrotik-save`.
- **Dados/backups** — repositório separado, só com `backups/<host>/` e `logs/<run_id>.json`.
  Ex.: `save-mikrotik`. Clonado localmente ao lado deste projeto, ex.: `../mikrotik-data`.

```
../mikrotik/            <- este repo (código)
../mikrotik-data/       <- repo de dados (backups + logs), clone separado
```

O container monta o repositório de dados inteiro (com `.git`) em `/app/data`,
e faz commit + push **nele**, nunca no repositório de código.

## Estrutura (código)

```
inventory/netbox.yml        inventário dinâmico (produção)
inventory/local/hosts.yml   inventário estático (teste local, sem NetBox)
inventory/group_vars/all.yml variáveis padrão (batch, timeouts, thresholds, retenção)
roles/mikrotik_backup/      conectividade -> extração (com dedup) -> integridade
playbooks/backup.yml        play em lotes + play de agregação/commit/notificação
scripts/run_backup.sh       orquestra inventário (netbox/local/cache) + chama o playbook
scripts/git_commit.sh       poda + commit único ao final da rodada, com push
scripts/notify.sh           notificação por e-mail (SMTP via curl) com o resumo da rodada
```

## Setup inicial

```bash
# repositório de dados, ao lado deste projeto
cd ..
git clone git@github.com:<org>/save-mikrotik.git mikrotik-data
cd mikrotik

git init   # se ainda não for um repositório
cp .env.example .env
```

Edite `.env`:
- Produção: preencha `NETBOX_URL` e `NETBOX_TOKEN`.
- Teste local (sem NetBox): preencha `MIKROTIK_TEST_HOST`, `MIKROTIK_TEST_USER`,
  `MIKROTIK_TEST_PASSWORD` do seu Mikrotik de laboratório e defina `INVENTORY_MODE=local`.
- `BACKUPS_REPO_HOST_DIR`: caminho, no host, do clone do repositório de dados
  (padrão `../mikrotik-data`).
- `RETENTION_DAYS`: dias de retenção dos snapshots datados (padrão 90).
- `NOTIFY_SMTP_*`: credenciais SMTP para notificação por e-mail (deixe
  `NOTIFY_SMTP_URL` vazio para desativar).

No NetBox, ajuste o filtro em `inventory/netbox.yml` (`query_filters`) para bater
com como seus Mikrotiks estão modelados (hoje assume `manufacturer: mikrotik`).

## Push do container para o repositório de dados

O container usa **ssh-agent forwarding** do host para autenticar o `git push`
(sem copiar chave privada para a imagem). No Docker Desktop para Mac, o
`docker-compose.yml` já monta `/run/host-services/ssh-auth.sock`; garanta que
sua chave está no agente do host (`ssh-add -l`). Em produção (Linux), monte
`$SSH_AUTH_SOCK` do host da mesma forma.

## Build

```bash
docker compose build
```

## Rodar backup manual — um host específico

```bash
docker compose run --rm -e INVENTORY_MODE=local -e TARGET=mikrotik-lab mikrotik-backup run
```

Em produção, `TARGET` deve ser o hostname exatamente como aparece no inventário
gerado pelo NetBox (`ansible-inventory -i inventory/netbox.yml --list` para conferir).

## Rodar backup manual — todos os hosts

```bash
docker compose run --rm -e INVENTORY_MODE=netbox -e TARGET=all mikrotik-backup run
```

## Rodar diariamente (agendado)

```bash
docker compose up -d
```

O container fica com `cron` em foreground e dispara `run_backup.sh` todo dia às
23:00 (`scripts/crontab`) com `INVENTORY_MODE=netbox TARGET=all`.

## Como funciona o fallback de NetBox

1. `run_backup.sh` checa `${NETBOX_URL}/api/status/` via HTTP.
2. Se OK: gera o inventário (`ansible-inventory --list --yaml`) e valida que
   não veio vazio; salva em `cache/last_netbox_inventory.yml` e roda normalmente.
3. Se o NetBox estiver fora do ar (ou responder mas o inventário vier vazio):
   usa o cache da execução anterior, loga isso explicitamente
   (`netbox_cache_fallback`) e avisa se o cache tiver mais de
   `NETBOX_CACHE_MAX_AGE_DAYS` dias.
4. Sem NetBox e sem cache: aborta com erro (não tem de onde tirar a lista).

Em `INVENTORY_MODE=local`, o NetBox nunca é consultado — usa direto
`inventory/local/hosts.yml`.

## Dedup e retenção

- A cada rodada, o export é comparado ao `latest.rsc` anterior daquele
  equipamento. Só é criado um snapshot datado (`backups/<host>/<timestamp>.rsc`)
  quando o conteúdo realmente muda — evita duplicar arquivo idêntico todos os
  dias para os 130+ equipamentos.
- `latest.rsc` é sempre atualizado; seu histórico no git já é a fonte de
  verdade de "o que mudou e quando" (`git log -p -- backups/<host>/latest.rsc`).
- Snapshots datados com mais de `RETENTION_DAYS` dias (padrão 90) são removidos
  da árvore de trabalho a cada rodada (continuam recuperáveis via
  `git show <commit>:<caminho>` no histórico). `latest.rsc` nunca é podado.

## Logs, commit e notificação

- Cada rodada gera `logs/<run_id>.json` (no repositório de dados) com status
  por host (`success`, `backup_failed`, `integrity_failed`, `unreachable`),
  quais tiveram configuração alterada, e um resumo agregado.
- Ao final da rodada inteira, `scripts/git_commit.sh` poda snapshots antigos,
  faz **um único commit** (backups + log) e `git push` no repositório de dados.
- Em seguida, `scripts/notify.sh` envia um e-mail com o resumo: total,
  sucesso/falha/inacessíveis, se o commit/push foi feito, e a lista de
  dispositivos com configuração alterada (com o caminho do arquivo).

## Execução em lotes

- `BACKUP_BATCH_SIZE` (padrão 10): quantos hosts por lote (`serial` do Ansible).
- `BACKUP_BATCH_PAUSE_SECONDS` (padrão 5): pausa entre lotes.
- `forks` em `ansible.cfg` controla o paralelismo dentro de cada lote (padrão 5).

## Recuperar um backup antigo

No repositório de dados (`../mikrotik-data`):

```bash
git log --oneline -- backups/<hostname>
git show <commit>:backups/<hostname>/latest.rsc > restaurado.rsc
```

## Pendências para produção

- Confirmar no NetBox o critério real de filtro dos Mikrotiks (`inventory/netbox.yml`).
- Definir onde ficam as credenciais SSH por device (vault indexado por host,
  ou custom field no NetBox) — hoje o repositório não traz isso pronto.
- Configurar `NOTIFY_SMTP_*` com as credenciais reais do SMTP do cliente.
- Garantir ssh-agent (ou deploy key) disponível para o container conseguir
  dar push no repositório de dados em produção (Linux).
