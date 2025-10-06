variable "project_id" {
  description = "GCP Project ID. If empty, uses GOOGLE_PROJECT / Cloud SDK default."
  type        = string
  default     = "streetcoder-rrakoton"
}

variable "region" {
  type    = string
  default = "europe-west9"
}

variable "network_name" {
  type    = string
  default = "vpc-main"
}

variable "gke_subnet_cidr" {
  type    = string
  default = "10.10.0.0/20"
}

variable "pods_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "svcs_cidr" {
  type    = string
  default = "10.30.0.0/20"
}

variable "master_cidr" {
  type    = string
  default = "172.16.0.0/28"
}

variable "sql_tier" {
  type    = string
  default = "db-custom-2-3840"
}

variable "cluster_deletion_protection" {
  description = "Protect the GKE cluster from accidental deletion (set to false before destroy)"
  type        = bool
  default     = false
}

variable "sql_deletion_protection" {
  description = "Protect the Cloud SQL instance from accidental deletion (set to false before destroy)"
  type        = bool
  default     = false
}
variable "sql_region" {
  description = "Region for Cloud SQL instance (use a region where Cloud SQL is available)"
  type        = string
  default     = "europe-west1"
}

variable "enable_cloud_sql" {
  description = "Create Cloud SQL resources (instance + databases + Service Networking). Default false to keep only in-cluster DBs."
  type        = bool
  default     = false
}

variable "retain_service_networking" {
  description = "Keep the Service Networking reserved range + connection even when Cloud SQL is disabled. Avoids deletion errors and speeds future re-enables."
  type        = bool
  default     = true
}
