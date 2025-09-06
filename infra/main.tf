# Generate secure random passwords
resource "random_password" "db_password" {
  length  = 32
  special = true
  upper   = true
  lower   = true
  numeric = true
  # Avoid characters that might cause issues in connection strings
  override_special = "!#$%&*()-_=+[]{}|;:,.<>?"
}

resource "random_password" "grafana_admin_password" {
  length           = 24
  special          = true
  upper            = true
  lower            = true
  numeric          = true
  override_special = "!#$%&*()-_=+[]{}|;:,.<>?"
}

# Store generated passwords in Secret Manager
resource "google_secret_manager_secret" "db_password" {
  secret_id = "db-password"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = random_password.db_password.result
}

resource "google_secret_manager_secret" "grafana_admin_password" {
  secret_id = "grafana-admin-password"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "grafana_admin_password" {
  secret      = google_secret_manager_secret.grafana_admin_password.id
  secret_data = random_password.grafana_admin_password.result
}

# Generate SSH key pair for bot deployment
resource "tls_private_key" "bot_ssh_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Store SSH private key in Secret Manager
resource "google_secret_manager_secret" "ssh_private_key" {
  secret_id = "ssh-private-key"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "ssh_private_key" {
  secret      = google_secret_manager_secret.ssh_private_key.id
  secret_data = tls_private_key.bot_ssh_key.private_key_pem
}

# Store SSH public key in Secret Manager (for reference)
resource "google_secret_manager_secret" "ssh_public_key" {
  secret_id = "ssh-public-key"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "ssh_public_key" {
  secret      = google_secret_manager_secret.ssh_public_key.id
  secret_data = tls_private_key.bot_ssh_key.public_key_openssh
}

# Reference existing secrets (only Discord token needs to be manually set)
data "google_secret_manager_secret_version" "discord_token" {
  secret  = "discord-token"
  version = "latest"
}
# Create a VPC network
resource "google_compute_network" "arccorp_vpc" {
  name                    = "arccorp-vpc"
  auto_create_subnetworks = true
}

# Create a Serverless VPC Access Connector
resource "google_vpc_access_connector" "cloud_run_connector" {
  name           = "cloud-run-connector"
  network        = google_compute_network.arccorp_vpc.name
  ip_cidr_range  = "10.8.0.0/28"
  machine_type   = "e2-micro"
  min_throughput = 200
  max_throughput = 300
}

# Allocate an IP range for private service connection
resource "google_compute_global_address" "private_ip_alloc" {
  name          = "private-ip-alloc"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.arccorp_vpc.self_link
}

# Set up private service connection for Cloud SQL
resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.arccorp_vpc.self_link
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_alloc.name]
}

# Cloud SQL for PostgreSQL (Free Tier)
resource "google_sql_database_instance" "arccorp_data_nexus" {
  name             = "arccorp-data-nexus"
  database_version = "POSTGRES_13"
  region           = "us-central1"
  depends_on       = [google_service_networking_connection.private_vpc_connection]
  settings {
    tier      = "db-f1-micro"
    disk_size = 10
    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.arccorp_vpc.self_link
    }
    backup_configuration {
      enabled = false
    }
  }
}

resource "google_sql_database" "arccorp_data_store" {
  name     = "red_legion_arccorp_data_store"
  instance = google_sql_database_instance.arccorp_data_nexus.name
}

resource "google_sql_user" "arccorp_sys_admin" {
  name     = "arccorp_sys_admin"
  instance = google_sql_database_instance.arccorp_data_nexus.name
  password = random_password.db_password.result
}

# Auto-generate and store database connection string in Secret Manager
resource "google_secret_manager_secret" "database_connection_string" {
  secret_id = "database-connection-string"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "database_connection_string" {
  secret      = google_secret_manager_secret.database_connection_string.id
  secret_data = "postgresql://arccorp_sys_admin:${random_password.db_password.result}@${google_sql_database_instance.arccorp_data_nexus.private_ip_address}:5432/${google_sql_database.arccorp_data_store.name}"
}

# Compute Engine for ArcCorp Compute (Free Tier)
resource "google_compute_instance" "arccorp_compute" {
  name         = "arccorp-compute"
  machine_type = "f1-micro"
  zone         = "us-central1-a"
  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = 10
    }
  }
  network_interface {
    network = google_compute_network.arccorp_vpc.name
    access_config {}
  }
  service_account {
    scopes = ["cloud-platform"]
  }
  tags = ["cloud-sql"]
  metadata = {
    ssh-keys = "ubuntu:${tls_private_key.bot_ssh_key.public_key_openssh}"
  }
}

