# secrets

Installs operator-provided secret files without Nix, SOPS-on-host, or a secret
value in git.

The operator decrypts the SOPS bundle **outside the repository** into a
temporary directory, then runs:

```sh
ansible-playbook playbooks/site.yml --tags secrets \
  -e secrets_source_dir=/run/operator-secrets
```

There is no file list on the command line. The policy is `host_secret_files` in
`group_vars/all.yml`, one entry per file:

```yaml
host_secret_files:
  - src: restic/data-plane.password          # root-only, storage host
  - src: event-service/append-token
    unit: homelab-event-service              # mounted, data-plane host
    mount: /run/secrets/event/append-token
```

`src` is relative to both `secrets_source_dir` and the destination root. An
entry with a `unit` installs on `data_plane_hosts` and is copied `root:<container
gid>` `0640`; an entry without one installs on `storage_hosts` and is copied
`root:root` `0600`. The parent chain stays `0700`, so the secret root remains
root-only and the numeric gid exists for the container's mount, not as a host
group.

The role creates each parent directory before copying, rejects absolute paths,
`..` components and symlinks that resolve outside the decrypted directory, and
marks every copy `no_log`. It never decrypts or prints a value.

The copy owns the final owner and mode, so a drift is corrected on the next run
and no other role writes that file. A rotation replaces the file's content and
`systemctl try-restart`s only a unit that is installed and running and whose
content changed; a stopped or recovery-fenced unit stays stopped.

After the run, wipe the temporary directory. The decrypted files are the only
copy on the host; keep the SOPS ciphertext in the repository as the source of
truth.
