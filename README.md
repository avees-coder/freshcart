# FreshCart — a mock quick-commerce app for learning container orchestration

FreshCart is a small "groceries in 10 minutes" shop used in **ZG527 Cloud Computing** to show *why* teams move
from Docker on one host → Docker Swarm → Kubernetes. The same four containers run in all three acts; only
the platform changes.

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
deploy/swarm/stack.yml   Act 2: 3-node Swarm
deploy/k8s/              Act 3: Kubernetes (kubectl apply -k deploy/k8s)
infra/                   EC2 bootstrap: Docker install, Kubernetes node prep, control-plane init
scripts/load.sh          CPU load generator for the autoscaling demo
.github/workflows/       Builds both images and pushes them to ghcr.io on every v* tag
```

## Environment variables (API)

| Variable | Default | Purpose |
|---|---|---|
| `DB_HOST` / `DB_PORT` / `DB_NAME` / `DB_USER` | `db` / `5432` / `freshcart` / `freshcart` | PostgreSQL connection |
| `DB_PASSWORD` or `DB_PASSWORD_FILE` | `freshcart` | `_FILE` wins — that is how Swarm secrets arrive |
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
   Danger Zone → Change visibility → **Public** (web UI only: GitHub has no API or CLI command for this) so the EC2 nodes can pull without credentials. (Private packages need `docker login ghcr.io`
   on every Swarm node, or an `imagePullSecret` in Kubernetes.)
4. Note your **lowercase** GitHub owner name — ghcr.io rejects uppercase. Below it is `<owner>`.

No CI? Build and push by hand from any machine with Docker:
```bash
echo <token> | docker login ghcr.io -u <owner> --password-stdin   # token with write:packages
docker build -t ghcr.io/<owner>/freshcart-api:v1 --build-arg APP_VERSION=v1 api
docker build -t ghcr.io/<owner>/freshcart-web:v1 --build-arg APP_VERSION=v1 web
docker push ghcr.io/<owner>/freshcart-api:v1
docker push ghcr.io/<owner>/freshcart-web:v1
```

## AWS lab topology (one region of your choice — ap-south-1 or us-east-1 — Ubuntu 24.04 LTS, 20 GiB gp3 root volume)

| Cluster | Instance name | Type | Role |
|---|---|---|---|
| Swarm | `swarm-mgr` | t3.small | Manager (also runs tasks; hosts the database) |
| Swarm | `swarm-w1`, `swarm-w2` | t3.small | Workers |
| Kubernetes | `k8s-cp` | t3.medium | Control plane (kubeadm needs ≥ 2 vCPU, ≥ 2 GB) |
| Kubernetes | `k8s-w1`, `k8s-w2` | t3.small | Workers |

Keep the two clusters on separate instances: Swarm's overlay address pool (10.0.0.0/8) and Flannel's pod
network (10.244.0.0/16) overlap, and two orchestrators on one 2 GiB node fight for memory.

**Security group** (one per cluster):

| Inbound rule | Source | Why |
|---|---|---|
| All traffic | the security group itself | Node-to-node: Swarm 2377/tcp, 7946/tcp+udp, 4789/udp · Kubernetes 6443, 10250, Flannel VXLAN 8472/udp |
| 22/tcp | your IP | SSH (or use SSM Session Manager and skip this) |
| 80/tcp (Swarm) or 30080/tcp (Kubernetes) | your IP, or 0.0.0.0/0 during class | The storefront. If public, set `CHAOS_ENABLED=false` |

**Name every instance before it joins a cluster** — Swarm and kubeadm register nodes under the OS hostname
(otherwise `ip-172-31-x-x`), and the commands below use the names above:
```bash
bash infra/set-hostname.sh swarm-mgr     # on each instance, with its own name
```

**Stop or terminate all six instances after class.**

---

## Act 1 — One host with Docker Compose (any one instance)

```bash
git clone https://github.com/<owner>/freshcart.git && cd freshcart
docker compose up -d --build
docker compose ps
# open http://<public-ip>/
```
It works. Now ask: what happens when this host reboots, the API crashes, or traffic triples at 7 pm?
`docker compose up --scale api=3` only adds containers on the **same** machine.

If you ran Act 1 on `swarm-mgr`, free port 80 before Act 2: `docker compose down -v`.

## Act 2 — Docker Swarm on three nodes

On **all three** Swarm instances: `bash infra/docker-install.sh` (then log out/in).

**2.1 Form the cluster** — on `swarm-mgr`:
```bash
docker swarm init --advertise-addr $(hostname -I | awk '{print $1}')
# copy the printed "docker swarm join ..." and run it with sudo on swarm-w1 and swarm-w2
docker node ls                       # 1 Leader + 2 workers, all Ready
```

**2.2 Why a registry** (optional, 2 min) — on `swarm-mgr`:
```bash
docker build -t freshcart-api:local api
docker service create -d --name probe --replicas 3 freshcart-api:local   # -d: don't wait (it never converges)
docker service ps probe              # tasks on workers: "No such image"
docker service rm probe
```
The image exists only on the manager's disk. Every node must be able to *pull* it.

**2.3 Deploy the stack** — on `swarm-mgr`, inside the cloned repo:
```bash
export GHCR_OWNER=<owner> TAG=v1
openssl rand -hex 16 > deploy/swarm/db_password.txt
docker node update --label-add db=true swarm-mgr
docker stack deploy -c deploy/swarm/stack.yml freshcart
docker stack services freshcart
docker stack ps freshcart --format '{{.Name}}\t{{.Node}}\t{{.CurrentState}}'
```
Open `http://<public-ip-of-ANY-node>/` — try all three. The routing mesh answers on every node.

