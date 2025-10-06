output "gke_name" { value = google_container_cluster.this.name }
output "gke_location" { value = google_container_cluster.this.location }
output "artifact_registry_repo" { value = google_artifact_registry_repository.docker.repository_id }
output "cloudsql_instance" {
  value = var.enable_cloud_sql ? google_sql_database_instance.pg[0].name : ""
}
output "api_gateway_ingress_ip" { value = google_compute_global_address.api_gateway_ingress.address }
