#!/usr/bin/env bash
# Prepare ONE Kubernetes node (run on k8s-cp, k8s-w1 and k8s-w2) — Ubuntu 24.04.
# Installs containerd (CRI runtime) + kubeadm/kubelet/kubectl. No Docker Engine needed.
set -euo pipefail
K8S_MINOR="${K8S_MINOR:-v1.36}"     # check https://kubernetes.io/releases before class

echo "== swap off (kubelet refuses to start with swap on by default)"
sudo swapoff -a
sudo sed -i.bak '/\sswap\s/ s/^#*/#/' /etc/fstab

echo "== kernel modules + sysctl (pod traffic crosses a bridge and must pass iptables)"
printf "overlay\nbr_netfilter\n" | sudo tee /etc/modules-load.d/k8s.conf >/dev/null
sudo modprobe overlay
sudo modprobe br_netfilter
printf "net.bridge.bridge-nf-call-iptables  = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward                 = 1\n" \
  | sudo tee /etc/sysctl.d/k8s.conf >/dev/null
sudo sysctl --system >/dev/null

echo "== containerd from Docker's repo, CRI enabled, systemd cgroups"
sudo apt-get update -qq
sudo apt-get install -y -qq ca-certificates curl gpg apt-transport-https
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update -qq
sudo apt-get install -y -qq containerd.io
sudo mkdir -p /etc/containerd
# The packaged config ships with disabled_plugins = ["cri"]; regenerate a full default.
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep -q 'SystemdCgroup = true' /etc/containerd/config.toml || echo "WARN: check SystemdCgroup in /etc/containerd/config.toml"
sudo systemctl restart containerd
sudo systemctl enable containerd

echo "== kubeadm / kubelet / kubectl ${K8S_MINOR} from pkgs.k8s.io"
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
  | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
sudo apt-get update -qq
sudo apt-get install -y -qq kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet     # crash-loops until init/join — expected
sudo crictl config --set runtime-endpoint=unix:///run/containerd/containerd.sock \
                   --set image-endpoint=unix:///run/containerd/containerd.sock
echo "node prepared: kubeadm $(kubeadm version -o short)"
