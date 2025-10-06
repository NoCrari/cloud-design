# Cloud-Design sur GCP (GKE) – Architecture, Mise en place et Opérations

Pile cible : GKE (Autopilot ou Standard) + RabbitMQ sur GKE + PostgreSQL (dans le cluster pour démarrer, Cloud SQL recommandé en prod) + Identity Platform + Load Balancer HTTPS + Terraform + Cloud Monitoring/Logging.

> Diagramme d’architecture : voir `resources/architecture_orchestrator.png`.

## Aperçu
- Objectif : déployer et opérer une application microservices sur GCP avec scalabilité, sécurité, observabilité et maîtrise des coûts.
- Services : `inventory-app`, `billing-app`, `api-gateway`, `rabbitmq`, `inventory-db` (Postgres), `billing-db` (Postgres).
- Référentiel : sources des conteneurs dans `Dockerfiles/*` ; manifestes Kubernetes dans `Manifests/*` ; infra IaC dans `infra/terraform`.

## Architecture
```
                    Internet (HTTPS)
                           |
             Cloud Load Balancer (GCLB)
                           |
                Ingress (ManagedCertificate)
                           |
           Service : api-gateway (ClusterIP)
                           |
      +--------------------+--------------------+
      |                                         |
  inventory-app (HTTP 8080)                 billing-app (consommateur)
      |                                         |
  inventory-db (Postgres) <---- RabbitMQ ----> (consomme la file)
      |                                         |
   Volume persistant (StatefulSet)        Volume persistant (StatefulSet)

  Namespace : microservices | NetworkPolicies | HPA | Secrets/ConfigMaps
```

Décisions clés
- Simplicité : un seul namespace (`microservices`) avec des manifestes complets pour un run de bout en bout.
- Dev vs Prod : Postgres dans le cluster pour itérer vite ; Cloud SQL (IP privée) recommandé en production.
- Sécurité : réseau privé, NetworkPolicies, hygiène des secrets, TLS au bord, Workload Identity.
- Coûts : dimensionner correctement ; utiliser HPA ; nettoyer les ressources quand elles ne servent plus.

## Structure du dépôt
- `Dockerfiles/`
  - `api-gateway-app/` (Flask proxy/gateway). Env : `APIGATEWAY_PORT`, `INVENTORY_APP_HOST/PORT`, `RABBITMQ_*`.
  - `inventory-app/` (Flask + SQLAlchemy + métriques Prometheus). Env : `INVENTORY_APP_PORT`, `INVENTORY_DB_*`.
  - `billing-app/` (SQLAlchemy + Pika consumer). Env : `BILLING_DB_*`, `RABBITMQ_*`, `RABBITMQ_QUEUE`.
  - `rabbitmq/` (Debian + `rabbitmq_management`, script d’init).
  - `inventory-db/`, `billing-db/` (images Postgres avec SQL d’init optionnel).
- `Manifests/`
  - `namespace.yaml` – Namespace `microservices`
  - `secrets/` – secrets de démonstration (à remplacer hors dev)
  - `configmaps/app-config.yaml` – hôte/port RabbitMQ
  - `messaging/rabbitmq.yaml` – Deployment + Service (AMQP 5672, management 15672)
  - `databases/*.yaml` – StatefulSets Postgres + Services headless + PVCs
  - `apps/*.yaml` – `inventory-app` (Deployment), `billing-app` (StatefulSet), `api-gateway` (Deployment+Service)
  - `autoscaling/*.yaml` – HPAs pour api-gateway et inventory-app
  - `monitoring/*` – ServiceMonitors + Services publics optionnels (LoadBalancer)
  - `ingress/api-gateway-ingress.yaml` – Ingress + ManagedCertificate
  - `networkpolicies/*.yaml` – deny par défaut + règles d’autorisation minimales
- `infra/terraform/` – VPC (VPC‑native), GKE Autopilot, Cloud NAT, Artifact Registry, Private Service Connect, Cloud SQL (IP privée).
- `Scripts/` – helpers build/apply/health/test/cleanup.

## Prérequis
- Projet GCP avec facturation activée.
- Outils : `gcloud`, `kubectl`, `docker`, `terraform`, `make`.
- Auth : `gcloud auth login && gcloud config set project <PROJECT_ID>`.

## Activer les APIs GCP requises
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

## Provisionner l’infrastructure (Terraform)
- Fichiers : `infra/terraform/{main.tf,variables.tf,outputs.tf}`.
- Valeurs par défaut : région GKE `europe-west9`. Cloud SQL est DÉSACTIVÉ par défaut (on utilise Postgres dans le cluster pour le dev).
```bash
gcloud auth login
gcloud config set project <PROJECT_ID>
cd infra/terraform
terraform init
terraform plan
terraform apply
```
- Le provider prend le projet depuis le Cloud SDK si `project_id` est vide (défaut). Surcharger avec `-var region=...` si besoin.
- Sorties : nom/emplacement du cluster GKE, dépôt Artifact Registry, instance Cloud SQL.
- Connecter kubectl :
```bash
gcloud container clusters get-credentials micro-autopilot \
  --region <REGION> --project <PROJECT_ID>
```

