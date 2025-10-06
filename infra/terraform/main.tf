provider "google" {
  project = var.project_id
  region  = var.region
}

resource "google_project_service" "services" {
  for_each = toset([
    "compute.googleapis.com",
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "sqladmin.googleapis.com",
    "servicenetworking.googleapis.com",
    "serviceusage.googleapis.com",
    "cloudresourcemanager.googleapis.com"
  ])
  service = each.value
}

# Allow a brief settling period after API enablement to avoid race conditions
resource "time_sleep" "wait_api_enablement" {
  create_duration = "60s"
  depends_on      = [google_project_service.services]
}

# VPC and subnet with secondary ranges for GKE
resource "google_compute_network" "vpc" {
  name                    = var.network_name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "gke" {
  name          = "gke-subnet"
  ip_cidr_range = var.gke_subnet_cidr
  region        = var.region
  network       = google_compute_network.vpc.id

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.svcs_cidr
  }

  private_ip_google_access = true
}

# Cloud NAT for private nodes egress
resource "google_compute_router" "router" {
  name    = "nat-router"
  region  = var.region
  network = google_compute_network.vpc.name
}

resource "google_compute_router_nat" "nat" {
  name                               = "nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  subnetwork {
    name                    = google_compute_subnetwork.gke.name
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
  depends_on = [google_project_service.services]
}

resource "google_compute_firewall" "allow_monitoring_lb" {
  name    = "allow-monitoring-lb"
  network = google_compute_network.vpc.name

  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["30000-32767"]
  }

  source_ranges = [
    "0.0.0.0/0",
    "130.211.0.0/22",
    "35.191.0.0/16",
  ]

  description = "Allow public LB health checks and client traffic to monitoring LoadBalancers"
}

# Allow GCLB health checks to reach Pod NEGs for monitoring (ports 3000,9090)
resource "google_compute_firewall" "allow_monitoring_negs" {
  name    = "allow-monitoring-negs"
  network = google_compute_network.vpc.name

  direction = "INGRESS"
  priority  = 1001

  allow {
    protocol = "tcp"
    ports    = ["3000", "9090"]
  }

  source_ranges = [
    "130.211.0.0/22",
    "35.191.0.0/16",
  ]

  description = "Allow Google LB health checks to reach monitoring NEGs (Grafana 3000, Prometheus 9090)"
}

# GKE Autopilot (private)
resource "google_container_cluster" "this" {
  name             = "micro-autopilot"
  location         = var.region
  enable_autopilot = true
  deletion_protection = var.cluster_deletion_protection

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.gke.name

  depends_on = [time_sleep.wait_api_enablement]
}

# Artifact Registry for Docker images
resource "google_artifact_registry_repository" "docker" {
  location      = var.region
  repository_id = "docker"
  format        = "DOCKER"
  depends_on    = [google_project_service.services]
}

# Global static IP for the API gateway ingress
resource "google_compute_global_address" "api_gateway_ingress" {
  name         = "api-gateway-ip"
  address_type = "EXTERNAL"
  ip_version   = "IPV4"
}

# Private Service Connect for Cloud SQL
resource "google_compute_global_address" "private_service_range" {
  count         = (var.enable_cloud_sql || var.retain_service_networking) ? 1 : 0
  name          = "google-managed-services-${var.network_name}"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "private_vpc_connection" {
  count                   = (var.enable_cloud_sql || var.retain_service_networking) ? 1 : 0
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_service_range[0].name]
  depends_on              = [google_project_service.services]
}

# Cloud SQL Postgres instance (private IP) with two databases
resource "google_sql_database_instance" "pg" {
  count               = var.enable_cloud_sql ? 1 : 0
  name                = "pg-micro"
  database_version    = "POSTGRES_15"
  region              = var.sql_region
  deletion_protection = var.sql_deletion_protection

  settings {
    tier = var.sql_tier

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.vpc.id
    }

    availability_type = "ZONAL" # change to REGIONAL for HA
    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
    }
    maintenance_window {
      day  = 7
      hour = 3
    }
  }

  depends_on = [google_service_networking_connection.private_vpc_connection]

  timeouts {
    create = "60m"
    delete = "60m"
    update = "60m"
  }
}

resource "google_sql_database" "inventory" {
  count      = var.enable_cloud_sql ? 1 : 0
  name       = "inventory"
  instance   = google_sql_database_instance.pg[0].name
  depends_on = [google_sql_database_instance.pg]
}

resource "google_sql_database" "billing" {
  count      = var.enable_cloud_sql ? 1 : 0
  name       = "billing"
  instance   = google_sql_database_instance.pg[0].name
  depends_on = [google_sql_database_instance.pg]
}
