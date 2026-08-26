# Ansible — Personal HomeLab

My personal Ansible repository to configure my homelab. It describes one machine,
a mini-PC serving as a homeserver, and everything running on it.

> [!NOTE]
> I'm describing MY OWN setup, for MY OWN homelab. I do not intend to share this
> so people can reuse it. I'm open to discussions about improvements (especially
> about security or the use of Ansible), but don't ask for features. I also
> discourage cloning this repository: it would likely be more useful to write your
> own for YOUR OWN homelab. Below, "you" refers to the future me.

## The machine

- Mini PC — HP EliteDesk 800 G2 (Intel Core i5 6500U, 8GB DDR4, 256GB SSD), Debian 12 bookworm
- Modem supplied by the ISP

## What is managed

| Role | What it does |
| --- | --- |
| `common` | Timezone, locale, the packages that are actually installed |
| `ssh` | sshd hardening, authorized keys, fail2ban, UFW |
| `docker` | Docker CE from the upstream deb822 repository, `daemon.json`, the `docker` group |
| `caddy` | Reverse proxy: main `Caddyfile` plus one vhost file per site, generated from `caddy_sites` |
| `jellyfin` | Media account, media libraries, the Jellyfin container |
| `homepage` | The dashboard container and its whole `/etc/homepage/config` tree |
| `authelia` | The SSO portal: configuration, users database, secrets, container |
| `arbitrage_ffv` | The Laravel app and its MySQL database |
| `compose_app` | Generic role, applied once per entry of `compose_apps` (affine, penpot, scholarsome, uptime-kuma) |

Services reachable from the outside, all proxied by Caddy:

| Domain | Upstream |
| --- | --- |
| `dashboard.homelab.alexandre-gerault.fr` | homepage, 8097 |
| `bibliofilm.alexandre-gerault.fr` | jellyfin, 8096 |
| `affine.alexandre-gerault.fr` | affine, 3010 |
| `penpot.alexandre-gerault.fr` | penpot, 9001 |
| `scholarsome.alexandre-gerault.fr` | scholarsome, 4444 |
| `monitor.alexandre-gerault.fr` | uptime-kuma, 3001 |
| `arbitrageffv.alexandre-gerault.fr` | arbitrage_ffv, 8000 |
| `authelia.alexandre-gerault.fr` | authelia, 8098 |
| `excalidraw.alexandre-gerault.fr` | excalidraw, 5000 — **no container, it was started with `--rm`** |

## Variables

Everything that is not a secret lives in `group_vars/all/main.yml`, in plain sight
and versioned. Every secret lives in `group_vars/all/vault.yml`, encrypted with
`ansible-vault` and versioned too — that is the point: a disk failure must not
take the configuration with it.

`host_vars/homeserver.yml` only maps the connection variables onto
`homeserver_host`, `ssh_port` and `homeserver_user`.

The vault holds:

| Variable | Used by |
| --- | --- |
| `vault_ssh_authorized_keys` | `ssh` — a dict of account name to list of public keys |
| `vault_homepage_jellyfin_api_key` | `homepage` — the Jellyfin widget |
| `vault_affine_db_password` | `compose_app` — affine's Postgres |
| `vault_scholarsome_database_password`, `vault_scholarsome_jwt_secret` | `compose_app` — scholarsome |
| `vault_arbitrage_ffv_app_key`, `vault_arbitrage_ffv_db_password`, `vault_arbitrage_ffv_mysql_root_password` | `arbitrage_ffv` |
| `vault_authelia_jwt_secret`, `vault_authelia_session_secret`, `vault_authelia_storage_encryption_key` | `authelia` |
| `vault_authelia_users` | `authelia` — the file backend accounts, with argon2id hashes |

## Putting a site behind the SSO

Authelia protects nothing by default. Add `protect: true` to an entry of
`caddy_sites` and re-run the `caddy` tag:

```yaml
  - name: penpot
    domain: penpot.alexandre-gerault.fr
    upstream_port: 9001
    log: true
    protect: true
```

Accounts live in `vault_authelia_users`. To add one, generate the hash with the
image itself and put it in the vault:

```bash
docker run --rm ghcr.io/authelia/authelia:4.38 \
  authelia crypto hash generate argon2 --password 'the-password'
```

## Running it

The vault password is read from `~/.ansible/vault-pass`, as declared in
`ansible.cfg`. That file is **not** in the repository — keep a copy in your
password manager, it is the one thing that cannot be recovered from the server.

```bash
# once
brew install ansible          # or pipx install ansible
ansible-galaxy install -r requirements.yml

# every run — -K prompts for the sudo password
ansible-playbook playbook.yml -K
```

Useful invocations:

```bash
ansible-playbook playbook.yml -K --check --diff     # dry run, shows the drift
ansible-playbook playbook.yml -K --tags caddy       # one role
ansible-vault edit group_vars/all/vault.yml         # edit the secrets
```

## Known gaps

Fixed in the repository, pending a real playbook run:

- **Published ports.** Every container port is now bound to
  `docker_publish_address` (`127.0.0.1`). They used to be on `0.0.0.0`: Docker
  writes its own iptables rules, so UFW never saw the traffic and the reverse
  proxy was bypassed. Verified from outside on 2026-08-25 — 3001, 3010, 4444,
  8000, 8096, 8097 and 1080 all answered, 1080 being Penpot's mailcatcher, which
  serves every mail the instance sends with no authentication. Jellyfin moves
  from host to bridge networking for the same reason; that costs DLNA and client
  auto-discovery on the LAN, recoverable with `jellyfin_network_mode: host`.
- **fail2ban** was protecting nothing. Debian 12 ships no rsyslog and no
  `/var/log/auth.log`, so the stock `backend = auto` found no log file, and the
  stock `port = ssh` watched 22 while sshd listens on 35123. `jail.local` now
  pins `backend = systemd` and the real port.
- **`AllowUsers`** no longer lists `alexandre`, an account that does not exist.

Still open, because they change the running server rather than describe it:

1. **Leaked credentials.** The arbitrage_ffv `APP_KEY` and MySQL password were
   passed on the command line and sit in `~/.bash_history`. They need rotating,
   which means recreating the database user.
2. **Penpot** runs with the stock `PENPOT_SECRET_KEY: change-this-insecure-key`
   from the upstream sample compose file. It derives the session and invitation
   keys.
3. **Jellyfin** runs as root inside its container.
4. **Dead services.** excalidraw is gone — it was started with `--rm` and did not
   survive a reboot — and coolify is installed with no container running. Their
   leftovers are the `excalidraw` vhost, the `coolify` docker network and
   `/data/coolify`.
5. **The legacy authelia stack** under `~/apps/authelia` is superseded by the
   `authelia` role and can be deleted once the role has run; its secrets are in
   the vault.
6. **No backups.** Nothing on this machine is backed up, which is what turned a
   disk format into the loss of this repository.
