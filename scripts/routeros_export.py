#!/usr/bin/env python3
import argparse
import os
import sys

import paramiko


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=22)
    parser.add_argument("--user", required=True)
    parser.add_argument("--command", default="/export terse")
    parser.add_argument("--timeout", type=int, default=20)
    args = parser.parse_args()

    password = os.environ.get("MIKROTIK_SSH_PASSWORD", "")

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    try:
        client.connect(
            hostname=args.host,
            port=args.port,
            username=args.user,
            password=password,
            timeout=args.timeout,
            auth_timeout=args.timeout,
            banner_timeout=args.timeout,
            allow_agent=False,
            look_for_keys=False,
        )
        # exec_command não aloca PTY: RouterOS não aplica wrap de terminal no output.
        stdin, stdout, stderr = client.exec_command(args.command, timeout=args.timeout)
        output = stdout.read().decode("utf-8", errors="replace")
        err = stderr.read().decode("utf-8", errors="replace")
        exit_status = stdout.channel.recv_exit_status()
    except Exception as exc:
        sys.stderr.write(f"routeros_export: falha ao conectar/executar: {exc}\n")
        sys.exit(1)
    finally:
        client.close()

    if exit_status != 0 and not output.strip():
        sys.stderr.write(f"routeros_export: comando retornou status {exit_status}: {err}\n")
        sys.exit(1)

    sys.stdout.write(output)


if __name__ == "__main__":
    main()
