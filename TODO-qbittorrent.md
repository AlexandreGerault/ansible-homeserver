# qBittorrent behind CyberGhost — what is left before it works

The `qbittorrent` role is written, wired into `playbook.yml` and documented in
the README. Nothing has run against the server yet: the role asserts on five
vault keys that do not exist, so `--tags qbittorrent` fails fast instead of
deploying a half-configured torrent client.

The VPN is **CyberGhost, over OpenVPN, through gluetun's built-in provider**
(`VPN_SERVICE_PROVIDER: cyberghost`). gluetun ships the CyberGhost server list
and the CyberGhost root CA, so there is no `.ovpn` file in the vault and no
`remote` hostname to resolve by hand — that whole class of problem is gone. What
is left is an account, and CyberGhost's manual-OpenVPN account is four pieces of
material, not two.

Critical path: **generating the manual configuration in the dashboard**.
Everything below is ordered so the blocked items are separated from the ones
that can be cleared while waiting.

## Blocked — needs access to the CyberGhost account

Everything in this section comes out of *one* trip through the dashboard.

- [ ] Log in at <https://my.cyberghostvpn.com>, open **My Devices**, pick
      **Other**, then **Configure New Device**.
- [ ] Fill that form in:
      - protocol **OpenVPN**,
      - a **country**. This is the country of the *VPN server* — where your
        traffic comes out onto the internet — not where the homeserver sits.
        Note that this form's country decides nothing here: it only picks the
        `remote` hostname written into the `openvpn.ovpn` of the ZIP, and
        gluetun throws that file away and chooses its own server from
        `qbittorrent_vpn_server_countries`. Pick the same country anyway, so the
        dashboard and `group_vars/all/main.yml` do not disagree, and so a
        `AUTH_FAILED` can never be blamed on the mismatch.
      - a **P2P-friendly** server group. CyberGhost blocks torrent traffic on
        some countries outright (United States, Australia, Russia among others);
        Netherlands, Switzerland and Romania are the usual safe picks. A blocked
        country does not fail loudly — the tunnel comes up and the torrents just
        never move, which is a miserable thing to debug.
      - a device name — `homeserver-gluetun` is as good as any. It is only a
        label in the dashboard, and it is what you delete to revoke this.

      Then **Save Configuration**.
- [ ] Click **View configuration** and copy the **username and password it
      shows**. These are *not* your CyberGhost account login: they are generated
      for this device and only work for manual configurations. Using the account
      login is the usual reason gluetun loops on `AUTH_FAILED`.
- [ ] **Download Configuration** — from that same screen, or later from
      **Download Hub** → **Manage Devices** → *Routers or other devices*. Unzip
      it. It holds four files:

      ca.crt        the CyberGhost CA — not needed, gluetun already has it
      client.crt    the client certificate  → vault_qbittorrent_openvpn_cert
      client.key    the client private key  → vault_qbittorrent_openvpn_key
      openvpn.ovpn  the config              → not needed, gluetun writes its own

      Only `client.crt` and `client.key` matter. gluetun refuses to start for
      CyberGhost without both — the error is literally
      `client certificate: missing value`.

- [ ] Nothing to do about port forwarding: **CyberGhost does not forward ports**,
      and gluetun only implements port forwarding for PIA, PrivateVPN and
      ProtonVPN anyway. Peers cannot connect back in. Downloads still work,
      because outgoing connections are unaffected; it costs seed ratio and
      slower swarm discovery. There is no setting for this, and the variable
      that used to exist for it (`qbittorrent_vpn_input_ports`) has been removed
      so it stops looking like an oversight.

## Can be done now, while blocked

- [ ] **DNS.** Point `torrent.alexandre-gerault.fr` at the server, unless there is
      already a wildcard `*.alexandre-gerault.fr` record. Caddy needs it to resolve
      publicly before it can get a certificate — this is the one step with a
      propagation delay, so it is worth doing first.
- [ ] Generate the WebUI password hash and keep it somewhere until the vault edit:

      python3 -c '
      import base64, hashlib, os, getpass
      p = getpass.getpass().encode()
      s = os.urandom(16)
      h = hashlib.pbkdf2_hmac("sha512", p, s, 100000)
      print("@ByteArray(" + base64.b64encode(s).decode() + ":" + base64.b64encode(h).decode() + ")")
      '

- [ ] Check the country name you want is one gluetun recognises — its list is not
      always the obvious spelling (`Czech Republic`, `United Kingdom`):

      docker run --rm qmcgaw/gluetun format-servers -cyberghost | less

      Run it on the server, or anywhere with Docker; it needs no credentials.
- [ ] Nothing to do for Authelia: its default rule is `*.alexandre-gerault.fr` with
      `one_factor`, so the new vhost is covered by the accounts already in
      `vault_authelia_users`.
- [ ] Nothing to do for UFW either. Peer traffic arrives inside the tunnel, in
      gluetun's namespace — it never touches the host's public interface.
