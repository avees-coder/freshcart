# FreshCart — a mock quick-commerce app for learning container orchestration

FreshCart is a small "groceries in 10 minutes" shop used in **ZG527 Cloud Computing** to show *why* teams move
from Docker on one host → Kubernetes. The same four containers run in both acts; only the platform changes.
(Docker Swarm is covered in the course as a concept only; its stack file is kept in `reference/swarm/`.)

```
 Browser ──► web  (Vite + React build, served by nginx; nginx proxies /api)
              │
              ▼
             api  (Node.js + Express: catalog, cart, orders)  ──►  redis    (cart sessions)
                                                               ──►  postgres (products, orders)
```

| Component | Image | State? | Why it matters for orchestration |
|---|---|---|---|
| `web` | `ghcr.io/<owner>/freshcart-web` | none | Scales freely; finds the API through cluster DNS |
| `api` | `ghcr.io/<owner>/freshcart-api` | none (if `CART_STORE=redis`) | The service we scale, crash, and roll out |
| `redis` | `redis:8-alpine` | disposable | Moves cart state *out* of the API so any replica can serve any user |
| `postgres` | `postgres:17-alpine` | **durable** | The part orchestrators cannot simply move — the lesson about state |

The **Ops panel** at the bottom of the page shows which `web` and `api` replica answered, the API version,
the sale %, and the cart store. "Send 20 requests" tallies replicas and versions — this is how students
*see* load balancing, rolling updates and the vanishing-cart bug.

## Repository layout

```
api/                     Node.js API + Dockerfile
web/                     Vite + React storefront, nginx config, multi-stage Dockerfile
db/init.sql              Schema + seed data (runs once on an empty database)
docker-compose.yml       Act 1: one host
deploy/k8s/              Act 2: Kubernetes (kubectl apply -k deploy/k8s)
infra/                   EC2 launcher (aws-lab.sh), auto-stop timer, Kubernetes node prep, control-plane init, hostname helper, preflight/
reference/swarm/         Docker Swarm stack file - NOT part of the lab, kept for reference
scripts/load.sh          CPU load generator for the autoscaling demo
.github/workflows/       Builds both images and pushes them to ghcr.io on every v* tag
```

## Environment variables (API)

| Variable | Default | Purpose |
|---|---|---|
| `DB_HOST` / `DB_PORT` / `DB_NAME` / `DB_USER` | `db` / `5432` / `freshcart` / `freshcart` | PostgreSQL connection |
| `DB_PASSWORD` or `DB_PASSWORD_FILE` | `freshcart` | `_FILE` wins (Docker/Swarm secrets arrive as files); Kubernetes passes `DB_PASSWORD` from a Secret |
| `CART_STORE` | `memory` | `memory` breaks as soon as there is more than one replica; `redis` fixes it |
| `REDIS_URL` | `redis://redis:6379` | Used when `CART_STORE=redis` |
| `SALE_PERCENT` | `0` | The "festive sale" we roll out live |
| `CHAOS_ENABLED` | `false` | Enables `/api/chaos/crash` and `/api/chaos/burn`. **Classroom only** — turn off if the URL is public |
| `APP_VERSION` | `dev` | Baked in at build time from the git tag |

API endpoints: `/api/healthz` (liveness), `/api/ready` (readiness — needs the DB), `/api/info`, `/api/products`,
`/api/cart` (GET/POST/DELETE, keyed by the `X-Cart-Id` header), `/api/orders` (POST), `/api/orders/recent`.

---

## 0. One-time setup: source on GitHub, images on GHCR

> Laptop commands in this section work in bash, Git Bash and PowerShell alike (one command per line).
> Windows PowerShell 5.1 does not accept `&&`. Keep the clone outside OneDrive.

1. Create a GitHub repository (public is simplest) and push this folder to it.
2. Tag a release; the workflow builds and pushes both images:
   ```bash
   git tag v1
   git push origin v1
   ```
3. On GitHub → your profile → **Packages**, open `freshcart-api` and `freshcart-web` → Package settings →
   Danger Zone → Change visibility → **Public** (web UI only: GitHub has no API or CLI command for this) so the EC2 nodes can pull without credentials. (Private packages need an `imagePullSecret` in Kubernetes.)
4. Note your **lowercase** GitHub owner name — ghcr.io rejects uppercase. Below it is `<owner>`.

No CI? Build and push by hand from any machine with Docker:
```bash
echo <token> | docker login ghcr.io -u <owner> --password-stdin   # token with write:packages
docker build -t ghcr.io/<owner>/freshcart-api:v1 --build-arg APP_VERSION=v1 api
docker build -t ghcr.io/<owner>/freshcart-web:v1 --build-arg APP_VERSION=v1 web
docker push ghcr.io/<owner>/freshcart-api:v1
docker push ghcr.io/<owner>/freshcart-web:v1
```

## AWS lab topology (BITS lab: region ap-south-1, instance types t3a only, Ubuntu 24.04 LTS, 20 GiB gp3 root volume)