**2.4 The vanishing cart** — add a few items. The cart panel says "Loaded from API replica X" and sometimes
shows an empty cart. Each of the three replicas keeps its own carts in memory. Fix it without rebuilding:
```bash
docker service update --env-add CART_STORE=redis freshcart_api
```

**2.5 The 7 pm rush** — scale out and see the spread:
```bash
docker service scale freshcart_api=6
docker service ps freshcart_api --filter desired-state=running --format '{{.Name}}\t{{.Node}}'
```

**2.6 Self-healing** — Ops panel → **Crash one API replica**, then:
```bash
docker service ps freshcart_api      # one task Failed, a new one Running
```

**2.7 Festive sale, rolled out live** — while it runs, press "Send 20 requests" repeatedly:
```bash
docker service update --env-add SALE_PERCENT=20 freshcart_api
```
"Version seen" shows *both* `sale 0%` and `sale 20%` mid-rollout: two versions serve users at the same
time. Then undo it: `docker service rollback freshcart_api`.

**2.8 A node dies** — stop `swarm-w2` from the EC2 console, wait ~30 s:
```bash
docker node ls                       # swarm-w2: Down
docker service ps freshcart_api --filter desired-state=running --format '{{.Name}}\t{{.Node}}'
```
**2.9 The database cannot move** — drain the node holding it:
```bash
docker node update --availability drain swarm-mgr
docker service ps freshcart_db       # Pending: "no suitable node" — the data lives on swarm-mgr's disk
docker node update --availability active swarm-mgr
```
While the database is down, Swarm keeps routing traffic to API replicas that cannot serve the catalog:
its health check can say "alive" but cannot say "alive but not ready". Kubernetes separates the two.

Teardown: `docker stack rm freshcart`; on workers `docker swarm leave`; on manager `docker swarm leave --force`.

## Act 3 — Kubernetes on three nodes (kubeadm)

**Before class** (≈ 20 min):
```bash
# on k8s-cp, k8s-w1, k8s-w2
bash infra/k8s-node-prep.sh
# on k8s-cp only — prints a join command at the end
bash infra/k8s-control-plane-init.sh
# on k8s-w1: run the printed join command with sudo
```
**Live**: run the join command on `k8s-w2`, then on `k8s-cp`: `kubectl get nodes -o wide` (3 nodes Ready).
A fresh token: `sudo kubeadm token create --print-join-command`.

