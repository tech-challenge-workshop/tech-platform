output "dashboard_urls" {
  description = "Direct links to the three dashboards, for the README and the demo video"
  value = {
    work_orders    = "https://app.datadoghq.com/dashboard/${datadog_dashboard.work_orders.id}"
    service_health = "https://app.datadoghq.com/dashboard/${datadog_dashboard.service_health.id}"
    saga           = "https://app.datadoghq.com/dashboard/${datadog_dashboard.saga.id}"
  }
}

output "monitor_ids" {
  description = "IDs of the created monitors"
  value = {
    error_rate         = { for k, m in datadog_monitor.service_error_rate : k => m.id }
    saga_compensations = datadog_monitor.saga_compensations.id
  }
}
