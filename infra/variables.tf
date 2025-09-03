variable "gcp_project_id" {
  description = "GCP project ID"
  type        = string
}

variable "db_password" {
  description = "Password for Cloud SQL database user"
  type        = string
  sensitive   = true
}