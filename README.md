# Cloud-Design on GCP (GKE) – Architecture, Setup, and Operations

[Disponible en français](README.fr.md)

Target stack: GKE (Autopilot or Standard) + RabbitMQ on GKE + PostgreSQL (in‑cluster for quickstart, Cloud SQL recommended for prod) + Identity Platform + HTTPS Load Balancer + Terraform + Cloud Monitoring/Logging.

> Architecture diagram: see `resources/architecture_orchestrator.png`.

## Overview
- Objective: deploy and operate a microservices app on GCP with scalable, secure, observable components.
- Services: `inventory-app`, `billing-app`, `api-gateway`, `rabbitmq`, `inventory-db` (Postgres), `billing-db` (Postgres).
- Repository: container sources under `Dockerfiles/*`; Kubernetes descriptors under `Manifests/*`; infra under `infra/terraform`.

## Architecture
```
                    Internet (HTTPS)
                           |
                 Cloud Load Balancer (GCLB)
                           |
                       Ingress (ManagedCertificate)
                           |
                  Service: api-gateway (ClusterIP)
                           |
      +--------------------+--------------------+
      |                                         |
  inventory-app (HTTP 8080)                 billing-app (queue consumer)
      |                                         |
  inventory-db (Postgres) <---- RabbitMQ ----> (consumes messages)
      |                                         |
   PersistentVolume (StatefulSet)         PersistentVolume (StatefulSet)

  Namespace: microservices | NetworkPolicies | HPAs | Secrets/ConfigMaps
```

Key decisions
- Simplicity first: one namespace (`microservices`) with complete manifests to run end‑to‑end.
- Dev vs Prod: in‑cluster PostgreSQL for fast iteration; prefer Cloud SQL (private IP) for production.
- Security: private networking, NetworkPolicies, secret hygiene, TLS at the edge, Workload Identity.
- Cost: rightsize resources; use HPA; clean up resources whenever not needed.

## Repository Structure
- `Dockerfiles/`
  - `api-gateway-app/` Flask proxy/gateway. Env: `APIGATEWAY_PORT`, `INVENTORY_APP_HOST/PORT`, `RABBITMQ_*`.
  - `inventory-app/` Flask + SQLAlchemy + Prometheus metrics. Env: `INVENTORY_APP_PORT`, `INVENTORY_DB_*`.
  - `billing-app/` SQLAlchemy + Pika consumer. Env: `BILLING_DB_*`, `RABBITMQ_*`, `RABBITMQ_QUEUE`.
  - `rabbitmq/` Debian + `rabbitmq_management`, init script.
  - `inventory-db/`, `billing-db/` Postgres images with optional init SQL.
- `Manifests/`
  - `namespace.yaml` – Namespace `microservices`
  - `secrets/` – demo secrets (replace for non‑dev)
  - `configmaps/app-config.yaml` – RabbitMQ host/port
  - `messaging/rabbitmq.yaml` – Deployment + Service (AMQP 5672, mgmt 15672)
  - `databases/*.yaml` – Postgres StatefulSets + headless Services + PVC templates
  - `apps/*.yaml` – `inventory-app` (Deployment), `billing-app` (StatefulSet), `api-gateway` (Deployment+Service)
  - `autoscaling/*.yaml` – HPAs for api-gateway and inventory-app
  - `monitoring/` – generic monitoring assets: Prometheus overrides, RBAC, PodMonitors, custom dashboards
  - `monitoring/gke/` – GKE‑specific: BackendConfigs, NEG‑enabled Service for Prometheus web, NetworkPolicy, Ingress
  - `ingress/api-gateway-ingress.yaml` – Ingress + ManagedCertificate (host auto‑set to api.<LB_IP>.nip.io by `Scripts/set-api-ingress-host.sh`)
  - `networkpolicies/*.yaml` – default deny + allow rules
- `infra/terraform/` – VPC (VPC‑native), GKE Autopilot, Cloud NAT, Artifact Registry, Private Service Connect, Cloud SQL (private IP).
- `Scripts/` – helpers for build/apply/health/test/cleanup.

## Prerequisites
- GCP project with billing enabled.
- Tools: `gcloud`, `kubectl`, `docker`, `terraform`, `make`.
- Auth: `gcloud auth login && gcloud config set project <PROJECT_ID>`.