Cloud SQL (optionnel)
- Désactivé par défaut (`enable_cloud_sql = false`) pour simplifier (les DB tournent dans le cluster via des StatefulSets K8s).
- Pour activer la création Cloud SQL via Terraform, utilisez un tfvars (recommandé) ou passez des variables :
  - `enable_cloud_sql=true`, `sql_region=europe-west1` (ou autre région supportée).
  - Exemple tfvars (infra/terraform/terraform.tfvars) :
    - enable_cloud_sql = true
    - sql_region       = "europe-west1"
 - Si vous voyez des erreurs de suppression sur Service Networking en re‑désactivant Cloud SQL, conservez le peering par défaut :
   - `retain_service_networking = true` (défaut). Ne le mettez à false que si vous souhaitez vraiment retirer le peering et qu’aucun service producteur ne l’utilise.

Protection contre la suppression
- Par défaut, le cluster GKE et l’instance Cloud SQL sont créés avec `deletion_protection = true` pour éviter les suppressions accidentelles.
- Pour détruire l’infra, désactivez d’abord la protection puis détruisez :
```bash
# Option A : tentative directe avec variables (selon le provider, cela peut requérir 2 étapes)
terraform destroy \
  -var cluster_deletion_protection=false -var sql_deletion_protection=false

# Si échec, faites en deux étapes :
terraform apply \
  -var cluster_deletion_protection=false -var sql_deletion_protection=false
terraform destroy \
  -var cluster_deletion_protection=false -var sql_deletion_protection=false
```

## Construire et pousser les images
- Docker Hub (par défaut) :
```bash
# Optionnel : export DOCKER_HUB_USERNAME=votre_user
make build TAG=v6        # construit toutes les images
make push TAG=v6         # construit + pousse ; met à jour les tags dans les manifests
```
- Artifact Registry (optionnel) : tagger en `REGION-docker.pkg.dev/PROJECT/docker/<image>:vX`, pousser et mettre à jour les manifests.

## Déployer sur GKE
```bash
make apply              # applique secrets/configmaps, messaging, databases, apps, HPAs, ingress (si présent)
make health             # contrôles rapides
make test               # tests E2E via le gateway (Ingress ou port-forward)
```
- Exposition par défaut : Ingress GKE + certificat managé (domaine public)
  - Le Service `api-gateway` est en `ClusterIP`; l’accès se fait via l’Ingress.
  - Renseignez votre domaine dans `Manifests/ingress/api-gateway-ingress.yaml` (une valeur nip.io est déjà fournie ici).
  - Appliquer : `kubectl apply -n microservices -f Manifests/ingress/api-gateway-ingress.yaml`
  - Récupérer l’IP du LB : `kubectl get ingress -n microservices api-gateway -o wide`
  - Pointer votre DNS (si besoin) vers cette IP et attendre la provision du certificat.

- Alternative (fallback) : basculer le Service en `type: LoadBalancer` et joindre `EXTERNAL_IP:3000`.

## Détails de configuration
- API Gateway : env `APIGATEWAY_PORT`, `INVENTORY_APP_HOST/PORT`, `RABBITMQ_*` via Secret/ConfigMap ; liveness/readiness sur `/`.
- Inventory App : env `INVENTORY_DB_*` ; expose `/metrics` pour Prometheus.
- Hôte/port de la DB Inventory via `INVENTORY_DB_HOST`/`INVENTORY_DB_PORT` (défaut: Service in‑cluster).
- Billing App : env `BILLING_DB_*`, `RABBITMQ_*`, `RABBITMQ_QUEUE` ; StatefulSet pour un démarrage ordonné.
- Hôte/port de la DB Billing via `BILLING_DB_HOST`/`BILLING_DB_PORT` (défaut: Service in‑cluster).
- Bases de données : StatefulSets + PVC ; adapter `storageClassName` (ex. `standard-rwo`). Remplacer les secrets de démo.

## Supervision et logs
- Cloud Monitoring/Logging : activés par défaut sur GKE pour métriques/logs cluster/nœuds.
- Prometheus/Grafana (optionnel, opérateur upstream) :
```bash
make monitoring  # installe kube-prometheus, applique ServiceMonitors, BackendConfigs, NEGs et Ingress GCE (HTTP/80)
kubectl get pods -n monitoring
kubectl describe ingress -n monitoring monitoring-ingress | sed -n '/Backends/,$p'
MON_IP=$(kubectl get ingress -n monitoring monitoring-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -sI http://$MON_IP/            # Grafana (200/302)
curl -sI http://$MON_IP/prom/graph  # Prometheus (200)
```
  - Les ServiceMonitors des apps sont dans `Manifests/monitoring/servicemonitors.yaml`.