**3.1 Deploy** — on `k8s-cp`, inside the cloned repo:
```bash
sed -i 's/CHANGE-ME/<owner>/' deploy/k8s/kustomization.yaml
sed -i 's/change-me-before-class/<a-password>/' deploy/k8s/10-config.yaml
kubectl apply -k deploy/k8s
kubectl -n freshcart get pods -o wide -w     # Ctrl-C when all are Running/Ready
kubectl -n freshcart get svc,pvc
```
Open `http://<public-ip-of-any-node>:30080/`.

**3.2 What `apply` set in motion**:
```bash
kubectl -n freshcart get deploy,rs,pods -l app=api
kubectl -n freshcart describe pod -l app=api | grep -A8 Events
kubectl -n freshcart get endpointslices -l kubernetes.io/service-name=api
```

**3.3 Self-healing** — Ops panel → **Crash one API replica**:
```bash
kubectl -n freshcart get pods -l app=api     # RESTARTS goes up: the kubelet restarted the container in place
kubectl -n freshcart delete $(kubectl -n freshcart get pod -l app=api -o name | head -1)   # one pod replaced, new name
```

**3.4 Readiness — the thing Swarm could not express**:
```bash
kubectl -n freshcart scale statefulset postgres --replicas=0
kubectl -n freshcart get pods -l app=api                  # READY 0/1 — alive, but taken out of the Service
kubectl -n freshcart get endpointslices -l kubernetes.io/service-name=api   # no endpoints
kubectl -n freshcart scale statefulset postgres --replicas=1
```

**3.5 Festive sale rollout and undo**:
```bash
kubectl -n freshcart set env deployment/api SALE_PERCENT=20
kubectl -n freshcart rollout status deployment/api
kubectl -n freshcart rollout undo deployment/api
```
Note: editing the ConfigMap alone does **not** restart pods; env vars are read at container start.

**3.6 Autoscaling for the 7 pm rush**:
```bash
kubectl apply -f deploy/k8s/60-hpa.yaml
kubectl -n freshcart get hpa -w
# from your laptop:
bash scripts/load.sh http://<node-public-ip>:30080 180 20
```
Replicas climb toward 8; about five minutes after the load stops they scale back down.

**3.7 How much room is left on a node** (links to exam question C3(c)):
```bash
kubectl describe node k8s-w1 | grep -A9 "Allocated resources"
kubectl apply -f deploy/k8s/extras/requests-demo.yaml     # 8 x 250m, all pinned to k8s-w1
kubectl get pods -l app=cpu-reserve -o wide               # some Running, the rest Pending
kubectl delete -f deploy/k8s/extras/requests-demo.yaml
```

**3.8 Drain a node — and the database again**:
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
| Swarm tasks Rejected: "No such image" | Image not in a registry, or package private | Push to ghcr.io; set package Public or `docker login ghcr.io` on every node |
| Storefront shows "Catalog unavailable" for the first ~20 s | Postgres initialising; API retrying | Wait — that retry loop is the point: orchestrators do not enforce start order |
| `freshcart_db` Pending in Swarm | No node has label `db=true` | `docker node update --label-add db=true swarm-mgr` |
| Web returns 502 on `/api` in Kubernetes | `API_HOST` is the short name `api` | Must be `api.freshcart.svc.cluster.local` (nginx resolver ignores search domains) |
| `postgres-0` Pending, PVC Pending | No `local-path` StorageClass | Re-run the local-path part of `infra/k8s-control-plane-init.sh` |
| HPA shows `<unknown>` targets | metrics-server not ready | `kubectl -n kube-system get pods -l k8s-app=metrics-server`; wait 60 s |
| Nodes NotReady | No CNI, or node-to-node traffic blocked | Check Flannel pods; security group must allow all traffic from itself |
| Database password changed but old one still used | Postgres initialises credentials only on an empty volume | Remove the volume / PVC, then redeploy |
