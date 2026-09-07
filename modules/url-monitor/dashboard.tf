data "aws_region" "current" {}

resource "aws_cloudwatch_dashboard" "operations" {
  count          = var.dashboard_enabled ? 1 : 0
  dashboard_name = "${var.project_name}-operations"

  # Existing service metrics only: no log queries, custom metrics, or public sharing.
  dashboard_body = jsonencode({
    start          = "-PT24H"
    periodOverride = "inherit"
    widgets = concat([
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 3
        properties = {
          markdown = "# ${var.project_name} operations\nManaged by Terraform. Change this dashboard through a reviewed PR.\n\nConfigured URL schedule: **${var.schedule_enabled ? "ENABLED" : "DISABLED"}**. This is configuration, not a live Scheduler status query. Missing data does not mean healthy. Lambda Duration is execution time, not URL response time or availability. Per-URL results are stored in DynamoDB history."
        }
      }
      ], [
      for index, graph in [
        {
          title = "Lambda invocations"
          stat  = "Sum"
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", aws_lambda_function.checker.function_name],
          ]
        },
        {
          title = "Lambda internal errors and throttles"
          stat  = "Sum"
          metrics = [
            ["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.checker.function_name],
            ["AWS/Lambda", "Throttles", "FunctionName", aws_lambda_function.checker.function_name],
          ]
        },
        {
          title = "Lambda execution time (ms, not URL latency)"
          stat  = "Average"
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.checker.function_name, { stat = "Average", label = "Average execution" }],
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.checker.function_name, { stat = "p95", label = "p95 execution" }],
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.checker.function_name, { stat = "Maximum", label = "Maximum execution" }],
          ]
        },
        {
          title = "SNS published and delivered notifications"
          stat  = "Sum"
          metrics = [
            ["AWS/SNS", "NumberOfMessagesPublished", "TopicName", aws_sns_topic.alerts.name],
            ["AWS/SNS", "NumberOfNotificationsDelivered", "TopicName", aws_sns_topic.alerts.name],
            ["AWS/SNS", "NumberOfNotificationsFailed", "TopicName", aws_sns_topic.alerts.name],
          ]
        },
        {
          title = "DynamoDB consumed write capacity (not item count)"
          stat  = "Sum"
          metrics = [
            ["AWS/DynamoDB", "ConsumedWriteCapacityUnits", "TableName", aws_dynamodb_table.state.name],
            ["AWS/DynamoDB", "ConsumedWriteCapacityUnits", "TableName", aws_dynamodb_table.history.name],
          ]
        },
        {
          title = "DynamoDB consumed read capacity (not item count)"
          stat  = "Sum"
          metrics = [
            ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", aws_dynamodb_table.state.name],
            ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", aws_dynamodb_table.history.name],
          ]
        }
        ] : {
        type   = "metric"
        x      = (index % 3) * 8
        y      = 3 + floor(index / 3) * 6
        width  = 8
        height = 6
        properties = {
          title    = graph.title
          metrics  = graph.metrics
          stat     = graph.stat
          period   = 300
          region   = data.aws_region.current.region
          view     = "timeSeries"
          stacked  = false
          liveData = false
        }
      }
    ])
  })
}
