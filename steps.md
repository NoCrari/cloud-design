# Cloud-Design – Étapes de bout en bout

Ce guide, aligné sur `project.md` et la checklist `audit.md`, décrit un plan d’exécution clair: provisionner l’infra GCP (VPC, GKE, Cloud SQL, Artifact Registry), builder/pusher les images, déployer les microservices (inventory, billing, api-gateway, RabbitMQ), sécuriser (NetworkPolicies, secrets), exposer l’API, monitorer/logguer et valider pour l’audit.

## 0. Plan d’exécution (résumé)
- Préparer GCP et outils; activer les APIs.
- Provisionner VPC, sous-réseau, NAT, GKE Autopilot, Artifact Registry, PSC, Cloud SQL (IP privée).
- Builder/pusher les images Docker (multi‑stage), optimiser taille/cache.
- Créer `namespace`, `Secrets`, `ConfigMaps` et déployer RabbitMQ + bases (dev) ou Cloud SQL (prod).
- Déployer `inventory-app`, `billing-app` (consommateur de queue), `api-gateway`.
- Exposer `api-gateway` via LoadBalancer ou Ingress + TLS; option Auth Identity Platform.
- Appliquer NetworkPolicies et HPAs; vérifier connectivité/health.
- Activer/installer le monitoring (Cloud Monitoring, option Prometheus/Grafana); config logs.
- Tester E2E; démonstration `gcloud`, `kubectl`, `terraform`, `docker` pour l’audit.
- Gérer coûts (budgets/alertes) et nettoyer.

## 1. Prérequis
1) Projet GCP avec facturation activée
2) Outils installés : `gcloud`, `kubectl`, `docker`, `terraform`, `make`
3) Authentification et projet actif
```bash
gcloud auth login
gcloud config set project <PROJECT_ID>
```

## 2. Activer les APIs requises
```bash
gcloud services enable \
  compute.googleapis.com \
  container.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  secretmanager.googleapis.com \
  logging.googleapis.com \
  monitoring.googleapis.com \
  sqladmin.googleapis.com \
  serviceusage.googleapis.com \
  servicenetworking.googleapis.com \
  cloudresourcemanager.googleapis.com \
  servicedirectory.googleapis.com \
  identitytoolkit.googleapis.com
```
Note: `sqladmin.googleapis.com` et `servicenetworking.googleapis.com` ne sont nécessaires que si vous activez l’option Cloud SQL (voir §3 et §6). Pour un run 100 % in‑cluster, ils sont optionnels.

## 2.b Déploiement rapide (premier run)
```bash
# Projet + APIs de base
gcloud auth login
gcloud config set project <PROJECT_ID>
gcloud services enable compute.googleapis.com container.googleapis.com servicenetworking.googleapis.com

# Infra (VPC, NAT, GKE Autopilot, IP globale)
cd infra/terraform
terraform init
terraform apply -var project_id=<PROJECT_ID> -var region=<REGION>

# kubeconfig
gcloud container clusters get-credentials micro-autopilot \
  --region <REGION> --project <PROJECT_ID>

# Apps
cd -
make apply

# URL HTTPS (attend le certificat)
HOST=$(kubectl -n microservices get ingress api-gateway -o jsonpath='{.spec.rules[0].host}')
curl -I https://$HOST/

# Monitoring (optionnel)
make monitoring
MON_IP=$(kubectl get ing -n monitoring monitoring-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -I http://$MON_IP/
curl -I http://$MON_IP/prom/-/ready
```
Notes
- L’Ingress est patché automatiquement (`api.<LB_IP>.nip.io`) et le certificat managé est attendu avant de rendre la main.
- Si `nip.io` ne résout pas chez vous, testez en curl ou changez de résolveur DNS.

## 3. Provisionner l’infrastructure (Terraform)
Crée : VPC (VPC‑native), sous-réseau avec plages secondaires (Pods/Services), Cloud NAT, GKE Autopilot (nœuds privés), Artifact Registry, Private Service Connect, Cloud SQL (IP privée) avec bases `inventory` et `billing`.
```bash
cd infra/terraform
terraform init
terraform plan  -var project_id=<PROJECT_ID> -var region=<REGION>
terraform apply -var project_id=<PROJECT_ID> -var region=<REGION>
```
Notes :
- Les sorties incluent le nom/emplacement du cluster GKE ; le nom de l’instance Cloud SQL.
- En production, envisager GKE régional et Cloud SQL en haute dispo régionale.
 - Pour la conformité audit: capturez les sorties `plan/apply` et conservez le `terraform.tfstate`.
 - Cloud SQL est optionnel et désactivé par défaut (`enable_cloud_sql = false` dans `infra/terraform/variables.tf`). Pour l’activer: `terraform apply -var enable_cloud_sql=true` (prévu pour un scénario prod, hors périmètre minimal in‑cluster).

