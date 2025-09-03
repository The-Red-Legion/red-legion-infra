provider "google" {
  project = var.gcp_project_id
  region  = "us-central1"
}

# Reference existing secrets
data "google_secret_manager_secret_version" "discord_token" {
  secret  = "discord-token"
  version = "latest"
}

data "google_secret_manager_secret_version" "db_password" {
  secret  = "db-password"
  version = "latest"
}

# Cloud SQL for PostgreSQL (Free Tier)
resource "google_sql_database_instance" "event_db" {
  name             = "event-data-db"
  database_version = "POSTGRES_13"
  region           = "us-central1"
  settings {
    tier      = "db-f1-micro" # Free tier
    disk_size = 10 # 10 GB
    ip_configuration {
      ipv4_enabled = true
    }
    backup_configuration {
      enabled = false # Disable backups to minimize costs
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
  password = var.db_password
}

# Compute Engine for Participation Bot (Free Tier)
resource "google_compute_instance" "participation_bot" {
  name         = "participation-bot"
  machine_type = "f1-micro" # Free tier
  zone         = "us-central1-a"
  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-11"
      size  = 10
    }
  }
  network_interface {
    network = "default"
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
      containers {
        image = "grafana/grafana:latest"
        env {
          name  = "GF_DATABASE_TYPE"
          value = "postgres"
        }
        env {
          name  = "GF_DATABASE_HOST"
          value = "${google_sql_database_instance.event_db.public_ip_address}:5432"
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
          value = "$(gcloud secrets versions access latest --secret=db-password)"
        }
      }
    }
  }
  traffic {
    percent         = 100
    latest_revision = true
  }
}

# Grant Secret Access
resource "google_secret_manager_secret_iam_member" "participation_bot_secret_access" {
  for_each  = toset(["discord-token", "db-password"])
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_compute_instance.participation_bot.service_account[0].email}"
}

resource "google_secret_manager_secret_iam_member" "grafana_secret_access" {
  secret_id = "db-password"
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_cloud_run_service.grafana.service_account_name}"
}

# Outputs
output "participation_bot_ip" {
  value = google_compute_instance.participation_bot.network_interface[0].access_config[0].nat_ip
}

output "grafana_url" {
  value = google_cloud_run_service.grafana.status[0].url
}

output "database_connection_string" {
  value = "postgresql://event_user:$(gcloud secrets versions access latest --secret=db-password)@${google_sql_database_instance.event_db.public_ip_address}:5432/${google_sql_database.red_legion_event_db.name}"
}