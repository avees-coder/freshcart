#!/usr/bin/env bash
# ZG527 auto-stop timer: the node powers itself off N hours after every boot.
#
# Why: the BITS lab portal session ends after 60 minutes but does NOT stop running instances,
# and each student has a USD 35 credit. A forgotten cluster costs about USD 0.06-0.09 per hour.
# EC2 treats a guest "shutdown" of an EBS-backed instance as STOP (the default), so the node stops
# (storage only is billed) and can be started again; its public IP changes, its private IP does not.
#
#   sudo bash infra/autostop.sh            install/refresh the timer, 4 hours (default)
#   sudo bash infra/autostop.sh 6          6 hours
#   sudo bash infra/autostop.sh off        remove the timer
#   systemctl show zg527-autostop -p ActiveEnterTimestamp     when the current timer started
#   sudo systemctl restart zg527-autostop                      restart the timer (extend by N hours)
#
# aws-lab.sh installs the same unit at first boot; k8s-node-prep.sh calls this script, so nodes
# launched by hand from the console are covered too. Safe to run repeatedly.
set -euo pipefail
ARG="${1:-${AUTOSTOP_HOURS:-4}}"
UNIT=/etc/systemd/system/zg527-autostop.service

if [[ "$EUID" -ne 0 ]]; then exec sudo -E bash "$0" "$@"; fi

if [[ "$ARG" == off || "$ARG" == 0 ]]; then
  systemctl disable --now zg527-autostop.service 2>/dev/null || true
  rm -f "$UNIT"; systemctl daemon-reload
  echo "auto-stop removed: this node will keep running until YOU stop it"
  exit 0
fi
[[ "$ARG" =~ ^[0-9]+$ ]] || { echo "usage: autostop.sh [hours|off]"; exit 1; }
SECS=$(( ARG * 3600 ))

cat >"$UNIT" <<EOF
[Unit]
Description=ZG527 lab auto-stop (credit protection)
[Service]
ExecStart=/bin/sh -c 'sleep ${SECS} && /sbin/shutdown -h now "ZG527 auto-stop"'
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable zg527-autostop.service >/dev/null 2>&1
systemctl restart zg527-autostop.service
echo "auto-stop armed: this node powers off ${ARG} h from now, and again ${ARG} h after every boot"
echo "restart the timer to extend:  sudo systemctl restart zg527-autostop"
