variable "datadog_api_url" {
  description = "Datadog API endpoint for the organisation's site (US1 by default)"
  type        = string
  default     = "https://api.datadoghq.com/"
}

variable "env" {
  description = "Value of the env tag the services report, used to scope every query"
  type        = string
  default     = "development"
}

variable "services" {
  description = "Services that report APM traces, in display order"
  type        = list(string)
  default = [
    "work-order-service",
    "billing-service",
    "execution-service",
  ]
}

variable "error_rate_threshold" {
  description = "Fraction of failing requests that triggers the error-rate monitor"
  type        = number
  default     = 0.05
}

variable "cancellation_threshold" {
  description = "Number of work orders cancelled in the evaluation window that triggers the saga monitor"
  type        = number
  default     = 3
}

variable "notification_handles" {
  description = "Datadog notification targets appended to every monitor message, e.g. [\"@slack-oficina\"]"
  type        = list(string)
  default     = []
}
