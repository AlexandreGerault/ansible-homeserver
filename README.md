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
| `qbittorrent` | The torrent client and the gluetun container that holds its VPN tunnel |
| `arr_stack` | Prowlarr, Sonarr, Radarr, Bazarr and Jellyseerr, plus the wiring between them |
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
| `torrent.alexandre-gerault.fr` | qbittorrent, 8099 — **behind the SSO** |
| `prowlarr.alexandre-gerault.fr` | prowlarr, 9696 — **behind the SSO** |
| `sonarr.alexandre-gerault.fr` | sonarr, 8989 — **behind the SSO** |
| `radarr.alexandre-gerault.fr` | radarr, 7878 — **behind the SSO** |
| `bazarr.alexandre-gerault.fr` | bazarr, 6767 — **behind the SSO** |
| `requests.alexandre-gerault.fr` | jellyseerr, 5055 — authenticates against Jellyfin instead |
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
| `vault_qbittorrent_openvpn_user`, `vault_qbittorrent_openvpn_password` | `qbittorrent` — the CyberGhost manual-configuration credentials, not the account login |
| `vault_qbittorrent_openvpn_cert`, `vault_qbittorrent_openvpn_key` | `qbittorrent` — the `client.crt` and `client.key` of the same manual configuration, as PEM block scalars |
| `vault_qbittorrent_password_pbkdf2` | `qbittorrent` — the WebUI password, PBKDF2 |
| `vault_qbittorrent_webui_password` | `arr_stack` and `homepage` — the same WebUI password in clear, which is what Sonarr and Radarr log in with |
| `vault_prowlarr_api_key`, `vault_sonarr_api_key`, `vault_radarr_api_key`, `vault_bazarr_api_key` | `arr_stack` and `homepage` — 32 hex characters each |

The four *arr keys are yours to pick rather than the applications': generating
them here is what lets the playbook wire Prowlarr to Sonarr and Radarr, and lets
the Homepage widgets work, instead of leaving both as a manual first-run step.

```bash
python3 -c 'import secrets; print(secrets.token_hex(16))'
```

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

## The torrent client and its VPN

