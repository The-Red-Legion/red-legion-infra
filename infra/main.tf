# Reference existing secrets
data "google_secret_manager_secret_version" "discord_token" {
  secret  = "discord-token"
  version = "latest"
}

data "google_secret_manager_secret_version" "db_password" {
  secret  = "db-password"
  version = "latest"
}

data "google_secret_manager_secret_version" "grafana_admin_password" {
  secret  = "grafana-admin-password"
  version = "latest"
}
# Create a VPC network
resource "google_compute_network" "red_legion_vpc" {
  name                    = "red-legion-vpc"
  auto_create_subnetworks = true
}

# Create a Serverless VPC Access Connector
resource "google_vpc_access_connector" "cloud_run_connector" {
  name           = "cloud-run-connector"
  network        = google_compute_network.red_legion_vpc.name
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
  network       = google_compute_network.red_legion_vpc.self_link
}

# Set up private service connection for Cloud SQL
resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.red_legion_vpc.self_link
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_alloc.name]
}

# Cloud SQL for PostgreSQL (Free Tier)
resource "google_sql_database_instance" "event_db" {
  name             = "event-data-db"
  database_version = "POSTGRES_13"
  region           = "us-central1"
  depends_on       = [google_service_networking_connection.private_vpc_connection]
  settings {
    tier      = "db-f1-micro"
    disk_size = 10
    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.red_legion_vpc.self_link
    }
    backup_configuration {
      enabled = false
    }
  }
}

resource "google_sql_database" "red_legion_event_db" {
  name     = "red_legion_event_db"
  instance = google_sql_database_instance.event_db.name
}

resource "google_sql_user" "event_user" {
  name     = "event_user"
  instance = google_sql_database_instance.event_db.name
  password = data.google_secret_manager_secret_version.db_password.secret_data
}

# Compute Engine for Participation Bot (Free Tier)
resource "google_compute_instance" "participation_bot" {
  name         = "participation-bot"
  machine_type = "f1-micro"
  zone         = "us-central1-a"
  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-11"
      size  = 10
    }
  }
  network_interface {
    network = google_compute_network.red_legion_vpc.name
    access_config {}
  }
  service_account {
    scopes = ["cloud-platform"]
  }
}

# Cloud Run for Grafana (Free Tier)
resource "google_cloud_run_service" "grafana" {
  name     = "grafana"
  location = "us-central1"
  template {
    spec {
      service_account_name = "60953116087-compute@developer.gserviceaccount.com"
      timeout_seconds     = 600
      containers {
        image = "grafana/grafana:10.0.0"
        env {
          name  = "GF_DATABASE_TYPE"
          value = "postgres"
        }
        env {
          name  = "GF_DATABASE_HOST"
          value = "${google_sql_database_instance.event_db.private_ip_address}:5432"
        }
        env {
          name  = "GF_DATABASE_NAME"
          value = "red_legion_event_db"
        }
        env {
          name  = "GF_DATABASE_USER"
          value = "event_user"
        }
        env {
          name  = "GF_DATABASE_PASSWORD"
          value = data.google_secret_manager_secret_version.db_password.secret_data
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
          value = data.google_secret_manager_secret_version.grafana_admin_password.secret_data
        }
      }
    }
    metadata {
      annotations = {
        "run.googleapis.com/vpc-access-connector" = google_vpc_access_connector.cloud_run_connector.id
        "run.googleapis.com/vpc-access-egress"   = "all-traffic"
        "run.googleapis.com/ingress"             = "all"
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
  secret_id = "db-password"
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:60953116087-compute@developer.gserviceaccount.com"
}

resource "google_secret_manager_secret_iam_member" "grafana_admin_password_access" {
  secret_id = "grafana-admin-password"
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:60953116087-compute@developer.gserviceaccount.com"
}

# Grant Secret Access for Participation Bot
resource "google_secret_manager_secret_iam_member" "participation_bot_secret_access" {
  for_each  = toset(["discord-token", "db-password"])
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_compute_instance.participation_bot.service_account[0].email}"
}

# Firewall rule to allow Cloud SQL traffic
resource "google_compute_firewall" "allow_sql" {
  name    = "allow-cloud-sql"
  network = google_compute_network.red_legion_vpc.name
  allow {
    protocol = "tcp"
    ports    = ["5432"]
  }
  source_ranges = ["10.8.0.0/28"]
  target_tags   = ["cloud-sql"]
}

# Outputs
output "participation_bot_ip" {
  value = google_compute_instance.participation_bot.network_interface[0].access_config[0].nat_ip
}

output "grafana_url" {
  value = google_cloud_run_service.grafana.status[0].url
}

output "database_connection_string" {
  value     = "postgresql://event_user:${data.google_secret_manager_secret_version.db_password.secret_data}@${google_sql_database_instance.event_db.private_ip_address}:5432/${google_sql_database.red_legion_event_db.name}"
  sensitive = true
}