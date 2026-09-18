# Backup automatizado de Mikrotiks (Ansible + Git + Docker)

Backup diário (ou sob demanda) de 130+ Mikrotiks, com teste de conectividade prévio,
checagem de integridade, execução em lotes, dedup por conteúdo, retenção e
notificação por e-mail. Inventário via NetBox em produção, com fallback em cache
local se o NetBox cair. Cada device gera dois artefatos por rodada: o export de
configuração em texto (`latest.rsc`) e o backup binário nativo do RouterOS
(`latest.backup`).

## Dois repositórios distintos

- **Código** (este repositório) — Ansible, Docker, scripts.
- **Dados/backups** — repositório separado, só com `backups/<host>/` e `logs/<run_id>.json`.
  Clonado localmente ao lado deste projeto (padrão `../mikrotik-data`).

```
mikrotik-save/          <- este repo (código)
mikrotik-data/           <- repo de dados (backups + logs), clone separado
```

O container monta o repositório de dados inteiro (com `.git`) em `/app/data`,
e faz commit + push **nele**, nunca no repositório de código.

## Estrutura (código)

```
inventory/netbox.yml            inventário dinâmico (produção)
inventory/local/hosts.yml       inventário estático (teste local, sem NetBox)
inventory/group_vars/mikrotik.yml credenciais SSH compartilhadas dos Mikrotiks
inventory/group_vars/all.yml    variáveis padrão (batch, timeouts, thresholds, retenção)
inventory/host_vars/<host>.yml  overrides por device (ex.: porta SSH não padrão)
roles/mikrotik_backup/          conectividade -> extração .rsc -> integridade .rsc -> extração .backup -> integridade .backup
scripts/routeros_export.py      exporta a config via SSH (paramiko, sem PTY) -> latest.rsc
scripts/routeros_binary_backup.py roda "/system backup save" e baixa via SFTP -> latest.backup
playbooks/backup.yml            play em lotes + play de agregação/commit/notificação
scripts/run_backup.sh           orquestra inventário (netbox/local/cache) + chama o playbook
scripts/git_commit.sh           poda + commit único ao final da rodada, com push
scripts/notify.sh               notificação por e-mail (SMTP via curl) com o resumo da rodada
scripts/entrypoint.sh           setup de git/SSH e agendamento via cron
```

## Setup inicial

```bash
# repositório de dados, ao lado deste projeto
cd ..
git clone git@<host>:<org>/mikrotik-ansible-backups.git mikrotik-data
cd mikrotik-save

cp .env.example .env
```

Edite `.env`:
- Produção: preencha `NETBOX_URL` e `NETBOX_TOKEN`. Aceita token clássico
  (sem ponto) ou token "scoped" do NetBox 4.x (formato `key.secret`, com
  ponto) — o cabeçalho `Token`/`Bearer` é detectado automaticamente pela
  presença de `.` no valor.
- Teste local (sem NetBox): preencha `MIKROTIK_TEST_HOST`, `MIKROTIK_TEST_USER`,
  `MIKROTIK_TEST_PASSWORD` do seu Mikrotik de laboratório e defina `INVENTORY_MODE=local`.
- `MIKROTIK_SSH_USER` / `MIKROTIK_SSH_PASSWORD` / `MIKROTIK_SSH_PORT`: credencial
  SSH compartilhada por todos os Mikrotiks do NetBox (`inventory/group_vars/mikrotik.yml`).
  Para um device com credencial ou porta diferente, crie
  `inventory/host_vars/<nome-exato-no-netbox>.yml` sobrescrevendo só o que precisar
  (ex.: `ansible_port: 1022`).
- `BACKUPS_REPO_HOST_DIR`: caminho, no host, do clone do repositório de dados
  (padrão `../mikrotik-data`).
- `RETENTION_DAYS`: dias de retenção dos snapshots datados (padrão 90).
- `CRON_SCHEDULE`: horário do backup agendado (padrão `0 23 * * *`).
- `NOTIFY_ENABLED`: `false` desliga o e-mail completamente, mesmo com SMTP
  configurado (útil enquanto o SMTP de produção ainda não existe).
- `NOTIFY_SMTP_*`: credenciais SMTP para notificação por e-mail.

No NetBox, ajuste o filtro em `inventory/netbox.yml` (`query_filters`) para bater
com como seus Mikrotiks estão modelados (hoje assume `manufacturer: mikrotik` +
`role: router`, agrupados em `mikrotik`).

## Extração via SSH (sem PTY)

O RouterOS quebra linhas do `/export` de acordo com a largura do terminal quando
a conexão usa PTY (comportamento padrão de `network_cli`/`community.routeros`),
corrompendo o backup. Por isso a extração roda via `scripts/routeros_export.py`
(paramiko, `exec_command` sem PTY), disparado do controller (`delegate_to:
localhost`) — o RouterOS não roda Python, então módulos Ansible comuns não
funcionam nele diretamente.

## Backup binário nativo (.backup)

