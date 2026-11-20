#!/usr/bin/env bash
# Load the local SELinux module that lets sudo_t reach the forwarded agent socket
# (design #767, T8; image/selinux/smortress_sudo_rssh.te carries the reasoning).
#
# bootc reconciles /usr, so a rebuilt image ships a new .pp and nothing runs
# semodule: the module in the kernel's policy stays whatever the last boot
# loaded. This unit is that step, and it has to be idempotent in both directions:
# `semodule -i` on an unchanged module is harmless but rewrites the policy store
# and its mtime on every boot, and a stamp alone would call a hand-removed module
# loaded. So it loads when the shipped .pp's digest differs from the one recorded
# with the last successful load, or when the module is absent from the policy.
set -euo pipefail

module=/usr/share/smortress/selinux/smortress_sudo_rssh.pp
module_name=smortress_sudo_rssh
stamp=/var/lib/smortress/selinux/$module_name.sha256

if [[ ! -s $module ]]; then
  echo "selinux-sudo-rssh: $module is missing; the image was built without it" >&2
  exit 1
fi
if ! command -v semodule >/dev/null 2>&1; then
  echo "selinux-sudo-rssh: semodule is not installed" >&2
  exit 1
fi

digest=$(sha256sum "$module" | cut -d' ' -f1)
recorded=
if [[ -f $stamp ]]; then
  read -r recorded <"$stamp" || true
fi

if [[ $recorded == "$digest" ]] && semodule -l | cut -f1 | grep -qx "$module_name"; then
  echo "selinux-sudo-rssh: $module_name is loaded at $digest"
  exit 0
fi

# -i replaces a module of the same name, so an upgraded .pp lands as an edit of
# the previous policy rather than as a second copy.
semodule -i "$module"
install -d -m 0755 "$(dirname "$stamp")"
printf '%s\n' "$digest" >"$stamp"
echo "selinux-sudo-rssh: loaded $module_name at $digest"
