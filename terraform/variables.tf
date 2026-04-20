variable "vultr_api_key" {
  description = "Vultr API key — set via TF_VAR_vultr_api_key"
  type        = string
  sensitive   = true
}

variable "bunny_api_key" {
  description = "Bunny.net API key — set via TF_VAR_bunny_api_key"
  type        = string
  sensitive   = true
}

variable "vultr_region" {
  description = "Vultr region ID (e.g. ewr, atl, lax, ord, sea, sjc, dfw, mia)"
  type        = string
  default     = "ewr"
}

variable "vultr_plan" {
  description = "Vultr plan ID"
  type        = string
  default     = "vc2-1c-1gb"
}

variable "vultr_ssh_key_ids" {
  description = "Vultr SSH key IDs to authorize on the instance"
  type        = list(string)
  default     = []
}

variable "domain" {
  description = "Base domain for the tunnel (e.g. example.com → *.example.com subdomains)"
  type        = string
}
