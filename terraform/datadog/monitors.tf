locals {
  notify = length(var.notification_handles) > 0 ? "\n\n${join(" ", var.notification_handles)}" : ""
}

# REQUISITOS §3.8: alerts on work order processing failures. One monitor covers
# the technical symptom (requests failing), the other the business symptom
# (orders being cancelled by saga compensation).

resource "datadog_monitor" "service_error_rate" {
  for_each = toset(var.services)

  name = "[${var.env}] ${each.value} error rate above ${var.error_rate_threshold * 100}%"
  type = "query alert"

  query = join("", [
    "sum(last_5m):",
    "sum:trace.express.request.errors{env:${var.env},service:${each.value}}.as_count()",
    " / ",
    "sum:trace.express.request.hits{env:${var.env},service:${each.value}}.as_count()",
    " > ${var.error_rate_threshold}",
  ])

  message = <<-EOT
    {{#is_alert}}
    `${each.value}` is failing more than ${var.error_rate_threshold * 100}% of its requests over the last 5 minutes.

    A work order may be stuck mid-saga. Check the Saga & Integrations dashboard for the failing step, then the traces for that service.
    {{/is_alert}}
    {{#is_recovery}}
    `${each.value}` error rate is back to normal.
    {{/is_recovery}}${local.notify}
  EOT

  monitor_thresholds {
    critical = var.error_rate_threshold
  }

  # A single failed request in an idle window is not an incident.
  require_full_window = false
  notify_no_data      = false
  renotify_interval   = 60

  tags = ["project:tech-challenge", "env:${var.env}", "service:${each.value}"]
}

resource "datadog_monitor" "saga_compensations" {
  name = "[${var.env}] Work orders being cancelled by saga compensation"
  type = "query alert"

  query = "sum(last_15m):sum:work_order.status_changed{env:${var.env},to:cancelled}.as_count() > ${var.cancellation_threshold}"

  message = <<-EOT
    {{#is_alert}}
    More than ${var.cancellation_threshold} work orders were cancelled in the last 15 minutes.

    Cancellation is the saga's compensation path, so this means orders are failing somewhere between parts reservation, quote generation and payment — not that customers are rejecting quotes in unusual numbers.

    Start from the Saga & Integrations dashboard and look at which step's error count rose.
    {{/is_alert}}
    {{#is_recovery}}
    Cancellation rate is back to normal.
    {{/is_recovery}}${local.notify}
  EOT

  monitor_thresholds {
    critical = var.cancellation_threshold
  }

  require_full_window = false
  notify_no_data      = false
  renotify_interval   = 60

  tags = ["project:tech-challenge", "env:${var.env}", "scope:saga"]
}
