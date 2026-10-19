#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/user-data.log) 2>&1

echo "== Installing Java 21 =="
dnf update -y
dnf install -y java-21-amazon-corretto-headless unzip

echo "== Installing Docker =="
# AL2023 ships Docker directly in its own dnf repo — no extra repo/GPG setup
# needed (unlike Ubuntu's docker.com apt repo).
dnf install -y docker
systemctl enable --now docker

echo "== Preparing CloudBees CI Client Controller data volume =="
mkdir -p /var/lib/cloudbees-client-controller
chown -R 1000:1000 /var/lib/cloudbees-client-controller

echo "== Installing systemd unit for the Client Controller =="
cat > /etc/systemd/system/cloudbees-client-controller.service <<'UNIT'
[Unit]
Description=CloudBees CI Client Controller
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Restart=always
RestartSec=10
ExecStartPre=-/usr/bin/docker rm -f cloudbees-client-controller
ExecStart=/usr/bin/docker run --rm --name cloudbees-client-controller \
  -p ${controller_port}:8080 \
  -v /var/lib/cloudbees-client-controller:/var/jenkins_home \
  -e JAVA_OPTS="-Xmx2g" \
  ${controller_image}
ExecStop=/usr/bin/docker stop cloudbees-client-controller

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now cloudbees-client-controller.service

echo "== Bootstrap complete =="