# Cloud Run for Grafana (Free Tier)
resource "google_cloud_run_service" "grafana" {
  name     = "grafana"
  location = "us-central1"
  
  metadata {
    annotations = {
      "run.googleapis.com/ingress" = "all"
    }
  }
  
  template {
    spec {
      service_account_name = "60953116087-compute@developer.gserviceaccount.com"
      timeout_seconds      = 600
      containers {
        image = "grafana/grafana:10.0.0"
        env {
          name  = "GF_DATABASE_TYPE"
          value = "postgres"
        }
        env {
          name  = "GF_DATABASE_HOST"
          value = "${google_sql_database_instance.arccorp_data_nexus.private_ip_address}:5432"
        }
        env {
          name  = "GF_DATABASE_NAME"
          value = "red_legion_arccorp_data_store"
        }
        env {
          name  = "GF_DATABASE_USER"
          value = "arccorp_sys_admin"
        }
        env {
          name  = "GF_DATABASE_PASSWORD"
          value = random_password.db_password.result
        }
        env {
          name  = "GF_SERVER_PROTOCOL"
          value = "http"
        }
        env {
          name  = "GF_SERVER_HTTP_PORT"
          value = "8080"
        }
        env {
          name  = "GF_SERVER_ROOT_URL"
          value = "http://localhost:8080"
        }
        env {
          name  = "GF_LOG_LEVEL"
          value = "error"
        }
        env {
          name  = "GF_AUTH_ANONYMOUS_ENABLED"
          value = "false"
        }
        env {
          name  = "GF_SECURITY_ADMIN_USER"
          value = "admin"
        }
        env {
          name  = "GF_SECURITY_ADMIN_PASSWORD"
          value = random_password.grafana_admin_password.result
        }
      }
    }
    metadata {
      annotations = {
        "run.googleapis.com/vpc-access-connector" = google_vpc_access_connector.cloud_run_connector.id
        "run.googleapis.com/vpc-access-egress"    = "all-traffic"
      }
    }
  }
  traffic {
    percent         = 100
    latest_revision = true
  }
}

# Allow public access to Grafana
resource "google_cloud_run_service_iam_member" "grafana_public_access" {
  service  = google_cloud_run_service.grafana.name
  location = google_cloud_run_service.grafana.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# Ensure Cloud Run service account has Cloud SQL client role
resource "google_project_iam_member" "grafana_sql_client" {
  project = "rl-prod-471116"
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:60953116087-compute@developer.gserviceaccount.com"
}

# Grant Secret Access for Grafana
resource "google_secret_manager_secret_iam_member" "grafana_secret_access" {
  secret_id = google_secret_manager_secret.db_password.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:60953116087-compute@developer.gserviceaccount.com"
}

resource "google_secret_manager_secret_iam_member" "grafana_admin_password_access" {
  secret_id = google_secret_manager_secret.grafana_admin_password.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:60953116087-compute@developer.gserviceaccount.com"
}

# Grant Secret Access for Participation Bot
resource "google_secret_manager_secret_iam_member" "arccorp_compute_secret_access" {
  for_each  = toset(["discord-token"])  # Only include existing secrets
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_compute_instance.arccorp_compute.service_account[0].email}"
}

