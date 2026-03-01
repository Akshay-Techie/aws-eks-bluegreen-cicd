# ============================================================
# CLOUDWATCH MODULE — modules/cloudwatch/main.tf
# Sets up monitoring, alerting and logging for the project
#
# WHAT THIS MODULE CREATES:
# ─────────────────────────────────────────────────────────────
#
#  EKS Cluster
#      │
#      ├── Logs ──────────► CloudWatch Log Groups
#      │                         │
#      │                         ▼
#      └── Metrics ────────► CloudWatch Alarms
#                                │
#                                ▼
#                           SNS Topic ──► Email Alert
#                                         (your inbox)
#
# COMPONENTS:
#   Log Groups  → store EKS control plane + app logs
#   Alarms      → trigger when metrics cross thresholds
#   SNS Topic   → sends email when alarm fires
#   Dashboard   → visual overview of cluster health
# ============================================================


# ---- Module Input Variables --------------------------------

variable "project_name" { type = string }
variable "cluster_name" { type = string }
variable "alert_email"  { type = string }
variable "aws_region"   { type = string }

# Needed to get account ID for alarm ARNs in dashboard
data "aws_caller_identity" "current" {}

# ============================================================
# SNS TOPIC — notification channel
#
# UNDERSTANDING SNS:
# SNS = Simple Notification Service
# Think of it as a notification router:
#
#   CloudWatch Alarm fires
#         │
#         ▼
#     SNS Topic ──────► Email (your inbox)
#                  ──── SMS (optional)
#                  ──── Lambda (optional)
#                  ──── Slack (via Lambda)
#
# We use email → simplest, no extra setup needed
# ============================================================

resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts"

  tags = { Name = "${var.project_name}-alerts" }
}

# Subscribe your email to receive alerts
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email

  # ⚠️ After terraform apply:
  # Check your email → click "Confirm subscription"
  # Without confirming → you won't receive alerts
}


# ============================================================
# CLOUDWATCH LOG GROUPS
#
# UNDERSTANDING LOG GROUPS:
# Log Group = container for log streams
# Log Stream = sequence of log events from one source
#
# retention_in_days = 7:
# → Keep logs for 7 days then auto-delete
# → Saves cost — logs storage costs money
# → For production use 30-90 days
#
# We create separate log groups for:
# → EKS control plane logs (API server, scheduler etc)
# → Application logs (your blue/green pods)
# ============================================================

# EKS control plane logs
resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 7

  tags = { Name = "${var.project_name}-eks-logs" }
}

# Application logs from pods
resource "aws_cloudwatch_log_group" "app" {
  name              = "/aws/eks/${var.cluster_name}/app"
  retention_in_days = 7

  tags = { Name = "${var.project_name}-app-logs" }
}


# ============================================================
# CLOUDWATCH ALARMS
#
# UNDERSTANDING ALARMS:
# Alarm = "watch this metric, alert me if it crosses threshold"
#
# States:
# OK        → metric is within normal range
# ALARM     → metric crossed threshold → SNS notified
# INSUFFICIENT_DATA → not enough data points yet
#
# period = 300 → check every 5 minutes
# evaluation_periods = 2 → must be in ALARM for 2 checks
# → prevents false alerts from brief spikes
# ============================================================

# Alarm 1 — High CPU on EKS nodes
resource "aws_cloudwatch_metric_alarm" "node_cpu_high" {
  alarm_name          = "${var.project_name}-node-cpu-high"
  alarm_description   = "EKS node CPU usage above 80% for 10 minutes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "node_cpu_utilization"
  namespace           = "ContainerInsights"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.cluster_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = { Name = "${var.project_name}-cpu-alarm" }
}

# Alarm 2 — High Memory on EKS nodes
resource "aws_cloudwatch_metric_alarm" "node_memory_high" {
  alarm_name          = "${var.project_name}-node-memory-high"
  alarm_description   = "EKS node memory usage above 80% for 10 minutes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "node_memory_utilization"
  namespace           = "ContainerInsights"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.cluster_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = { Name = "${var.project_name}-memory-alarm" }
}

# Alarm 3 — Pod restart too many times (crashlooping)
resource "aws_cloudwatch_metric_alarm" "pod_restarts" {
  alarm_name          = "${var.project_name}-pod-restarts"
  alarm_description   = "Pod restarting too frequently — possible crashloop"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "pod_number_of_container_restarts"
  namespace           = "ContainerInsights"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.cluster_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = { Name = "${var.project_name}-restart-alarm" }
}


# ============================================================
# CLOUDWATCH DASHBOARD
#
# UNDERSTANDING DASHBOARDS:
# Dashboard = visual overview of your metrics in one place
# Instead of clicking through multiple pages:
# → Open dashboard → see everything at once
#
# We create widgets for:
# → CPU utilization over time (line graph)
# → Memory utilization over time (line graph)
# → Pod restart count (number widget)
# ============================================================

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project_name}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "EKS Node CPU Utilization %"
          view   = "timeSeries"
          region = var.aws_region
          stat   = "Average"
          period = 300
          metrics = [
            [
              "ContainerInsights",
              "node_cpu_utilization",
              "ClusterName",
              var.cluster_name,
              { stat = "Average" }
            ]
          ]
          yAxis = {
            left = { min = 0, max = 100 }
          }
          annotations = {
            horizontal = [
              {
                label = "High CPU threshold"
                value = 80
                color = "#ff0000"
              }
            ]
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "EKS Node Memory Utilization %"
          view   = "timeSeries"
          region = var.aws_region
          stat   = "Average"
          period = 300
          metrics = [
            [
              "ContainerInsights",
              "node_memory_utilization",
              "ClusterName",
              var.cluster_name,
              { stat = "Average" }
            ]
          ]
          yAxis = {
            left = { min = 0, max = 100 }
          }
          annotations = {
            horizontal = [
              {
                label = "High memory threshold"
                value = 80
                color = "#ff0000"
              }
            ]
          }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Pod Restart Count"
          view   = "timeSeries"
          region = var.aws_region
          stat   = "Sum"
          period = 300
          metrics = [
            [
              "ContainerInsights",
              "pod_number_of_container_restarts",
              "ClusterName",
              var.cluster_name,
              { stat = "Sum" }
            ]
          ]
          annotations = {
            horizontal = [
              {
                label = "Restart threshold"
                value = 5
                color = "#ff6600"
              }
            ]
          }
        }
      },
      {
        type   = "alarm"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title = "Active Alarms"
          alarms = [
            "arn:aws:cloudwatch:${var.aws_region}:${data.aws_caller_identity.current.account_id}:alarm:${var.project_name}-node-cpu-high",
            "arn:aws:cloudwatch:${var.aws_region}:${data.aws_caller_identity.current.account_id}:alarm:${var.project_name}-node-memory-high",
            "arn:aws:cloudwatch:${var.aws_region}:${data.aws_caller_identity.current.account_id}:alarm:${var.project_name}-pod-restarts"
          ]
        }
      }
    ]
  })
}


# ============================================================
# MODULE OUTPUTS
# ============================================================

output "sns_topic_arn" {
  description = "SNS topic ARN for alerts"
  value       = aws_sns_topic.alerts.arn
}

output "dashboard_url" {
  description = "CloudWatch dashboard URL"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}