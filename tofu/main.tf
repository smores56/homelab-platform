# The zone is looked up by name: the token is scoped to this one zone, so the ID
# is not an input the operator has to transcribe.
data "cloudflare_zone" "this" {
  filter = {
    name = var.domain
  }
}

locals {
  # Let's Encrypt account URI, in the exact form the ACME client writes into a
  # CSR. CAA `accounturi` compares the string literally, so a staging directory
  # URL yields a staging pin and the two must not be mixed.
  acme_account_uri = "${trimsuffix(var.acme_directory, "/directory")}/acme/acct/${var.acme_account_id}"
}
