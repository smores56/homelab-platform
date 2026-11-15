#!/usr/bin/env bash
# Static assertions for roles/backup. No host, no ZFS, no restic.
#
#   nix-shell -p python3 --run 'bash ansible/roles/backup/tests/check.sh'
set -uo pipefail

role=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(git -C "$role" rev-parse --show-toplevel)

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { if "$@" >/dev/null 2>&1; then ok "$*"; else bad "$*"; fi; }
refute() { if "$@" >/dev/null 2>&1; then bad "$*"; else ok "not: $*"; fi; }

check test -f "$role/templates/backup.json.j2"
check test -f "$role/templates/backup-runner.py.j2"
check test -f "$role/templates/backup.service.j2"
check test -f "$role/templates/backup.timer.j2"
check test -f "$role/files/lock-drill.sh"
refute test -d "$root/ansible/roles/restic"
refute test -e "$role/templates/snapshot.service.j2"
refute test -e "$role/files/checkpoint-sqlite.py"

check grep -qE '^restic_version: "[0-9]+\.[0-9]+\.[0-9]+"$' "$role/defaults/main.yml"
check grep -qE '^[[:space:]]+(amd64|arm64): [0-9a-f]{64}$' "$role/defaults/main.yml"
check grep -q 'checksum: "sha256:{{ restic_checksums\[restic_arch\] }}"' "$role/tasks/main.yml"
check grep -q 'restic_version not in' "$role/tasks/main.yml"

# The plan is exactly one snapshot dataset, one password, three tiers, groups.
for needle in backup_snapshot_dataset backup_snapshot_root backup_password_file \
  backup_tiers backup_group_specs backup_group_ids; do
  check grep -q "$needle" "$role/templates/backup.json.j2"
done
check grep -q "backup_cadences" "$role/tasks/main.yml"
check grep -q "'snapshot_dataset'" "$role/templates/backup.json.j2"
check grep -q "'password_file'" "$role/templates/backup.json.j2"
check grep -q "'repository_root'" "$role/templates/backup.json.j2"

# The host entry point executes the tested library; restic argv lives there.
check grep -q 'sys.path.insert(0, "/opt/data-plane/lib")' "$role/templates/backup-runner.py.j2"
check grep -q 'from data_plane.backup.plan import' "$role/templates/backup-runner.py.j2"
check grep -q 'from data_plane.backup.runner import run_group, snapshot' "$role/templates/backup-runner.py.j2"
check grep -q 'run_group(plan' "$role/templates/backup-runner.py.j2"
check grep -q 'snapshot(plan' "$role/templates/backup-runner.py.j2"
refute grep -qE '"(restic|copy|backup|forget|snapshots|init)"' "$role/templates/backup-runner.py.j2"
refute grep -q -- '--password-file' "$role/templates/backup-runner.py.j2"
refute grep -q 'RESTIC_PASSWORD' "$role/templates/backup-runner.py.j2"
check grep -q 'fcntl.flock' "$role/templates/backup-runner.py.j2"
check grep -q '"mount", "--bind"' "$role/templates/backup-runner.py.j2"
check grep -q '"umount"' "$role/templates/backup-runner.py.j2"
check grep -q '"zfs", "destroy"' "$role/templates/backup-runner.py.j2"

# Every bind is guarded against a leftover mount and every unmount is fatal, so
# an interrupted run can never make the next one back up the previous generation.
runner=$role/templates/backup-runner.py.j2
check grep -qF 'findmnt", "-rn", "-o", "TARGET", "--target"' "$runner"
check grep -qF 'is already a mountpoint; refusing to stack a bind on it' "$runner"
check grep -qF 'is not a mountpoint after mounting' "$runner"
refute grep -qF 'os.path.isdir(target)' "$runner"
if awk '/^def unmount_tree/,/^def retire_snapshots/' "$runner" | grep -qF 'raise DataPlaneError'; then
  ok "a failed umount stops the run"
else
  bad "a failed umount is swallowed"
fi
if [[ $(grep -cF 'unmount_tree(plan)' "$runner") -ge 3 ]]; then
  ok "unmount runs before mounting, on a signal, and in the finally"
else
  bad "unmount_tree is not wired into the finally and the signal handler"
fi
check grep -qF 'signal.signal(signal.SIGTERM' "$runner"
check grep -qF 'signal.signal(signal.SIGINT' "$runner"

# The plan decides what is live; a missing snapshot tree fails closed instead of
# silently reading the live path.
check grep -qF 'if group.live:' "$runner"
check grep -qF 'has no snapshot mount at' "$runner"

# One failing group never starves the rest of the cadence.
if awk '/^ *for group in groups:/,/^    except DataPlaneError/' "$runner" \
  | grep -qF 'except Exception as exc'; then
  ok "a group failure is caught and the loop continues"
else
  bad "one group failure aborts the cadence"
fi
check grep -qF 'group {group.id} failed: {exc}' "$runner"
check grep -qF 'cache", "--cleanup"' "$runner"