Além do export em texto, cada rodada também roda `/system backup save` no
device e baixa o `.backup` resultante via SFTP (mesma sessão SSH, sem PTY),
via `scripts/routeros_binary_backup.py`. O arquivo é removido do próprio
RouterOS logo após o download (a flash do equipamento não acumula lixo).

- `MIKROTIK_BACKUP_PASSWORD` (opcional, vazio por padrão): se preenchida, o
  backup binário é salvo criptografado (mesma senha necessária depois para
  `/system backup load` no RouterOS). O `.rsc` nunca é criptografado.
- A extração e a integridade do `.rsc` acontecem primeiro; o backup binário só
  é tentado se o `.rsc` daquele device já tiver sido extraído e validado com
  sucesso (evita gastar tempo com o binário se o device já falhou no passo
  anterior). Uma falha isolada no binário (`binary_backup_failed` /
  `binary_integrity_failed`) não é silenciosamente ignorada: aparece no
  `status` do host no log e conta separadamente no resumo da rodada.
- A checagem de integridade do binário é apenas tamanho mínimo
  (`binary_backup_min_size_bytes`, padrão 200 bytes) — a MikroTik não
  documenta publicamente uma assinatura de "magic bytes" para o formato
  `.backup`, então não há validação de conteúdo além disso.

## Push do container para o repositório de dados

Duas opções, configuráveis no `.env` (escolha uma):

- **ssh-agent do host** (bom para dev local, ex. Docker Desktop no Mac): defina
  `SSH_AUTH_SOCK_HOST_PATH` (no Mac, `/run/host-services/ssh-auth.sock`) e
  garanta que sua chave está no agente do host (`ssh-add -l`).
- **Deploy key dedicada** (recomendado em produção/Linux): gere um par de
  chaves só para esta automação, cadastre a pública como Deploy Key **com
  permissão de escrita** no projeto do repositório de dados, e aponte
  `SSH_DEPLOY_KEY_HOST_PATH` para o arquivo da chave privada no host
  (permissão 600). Descomente `GIT_SSH_COMMAND` no `.env`.

Em ambos os casos, ajuste `GIT_KNOWN_HOSTS` para o host do seu servidor git
(ex.: `gitlab.exemplo.com`) — o `entrypoint.sh` roda `ssh-keyscan` nele para
evitar "Host key verification failed".

## Build

```bash
docker compose build
```

## Rodar backup manual — um host específico

```bash
docker compose run --rm -e INVENTORY_MODE=local -e TARGET=mikrotik-lab mikrotik-backup run
```

Em produção, `TARGET` deve ser o hostname exatamente como aparece no inventário
gerado pelo NetBox (`ansible-inventory -i inventory/netbox.yml --graph` para conferir).

## Rodar backup manual — todos os hosts

```bash
docker compose run --rm -e INVENTORY_MODE=netbox -e TARGET=all mikrotik-backup run
```

## Rodar diariamente (agendado)

```bash
docker compose up -d
```

O container fica com `cron` em foreground e dispara `run_backup.sh` no horário
definido por `CRON_SCHEDULE` no `.env` (padrão `0 23 * * *`, todo dia às 23:00),
com `INVENTORY_MODE=netbox TARGET=all`. O crontab é gerado no `entrypoint.sh` a
cada início de container — para mudar o horário, edite `CRON_SCHEDULE` no `.env`
e reinicie o container (`docker compose restart`), sem precisar rebuildar a imagem.

O job do cron roda sob `SHELL=/bin/bash` (não o `/bin/sh` padrão) porque precisa
fazer `source` de `/app/.cron_env` — um dump das variáveis de ambiente relevantes
gerado no início do container, já que `cron` não herda `.env` automaticamente.

## Como funciona o fallback de NetBox

1. `run_backup.sh` checa `${NETBOX_URL}/api/status/` via HTTP (com o mesmo
   header de autenticação usado pelo inventário).
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

- A cada rodada, o export `.rsc` é comparado ao `latest.rsc` anterior daquele
  equipamento (ignorando a 1ª linha, o timestamp do `/export`, que muda
  sempre e não é uma mudança de configuração real); o `.backup` é comparado
  por checksum (sha256) do arquivo inteiro ao `latest.backup` anterior. Só é
  criado um snapshot datado (`backups/<host>/<timestamp>.rsc` ou `.backup`)
  quando o conteúdo daquele tipo realmente muda.
- **Atenção**: o formato binário do RouterOS pode embutir estado interno do
  equipamento (não só a configuração), então o `.backup` pode ser marcado
  como "alterado" com mais frequência que o `.rsc`, mesmo sem mudança de
  configuração real — isso é uma característica do formato, não um bug do
  dedup.
- `latest.rsc` e `latest.backup` são sempre atualizados a cada rodada; o
  histórico no git já é a fonte de verdade de "o que mudou e quando"
  (`git log -p -- backups/<host>/latest.rsc`).
- Snapshots datados com mais de `RETENTION_DAYS` dias (padrão 90) são removidos
  da árvore de trabalho a cada rodada (continuam recuperáveis via
  `git show <commit>:<caminho>` no histórico). `latest.rsc` e `latest.backup`
  nunca são podados.

