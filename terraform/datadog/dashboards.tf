locals {
  scope = "env:${var.env}"

  # Statuses a work order spends measurable time in. FINISHED and DELIVERED are
  # terminal, so there is no "time spent" to chart for them.
  tracked_statuses = ["received", "in_diagnosis", "awaiting_approval", "in_execution"]
}

# Dashboard 1 — the business view REQUISITOS §3.8 asks for by name: daily work
# order volume and average time per status.
resource "datadog_dashboard" "work_orders" {
  title       = "Tech Challenge — Work Orders"
  description = "Daily work order volume and how long orders sit in each status."
  layout_type = "ordered"

  widget {
    timeseries_definition {
      title = "Work orders opened per day"

      request {
        q            = "sum:work_order.status_changed{${local.scope},to:received}.as_count().rollup(sum, 86400)"
        display_type = "bars"
      }
    }
  }

  widget {
    query_value_definition {
      title     = "Work orders opened (selected period)"
      autoscale = true
      precision = 0

      request {
        q          = "sum:work_order.status_changed{${local.scope},to:received}.as_count()"
        aggregator = "sum"
      }
    }
  }

  widget {
    toplist_definition {
      title = "Status transitions by destination"

      request {
        q = "top(sum:work_order.status_changed{${local.scope}} by {to}.as_count(), 10, 'sum', 'desc')"
      }
    }
  }

  widget {
    timeseries_definition {
      title = "Average time spent in each status (seconds)"

      dynamic "request" {
        for_each = local.tracked_statuses

        content {
          q            = "avg:work_order.status_duration{${local.scope},status:${request.value}}"
          display_type = "line"

          style {
            line_type = "solid"
          }
        }
      }
    }
  }

  widget {
    query_value_definition {
      title     = "Average execution time (seconds)"
      autoscale = true
      precision = 1

      request {
        q          = "avg:work_order.status_duration{${local.scope},status:in_execution}"
        aggregator = "avg"
      }
    }
  }

  widget {
    query_value_definition {
      title     = "Work orders cancelled"
      autoscale = true
      precision = 0

      request {
        q          = "sum:work_order.status_changed{${local.scope},to:cancelled}.as_count()"
        aggregator = "sum"

        conditional_formats {
          comparator = ">"
          value      = 0
          palette    = "white_on_yellow"
        }
      }
    }
  }
}

# Dashboard 2 — API latency, throughput and error rate, plus the healthchecks
# and resource usage §3.8 requires once the services run on Kubernetes.
resource "datadog_dashboard" "service_health" {
  title       = "Tech Challenge — Service Health"
  description = "Latency, throughput and error rate per service."
  layout_type = "ordered"

  widget {
    timeseries_definition {
      title = "Request latency p95 by service"

      dynamic "request" {
        for_each = var.services

        content {
          q            = "p95:trace.express.request{${local.scope},service:${request.value}}"
          display_type = "line"
        }
      }
    }
  }

  widget {
    timeseries_definition {
      title = "Request rate by service"

      dynamic "request" {
        for_each = var.services

        content {
          q            = "sum:trace.express.request.hits{${local.scope},service:${request.value}}.as_rate()"
          display_type = "area"
        }
      }
    }
  }

  widget {
    timeseries_definition {
      title = "Errors by service"

      dynamic "request" {
        for_each = var.services

        content {
          q            = "sum:trace.express.request.errors{${local.scope},service:${request.value}}.as_count()"
          display_type = "bars"
        }
      }
    }
  }

  widget {
    timeseries_definition {
      title = "Container CPU usage by service"

      request {
        q            = "avg:container.cpu.usage{${local.scope}} by {kube_deployment}"
        display_type = "line"
      }
    }
  }

  widget {
    timeseries_definition {
      title = "Container memory usage by service"

      request {
        q            = "avg:container.memory.usage{${local.scope}} by {kube_deployment}"
        display_type = "line"
      }
    }
  }
}

# Dashboard 3 — the distributed transaction itself: how long each saga step
# takes and where integrations fail.
resource "datadog_dashboard" "saga" {
  title       = "Tech Challenge — Saga & Integrations"
  description = "Duration of each orchestrated saga step and failures across service boundaries."
  layout_type = "ordered"

  widget {
    timeseries_definition {
      title = "Saga step duration (p95)"

      request {
        q            = "p95:trace.saga{${local.scope}} by {resource_name}"
        display_type = "line"
      }
    }
  }

  widget {
    timeseries_definition {
      title = "Saga step throughput"

      request {
        q            = "sum:trace.saga.hits{${local.scope}} by {resource_name}.as_count()"
        display_type = "bars"
      }
    }
  }

  widget {
    timeseries_definition {
      title = "Saga compensations"

      request {
        q            = "sum:work_order.status_changed{${local.scope},to:cancelled}.as_count()"
        display_type = "bars"
      }
    }
  }

  widget {
    timeseries_definition {
      title = "RabbitMQ span errors"

      request {
        q            = "sum:trace.amqp.command.errors{${local.scope}} by {service}.as_count()"
        display_type = "bars"
      }
    }
  }

  widget {
    timeseries_definition {
      title = "Database span errors"

      request {
        q            = "sum:trace.pg.query.errors{${local.scope}} by {service}.as_count()"
        display_type = "bars"
      }
    }
  }
}