## Cloud SQL (Production)
- Option 1 — IP privée (recommandée) :
  - Assurez la connectivité privée GKE↔Cloud SQL (VPC‑native, PSC, règles firewall). Le Terraform dans `infra/terraform` le couvre.
  - Pointez les apps vers l’hôte Cloud SQL et le port via des variables d’environnement, avec un utilisateur dédié.
    - Inventory :
      - `kubectl -n microservices set env deploy/inventory-app INVENTORY_DB_HOST=<CLOUD_SQL_HOST> INVENTORY_DB_PORT=5432 INVENTORY_DB_USER=<USER> INVENTORY_DB_PASSWORD=<PASS>`
    - Billing :
      - `kubectl -n microservices set env sts/billing-app BILLING_DB_HOST=<CLOUD_SQL_HOST> BILLING_DB_PORT=5432 BILLING_DB_USER=<USER> BILLING_DB_PASSWORD=<PASS>`
  - Supprimez les DB in‑cluster si non nécessaires : `kubectl delete -n microservices -f Manifests/databases/`.

- Option 2 — Sidecar Cloud SQL Auth Proxy :
  - Gardez `*_DB_HOST=127.0.0.1` et `*_DB_PORT=5432`, ajoutez un sidecar proxy dans les Pods qui expose `127.0.0.1:5432` et se connecte à l’instance Cloud SQL.
  - Requiert Workload Identity ou un compte de service monté.

Notes :
- Par défaut, les manifests visent Postgres in‑cluster avec l’utilisateur `postgres` pour itérer vite. En prod, préférez des comptes à moindre privilège (placeholders `inventory-user`/`billing-user` dans `Manifests/secrets/db-secrets.yaml`).
- Mettez à jour les Secrets avant la bascule Cloud SQL.

## État Terraform (versionné dans le dépôt)
- Ce dépôt versionne les fichiers d’état Terraform (ex. `infra/terraform/terraform.tfstate`).
- Bonnes pratiques et risques :
  - Considérez le `tfstate` comme sensible : il peut contenir des sorties et parfois des secrets.
  - Restreignez qui peut pousser des changements d’état ; relisez les diffs.
  - Évitez de versionner le cache provider (`**/.terraform/*` est ignoré).
  - En équipe/échelle, envisagez un backend distant avec verrouillage (GCS + locking) pour éviter les corruptions.

## Sécurité
- Secrets : rotation régulière ; en prod, Secret Manager + CSI driver.
- NetworkPolicies : deny par défaut ; autoriser uniquement les flux nécessaires (gateway→apps, apps↔RabbitMQ, apps→DBs, DNS egress).
- Identité : Workload Identity pour accéder aux APIs GCP (pas de clés sur les nœuds).
- TLS/bord : HTTPS via GCLB ManagedCertificate ; envisager Cloud Armor.
- Bases : préférer Cloud SQL (IP privée), sauvegardes/PITR, comptes DB à moindre privilège.

## Autoscaling
- HPAs pour api-gateway et inventory-app (1–3 réplicas, cible CPU ~60 %) : `kubectl get hpa -n microservices`.
- Pour billing, envisager un scale sur la profondeur de file avec métriques externes en production.

## Gestion des coûts
- Démarrer petit (Autopilot ou petit node pool Standard), utiliser HPA, adapter requests/limits.
- Nettoyage : clusters, load balancers, Cloud SQL, stockage Artifact Registry.
- Budgets/alertes : suivre les coûts.

## Nettoyage
```bash
make delete                  # supprime le namespace + PV rattachés
# Si vous avez créé l’infra avec Terraform
cd infra/terraform && terraform destroy -var project_id=<PROJECT_ID>
```

## Dépannage
- Pods non prêts : `kubectl describe pod -n microservices <pod>` ; voir les événements et `kubectl logs`.
- StatefulSets DB : s’assurer que les PVC sont liés ; vérifier la storage class.
- HPA : `metrics-server` doit être dispo.
- Ingress : DNS doit pointer vers l’IP du LB ; la provision du certificat peut prendre du temps.

## Role‑Play : raisonnement d’architecture
- Pourquoi GKE vs Cloud Run, RabbitMQ vs Pub/Sub, Cloud SQL vs autogéré.
- Posture sécurité (IP privée, NetworkPolicies, Workload Identity, Secret Manager, TLS).
- Exploitabilité (monitoring/logging, HPAs, dashboards, runbooks).
- Compromis coût/échelle et évolutions futures.
