terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

variable "billing_account" {
  description = "Billing account id (the only required input)."
  type        = string
}

variable "amount" {
  description = "Monthly budget amount, whole units of currency_code."
  type        = number
}

variable "currency_code" {
  description = "Must match the billing account currency."
  type        = string
  default     = "USD"
}

variable "thresholds" {
  description = "Alert thresholds as fractions of amount."
  type        = list(number)
  default     = [0.5, 0.9, 1.0]
}

variable "display_name" {
  type    = string
  default = "compass-cost-cap"
}

resource "google_billing_budget" "cap" {
  billing_account = var.billing_account
  display_name    = var.display_name

  amount {
    specified_amount {
      currency_code = var.currency_code
      units         = tostring(var.amount)
    }
  }

  dynamic "threshold_rules" {
    for_each = var.thresholds
    content {
      threshold_percent = threshold_rules.value
    }
  }
}