# Add separate IAM permissions for auto-generated secrets with proper dependencies
resource "google_secret_manager_secret_iam_member" "arccorp_compute_generated_secrets" {
  for_each  = {
    database-connection-string = google_secret_manager_secret.database_connection_string.secret_id
    ssh-private-key           = google_secret_manager_secret.ssh_private_key.secret_id
    ssh-public-key            = google_secret_manager_secret.ssh_public_key.secret_id
    db-password                = google_secret_manager_secret.db_password.secret_id
    grafana-admin-password     = google_secret_manager_secret.grafana_admin_password.secret_id
  }
  
  secret_id  = each.value
  role       = "roles/secretmanager.secretAccessor"
  member     = "serviceAccount:${google_compute_instance.arccorp_compute.service_account[0].email}"
  depends_on = [google_compute_instance.arccorp_compute]
}

# Firewall rule to allow Cloud SQL traffic from VM
resource "google_compute_firewall" "allow_sql" {
  name    = "allow-cloud-sql"
  network = google_compute_network.arccorp_vpc.name
  allow {
    protocol = "tcp"
    ports    = ["5432"]
  }
  source_tags = ["cloud-sql"]
}

# Alternative rule: allow all internal VPC traffic (more permissive)
resource "google_compute_firewall" "allow_internal" {
  name    = "allow-internal"
  network = google_compute_network.arccorp_vpc.name
  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }
  source_ranges = ["10.128.0.0/9"]
}

resource "google_compute_firewall" "allow_ssh" {
  name    = "allow-ssh"
  network = google_compute_network.arccorp_vpc.name
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["0.0.0.0/0"]
}

# Outputs
output "arccorp_compute_ip" {
  description = "External IP of the participation bot instance"
  value       = google_compute_instance.arccorp_compute.network_interface[0].access_config[0].nat_ip
}

output "grafana_url" {
  description = "URL for Grafana dashboard"
  value       = google_cloud_run_service.grafana.status[0].url
}

output "database_connection_string" {
  description = "Database connection string (sensitive)"
  value       = "postgresql://arccorp_sys_admin:${random_password.db_password.result}@${google_sql_database_instance.arccorp_data_nexus.private_ip_address}:5432/${google_sql_database.arccorp_data_store.name}"
  sensitive   = true
}

output "sql_private_ip" {
  description = "Private IP of the Cloud SQL instance"
  value       = google_sql_database_instance.arccorp_data_nexus.private_ip_address
}

output "db_password" {
  description = "Generated database password (sensitive)"
  value       = random_password.db_password.result
  sensitive   = true
}

output "grafana_admin_password" {
  description = "Generated Grafana admin password (sensitive)"
  value       = random_password.grafana_admin_password.result
  sensitive   = true
}

output "ssh_private_key_secret" {
  description = "Name of the SSH private key secret in Secret Manager"
  value       = google_secret_manager_secret.ssh_private_key.secret_id
}

output "ssh_public_key_secret" {
  description = "Name of the SSH public key secret in Secret Manager"
  value       = google_secret_manager_secret.ssh_public_key.secret_id
}

output "github_secrets_update_command" {
  description = "Commands to update GitHub secrets with new values"
  value       = <<-EOT
    # Update GitHub repository secrets with these values:
    # BOT_SERVER_HOST: ${google_compute_instance.arccorp_compute.network_interface[0].access_config[0].nat_ip}
    # BOT_SSH_PRIVATE_KEY: Get from Secret Manager -> ssh-private-key
    
    # To get the SSH private key:
    gcloud secrets versions access latest --secret="ssh-private-key"
    
    # To get the database password (if needed):
    gcloud secrets versions access latest --secret="db-password"
    
    # To get the Grafana admin password:
    gcloud secrets versions access latest --secret="grafana-admin-password"
    
    # All secrets are automatically stored in Secret Manager:
    # - discord-token (manual - set this first)
    # - ssh-private-key (auto-generated)
    # - ssh-public-key (auto-generated)
    # - db-password (auto-generated)
    # - grafana-admin-password (auto-generated)
    # - database-connection-string (auto-generated)
  EOT
}

output "secret_manager_summary" {
  description = "Summary of all secrets in Secret Manager"
  value = {
    manual_secrets = [
      "discord-token"
    ]
    auto_generated_secrets = [
      "ssh-private-key",
      "ssh-public-key",
      "db-password",
      "grafana-admin-password",
      "database-connection-string"
    ]
  }
}