variable "account_id" {
  type        = string
  description = "Cloudflare account ID (the 32-character account tag)."

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.account_id))
    error_message = "account_id is the 32-character hex account tag, not the account name."
  }
}

variable "domain" {
  type        = string
  description = "Apex zone whose subdomains are exposed."

  validation {
    condition     = can(regex("^[a-z0-9.-]+$", var.domain))
    error_message = "domain is the bare apex, lowercase, without a trailing dot."
  }
}

variable "tailscale_login" {
  type        = string
  description = "The tailnet's own login for the owner (e.g. user@github), which is what a Tailscale group member must be. A GitHub-linked login, not the address of an identity provider."

  validation {
    condition     = can(regex("^[^@]+@[^@]+$", var.tailscale_login))
    error_message = "tailscale_login is the login Tailscale shows for the account, such as smores56@github."
  }
}

variable "edge_ipv4" {
  type        = string
  description = "Public IPv4 of the edge VPS (design #725). Empty until the cutover, which is why it gates the A records: setting it creates them. The edge is not proxied, so this address is what the internet reaches."
  default     = ""

  validation {
    condition = var.edge_ipv4 == "" || can(regex(
      "^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])$",
      var.edge_ipv4,
    ))
    error_message = "edge_ipv4 is either empty or a single dotted-quad IPv4 address (the edge has one IPv4 and no IPv6 allocation)."
  }
}

variable "tailscale_readonly" {
  type        = bool
  description = "Ask the Tailscale provider for the read-only scope set in local.tailscale_plan_scopes (design #841). The pre-merge plan sets it from TF_VAR_tailscale_readonly; an apply leaves it false so the provider takes the write client's own scopes."
  default     = false
}

variable "tailnet" {
  type        = string
  description = "Tailnet name (the label before .ts.net) whose policy tofu/tailscale.tf owns. Empty until the owner supplies it at cutover, and the ACL resource is gated on it so nothing about the tailnet is planned while it is empty."
  default     = ""

  validation {
    condition     = var.tailnet == "" || can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.tailnet))
    error_message = "tailnet is either empty or the tailnet name (lowercase, no dots, no .ts.net suffix)."
  }
}
