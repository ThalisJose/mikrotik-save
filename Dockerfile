FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        git openssh-client cron jq tzdata curl \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir ansible-core==2.17.* pynetbox paramiko pytz

WORKDIR /app

COPY requirements.yml .
RUN ansible-galaxy collection install -r requirements.yml

COPY . .
RUN chmod +x scripts/*.sh scripts/entrypoint.sh

ENV ANSIBLE_CONFIG=/app/ansible.cfg \
    PYTHONUNBUFFERED=1

VOLUME ["/app/backups", "/app/logs", "/app/cache"]

ENTRYPOINT ["/app/scripts/entrypoint.sh"]
CMD ["cron"]
