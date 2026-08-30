module "url_monitor" {
  source = "../modules/url-monitor"

  project_name    = "url-monitor"
  alert_email     = var.alert_email
  monitor_targets = var.monitor_targets
  lambda_package = {
    filename         = data.archive_file.lambda.output_path
    source_code_hash = data.archive_file.lambda.output_base64sha256
  }

  schedule_expression = "rate(5 minutes)"
  failure_threshold   = 2
  log_retention_days  = 7
}