# The restic cache lives on the backup disk, never on the root filesystem, and
# the unit mounts and opens exactly that path.
check grep -qE '^backup_cache_dir: /var/backups/primary/restic-cache$' "$role/defaults/main.yml"
check grep -qF 'repository_roots + [backup_cache_dir]' "$role/templates/backup.service.j2"
check grep -qF 'ReadWritePaths={{ backup_cache_dir }}' "$role/templates/backup.service.j2"
check grep -qF 'Create the root-only restic cache on the mounted backup disk' "$role/tasks/main.yml"
check grep -qF 'backup_local_roots + [backup_cache_dir]' "$role/tasks/main.yml"

# The role installs that library and the unit puts it on PYTHONPATH.
check grep -q 'libs/data_plane' "$role/tasks/main.yml"
check grep -q 'dest: /opt/data-plane/lib/data_plane' "$role/tasks/main.yml"
check grep -q 'directory_mode: "0755"' "$role/tasks/main.yml"
check grep -q 'Environment=PYTHONPATH=/opt/data-plane/lib' "$role/templates/backup.service.j2"
check grep -q 'ReadOnlyPaths=/opt/data-plane/lib' "$role/templates/backup.service.j2"
check grep -qE '^backup_zfs_keep_days: 7$' "$role/defaults/main.yml"

check grep -q 'RequiresMountsFor=' "$role/templates/backup.service.j2"
check grep -q 'AssertPathIsMountPoint={{ mount }}' "$role/templates/backup.service.j2"
check grep -q -- '--cadence %i' "$role/templates/backup.service.j2"

# Retention runs inside each group run after the copies, from the library.
refute test -e "$role/templates/restic-retention.py.j2"
check grep -q -- '"--keep-daily"' "$root/libs/data_plane/backup/restic.py"
check grep -q -- '"--keep-weekly"' "$root/libs/data_plane/backup/restic.py"
check grep -q -- '"--keep-monthly"' "$root/libs/data_plane/backup/restic.py"

check grep -q 'unlock' "$role/files/lock-drill.sh"
check grep -q 'fresh lock was removed' "$role/files/lock-drill.sh"
check grep -q 'expired lock survived' "$role/files/lock-drill.sh"
refute grep -qE 'unlock[^#]*--remove-all' "$role/files/lock-drill.sh"

check grep -q "stat.mode == '0600'" "$role/tasks/main.yml"
check grep -q "stat.pw_name == 'root'" "$role/tasks/main.yml"
check grep -q 'mode: "0700"' "$role/tasks/main.yml"

# No secret on argv, no password in the tree, no retired script or helper.
refute grep -rnE -- '--password([^a-z-]|$)' "$role/tasks" "$role/templates" "$role/files"
refute grep -rnE 'RESTIC_PASSWORD=' "$role/tasks" "$role/templates" "$role/files"
output=$(grep -rnE 'backup_(domains|destinations|repositories|pending_host_groups)' \
  "$role" "$root/ansible/playbooks" "$root/ansible/group_vars/backup.yml" 2>/dev/null \
  | grep -vF 'is not defined' || true)
if [[ -n $output ]]; then
  bad "retired per-domain vars are still referenced" "$output"
else
  ok "retired per-domain vars are not referenced"
fi
refute grep -rnE 'checkpoint-sqlite|manifest_hash|generation_id' \
  "$role/tasks" "$role/templates" "$role/files"

if command -v python3 >/dev/null 2>&1; then
  if python3 - "$root" <<'PY'
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
renderer = root / "scripts" / "render-recovery-groups.py"
spec = importlib.util.spec_from_file_location("render", renderer)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
all_vars, backup_vars = module.load_group_vars()
plan = module.build_host_plan(all_vars, backup_vars)
assert set(plan) == {
    "schema_version",
    "snapshot_dataset",
    "snapshot_root",
    "password_file",
    "tiers",
    "groups",
}, set(plan)
assert plan["schema_version"] == 1
assert plan["snapshot_root"] == "/run/data-plane/current"
assert [tier["name"] for tier in plan["tiers"]] == ["nvme", "hdd", "r2"]
assert plan["password_file"].startswith("/etc/homelab/secrets/restic/")
assert json.dumps(plan).count(".password") == 1
groups = {group["id"]: group for group in plan["groups"]}
assert groups, "no backup groups"
assert groups["host-keys"]["path"] == "var/lib/sbctl"
assert groups["host-keys"]["cadence"] == "media"
assert groups["host-keys"]["tiers"] == ["nvme", "hdd", "r2"]
for group in plan["groups"]:
    assert group["cadence"] in {"fast", "media"}, group
    assert group["tiers"], group
    assert not group["path"].startswith("/"), group
host = subprocess.run(
    [sys.executable, str(renderer), "--host-plan"], capture_output=True, text=True
)
assert host.returncode == 0, host.stderr
assert json.loads(host.stdout) == plan
print("plan ok")
PY
  then
    ok "one plan: recursive snapshot, shared password, per-group repositories"
  else
    bad "backup plan failed static validation"
  fi
else
  printf 'skip python3 missing; plan assertions not run\n'
fi

if command -v python3 >/dev/null 2>&1; then
  if python3 "$root/scripts/render-recovery-groups.py" --check >/dev/null 2>&1; then
    ok "deploy manifest matches the Ansible vars"
  else
    bad "deploy manifest is stale; run scripts/render-recovery-groups.py"
  fi
else
  printf 'skip python3 missing; manifest drift check not run\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
