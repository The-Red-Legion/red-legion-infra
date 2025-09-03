variable "render_api_key" {
  description = "Render API key from the dashboard"
  type        = string
  sensitive   = true
}

variable "render_owner_id" {
  description = "Render owner ID (usr- or tea- prefixed)"
  type        = string
}

variable "discord_token" {
  description = "Discord bot token"
  type        = string
  sensitive   = true
}

variable "text_channel_id" {
  description = "Discord logging channel ID"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository URL"
  type        = string
  default     = "https://github.com/your-username/your-repo" # Replace with your repo
}

variable "dev_environment_id" {
  description = "Render environment ID for Dev"
  type        = string
}

variable "prod_environment_id" {
  description = "Render environment ID for Prod"
  type        = string
}