## Quickstart (First Deployment)
```bash
# 1) Set project and enable core APIs
gcloud auth login
gcloud config set project <PROJECT_ID>
gcloud services enable compute.googleapis.com container.googleapis.com servicenetworking.googleapis.com

# 2) Provision infra (VPC, NAT, GKE Autopilot, static IP)
cd infra/terraform
terraform init
terraform apply -var project_id=<PROJECT_ID> -var region=<REGION>

# 3) Configure kubectl for the new cluster
gcloud container clusters get-credentials micro-autopilot \
  --region <REGION> --project <PROJECT_ID>

# 4) Deploy apps (namespace, secrets, messaging, DBs, apps, HPAs, NetworkPolicies, Ingress)
cd -
make apply

# 5) Get HTTPS URL and test (script waits for cert)
HOST=$(kubectl -n microservices get ingress api-gateway -o jsonpath='{.spec.rules[0].host}')
echo https://$HOST/
curl -I https://$HOST/

# 6) Optional: install monitoring (Prometheus/Grafana via kube-prometheus)
make monitoring
MON_IP=$(kubectl get ing -n monitoring monitoring-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo http://$MON_IP/           # Grafana
echo http://$MON_IP/prom/graph # Prometheus
```
Notes
- The Ingress host is auto‑set to `api.<LB_IP>.nip.io` and a ManagedCertificate is created/rotated automatically; the deploy waits until HTTPS is ready.
- If your browser doesn’t resolve nip.io, test with curl first or change your DNS resolver.

## Enable Required GCP APIs
```bash
gcloud services enable \
  compute.googleapis.com \
  container.googleapis.com \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  secretmanager.googleapis.com \
  logging.googleapis.com \
  monitoring.googleapis.com \
  sqladmin.googleapis.com \
  servicedirectory.googleapis.com \
  serviceusage.googleapis.com \
  cloudresourcemanager.googleapis.com \
  servicenetworking.googleapis.com \
  redis.googleapis.com \
  identitytoolkit.googleapis.com
```

## Provision Infrastructure (Terraform)
- Files: `infra/terraform/{main.tf,variables.tf,outputs.tf}`.
- Defaults: GKE region `europe-west9`. Cloud SQL is DISABLED by default (we use in‑cluster Postgres for dev).
```bash
gcloud auth login
gcloud config set project <PROJECT_ID>
cd infra/terraform
terraform init
terraform plan
terraform apply
```
- Important: set the project explicitly. Either pass it via CLI `-var project_id=<PROJECT_ID>` (recommended) or export `TF_VAR_project_id=<PROJECT_ID>`. If you set it empty, the Google provider errors.
  - Example: `terraform plan -var project_id=<PROJECT_ID> -var region=<REGION>`
- Outputs: GKE cluster name/location, Artifact Registry repo, Cloud SQL instance.
- Connect kubectl:
```bash
gcloud container clusters get-credentials micro-autopilot \
  --region <REGION> --project <PROJECT_ID>
```

Cloud SQL (optional)
- Disabled by default (`enable_cloud_sql = false`) to keep setup simple (DBs run in‑cluster via K8s StatefulSets).
- To enable Cloud SQL creation via Terraform, set a tfvars file (recommended) or pass vars:
  - `enable_cloud_sql=true`, `sql_region=europe-west1` (or another supported region).
  - Example tfvars (infra/terraform/terraform.tfvars):
    - enable_cloud_sql = true
    - sql_region       = "europe-west1"
 - If you see deletion errors for Service Networking when disabling Cloud SQL, keep the connection by default:
   - `retain_service_networking = true` (default). Set to false only when you really want to remove the peering and no producer service is using it.

Deletion protection
- By default, the GKE cluster and Cloud SQL instance are created with deletion protection enabled to prevent accidents.
- To destroy infra, first disable protection then destroy:
```bash
# Option A: one-time destroy with vars (provider may require two steps)
terraform destroy \
  -var cluster_deletion_protection=false -var sql_deletion_protection=false

# If destroy still fails, do it in two steps:
terraform apply \
  -var cluster_deletion_protection=false -var sql_deletion_protection=false
terraform destroy \
  -var cluster_deletion_protection=false -var sql_deletion_protection=false
```

## What Terraform Deploys
- Enabled GCP APIs (via `google_project_service`):
  - `compute.googleapis.com` — VPC/Subnets, Cloud NAT, firewall rules, Load Balancers.
  - `container.googleapis.com` — required for GKE cluster creation/management.
  - `artifactregistry.googleapis.com` — optional; only needed if you use Google Artifact Registry to host images.
  - `sqladmin.googleapis.com` — Cloud SQL (used when `enable_cloud_sql = true`).
  - `servicenetworking.googleapis.com` — Private Service Connect for Cloud SQL private IP.

