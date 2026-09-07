data "aws_kms_key" "alerts" {
  key_id = "alias/url-monitor-alerts"
}
