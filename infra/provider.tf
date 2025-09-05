terraform {
  backend "gcs" {
    bucket = "red-legion-tf-state"
    prefix = "terraform/state"
  }
}
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0.0"
    }
  }
}

provider "google" {
  project = var.gcp_project_id
  region  = "us-central1"
}