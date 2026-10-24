#!/usr/bin/env bash
# Runs on every VM boot (instance template metadata: startup-script).
# Pulls the app bundle from Cloud Storage, installs it and starts gunicorn under systemd.
set -euo pipefail

md() { curl -fs -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/$1"; }
BUCKET="$(md instance/attributes/app-bucket)"
APP_DIR=/opt/inventory

if ! systemctl is-active --quiet inventory; then
  apt-get update -y
  apt-get install -y python3-venv python3-pip
  mkdir -p "$APP_DIR"
  gcloud storage cp "gs://${BUCKET}/app.tar.gz" /tmp/app.tar.gz
  tar -xzf /tmp/app.tar.gz -C "$APP_DIR"
  python3 -m venv "$APP_DIR/venv"
  "$APP_DIR/venv/bin/pip" install --quiet -r "$APP_DIR/requirements.txt"

  cat >/etc/systemd/system/inventory.service <<UNIT
[Unit]
Description=Inventory API
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/venv/bin/gunicorn --bind 0.0.0.0:8080 --workers 2 --threads 4 --timeout 30 main:app
Restart=always
User=nobody

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now inventory
fi
