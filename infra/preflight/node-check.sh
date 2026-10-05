#!/usr/bin/env bash
# ZG527 account preflight, part 2 — run on TWO throwaway t3.small instances (Ubuntu 24.04)
# in the security group under test. Tests what dry-runs cannot: real egress to every
# download source the lab uses, and real node-to-node TCP/UDP traffic.
#
#   bash node-check.sh egress                 # on each instance: can it reach every source?
#   bash node-check.sh listen                 # on instance B: open listeners on cluster ports
#   bash node-check.sh probe <B-private-ip>   # on instance A: send to each port on B
#   bash node-check.sh report                 # on instance B: which ports received traffic?
#   sudo bash node-check.sh web               # serve port 80 and 30080; open both from your laptop
#   bash node-check.sh stop                   # on B: stop the listeners / web servers
set -uo pipefail
TCP_PORTS=(2377 7946 6443 10250 2379 2380)    # swarm mgmt, gossip, k8s API, kubelet, etcd
UDP_PORTS=(4789 7946 8472)                     # swarm VXLAN, gossip, flannel VXLAN
LOG=/tmp/zg527-preflight; mkdir -p "$LOG"

egress() {
  # Each source must return the code a REAL endpoint returns. A filtering proxy usually
  # answers 403/407 instead — counting "any answer" as success would hide exactly that.
  local fails=0
  local ACC='Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json'
  check() {   # check <label> <expected codes, e.g. 200|401> <url> [extra curl args...]
    local label="$1" want="$2" url="$3"; shift 3
    local code; code=$(curl -s -L -o /dev/null -m 20 -w '%{http_code}' "$@" "$url")
    if [[ "$code" =~ ^(${want})$ ]]; then printf '  PASS  %-36s HTTP %s\n' "$label" "$code"
    else printf '  FAIL  %-36s HTTP %s (expected %s)  %s\n' "$label" "$code" "$want" "$url"; fails=$((fails+1)); fi
  }
  token() {   # anonymous pull token from a registry token service
    curl -s -m 20 "$1" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))' 2>/dev/null
  }
  echo "== Egress from $(hostname) ($(hostname -I | awk '{print $1}'))"
  check "Ubuntu apt mirror"                200     "http://ap-south-1.ec2.archive.ubuntu.com/ubuntu/dists/noble/Release"
  check "GitHub (git clone)"               200     "https://github.com"
  check "Docker apt repo key"              200     "https://download.docker.com/linux/ubuntu/gpg"
  check "Kubernetes v1.36 apt repo key"    200     "https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key"
  check "Docker Hub registry API"          401     "https://registry-1.docker.io/v2/"
  T=$(token "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/redis:pull")
  if [[ -n "$T" ]]; then
    check "Docker Hub: redis:8-alpine manifest" 200 "https://registry-1.docker.io/v2/library/redis/manifests/8-alpine" -H "Authorization: Bearer $T" -H "$ACC"
  else printf '  FAIL  %-36s no token from auth.docker.io\n' "Docker Hub auth"; fails=$((fails+1)); fi
  check "registry.k8s.io: pause:3.10.2"    "200|401"     "https://registry.k8s.io/v2/pause/manifests/3.10.2" -H "$ACC"
  check "ghcr.io registry API"             401     "https://ghcr.io/v2/"
  if [[ -n "${GHCR_OWNER:-}" ]]; then
    T=$(token "https://ghcr.io/token?scope=repository:${GHCR_OWNER}/freshcart-api:pull")
    if [[ -n "$T" ]]; then
      check "ghcr.io: freshcart-api:v1 (public?)" 200 "https://ghcr.io/v2/${GHCR_OWNER}/freshcart-api/manifests/v1" -H "Authorization: Bearer $T" -H "$ACC"
    else printf '  FAIL  %-36s no anonymous token: package private or name wrong\n' "ghcr.io freshcart-api"; fails=$((fails+1)); fi
  else echo "  SKIP  ghcr.io freshcart images (run with GHCR_OWNER=<owner> to test them)"; fi
  check "Flannel v0.28.9 manifest"         200     "https://github.com/flannel-io/flannel/releases/download/v0.28.9/kube-flannel.yml"
  check "metrics-server v0.9.0 manifest"   200     "https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.9.0/components.yaml"
  check "local-path v0.0.35 manifest"      200     "https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.35/deploy/local-path-storage.yaml"
  echo "  NOTE  image layers come from CDNs (Cloudflare for Docker Hub, GitHub for ghcr.io);"
  echo "        the real-pull test in the runbook (P0.4) is the final proof"
  (( fails == 0 )) && echo "RESULT: egress OK" || echo "RESULT: ${fails} source(s) blocked or misbehaving — 403/407 usually means a filtering proxy"
}