- Network:
  - VPC and subnetwork with secondary ranges for Pods/Services.
  - Cloud Router + Cloud NAT for private egress.
  - Firewall rules to allow GCLB health checks to monitoring NEGs (Grafana 3000, Prometheus 9090).

- Kubernetes:
  - GKE Autopilot regional cluster (VPC‑native, IP aliasing).

- Ingress:
  - Global static external IP for the API Gateway Ingress.

- Registry (optional):
  - Artifact Registry repository `docker`. If you push to Docker Hub instead, you can skip this and the related API.

- Database (optional):
  - Service Networking reserved range + connection for private IP.
  - Cloud SQL Postgres instance and two databases (inventory, billing) when `enable_cloud_sql = true`.

Notes
- Docker vs Artifact Registry: Docker est l’outil de build/exécution d’images; Artifact Registry est un service GCP pour héberger les images. Les manifests de ce dépôt référencent par défaut des images Docker Hub (`nocrarii/...`). Si vous restez sur Docker Hub, Artifact Registry n’est pas requis.

## Build and Push Images
- Docker Hub (default):
```bash
# Optional: export DOCKER_HUB_USERNAME=your_dockerhub_user
make build TAG=v6        # build all images
make push TAG=v6         # build + push; bumps tags in manifests
```
- Artifact Registry (optional): tag images as `REGION-docker.pkg.dev/PROJECT/docker/<image>:vX` and push; update manifests accordingly.

## Deploy to GKE
```bash
make apply              # applies secrets/configmaps, messaging, databases, apps, HPAs, ingress (if present)
make health             # quick status checks
make test               # E2E tests via gateway (Ingress or port-forward)
```
- Default exposure: Ingress + ManagedCertificate (HTTPS)
  - The `api-gateway` Service is `ClusterIP`; traffic comes via GKE Ingress.
  - The manifest ships with a placeholder host; `Scripts/set-api-ingress-host.sh` auto-sets `api.<LB_IP>.nip.io`, creates/rotates a ManagedCertificate as needed, and waits until it is Active.
  - Apply: `kubectl apply -n microservices -f Manifests/ingress/api-gateway-ingress.yaml` (already done by `make apply`)
  - Get LB IP: `kubectl get ingress -n microservices api-gateway -o wide`
  - Open: `HOST=$(kubectl -n microservices get ingress api-gateway -o jsonpath='{.spec.rules[0].host}') && echo https://$HOST/`

- Fallback exposure (Option B): switch the Service to `type: LoadBalancer` and reach it via `EXTERNAL_IP:3000`.

## Configuration Details
- API Gateway: env `APIGATEWAY_PORT`, `INVENTORY_APP_HOST/PORT`, `RABBITMQ_*` from Secret/ConfigMap; liveness/readiness on `/`.
- Inventory App: env `INVENTORY_DB_*`; exposes `/metrics` for Prometheus.
- Inventory DB host/port are configurable via `INVENTORY_DB_HOST`/`INVENTORY_DB_PORT` (defaults to in‑cluster Service).
- Billing App: env `BILLING_DB_*`, `RABBITMQ_*`, `RABBITMQ_QUEUE`; StatefulSet for ordered startup.
- Billing DB host/port are configurable via `BILLING_DB_HOST`/`BILLING_DB_PORT` (defaults to in‑cluster Service).
- Databases: StatefulSets with PVCs; update `storageClassName` to match your cluster (e.g., `standard-rwo`). Replace demo secrets.

## Monitoring and Logging
- Cloud Monitoring/Logging: available by default on GKE for cluster/node logs and metrics.
- Prometheus/Grafana (optional, upstream operator), one‑shot setup:
```bash
make monitoring  # installs kube‑prometheus, applies RBAC + PodMonitors, GKE Ingress/NEGs/BackendConfigs, dashboard provisioning
kubectl get pods -n monitoring
kubectl describe ingress -n monitoring monitoring-ingress | sed -n '/Backends/,$p'
MON_IP=$(kubectl get ingress -n monitoring monitoring-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -sI http://$MON_IP/            # Grafana (200/302)
curl -sI http://$MON_IP/prom/graph  # Prometheus (200)
```
  - App scraping: we use `PodMonitor`s (`Manifests/monitoring/podmonitors.yaml`).
  - Prometheus route prefix: `/prom` (set via `Manifests/monitoring/prometheus-overrides.yaml` and adjusted dynamically by `Scripts/set-prometheus-external-url.sh`).
  - Grafana admin (optional): copy `Manifests/monitoring/grafana-secret.example.yaml` to `grafana-secret.yaml`, edit values, then `make monitoring` patches the deployment to consume it.
  - Custom dashboards: `Manifests/monitoring/grafana-dashboard-microservices.yaml` is mounted automatically by the Makefile.

