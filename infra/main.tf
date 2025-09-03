resource "render_postgres" "event_db" {
  name = "event-data-db"
  plan = "free" # Updated from 'starter' to 'free' (or choose 'basic_256mb', 'pro_4gb', etc.)
  region = "oregon"
  environment_id = var.dev_environment_id
  version = "13"
  database_name = "red_legion_event_db"
  database_user = "event_user"
}

resource "render_background_worker" "participation_bot" {
  name = "participation-bot"
  plan = "starter"
  region = "oregon"
  environment_id = var.dev_environment_id
  start_command = "python bots/participation_bot.py"
  runtime_source = {
    native_runtime = {
      auto_deploy = true
      branch = "feature/dual-bots-sqlite"
      build_command = "pip install -r requirements.txt"
      repo_url = var.github_repo
      runtime = "python"
    }
  }
  env_vars = {
    DISCORD_TOKEN = { value = var.discord_token }
    TEXT_CHANNEL_ID = { value = var.text_channel_id }
    DATABASE_URL = { value = render_postgres.event_db.connection_info.internal_connection_string }
  }
  num_instances = 1
}

resource "render_web_service" "dashboard_bot" {
  name = "dashboard-bot"
  plan = "starter"
  region = "oregon"
  environment_id = var.dev_environment_id
  start_command = "python bots/dashboard_bot.py"
  runtime_source = {
    native_runtime = {
      auto_deploy = true
      branch = "feature/dual-bots-sqlite"
      build_command = "pip install -r requirements.txt"
      repo_url = var.github_repo
      runtime = "python"
    }
  }
  env_vars = {
    PORT = { value = "5000" }
    DATABASE_URL = { value = render_postgres.event_db.connection_info.internal_connection_string }
  }
  num_instances = 1
}

output "participation_bot_url" {
  value = null
}

output "dashboard_bot_url" {
  value = render_web_service.dashboard_bot.url
}