qBittorrent has no network interface of its own. It runs with
`network_mode: service:gluetun`, inside the network namespace of a
[gluetun](https://github.com/qdm12/gluetun) container that holds the OpenVPN
tunnel and a firewall that drops everything not going through it. If the VPN
drops, the client loses the internet instead of falling back to the bare
connection — that is the point of the arrangement, and it is why the two are one
compose project in `/etc/qbittorrent` rather than two `docker_container` tasks:
only compose gives an ordering guarantee when gluetun is recreated.

The tunnel goes to **CyberGhost**, over OpenVPN, through the provider gluetun
has built in. That is worth stating because it decides two things: the exit
country is a variable rather than a downloaded `.ovpn`
(`qbittorrent_vpn_server_countries`), and there is no forwarded port, ever.

The WebUI is published by the *gluetun* container (`127.0.0.1:8099`), because
that is where the network stack lives, and it is proxied by Caddy with
`protect: true`, so it sits behind Authelia.

Downloads land in `/var/jellyfin/media/downloads/{incomplete,complete}`, written
by a `qbittorrent` service account in the `jellyfin` group with `UMASK=002`, on
setgid directories. Finished files are readable by Jellyfin where they are —
point a library at `complete` and nothing needs copying or chowning.

### Filling the vault

The provider is CyberGhost, over OpenVPN. gluetun knows it natively — it carries
the server list and the CyberGhost root CA — so there is no `.ovpn` file to keep
in the vault and no hostname to resolve by hand; the country to exit from is
plain configuration, in `qbittorrent_vpn_server_countries`.

What it cannot invent is the account. CyberGhost authenticates a manual OpenVPN
client with a username and password *and* a client certificate and key, and all
four come from the same "manual configuration" in the dashboard — the username
and password there are **not** the account login. `TODO-qbittorrent.md` walks
through where to click and how to split the downloaded ZIP into the four keys.

```bash
ansible-vault edit group_vars/all/vault.yml
```

```yaml
vault_qbittorrent_openvpn_user: the-generated-username
vault_qbittorrent_openvpn_password: the-generated-password
vault_qbittorrent_openvpn_cert: |
  -----BEGIN CERTIFICATE-----
  ...
  -----END CERTIFICATE-----
vault_qbittorrent_openvpn_key: |
  -----BEGIN PRIVATE KEY-----
  ...
  -----END PRIVATE KEY-----
vault_qbittorrent_password_pbkdf2: "@ByteArray(...)"
```

The four are written to `/etc/qbittorrent/secrets/` and passed as compose
secrets, so they stay out of `docker inspect` and the container's environment.
The file names are gluetun's own: `openvpn_user`, `openvpn_password`,
`openvpn_clientcrt`, `openvpn_clientkey`. The two PEM ones keep their armour
lines — gluetun runs those through a PEM parser and base64s them itself, which
is the one place it accepts anything but a single base64 line.

The WebUI password is stored the way qBittorrent stores it, PBKDF2-HMAC-SHA512
over 100000 iterations:

```bash
python3 -c '
import base64, hashlib, os, getpass
p = getpass.getpass().encode()
s = os.urandom(16)
h = hashlib.pbkdf2_hmac("sha512", p, s, 100000)
print("@ByteArray(" + base64.b64encode(s).decode() + ":" + base64.b64encode(h).decode() + ")")
'
```

### Checking the tunnel actually holds

```bash
# the public address gluetun sees — must be the VPN's, not the ISP's
docker exec gluetun wget -qO- http://127.0.0.1:8000/v1/publicip/ip

# the same, from inside the torrent client
docker exec qbittorrent curl -s https://ipinfo.io/ip
```

Both must return the VPN address. If the second one returns anything at all
while gluetun is stopped, the namespace sharing is broken.

### What Ansible does *not* manage

`qBittorrent.conf` is rewritten wholesale by qBittorrent every time it exits, so
Ansible seeds it once and then leaves it alone: whatever you change in the WebUI
sticks. The seed sets the save paths, the WebUI credentials, host header
validation for the vhost, and binds the session to `tun0` as a second killswitch
under gluetun's. To make the template authoritative again for one run:

```bash
ansible-playbook playbook.yml -K --tags qbittorrent -e qbittorrent_reset_config=true
```

Incoming peer connections do not work, and cannot: CyberGhost forwards no port,
and gluetun only implements port forwarding for PIA, PrivateVPN and ProtonVPN.
Outgoing connections to peers are unaffected, so downloads work — it costs seed
ratio and slower swarm discovery, nothing else. There is no setting to fix here.

## The *arr stack

Five containers in one compose project (`/etc/arr/compose.yml`), each with its
state under `/var/lib/arr/<app>`:

| Application | Does what |
| --- | --- |
| Prowlarr | Holds the indexers and pushes them into Sonarr and Radarr |
| Sonarr | Series and anime — two root folders, `/data/show` and `/data/anime` |
| Radarr | Films — `/data/movie` |
| Bazarr | Subtitles for whatever Sonarr and Radarr imported |
| Jellyseerr | Request portal, signed in against Jellyfin |

### Why they all mount `/data`

Every container that touches a file — qBittorrent included — mounts the whole
media tree at `/data`, not just the directory it cares about. Two things follow
from that, and both matter:

- **Imports are hardlinks.** Sonarr links `/data/downloads/complete/…` into
  `/data/show/…` instead of copying it. The file is not duplicated on disk and
  the torrent keeps seeding from the same inode. A hardlink cannot cross a mount
  point, so splitting this into `/downloads` and `/tv` would silently turn every
  import into a full copy.
- **No remote path mapping.** The save path qBittorrent reports over its API is a
  path Sonarr can open, because it is the same path.

```
/var/jellyfin/media        ->  /data in every container
├── downloads/
│   ├── incomplete/
│   └── complete/          <- qBittorrent writes here, under a category directory
├── anime/                 <- Sonarr, root folder #2
├── movie/                 <- Radarr
├── music/
└── show/                  <- Sonarr, root folder #1
```

Permissions hold this together: the containers run as the `arr` account, which
is in the `jellyfin` group, with `UMASK=002`. The library directories are setgid
so the directories Sonarr creates keep the `jellyfin` group rather than falling
back to `arr`.

### The shared network

`media` is a docker network created by the `docker` role, not by any compose
project — a network owned by one project vanishes when that project is torn
down. Jellyfin, Homepage, the five *arr containers and gluetun all join it, and
address each other by container name.

They have to. Every vhost above is behind Authelia, so an API call sent to the
public address gets a login redirect, not JSON. `http://sonarr:8989` gets JSON.

gluetun is the awkward one: qBittorrent lives in its network namespace, so the
WebUI answers on the name `gluetun`, not `qbittorrent`. gluetun also needs
`FIREWALL_OUTBOUND_SUBNETS` set to the `media` subnet, otherwise its killswitch
drops the replies to Sonarr along with everything else.

### Authentication

The three Servarr applications are seeded with `AuthenticationMethod=External`:
they do no login of their own and trust what is in front of them, which is Caddy
with Authelia. Their ports are published on the loopback only, so the practical
consequence is that anyone with a shell on the host can reach the API without
authenticating — which is already true of the docker socket.

Jellyseerr is deliberately **not** behind Authelia. It signs people in against
Jellyfin, so the people you have already given a Jellyfin account can request a
film without you also creating an Authelia account for each of them.

### What Ansible wires, and what it does not

The API keys are generated by you and kept in the vault, which is what lets the
playbook do the wiring instead of leaving it as a first-run checklist. On every
run it reads what each application already has and posts only what is missing:

- Sonarr's two root folders and Radarr's one.
- qBittorrent as the download client in Sonarr, Radarr and Prowlarr, pointed at
  `gluetun:8080` with a category each.
- Sonarr and Radarr registered as applications in Prowlarr, with the Torznab
  category ids, so indexers sync into both automatically.

Re-running is a no-op, and anything you change in a web interface survives.
`config.xml` and Bazarr's `config.yaml` are seeded once and then left alone,
like `qBittorrent.conf`; to make the templates authoritative again for one run:

```bash
ansible-playbook playbook.yml -K --tags arr -e arr_reset_config=true
```

To bring the containers up and wire them yourself instead:

```bash
ansible-playbook playbook.yml -K --tags arr -e arr_configure=false
```

Left to the web interfaces, because it depends on accounts you hold or on taste:
the indexers in Prowlarr, the subtitle providers and languages in Bazarr, the
quality profiles, and Jellyseerr's first-run wizard.

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

Fixed, applied and verified on the machine on 2026-08-26:

- **Published ports.** Every container port is now bound to
  `docker_publish_address` (`127.0.0.1`). They used to be on `0.0.0.0`: Docker
  writes its own iptables rules, so UFW never saw the traffic and the reverse
  proxy was bypassed. Probing the public address from outside on 2026-08-25
  answered on 3001, 3010, 4444, 8000, 8097 and 1080 — the last being Penpot's
  mailcatcher, which serves every mail the instance sends, with no
  authentication, including invitation and password reset links. Re-probing
  after the run on 2026-08-26: all closed, only 80, 443 and the SSH port answer.

  Jellyfin moves from host to bridge networking for the same reason. That costs
  DLNA and client auto-discovery on the LAN, recoverable with
  `jellyfin_network_mode: host`.

  Correction to an earlier reading of that first probe: port 8096 was also
  answering, and was attributed to this machine because Jellyfin was on host
  networking at the time. It is not this machine. The router forwards 8096 to a
  different host on the LAN — a machine reporting itself as `LOTUS`, running
  Jellyfin 10.8.10, server id `72bf96976a8648b1a23002be41cda2cd`, against the
  `51f68eec935b4f0084fc9b6c6717d39f` of the container here. It still answers on
  the public address after the run. That host is outside the scope of this
  repository, but an unproxied Jellyfin two years behind on patches is worth
  looking at.
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
