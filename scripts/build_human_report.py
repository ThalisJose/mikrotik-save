#!/usr/bin/env python3
"""Gera um relatório humanizado (texto simples) a partir do log JSON de uma
rodada de backup, classificando a causa provável de cada falha (senha/usuário
incorretos, porta incorreta/sem resposta, timeout, permissão RouterOS
insuficiente, etc.) em vez de só repetir a exceção crua do paramiko.

Uso: build_human_report.py <log.json> <saida.txt>

O arquivo de saída é gravado dentro de logs_root_dir (mesmo diretório do
.json), então scripts/git_commit.sh (que faz `git add -A backups/ logs/`) o
versiona junto com o log JSON da mesma rodada.
"""
import json
import re
import sys

# Cada item: (regex a procurar no texto do erro, rótulo humano da causa).
# Checados em ordem - o primeiro que bater vence. Case-insensitive.
#
# Os dois primeiros padrões pegam erro de CHAMADA do script (argparse) -
# ficam antes de tudo porque a mensagem de "usage:" do argparse cita o nome
# de várias opções (ex.: "--timeout TIMEOUT") que bateriam por engano em
# padrões mais genéricos abaixo (já aconteceu: "TIMEOUT" no usage sendo
# classificado como timeout de conexão). Isso não é um problema do device -
# é bug/uso incorreto do próprio script de automação.
CAUSA_PATTERNS = [
    (r"unrecognized arguments|^usage: ", "erro de chamada do script de automação (bug, não é problema do device - reportar)"),
    (r"authentication failed", "usuário/senha incorretos"),
    (r"auth fail", "usuário/senha incorretos"),
    (r"not enough permissions", "permissão insuficiente no RouterOS (policy do usuário)"),
    (r"connection refused", "porta incorreta ou serviço SSH desligado"),
    (r"no route to host|network is unreachable", "rede inacessível (roteamento/firewall)"),
    # Timeout especificamente ao ABRIR a conexão SSH (não durante um comando
    # já conectado) - se o .rsc deste mesmo host funcionou segundos antes na
    # mesma rodada, é forte indício de firewall/rate-limit anti-bruteforce no
    # RouterOS bloqueando uma 2a conexão nova em sequência rápida, não senha
    # errada nem timeout curto (ver routeros_binary_backup.py).
    (r"falha ao abrir conexão ssh", "conexão SSH nova sem resposta (suspeita de firewall/rate-limit anti-bruteforce no RouterOS - confira se o .rsc deste host funcionou segundos antes)"),
    (r"durante comando/download \(conexão já estava aberta\)", "timeout durante comando/SFTP já com a conexão aberta (RouterOS sobrecarregado ou conexão caiu no meio)"),
    # \b evita bater em "TIMEOUT" só porque aparece como nome de opção em
    # algum texto (ex.: usage: ... [--timeout TIMEOUT]) - exige a frase real
    # que paramiko/socket produzem numa falha de verdade.
    (r"\btimed out\b|\bread timeout\b", "sem resposta a tempo (timeout)"),
    (r"banner", "protocolo SSH incompatível (banner)"),
    (r"não apareceu no routeros a tempo", "RouterOS demorou demais pra gerar o arquivo .backup"),
    (r"ausente ou vazio|ausente ou menor", "arquivo baixado veio vazio/incompleto"),
    (r"não contém nenhum dos marcadores", "conteúdo do export não parece uma config válida do RouterOS"),
]

STATUS_LABELS = {
    "success": "OK",
    "backup_failed": "FALHA NO EXPORT (.rsc)",
    "integrity_failed": "FALHA DE INTEGRIDADE (.rsc)",
    "binary_backup_failed": "FALHA NO BACKUP BINÁRIO (.backup)",
    "binary_integrity_failed": "FALHA DE INTEGRIDADE (.backup)",
    "unreachable": "INACESSÍVEL",
    "unknown": "DESCONHECIDO",
}


def classify(status, error_text):
    # unreachable tem causa arquiteturalmente conhecida (connectivity_check.yml
    # só marca assim depois de testar TCP na porta principal E na 22
    # alternativa, ambas sem resposta) - não depende de regex na mensagem.
    if status == "unreachable":
        return "host não respondeu na rede (porta incorreta, firewall ou equipamento offline)"
    if not error_text:
        return "sem detalhe do erro"
    low = error_text.lower()
    for pattern, causa in CAUSA_PATTERNS:
        if re.search(pattern, low):
            return causa
    return "outro/desconhecido (ver mensagem original abaixo)"