## 4. Configurer kubectl
```bash
gcloud container clusters get-credentials micro-autopilot \
  --region <REGION> --project <PROJECT_ID>
kubectl get nodes
```

## 5. Construire et pousser les images
Optimisez vos Dockerfiles (multi‑stage, bases slim, `.dockerignore`), puis:

Docker Hub :
```bash
export DOCKER_HUB_USERNAME=<votre_user_dockerhub>   # optionnel, défaut : nocrarii
make build TAG=v1
make push TAG=v1
```

## 6. Déployer la couche data & messaging

Par défaut (projet in‑cluster)
- Secrets/ConfigMaps: voir section 7.
- RabbitMQ: `kubectl apply -f Manifests/messaging/rabbitmq.yaml`
- Bases de données (in‑cluster): `kubectl apply -f Manifests/databases/`

Option Make (déploiement en une passe in‑cluster)
- `make apply` appliquera `secrets/`, `configmaps/`, `messaging/`, `databases/`, puis les apps, HPA, NetworkPolicies et Ingress s’ils existent.

Optionnel — Cloud SQL (hors périmètre minimal; alternative prod)
- Ne déployez pas `Manifests/databases/` (pas de DB in‑cluster).
- Assurez la connectivité privée et la création via Terraform (voir §3, `enable_cloud_sql=true`).
- Pointez les apps vers Cloud SQL via variables d’environnement:
  - Inventory: `kubectl -n microservices set env deploy/inventory-app INVENTORY_DB_HOST=<CLOUD_SQL_HOST> INVENTORY_DB_PORT=5432 INVENTORY_DB_USER=<USER> INVENTORY_DB_PASSWORD=<PASS>`
  - Billing: `kubectl -n microservices set env sts/billing-app BILLING_DB_HOST=<CLOUD_SQL_HOST> BILLING_DB_PORT=5432 BILLING_DB_USER=<USER> BILLING_DB_PASSWORD=<PASS>`
  - Option sidecar: Cloud SQL Auth Proxy dans les Pods si vous ne voulez pas exposer l’IP privée.

## 7. Exposer l’API

Défaut — Ingress + DNS + TLS (GKE ManagedCertificate)
- Le Service `api-gateway` reste en `ClusterIP`.
- `make apply` applique l’Ingress et ajuste automatiquement le host en `api.<LB_IP>.nip.io` via `Scripts/set-api-ingress-host.sh`.
- Si besoin manuel: `kubectl apply -n microservices -f Manifests/ingress/api-gateway-ingress.yaml` puis exécutez `bash Scripts/set-api-ingress-host.sh`.
- Récupérez l’IP du LB: `kubectl get ingress -n microservices api-gateway -o wide`
- Créez l’enregistrement DNS si nécessaire et attendez la provision du certificat.

Alternative — Service `LoadBalancer` sur le port 3000: basculez le Service si besoin et testez `http://EXTERNAL_IP:3000/`.

Option Make:
- `make apply` réapplique automatiquement les manifests d’Ingress (et `BackendConfig`) si le dossier `Manifests/ingress/` est présent.

## 8. Revoir/mettre à jour Secrets et ConfigMaps
- Secrets (dev → prod):
  - Les fichiers `Manifests/secrets/*.yaml` utilisent maintenant `stringData` (valeurs en clair). Remplacez les mots de passe et utilisateurs par des valeurs fortes avant un usage non‑dev.
  - Attention: pour les bases PostgreSQL, `POSTGRES_*` ne réinitialise pas une DB déjà initialisée sur un volume. Si des PVC existent, changer `postgres-user/password` ne changera pas le mot de passe effectif. Il faut soit faire une rotation SQL côté base, soit recréer les volumes.
  - Rotation en ligne (exemples):
