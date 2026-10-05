#!/usr/bin/env bash
# Run ONCE on k8s-cp after k8s-node-prep.sh. Prints the worker join command at the end.
set -euo pipefail
POD_CIDR="10.244.0.0/16"   # Flannel default
FLANNEL_URL="https://github.com/flannel-io/flannel/releases/download/v0.28.9/kube-flannel.yml"
LOCAL_PATH_URL="https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.35/deploy/local-path-storage.yaml"
METRICS_URL="https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.9.0/components.yaml"

sudo kubeadm config images pull
sudo kubeadm init --pod-network-cidr="${POD_CIDR}"

mkdir -p "$HOME/.kube"
sudo cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

echo "== CNI (pod network): Flannel"
kubectl apply -f "${FLANNEL_URL}"

echo "== storage: local-path provisioner (PVCs become directories on a node's disk)"
kubectl apply -f "${LOCAL_PATH_URL}"
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

echo "== metrics-server (needed by the HPA). Lab-only flag: kubelets use self-signed certs."
kubectl apply -f "${METRICS_URL}"
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

kubectl wait --for=condition=Ready node --all --timeout=240s
kubectl get nodes -o wide
echo
echo "== Run THIS on each worker (sudo):"
sudo kubeadm token create --print-join-command