listen() {
  stop >/dev/null 2>&1
  for p in "${TCP_PORTS[@]}"; do nohup nc -lk "$p" </dev/null >"$LOG/tcp-$p.log" 2>&1 & echo $! >>"$LOG/pids"; done
  for p in "${UDP_PORTS[@]}"; do nohup nc -luk "$p" </dev/null >"$LOG/udp-$p.log" 2>&1 & echo $! >>"$LOG/pids"; done
  sleep 1
  echo "Listening on $(hostname -I | awk '{print $1}'): TCP ${TCP_PORTS[*]} | UDP ${UDP_PORTS[*]}"
  echo "Now run on the other instance:  bash node-check.sh probe $(hostname -I | awk '{print $1}')"
}

probe() {
  local peer="${1:?usage: node-check.sh probe <peer-private-ip>}"; local fails=0
  echo "== TCP from $(hostname) to $peer"
  for p in "${TCP_PORTS[@]}"; do
    if nc -z -w3 "$peer" "$p" 2>/dev/null; then echo "  PASS  tcp/$p"; else echo "  FAIL  tcp/$p"; fails=$((fails+1)); fi
  done
  echo "== UDP from $(hostname) to $peer (sent; confirm with 'report' on the peer)"
  for p in "${UDP_PORTS[@]}"; do echo "zg527-udp-$p" | nc -u -w1 "$peer" "$p"; echo "  SENT  udp/$p"; done
  (( fails == 0 )) && echo "RESULT: TCP OK — now run 'bash node-check.sh report' on $peer" || echo "RESULT: ${fails} TCP port(s) blocked — check the self-referencing SG rule and NACLs"
}

report() {
  echo "== UDP received on $(hostname)"
  local fails=0
  for p in "${UDP_PORTS[@]}"; do
    if grep -q "zg527-udp-$p" "$LOG/udp-$p.log" 2>/dev/null; then echo "  PASS  udp/$p"; else echo "  FAIL  udp/$p"; fails=$((fails+1)); fi
  done
  (( fails == 0 )) && echo "RESULT: UDP OK (overlay networks will work)" || echo "RESULT: UDP blocked — Swarm overlay and Flannel will NOT work"
}

web() {
  [[ $EUID -eq 0 ]] || { echo "run with sudo (port 80)"; exit 1; }
  mkdir -p "$LOG/www"; echo "ZG527 preflight: reached $(hostname)" >"$LOG/www/index.html"
  for port in 80 30080; do
    nohup python3 -m http.server "$port" --directory "$LOG/www" </dev/null >"$LOG/web$port.log" 2>&1 &
    echo $! >>"$LOG/pids"
  done
  sleep 1
  PUB=$(curl -s -m 3 -H "X-aws-ec2-metadata-token: $(curl -s -m 3 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" http://169.254.169.254/latest/meta-data/public-ipv4)
  [[ "$PUB" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || PUB="<public-ip>"
  echo "Open from your laptop:  http://${PUB}/   and   http://${PUB}:30080/"
  echo "(80 needs the Swarm SG rule, 30080 the Kubernetes SG rule — only one will answer per SG)"
}

stop() {   # kill only the processes this script started (PIDs recorded in $LOG/pids)
  if [[ -f "$LOG/pids" ]]; then xargs -r kill 2>/dev/null <"$LOG/pids"; rm -f "$LOG/pids"; fi
  echo "stopped"
}

case "${1:-}" in
  egress) egress ;; listen) listen ;; probe) probe "${2:-}" ;; report) report ;; web) web ;; stop) stop ;;
  *) sed -n '2,13p' "$0"; exit 1 ;;
esac