## Logs, commit e notificação

- Cada rodada gera `logs/<run_id>.json` (no repositório de dados) com status
  por host (`success`, `backup_failed`, `integrity_failed`,
  `binary_backup_failed`, `binary_integrity_failed`, `unreachable`), quais
  tiveram `.rsc` e/ou `.backup` alterado, e um resumo agregado.
- Ao final da rodada inteira, `scripts/git_commit.sh` poda snapshots antigos,
  faz **um único commit** (backups + log) e `git push` no repositório de dados.
- `scripts/notify.sh` envia um e-mail com o resumo: total, sucesso/falha
  (`.rsc` e `.backup` separadamente)/inacessíveis, diff normalizado por
  device com `.rsc` alterado (o `.backup` não entra no diff por ser binário,
  só é listado como alterado), link direto para o commit (calculado a partir
  da URL do remote, SSH ou HTTPS) e se o push foi feito. `NOTIFY_ENABLED=false`
  desativa o envio por completo.

## Telemetria pro Zabbix

Opcional, desligado por padrão (`ZABBIX_ENABLED=false`). Quando ligado,
`scripts/zabbix_report.py` envia o status de backup de cada host pro Zabbix
via protocolo trapper (implementado direto em Python, sem depender do
binário `zabbix_sender`), ao final de toda rodada.

**Mapeamento de nome**: o host no Zabbix é o nome do device no NetBox mais
um sufixo (`ZABBIX_HOST_SUFFIX`, padrão `-INT`) — ex.: `MKT_AUR` no NetBox
vira `MKT_AUR-INT` no Zabbix. Isso bate com o padrão de nomenclatura já
usado pra separar monitoramento externo (`-EXT`, via cloud do Mikrotik) do
interno (`-INT`, via SNMP/WireGuard) — o backup roda pela rede interna,
então reporta pro lado `-INT`.

**Itens enviados** (criar como *Zabbix trapper* num Template aplicado ao
grupo de hosts `*-INT`):

| Item key | Tipo | Quando é atualizado |
|---|---|---|
| `mikrotik.backup.status` | Texto | toda rodada (`success`, `backup_failed`, `unreachable`, etc.) |
| `mikrotik.backup.last_run` | Numérico (timestamp Unix) | toda rodada, sucesso ou não — "quando foi a última tentativa" |
| `mikrotik.backup.last_success` | Numérico (timestamp Unix) | só quando `status == success` — "quando foi o último backup bom" |
| `mikrotik.backup.changed` | Numérico (0/1) | toda rodada — configuração mudou nessa rodada? |
| `mikrotik.backup.error` | Texto | toda rodada (vazio se sucesso) |

Trigger sugerido no Zabbix: `nodata(/host/mikrotik.backup.last_run,26h)=1`
pra alertar se a automação parar de reportar (rodada agendada não rodou,
ou o item não está mais recebendo dados).

No Grafana, com o datasource Zabbix já configurado, um dashboard com
variável `$host` (grupo `MKTS-INT`) consegue mostrar status atual, data do
último sucesso e histórico — mesmo padrão dos outros dashboards Zabbix já
usados no ambiente.

Variáveis (`.env` ou CI/CD Variables):
- `ZABBIX_ENABLED`: `true` pra ligar (padrão `false`).
- `ZABBIX_SERVER`: endereço do servidor Zabbix.
- `ZABBIX_PORT`: porta trapper, padrão `10051`.
- `ZABBIX_HOST_SUFFIX`: padrão `-INT`.

## Execução em lotes

- `BACKUP_BATCH_SIZE` (padrão 10): quantos hosts por lote (`serial` do Ansible).
- `BACKUP_BATCH_PAUSE_SECONDS` (padrão 5): pausa entre lotes.
- `forks` em `ansible.cfg` controla o paralelismo dentro de cada lote (padrão 5).

## Recuperar um backup antigo

No repositório de dados (`../mikrotik-data`):

```bash
git log --oneline -- backups/<hostname>
git show <commit>:backups/<hostname>/latest.rsc > restaurado.rsc
git show <commit>:backups/<hostname>/latest.backup > restaurado.backup
```

- `.rsc`: cole/rode o conteúdo no terminal do RouterOS (é um script `/export`).
- `.backup`: envie de volta pro device (via SFTP/WinBox) e rode
  `/system backup load name=restaurado` (peça a senha se `MIKROTIK_BACKUP_PASSWORD`
  estava preenchida na rodada em que aquele backup foi gerado) — isso restaura
  o estado binário completo, não só a configuração exportável em texto.

## Pendências para produção

- Configurar `NOTIFY_SMTP_*` com as credenciais reais do SMTP do cliente e
  ligar `NOTIFY_ENABLED=true`.
- Validar o backup contra todos os devices reais (`TARGET=all`) após a
  validação em um device único.
- Confirmar/documentar credenciais por device fora do padrão (além dos
  `host_vars` de porta) caso surjam mais casos como esse.
