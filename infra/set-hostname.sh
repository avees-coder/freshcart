#!/usr/bin/env bash
# Give an EC2 instance a stable, human-readable hostname BEFORE it joins a cluster.
# Swarm and kubeadm both register a node under its hostname; on EC2 that is
# otherwise ip-172-31-x-x, and cloud-init may reset it on every reboot.
# Usage: bash infra/set-hostname.sh swarm-mgr
set -euo pipefail
NAME="${1:?usage: set-hostname.sh <name>}"
sudo hostnamectl set-hostname "$NAME"
# stop cloud-init from restoring the EC2 default name at the next boot
echo "preserve_hostname: true" | sudo tee /etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg >/dev/null
# make the new name resolvable locally (avoids "sudo: unable to resolve host")
grep -q " $NAME\$" /etc/hosts || echo "127.0.1.1 $NAME" | sudo tee -a /etc/hosts >/dev/null
echo "hostname is now: $(hostname)"