```bash
kubectl -n microservices create secret generic db-secrets \
  --from-literal=postgres-user=postgres \
  --from-literal=postgres-password='RemplacezParUnSecretFort' \
  --from-literal=inventory-user=inventory_user \
  --from-literal=inventory-password='RemplacezParUnSecretFort' \
  --from-literal=billing-user=billing_user \
  --from-literal=billing-password='RemplacezParUnSecretFort' \
  -o yaml --dry-run=client | kubectl apply -f -

kubectl -n microservices create secret generic rabbitmq-secrets \
  --from-literal=rabbitmq-user=admin \
  --from-literal=rabbitmq-password='RemplacezParUnSecretFort' \
  --from-literal=rabbitmq-erlang-cookie='RemplacezParUnCookieFort' \
  -o yaml --dry-run=client | kubectl apply -f -
```

  - ConfigMap:
    - `Manifests/configmaps/app-config.yaml` définit `RABBITMQ_HOST` et `RABBITMQ_PORT`. Ajustez si vous changez le nom de Service ou le port.

Option Make (si vous modifiez les YAML):
- `make apply` réappliquera les secrets et configmaps depuis `Manifests/secrets/` et `Manifests/configmaps/`.

## 9. Déployer sur GKE
```bash
make apply
kubectl get all -n microservices
```
Si vous utilisez un Ingress, attendre l’IP externe et la provision du certificat ; puis mettre à jour le DNS.

## 10. Vérifications et tests E2E
```bash
make health
make test
```
`make test` utilise l’Ingress s’il existe ; sinon, effectue un port‑forward vers `svc/api-gateway` sur le port 3000.

## 11. Supervision & logs
Par défaut : Cloud Monitoring/Logging collecte métriques et logs cluster/nœuds.

Optionnel (opérateur upstream) : Prometheus/Grafana via kube‑prometheus
```bash
make monitoring  # installe kube‑prometheus, applique RBAC + PodMonitors, Ingress/NEGs/BackendConfigs GKE, dashboards custom

# Vérifier
kubectl get pods -n monitoring
kubectl describe ingress -n monitoring monitoring-ingress | sed -n '/Backends/,$p'
MON_IP=$(kubectl get ingress -n monitoring monitoring-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -sI http://$MON_IP/            # Grafana (200/302)
curl -sI http://$MON_IP/prom/graph  # Prometheus (200)
```
Notes:
- Scraping via `PodMonitor` (`Manifests/monitoring/podmonitors.yaml`).
- Manifests GKE sous `Manifests/monitoring/gke/` (BackendConfigs, Service NEG pour Prometheus web, NetworkPolicy, Ingress).
- Si les backends restent UNHEALTHY, relance `make monitoring`, patiente 2–4 min, puis revérifie `describe ingress`.
- Identifiants Grafana: secret optionnel.
  - `cp Manifests/monitoring/grafana-secret.example.yaml Manifests/monitoring/grafana-secret.yaml`
  - éditez `admin-user` / `admin-password`, puis `make monitoring` (Grafana est patché pour consommer le Secret).
- Dashboard custom: `Manifests/monitoring/grafana-dashboard-microservices.yaml` est monté automatiquement et apparaît dans Grafana.
- Datasource Grafana: doit pointer vers `http://prometheus-web.monitoring.svc:9090/prom` (routePrefix `/prom`).

## 12. Durcissement sécurité (Production)
- Remplacer Postgres in‑cluster par Cloud SQL ; supprimer `Manifests/databases/*.yaml` ; pointer les apps vers Cloud SQL (IP privée ou sidecars Cloud SQL Auth Proxy).
- Utiliser Secret Manager + driver CSI pour monter les secrets ; faire tourner les identifiants.
- Garder des NetworkPolicies restrictives ; n’autoriser que le trafic nécessaire.
- Activer Identity Platform et appliquer l’authentification au gateway si requis.
- Considérer Cloud Armor pour la protection en bordure.

## 13. Autoscaling & performance
- HPAs fournis pour `api-gateway` et `inventory-app` (cible CPU ~60 %).
- Pour `billing-app`, envisager un scale basé sur la profondeur de la file (métriques externes/custom).
- Faire des tests de charge et ajuster requests/limits et cibles HPA.

Option Make (après modification des HPAs):
- `make apply` appliquera les fichiers `Manifests/autoscaling/*.yaml`.