| Instance name | Type | Role |
|---|---|---|
| `k8s-cp` | t3a.medium | Control plane (kubeadm needs ≥ 2 vCPU, ≥ 1.7 GB; the extra memory carries etcd + metrics-server) |
| `k8s-w1`, `k8s-w2` | t3a.small | Workers |

Six vCPUs in total. The BITS account allows only `t3a.nano/micro/small/medium`; `nano` and `micro` are too small for kubeadm.
Do **not** install Docker Engine on these nodes: Kubernetes uses containerd directly, images pulled by Docker are
invisible to it, and 2 GiB workers cannot spare the memory.

**Security group** (one, `zg527-k8s`):

| Inbound rule | Source | Why |
|---|---|---|
| All traffic | the security group itself | Node-to-node: API server 6443, kubelet 10250, Flannel VXLAN 8472/udp, NodePorts |
| 22/tcp | your IP | SSH (or use SSM Session Manager and skip this) |
| 30080/tcp | your IP, or 0.0.0.0/0 during class | The storefront. If public, set `CHAOS_ENABLED=false` |

**Scripted launch (recommended):** `infra/aws-lab.sh` creates the security group and all three instances, with
hostnames set, this repository cloned, tmux installed and the auto-stop timer armed:
```bash
KEY_NAME=zg527-aps1 MY_IP=<laptop public IP> REPO_URL=https://github.com/<owner>/freshcart.git bash infra/aws-lab.sh up
bash infra/aws-lab.sh status      # IPs and ready-made ssh commands
bash infra/aws-lab.sh stop        # END OF EVERY SITTING
bash infra/aws-lab.sh down        # terminate everything (asks to confirm)
```
If you launch by hand instead: **Name every instance before it joins the cluster** — kubeadm registers nodes under the OS
hostname (otherwise `ip-172-31-x-x`), and the commands below use these names:
```bash
bash infra/set-hostname.sh k8s-cp        # on each instance, with its own name (k8s-cp, k8s-w1, k8s-w2)
```

### The lab account has three habits you must design around

| Fact | What to do |
|---|---|
| Each student has USD 35 of credit. Three nodes left running cost about USD 0.06–0.07 per hour; the credit lasts about 3 weeks of 24×7 | **Stop all three nodes at the end of every sitting** (`bash infra/aws-lab.sh stop`, or the console). A stopped node costs storage only |
| The lab portal session ends after 60 minutes **and does not stop running instances** | Every node powers itself off 4 hours after boot (`infra/autostop.sh`). Restart the timer to extend: `sudo systemctl restart zg527-autostop`. Never rely on the portal to clean up |
| The portal session, CloudShell and any browser console end with it | Run long steps inside `tmux new -s lab` on the node, over SSH from your own terminal; re-attach with `tmux attach -t lab` |

After a stop/start the **public** IPs change; the private IPs (which the cluster uses) do not, so the cluster comes back by itself.

---

## Act 1 — One host with Docker Compose (your laptop, Docker Desktop)

```bash
git clone https://github.com/<owner>/freshcart.git && cd freshcart
docker compose up -d --build            # WEB_PORT=8080 docker compose up -d --build   if port 80 is taken
docker compose ps
# open http://localhost/   (or :8080)
```
It works. Now ask: what happens when this host reboots, the API crashes, or traffic triples at 7 pm?
`docker compose up --scale api=3` only adds containers on the **same** machine.
Clean up: `docker compose down -v`.

(On a throwaway EC2 host instead: `bash infra/docker-install.sh`, reconnect, and open `http://<public-ip>/` — port 80 must be open.
Never on a Kubernetes node.)

## Act 2 — Kubernetes on three nodes (kubeadm)

**Before class** (≈ 20 min; run inside tmux — the portal session may end before it finishes):
```bash
# on k8s-cp, k8s-w1, k8s-w2
tmux new -s lab
bash infra/k8s-node-prep.sh
# on k8s-cp only — prints a join command at the end
bash infra/k8s-control-plane-init.sh
# on k8s-w1: run the printed join command with sudo
```
**Live**: run the join command on `k8s-w2`, then on `k8s-cp`: `kubectl get nodes -o wide` (3 nodes Ready).
A fresh token: `sudo kubeadm token create --print-join-command`.

**2.1 Deploy** — on `k8s-cp`, inside the cloned repo:
```bash
sed -i 's/CHANGE-ME/<owner>/' deploy/k8s/kustomization.yaml
sed -i 's/change-me-before-class/<a-password>/' deploy/k8s/10-config.yaml
kubectl apply -k deploy/k8s
kubectl -n freshcart get pods -o wide -w     # Ctrl-C when all are Running/Ready
kubectl -n freshcart get svc,pvc
```
Open `http://<public-ip-of-any-node>:30080/`.

