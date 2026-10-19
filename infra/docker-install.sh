#!/usr/bin/env bash
# OPTIONAL. Install Docker Engine on Ubuntu 24.04 from Docker's apt repo.
# Only needed to run Act 1 (Docker Compose) on a throwaway EC2 instance. Do NOT run it on the
# Kubernetes nodes: images pulled or built by Docker are invisible to Kubernetes, and it costs
# memory on 2 GiB workers. Act 1 normally runs on the instructor's laptop (Docker Desktop).
set -euo pipefail
sudo apt-get update -qq
sudo apt-get install -y -qq ca-certificates curl git
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update -qq
sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"
echo "Docker $(docker --version | awk '{print $3}') installed. Log out and back in (or: newgrp docker)."