## 14. Gestion des coûts
- Commencer petit (Autopilot ou petit node pool Standard).
- Nettoyer les ressources inutilisées ; définir budgets/alertes.
- Préférer une instance Cloud SQL unique avec deux bases pour dev/petites charges.
 - Créer un budget/alerte: Console GCP > Billing > Budgets & alerts.

## 15. Nettoyage
```bash
make delete                              # supprime le namespace et les PV rattachés
cd infra/terraform
# Désactiver la protection avant destruction (peut nécessiter deux étapes)
terraform apply -var project_id=<PROJECT_ID> -var region=<REGION> \
  -var cluster_deletion_protection=false -var sql_deletion_protection=false
terraform destroy -var project_id=<PROJECT_ID> -var region=<REGION> \
  -var cluster_deletion_protection=false -var sql_deletion_protection=false
```

## 16. Dépannage
- Pods en attente : vérifier la storage class et les PVC ; `kubectl describe pod -n microservices <pod>`.
- Échecs de connexion DB : vérifier secrets, DNS des Services, readiness des StatefulSets.
- Ingress non fonctionnel : DNS doit pointer vers l’IP du LB ; attendre la provision du certificat ; vérifier annotations/classe.
- HPA absent : `metrics-server` doit être disponible ; `kubectl get hpa -n microservices`.

Aides Make:
- `make health` pour un état rapide du namespace et de l’accès au gateway.
- `make test` pour un test E2E (Ingress ou port-forward automatique).
- `make delete` pour supprimer entièrement le namespace en cas de besoin de repartir proprement.

## 17. Préparation au rôle play (audit)
- Architecture: décrire GKE (Autopilot, VPC‑native), Cloud SQL en IP privée via PSC, Artifact Registry, Ingress/GCLB, Identity Platform, Cloud Monitoring.
- Choix GCP: coûts, simplicité, services managés; alternatives (Cloud Run vs GKE, Pub/Sub vs RabbitMQ, Cloud SQL vs in‑cluster).
- Sécurité: réseau privé, NetworkPolicies, Workload Identity (si ajouté), Secrets/CSI, HTTPS via ManagedCertificate, DB privée.
- Coûts: sizing minimal, HPA, nettoyage, budgets/alertes.
- Conteneurs: multi‑stage, images slim, cache build.
- Scalabilité: HPA CPU; pour `billing`, métrique externe (profondeur de queue).
- Évolutions: nouveaux microservices, régions, portabilité multi‑cloud.

## 18. Démonstration pour l’audit (exemples de commandes)
- `terraform`:
  - `cd infra/terraform && terraform plan` puis `terraform apply`
- `gcloud`:
  - `gcloud config list` ; `gcloud container clusters list` ; `gcloud container clusters get-credentials ...`
- `kubectl`:
  - `kubectl get ns` ; `kubectl get all -n microservices` ; `kubectl get hpa -n microservices`
  - `kubectl get svc -n microservices api-gateway -o wide` ; `kubectl get ingress -n microservices`
  - `kubectl logs -n microservices deploy/api-gateway` ; `kubectl describe netpol -n microservices`
- `docker`:
  - `docker images | grep -E "(api-gateway|inventory|billing|rabbitmq|db)"`
- Tests:
  - `curl http://<EXTERNAL_IP>:3000/` ; scénarios via l’API pour créer/consommer des messages billing.

## 19. Checklist de conformité à audit.md
- Contenu repo: README complet, code microservices, IaC Terraform, manifests K8s, Dockerfiles, scripts.
- Architecture: scalabilité, dispo, sécurité (privé), coût, simplicité validés.
- Déploiement: microservices OK, LB/Ingress opérationnel, comms sécurisées.
- Infra: Terraform pour VPC, GKE, Artifact Registry, Cloud SQL, PSC.
- Conteneurs & K8s: Dockerfiles optimisés; Deployments/StatefulSets/Services/HPAs/Secrets/ConfigMaps/Ingress/NetworkPolicies corrects.
- Monitoring/Logging: tableaux de bord Cloud Monitoring; Prometheus/Grafana si déployés.
- Optimisation: HPA raisonnables; scaling file d’attente envisagé.
- Sécurité: HTTPS, secrets, scanning images, IAM minimal, DB privée.
- Bonus (optionnel): Identity Platform, Cloud Armor, Secret Manager CSI, sidecars Cloud SQL Auth Proxy, Pub/Sub alternative.
