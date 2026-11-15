# secrets

Installs operator-provided secret files without Nix, SOPS-on-host, or a
secret value in git.

The operator decrypts the SOPS bundle **outside the repository** into a
temporary directory, then runs:

```sh
ansible-playbook playbooks/site.yml --tags secrets \
  -e secrets_source_dir=/run/operator-secrets \
  -e '{"secrets_files":["event-service/append-token", \
       "event-service/read-token","event-service/consumers.json", \
       "write-broker/identity","write-broker/operator-key", \
       "restic/data-plane.password","restic/r2.env"]}'
```

The play is imported by `site.yml` and skips itself while
`secrets_source_dir` is empty, so a plain converge without a bundle is not an
error; the consuming role still asserts every file it mounts. The play targets
`storage_hosts:data_plane_hosts` only — the hosts whose roles read these files.

The file list is relative to the source directory and mirrors the destination
under `/etc/homelab/secrets`. The role creates each parent directory at `0700`
before it copies, so a nested entry such as `restic/r2.env` or
`event-service/append-token` needs no manual `install -d`. Entries may not be
absolute paths or contain `..`.

The role refuses an empty or relative source directory, refuses a path inside
`.git`, rejects `..` components and symlinks that resolve outside the source
directory, creates `/etc/homelab/secrets` at `0700`, and copies each file at
`0600` root:root with `no_log`. It never decrypts or prints a value. The host
backup units read `restic/data-plane.password` and `restic/r2.env` as root
(`--password-file`, and `AWS_*` from an `EnvironmentFile`). The data-plane units
mount their files read-only, and the `data_plane` role raises exactly those
files to `0640 root:65532` for the container uid; the secret root stays
root-only.

That raise is owned by the untagged `data_plane` play. After rotating a token,
run the full converge before restarting a unit: `--tags secrets` alone replaces
the file at `0600` and a running unit keeps the old inode until it restarts.

After the run, wipe the temporary directory. The decrypted files are the only
copy on the host; keep the SOPS ciphertext in the repository as the source of
truth.
