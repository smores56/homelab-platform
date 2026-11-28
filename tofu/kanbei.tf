# Kanbei: a retired public hostname and the route it used (SDLC #586).
#
# No resource is declared here. Its Cloudflare Access application is deleted and
# the host tunnel's wildcard record is retired (#833); the ingress rule in
# nix-config (`webProxy.services.kanbei`) is the only piece left, and it has no
# connector to answer it.
#
# This file stays as the note `docs/cloudflare.md` references; it declares no
# resource.
