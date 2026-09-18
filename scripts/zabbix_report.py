#!/usr/bin/env python3
import json
import os
import socket
import struct
import sys
import time


def build_packet(payload: dict) -> bytes:
    body = json.dumps(payload).encode("utf-8")
    header = b"ZBXD\x01" + struct.pack("<q", len(body))
    return header + body


def recvall(sock: socket.socket, n: int) -> bytes:
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            break
        data += chunk
    return data


def send_to_zabbix(server: str, port: int, payload: dict, timeout: int) -> dict:
    packet = build_packet(payload)
    with socket.create_connection((server, port), timeout=timeout) as sock:
        sock.sendall(packet)
        resp_header = recvall(sock, 13)
        if resp_header[:4] != b"ZBXD":
            raise ValueError(f"resposta inesperada do Zabbix: {resp_header!r}")
        (resp_len,) = struct.unpack("<q", resp_header[5:13])
        resp_body = recvall(sock, resp_len)
    return json.loads(resp_body.decode("utf-8"))


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("uso: zabbix_report.py <log.json>\n")
        sys.exit(1)
    log_file = sys.argv[1]

    if os.environ.get("ZABBIX_ENABLED", "false").lower() != "true":
        print("[zabbix] ZABBIX_ENABLED != true; envio pro Zabbix desativado.")
        return

    server = os.environ.get("ZABBIX_SERVER", "")
    if not server:
        print("[zabbix] ZABBIX_SERVER não configurado; pulando envio.", file=sys.stderr)
        return

    port = int(os.environ.get("ZABBIX_PORT", "10051"))
    suffix = os.environ.get("ZABBIX_HOST_SUFFIX", "-INT")
    timeout = int(os.environ.get("ZABBIX_TIMEOUT_SECONDS", "15"))

    with open(log_file, encoding="utf-8") as f:
        log = json.load(f)

    now = int(time.time())
    items = []
    for h in log.get("hosts", []):
        zbx_host = f"{h['host']}{suffix}"
        status = h.get("status", "unknown")
        items.append({"host": zbx_host, "key": "mikrotik.backup.status", "value": status, "clock": now})
        # last_run é sempre atualizado (deu certo ou não) - responde "quando
        # foi a última tentativa"; last_success só atualiza em sucesso -
        # responde "quando foi o último backup bom de fato".
        items.append({"host": zbx_host, "key": "mikrotik.backup.last_run", "value": str(now), "clock": now})
        items.append({
            "host": zbx_host,
            "key": "mikrotik.backup.changed",
            "value": "1" if h.get("changed") else "0",
            "clock": now,
        })
        items.append({
            "host": zbx_host,
            "key": "mikrotik.backup.error",
            "value": h.get("error", "") if status != "success" else "",
            "clock": now,
        })
        if status == "success":
            items.append({
                "host": zbx_host,
                "key": "mikrotik.backup.last_success",
                "value": str(now),
                "clock": now,
            })

    if not items:
        print("[zabbix] nenhum host no log; nada a enviar.")
        return

    payload = {"request": "sender data", "data": items}

    # Best-effort: uma falha aqui não deve derrubar a rodada de backup, que
    # já terminou com sucesso antes desse envio de telemetria.
    try:
        result = send_to_zabbix(server, port, payload, timeout)
        print(f"[zabbix] {len(items)} valores enviados para {server}:{port} -> {result.get('info', result)}")
    except Exception as exc:
        sys.stderr.write(f"[zabbix] falha ao enviar dados para {server}:{port}: {exc}\n")


if __name__ == "__main__":
    main()