- [ ] Check no container named `gluetun` or `qbittorrent` already exists on the
      machine, left over from something started by hand:

      ssh homeserver 'docker ps -a --filter name=gluetun --filter name=qbittorrent'

## Putting the secrets in the vault

Five keys for this role, plus the cleartext WebUI password the *arr stack needs.

    ansible-vault edit group_vars/all/vault.yml

```yaml
# From the "manual configuration" screen. NOT the account login.
vault_qbittorrent_openvpn_user: the-generated-username
vault_qbittorrent_openvpn_password: the-generated-password

# The whole client.crt, armour lines included, as a block scalar.
vault_qbittorrent_openvpn_cert: |
  -----BEGIN CERTIFICATE-----
  MIIEwzCCA6ugAwIBAgIJAO...
  -----END CERTIFICATE-----

# The whole client.key, same treatment.
vault_qbittorrent_openvpn_key: |
  -----BEGIN PRIVATE KEY-----
  MIIEvQIBADANBgkqhkiG9w...
  -----END PRIVATE KEY-----

# The WebUI password, hashed the way qBittorrent stores it.
vault_qbittorrent_password_pbkdf2: "@ByteArray(...)"

# The same password in clear. Required since the *arr stack landed: it is what
# Sonarr and Radarr authenticate to the download client with, and what the
# Homepage widget uses. See TODO-arr-stack.md.
vault_qbittorrent_webui_password: "..."
```

`vault_qbittorrent_openvpn_config` is no longer read by anything and can be
deleted from the vault in the same edit.

### Pasting the PEM blocks without breaking them

The two block scalars are the only fiddly part. `|` keeps the newlines, which is
what a PEM needs, but it is indentation-sensitive: every line of the block must
be indented further than the key, and consistently. In `vi` (what
`ansible-vault edit` opens by default) `:set paste` before pasting, or the
auto-indent will stagger the lines and Ansible will fail to parse the vault.

The role checks the result before deploying anything — it asserts the cert
contains `-----BEGIN CERTIFICATE-----` and the key `-----BEGIN PRIVATE KEY-----`.
An `ENCRYPTED PRIVATE KEY` is rejected too: gluetun wants
`OPENVPN_ENCRYPTED_KEY` plus a passphrase for those, which CyberGhost never
hands out.

If you would rather not paste by hand, from the directory holding the unzipped
files:

    python3 - <<'PY'
    import pathlib, textwrap
    for key, name in (("cert", "client.crt"), ("key", "client.key")):
        body = pathlib.Path(name).read_text().strip()
        print(f"vault_qbittorrent_openvpn_{key}: |")
        print(textwrap.indent(body, "  "))
    PY

That prints the two entries ready to paste as a block. Delete the files
afterwards — they are the VPN account.

### Where they end up on the server

Ansible writes the four to `/etc/qbittorrent/secrets/`, `0600 root:root`, and
compose passes them as *secrets* rather than environment variables, so they stay
out of `docker inspect` and out of the container's `/proc/1/environ`. The file
names are gluetun's, and it looks for each at `/run/secrets/<name>`:

| Vault key | Secret file | gluetun setting |
| --- | --- | --- |
| `vault_qbittorrent_openvpn_user` | `openvpn_user` | `OPENVPN_USER` |
| `vault_qbittorrent_openvpn_password` | `openvpn_password` | `OPENVPN_PASSWORD` |
| `vault_qbittorrent_openvpn_cert` | `openvpn_clientcrt` | `OPENVPN_CERT` |
| `vault_qbittorrent_openvpn_key` | `openvpn_clientkey` | `OPENVPN_KEY` |

The last two are why the PEM armour lines stay in. The environment variables
`OPENVPN_CERT` and `OPENVPN_KEY` want a single line of base64 with the armour
stripped, but the *secret files* of the same settings go through a PEM parser
first — gluetun does the stripping and base64ing itself. Feeding a bare base64
blob to the file would fail to parse.

## Choosing where to exit

Not a secret, so it lives in `group_vars/all/main.yml` in plain sight:

```yaml
qbittorrent_openvpn_protocol: udp
qbittorrent_vpn_server_countries:
  - Netherlands
qbittorrent_vpn_server_hostnames: []
```

- Several countries in the list means gluetun picks among all of them and can
  fail over when a server refuses the connection.
- `qbittorrent_vpn_server_hostnames` pins one exact host instead. Leave it empty
  unless a country is not specific enough.
- `udp` is right for torrenting. `tcp` only earns its keep on a network that
  blocks UDP; it makes a TCP-in-TCP stack, which behaves badly under the packet
  loss a saturated torrent connection produces.
- This is the only setting that decides where the traffic comes out. The country
  picked in the CyberGhost dashboard does not: gluetun ignores the `.ovpn` that
  form generates and resolves a server from its own list. It is not established
  whether the generated credentials are accepted by servers outside the country
  they were issued for — so if `AUTH_FAILED` appears after widening or changing
  this list, generate a fresh manual configuration for the new country before
  looking anywhere else.

