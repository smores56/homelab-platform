# The zone is looked up by name: the token is scoped to this one zone, so the ID
# is not an input the operator has to transcribe.
data "cloudflare_zone" "this" {
  filter = {
    name = var.domain
  }
}