**2.2 What `apply` set in motion**:
```bash
kubectl -n freshcart get deploy,rs,pods -l app=api
kubectl -n freshcart describe pod -l app=api | grep -A8 Events
kubectl -n freshcart get endpointslices -l kubernetes.io/service-name=api
```

**2.3 Self-healing** — Ops panel → **Crash one API replica**:
```bash
kubectl -n freshcart get pods -l app=api     # RESTARTS goes up: the kubelet restarted the container in place
kubectl -n freshcart delete $(kubectl -n freshcart get pod -l app=api -o name | head -1)   # one pod replaced, new name
```

**2.4 Readiness — alive is not the same as ready**:
```bash
kubectl -n freshcart scale statefulset postgres --replicas=0
kubectl -n freshcart get pods -l app=api                  # READY 0/1 — alive, but taken out of the Service
kubectl -n freshcart get endpointslices -l kubernetes.io/service-name=api   # no endpoints
kubectl -n freshcart scale statefulset postgres --replicas=1
```

**2.5 Festive sale rollout and undo**:
```bash
kubectl -n freshcart set env deployment/api SALE_PERCENT=20
kubectl -n freshcart rollout status deployment/api
kubectl -n freshcart rollout undo deployment/api
```
Note: editing the ConfigMap alone does **not** restart pods; env vars are read at container start.

**2.6 Autoscaling for the 7 pm rush**:
```bash
kubectl apply -f deploy/k8s/60-hpa.yaml
kubectl -n freshcart get hpa -w
# from your laptop:
bash scripts/load.sh http://<node-public-ip>:30080 180 20
```
Replicas climb toward 8; about five minutes after the load stops they scale back down.

**2.7 How much room is left on a node** (links to exam question C3(c)):
```bash
kubectl describe node k8s-w1 | grep -A9 "Allocated resources"
kubectl apply -f deploy/k8s/extras/requests-demo.yaml     # 8 x 250m, all pinned to k8s-w1
kubectl get pods -l app=cpu-reserve -o wide               # some Running, the rest Pending
kubectl delete -f deploy/k8s/extras/requests-demo.yaml
```

**2.8 Drain a node — and the database again**:
```bash
kubectl get pods -n freshcart -o wide | grep postgres     # note its node
kubectl drain <that-node> --ignore-daemonsets --delete-emptydir-data
kubectl -n freshcart get pods -o wide                     # postgres-0 Pending: its local-path volume is tied to that node
kubectl uncordon <that-node>
```
Production answer: network storage (EBS CSI driver) or a managed database (Amazon RDS).

Teardown: `kubectl delete -k deploy/k8s` and `kubectl delete -f deploy/k8s/60-hpa.yaml`, or simply
terminate the three instances.

---

## Local development (no containers, bash shell)

```bash
# terminal 1 — needs a local PostgreSQL loaded with db/init.sql (and Redis if CART_STORE=redis)
cd api && npm ci && DB_HOST=127.0.0.1 CHAOS_ENABLED=true npm start
# terminal 2
cd web && npm ci && npm run dev        # http://localhost:5173 — Vite proxies /api to :3000
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Pod `ErrImagePull` / `ImagePullBackOff` | Image not in a registry, wrong owner in `kustomization.yaml`, or package private | Push to ghcr.io; set the package Public; `kubectl -n freshcart describe pod <pod>` shows the exact error |
| Storefront shows "Catalog unavailable" for the first ~20 s | Postgres initialising; API retrying | Wait — that retry loop is the point: orchestrators do not enforce start order |
| Web returns 502 on `/api` in Kubernetes | `API_HOST` is the short name `api` | Must be `api.freshcart.svc.cluster.local` (nginx resolver ignores search domains) |
| `postgres-0` Pending, PVC Pending | No `local-path` StorageClass | Re-run the local-path part of `infra/k8s-control-plane-init.sh` |
| HPA shows `<unknown>` targets | metrics-server not ready | `kubectl -n kube-system get pods -l k8s-app=metrics-server`; wait 60 s |
| Nodes NotReady | No CNI, or node-to-node traffic blocked | Check Flannel pods; security group must allow all traffic from itself |
| Database password changed but old one still used | Postgres initialises credentials only on an empty volume | Remove the volume / PVC, then redeploy |
| Console logged you out; cluster seems gone | The portal session ended (60 min). Instances keep running | Sign in again from the portal; the nodes are untouched. Use SSH + tmux for anything long |
| A node is stopped and nobody stopped it | The auto-stop timer fired (4 h after boot) | Start it; the timer restarts at boot. To extend: `sudo systemctl restart zg527-autostop`; to remove: `sudo bash infra/autostop.sh off` |
| After a start, SSH to the old IP times out | Public IPs change on every stop/start | `bash infra/aws-lab.sh status` (or the console) for the new ones; the cluster uses private IPs and is unaffected |
| `kubectl` refused / hangs just after a start | The API server static pod is still starting | Wait ~2 minutes; `sudo crictl ps` on `k8s-cp` |