def fmt_row(host):
    status = host.get("status", "unknown")
    label = STATUS_LABELS.get(status, status)
    ip = host.get("ip") or "sem IP"
    line = f"[{label}] {host['host']} [{ip}]"

    if status == "success":
        rsc_bytes = host.get("bytes", 0)
        bin_bytes = host.get("binary_bytes", 0)
        rsc_note = "alterado" if host.get("changed") else "sem mudança"
        bin_note = "alterado" if host.get("binary_changed") else "sem mudança"
        line += f"\n         .rsc OK ({rsc_bytes} bytes, {rsc_note}) | .backup OK ({bin_bytes} bytes, {bin_note})"
        return line

    causa = classify(status, host.get("error", ""))
    line += f"\n         causa provável: {causa}"
    if host.get("error"):
        line += f"\n         mensagem original: {host['error']}"

    # Mesmo com status de falha em etapa posterior (ex.: binary_backup_failed),
    # o .rsc pode ter sido salvo com sucesso - deixa isso claro, já que o
    # pipeline é sequencial (só chega no binário se o .rsc deu certo antes).
    if status in ("binary_backup_failed", "binary_integrity_failed") and host.get("file"):
        line += f"\n         obs.: export .rsc foi salvo normalmente antes desta etapa falhar ({host.get('bytes', 0)} bytes)"
    return line


def main():
    if len(sys.argv) != 3:
        sys.stderr.write("uso: build_human_report.py <log.json> <saida.txt>\n")
        sys.exit(1)

    log_path, out_path = sys.argv[1], sys.argv[2]
    with open(log_path, encoding="utf-8") as f:
        log = json.load(f)

    summary = log.get("summary", {})
    hosts = log.get("hosts", [])

    total = int(summary.get("total", len(hosts)))
    unreachable = int(summary.get("unreachable", 0))
    reachable = total - unreachable
    success = int(summary.get("success", 0))
    backup_failed = int(summary.get("backup_failed", 0))
    integrity_failed = int(summary.get("integrity_failed", 0))
    binary_backup_failed = int(summary.get("binary_backup_failed", 0))
    binary_integrity_failed = int(summary.get("binary_integrity_failed", 0))

    problemas = total - success
    status_geral = "OK - todos os hosts tiveram backup completo" if problemas == 0 else f"ATENÇÃO - {problemas} de {total} host(s) com algum problema"

    # Conta causas só dos hosts com problema (ignora sucesso).
    causa_counts = {}
    for h in hosts:
        if h.get("status") == "success":
            continue
        causa = classify(h.get("status"), h.get("error", ""))
        causa_counts[causa] = causa_counts.get(causa, 0) + 1

    lines = []
    lines.append("=" * 72)
    lines.append(" RELATÓRIO DA RODADA DE BACKUP - MIKROTIK")
    lines.append(f" Rodada: {summary.get('run_id', '?')}")
    lines.append(f" Início: {summary.get('started_at', '?')}")
    lines.append(f" Modo de inventário: {summary.get('inventory_mode', '?')}")
    lines.append("=" * 72)
    lines.append("")
    lines.append("RESUMO")
    lines.append("-" * 72)
    lines.append(f"Total de hosts no lote........................ {total}")
    pct_reach = f"{(reachable / total * 100):.0f}%" if total else "0%"
    lines.append(f"Alcançáveis (SSH respondeu)................... {reachable} ({pct_reach})")
    lines.append(f"Inacessíveis (porta não respondeu)............ {unreachable}")
    lines.append(f"Backup completo com sucesso (.rsc + .backup).. {success}")
    lines.append(f"Falha no export .rsc........................... {backup_failed}")
    lines.append(f"Falha de integridade do .rsc................... {integrity_failed}")
    lines.append(f"Falha no backup binário .backup................ {binary_backup_failed}")
    lines.append(f"Falha de integridade do .backup................ {binary_integrity_failed}")
    lines.append("")
    lines.append(f"STATUS GERAL: {status_geral}")
    lines.append("")

    if causa_counts:
        lines.append("CAUSAS DAS FALHAS (contagem por categoria)")
        lines.append("-" * 72)
        for causa, count in sorted(causa_counts.items(), key=lambda kv: -kv[1]):
            lines.append(f"{causa}: {count}")
        lines.append("")

    lines.append("DETALHE POR HOST")
    lines.append("-" * 72)
    if not hosts:
        lines.append("(nenhum host processado nesta rodada)")
    for h in hosts:
        lines.append(fmt_row(h))
        lines.append("")

    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines).rstrip() + "\n")

    print(f"[relatório] gravado em {out_path}")


if __name__ == "__main__":
    main()
