#!/usr/bin/env python3
import argparse
import os
import re
import sys
import time

import paramiko


def run(client, command, timeout):
    stdin, stdout, stderr = client.exec_command(command, timeout=timeout)
    out = stdout.read().decode("utf-8", errors="replace")
    err = stderr.read().decode("utf-8", errors="replace")
    rc = stdout.channel.recv_exit_status()
    return rc, out, err


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=22)
    parser.add_argument("--user", required=True)
    parser.add_argument("--output", required=True, help="Caminho local para salvar o .backup baixado")
    parser.add_argument("--name", default="ansible-backup", help="Nome do arquivo no RouterOS (sem extensão)")
    parser.add_argument("--timeout", type=int, default=60)
    args = parser.parse_args()

    ssh_password = os.environ.get("MIKROTIK_SSH_PASSWORD", "")
    # Senha de criptografia do backup - via env, nunca em argv (argv aparece
    # em texto puro no log do Ansible se a task falhar, mesmo sem no_log).
    backup_password = os.environ.get("MIKROTIK_BACKUP_PASSWORD", "")
    remote_file = f"{args.name}.backup"

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    try:
        client.connect(
            hostname=args.host,
            port=args.port,
            username=args.user,
            password=ssh_password,
            timeout=args.timeout,
            auth_timeout=args.timeout,
            banner_timeout=args.timeout,
            allow_agent=False,
            look_for_keys=False,
        )

        save_cmd = f"/system backup save name={args.name}"
        if backup_password:
            save_cmd += f' password="{backup_password}"'
        rc, out, err = run(client, save_cmd, args.timeout)
        if rc != 0:
            sys.stderr.write(f"routeros_binary_backup: falha ao salvar backup: {err or out}\n")
            sys.exit(1)

        # RouterOS grava o arquivo de forma assíncrona em alguns modelos; aguarda
        # ele aparecer com tamanho estável antes de baixar via SFTP.
        deadline = time.time() + args.timeout
        last_size = -1
        size = None
        while time.time() < deadline:
            rc, out, err = run(client, f'/file print terse where name="{remote_file}"', args.timeout)
            match = re.search(r"size=(\d+)", out)
            if match:
                size = int(match.group(1))
                if size == last_size and size > 0:
                    break
                last_size = size
            time.sleep(1)

        if not size:
            sys.stderr.write(f"routeros_binary_backup: arquivo {remote_file} não apareceu no RouterOS a tempo\n")
            sys.exit(1)

        sftp = client.open_sftp()
        try:
            sftp.get(remote_file, args.output)
        finally:
            try:
                sftp.remove(remote_file)
            except Exception:
                sys.stderr.write(f"routeros_binary_backup: aviso - não consegui remover {remote_file} do device\n")
            sftp.close()

    except Exception as exc:
        sys.stderr.write(f"routeros_binary_backup: falha ao conectar/executar: {exc}\n")
        sys.exit(1)
    finally:
        client.close()

    if not os.path.exists(args.output) or os.path.getsize(args.output) == 0:
        sys.stderr.write("routeros_binary_backup: arquivo baixado está ausente ou vazio\n")
        sys.exit(1)

    sys.stdout.write(f"{os.path.getsize(args.output)}\n")


if __name__ == "__main__":
    main()
