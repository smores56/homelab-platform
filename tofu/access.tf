# The zone declares no Cloudflare Access objects (SDLC #833 T1). Every
# application and policy, and the `local.public_apps` set that fed the public
# bypass one, is retired: nothing they gated resolves to a live origin.
#
# The blocks are deleted rather than emptied from state. `prevent_destroy` is
# read from configuration, so an object whose block is gone plans a destroy, and
# the owner's apply removes it without a `tofu state rm` first.
#
# The public hostnames are served by the smoresnet edge, and the two agent UIs
# answer the tailnet, so no name is left behind a gate.