Notes
- The Grafana datasource (Secret `grafana-datasources`) must point to the Prometheus web URL with the `/prom` prefix. If you changed it earlier or use a custom stack, ensure it is set to `http://prometheus-web.monitoring.svc:9090/prom`.

## Cloud SQL (Production)
- Option 1 — Private IP (recommended):
  - Ensure your GKE cluster has private connectivity to Cloud SQL (VPC‑native, Private Service Connect, correct firewall rules). Terraform in `infra/terraform` covers this.
  - Set app env vars to point to Cloud SQL host/IP and ports; use a dedicated DB user.
    - Inventory:
      - `kubectl -n microservices set env deploy/inventory-app INVENTORY_DB_HOST=<CLOUD_SQL_HOST> INVENTORY_DB_PORT=5432 INVENTORY_DB_USER=<USER> INVENTORY_DB_PASSWORD=<PASS>`
    - Billing:
      - `kubectl -n microservices set env sts/billing-app BILLING_DB_HOST=<CLOUD_SQL_HOST> BILLING_DB_PORT=5432 BILLING_DB_USER=<USER> BILLING_DB_PASSWORD=<PASS>`
  - Remove in‑cluster DBs if not needed: `kubectl delete -n microservices -f Manifests/databases/`.

- Option 2 — Cloud SQL Auth Proxy sidecar:
  - Keep `*_DB_HOST=127.0.0.1` and `*_DB_PORT=5432`, add a sidecar Cloud SQL Auth Proxy container to your Pod specs that exposes `127.0.0.1:5432` and connects to your instance.
  - Requires Workload Identity or service account credentials mounted to the Pod.

Notes:
- By default, manifests target in‑cluster Postgres with the `postgres` superuser for dev speed. For prod, prefer least‑privilege users (see `Manifests/secrets/db-secrets.yaml` for placeholders `inventory-user`/`billing-user`).
- Update Secrets accordingly before switching to Cloud SQL.

## Terraform State (Versioned in Repo)
- This repo versions Terraform state files (e.g., `infra/terraform/terraform.tfstate`).
- Good practices and risks:
  - Treat `tfstate` as sensitive: it can contain values of outputs and some resources (potentially secrets).
  - Limit who can push to branches carrying state changes; review diffs carefully.
  - Keep provider caches out of VCS (we ignore `**/.terraform/*`).
  - Consider migrating to a remote backend with locking (GCS + state locking via Google Cloud Storage) when collaborating or scaling.

## Security
- Secrets: rotate demo secrets; for prod use Secret Manager + CSI driver.
- NetworkPolicies: default deny; allow only necessary flows (gateway→apps, apps↔RabbitMQ, apps→DBs, DNS egress).
- Identity: Workload Identity for GCP access (no node‑wide keys).
- TLS/Edge: HTTPS via GCLB ManagedCertificate; consider Cloud Armor.
- Databases: prefer Cloud SQL (private IP), backups/PITR, least privilege users.

## Autoscaling
- HPAs for api-gateway and inventory-app (1–3 replicas, ~60% CPU target): `kubectl get hpa -n microservices`.
- For billing, consider scaling by queue depth with external metrics in production.

## Cost Management
- Start small (Autopilot or minimal node pool), use HPA, rightsize requests/limits.
- Clean up when finished: clusters, LBs, Cloud SQL, Artifact Registry storage.
- Set budgets/alerts.

## Cleanup
```bash
make delete                  # deletes namespace + bound PVs
# If you created infra with Terraform
cd infra/terraform && terraform destroy -var project_id=<PROJECT_ID>
```

## Troubleshooting
- Pods not ready: `kubectl describe pod -n microservices <pod>`; check events and `kubectl logs`.
- DB StatefulSets: ensure PVCs are bound; review storage class.
- HPA: metrics-server must be available on the cluster.
- Ingress: DNS must point to the LB IP; certs take time to provision.

## Role‑Play: Design Rationale
- Why GKE vs Cloud Run, RabbitMQ vs Pub/Sub, Cloud SQL vs self‑managed.
- Security posture (private IP, NetworkPolicies, WI, Secret Manager, TLS).
- Operability (monitoring/logging, HPAs, dashboards, runbooks).
- Cost/scale tradeoffs and future evolution.