## Running it

- [ ] Dry run first — it shows the drift without touching anything:

      ansible-playbook playbook.yml -K --tags qbittorrent --check --diff

      Expect it to fail in check mode on a fresh install: the service account does
      not exist yet, so the compose template has no uid to render. That failure is
      the check-mode artefact, not a real problem. The two asserts at the top are
      the part worth reading.

- [ ] Run it:

      ansible-playbook playbook.yml -K --tags qbittorrent

      The task waits up to 180s (`qbittorrent_wait_timeout`) for gluetun to report
      healthy. If it times out, the tunnel never came up — read the logs before
      changing anything else:

      ssh homeserver 'docker logs gluetun'

- [ ] Re-run the `caddy` tag if the vhost was not picked up, and confirm the
      certificate was issued:

      ansible-playbook playbook.yml -K --tags caddy
      ssh homeserver 'journalctl -u caddy -n 50'

### When gluetun does not come up

| In `docker logs gluetun` | What it means |
| --- | --- |
| `client certificate: missing value` | `vault_qbittorrent_openvpn_cert` is empty or did not survive the block scalar. The role's assert should have caught it — check the vault actually decrypted. |
| `AUTH_FAILED` | Wrong username/password. Almost always the account login instead of the manual-configuration one. Failing that, try regenerating the manual configuration for the country in `qbittorrent_vpn_server_countries`. |
| `TLS handshake failed` / `TLS key negotiation failed` | The client certificate and key do not match each other, or they are from a manual configuration that has since been deleted in the dashboard. |
| `cannot filter servers: no server found` | The country name is not one gluetun knows. Check it against `format-servers -cyberghost`. |
| Healthy, but no peers and no traffic | The server group is one where CyberGhost blocks P2P. Regenerate the manual configuration on a P2P-friendly country. |

## Verify before putting anything through it

- [ ] The tunnel carries the traffic — both must return the VPN address, not the ISP's:

      docker exec gluetun wget -qO- http://127.0.0.1:8000/v1/publicip/ip
      docker exec qbittorrent curl -s https://ipinfo.io/ip

- [ ] The killswitch actually holds. This is the check that matters, and the one
      that is easy to skip:

      docker stop gluetun
      docker exec qbittorrent curl -s --max-time 10 https://ipinfo.io/ip   # must fail
      docker start gluetun

      If that returns an address, the namespace sharing is broken and the client
      is exposed. Do not use it until it fails.

- [ ] The WebUI answers at `https://torrent.alexandre-gerault.fr`, redirects to
      Authelia first, and then accepts the admin password from the vault.
- [ ] A finished download is readable by Jellyfin in place — check the group and
      the mode on something in `complete/`:

      ssh homeserver 'ls -l /var/jellyfin/media/downloads/complete'

      Expect `qbittorrent:jellyfin` and group-writable. If it is not, `UMASK` or the
      setgid bit did not take.

## After it runs — WebUI only, not managed by Ansible

`qBittorrent.conf` is rewritten by qBittorrent on every exit, so Ansible seeds it
once and then leaves it alone. Everything here is done in the WebUI and stays:

- [ ] Change the admin password if you would rather not keep the vault one.
- [ ] Nothing to do about the listening port. Without port forwarding it only
      decides which port outgoing connections come from, and 6881 is fine.
- [ ] Nothing to do about categories: Sonarr and Radarr create their own
      (`tv-sonarr`, `radarr`) under `/data/downloads/complete/` when they hand a
      release over. Add one by hand only for what you download outside them.
- [ ] Nothing to do about the Jellyfin libraries either: Sonarr and Radarr
      hardlink finished downloads into `anime`/`movie`/`show`, which Jellyfin
      already scans. Do not point a library at the download directory.

To make the template authoritative again for one run — this discards WebUI changes:

    ansible-playbook playbook.yml -K --tags qbittorrent -e qbittorrent_reset_config=true

## Deliberately left out

- **WireGuard.** CyberGhost supports it and it would be faster, but gluetun's
  `cyberghost` provider is OpenVPN-only — WireGuard would mean going back to
  `VPN_SERVICE_PROVIDER: custom` and pasting a peer configuration into the vault,
  which is exactly the arrangement this replaced.
- ~~**The Homepage widget.**~~ Done. The *arr stack needs
  `vault_qbittorrent_webui_password` in the vault anyway, so the widget costs
  nothing extra and is now in `roles/homepage/templates/services.yaml.j2`. It
  calls `http://gluetun:8080` over the shared `media` network, because that is
  where qBittorrent's WebUI answers.
- **Reverse proxy support in qBittorrent** (`WebUI\ReverseProxySupportEnabled`).
  It only affects which IP is logged and banned on failed logins; the source is
  the Docker bridge gateway, whose address comes from the `10.0.0.0/8` pool and
  is not fixed. Authelia is in front, so it earns little.
