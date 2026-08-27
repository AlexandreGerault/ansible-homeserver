# qBittorrent — what is left before it works

The `qbittorrent` role is written, wired into `playbook.yml` and documented in
the README. Nothing has run against the server yet: the role asserts on four
vault keys that do not exist, so `--tags qbittorrent` fails fast instead of
deploying a half-configured torrent client.

Since this was written, the `arr_stack` role has landed and changed two things
here: the container now mounts `/var/jellyfin/media` at `/data` rather than just
the download directory at `/downloads` (so Sonarr and Radarr can hardlink out of
it), and gluetun joins the shared `media` network. Nothing below changes because
of it — the role has still never run — but `TODO-arr-stack.md` is the sequel and
depends on this file being finished first.

Critical path: **the VPN account**. Everything below is ordered so the blocked
items are separated from the ones that can be cleared while waiting.

## Blocked — needs access to the VPN account

- [ ] Download the OpenVPN configuration file for the server/region you want.
- [ ] Note the **OpenVPN credentials**. On most providers these are *not* the
      account login — they are a separate service username and password shown in
      the dashboard. Using the account login is the usual reason gluetun loops on
      `AUTH_FAILED`.
- [ ] Check whether the provider forwards a port, and which one. It is optional:
      without it the client still downloads, it just never accepts incoming peers.
      With it, fill `qbittorrent_vpn_input_ports` in `group_vars/all/main.yml` and
      set the same port as the listening port in the WebUI afterwards.
- [ ] Resolve the `remote` hostname to an IP and put the address in the file:

      dig +short vpn.example.com

      gluetun raises its firewall before OpenVPN starts, so it can never resolve
      that name itself — a hostname there means a container that hangs rather
      than a DNS error. The role asserts on this before deploying anything.
- [ ] If the file references `ca`/`cert`/`key`/`up` by relative path, inline the
      material as `<ca>...</ca>` blocks. gluetun rewrites the config elsewhere,
      so relative paths break. Most providers already ship it inlined.

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

- [ ] Nothing to do for Authelia: its default rule is `*.alexandre-gerault.fr` with
      `one_factor`, so the new vhost is covered by the accounts already in
      `vault_authelia_users`.
- [ ] Nothing to do for UFW either. Peer traffic arrives inside the tunnel, in
      gluetun's namespace — it never touches the host's public interface.
- [ ] Check no container named `gluetun` or `qbittorrent` already exists on the
      machine, left over from something started by hand:

      ssh homeserver 'docker ps -a --filter name=gluetun --filter name=qbittorrent'

## Once the VPN details are in hand

- [ ] Put the secrets in the vault (four for this role, plus the cleartext
      password the *arr stack needs):

      ansible-vault edit group_vars/all/vault.yml

      ```yaml
      vault_qbittorrent_openvpn_user: ...
      vault_qbittorrent_openvpn_password: ...
      vault_qbittorrent_password_pbkdf2: "@ByteArray(...)"
      # The same password in clear. Required since the *arr stack landed: it is
      # what Sonarr and Radarr authenticate to the download client with, and
      # what the Homepage widget uses. See TODO-arr-stack.md.
      vault_qbittorrent_webui_password: "..."
      vault_qbittorrent_openvpn_config: |
        client
        dev tun
        remote 203.0.113.7 1194
        ...
      ```

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
- [ ] Set the listening port to the forwarded port, if the provider gave one.
- [ ] Nothing to do about categories: Sonarr and Radarr create their own
      (`tv-sonarr`, `radarr`) under `/data/downloads/complete/` when they hand a
      release over. Add one by hand only for what you download outside them.
- [ ] Nothing to do about the Jellyfin libraries either: Sonarr and Radarr
      hardlink finished downloads into `anime`/`movie`/`show`, which Jellyfin
      already scans. Do not point a library at the download directory.

To make the template authoritative again for one run — this discards WebUI changes:

    ansible-playbook playbook.yml -K --tags qbittorrent -e qbittorrent_reset_config=true

## Deliberately left out

- ~~**The Homepage widget.**~~ Done. The *arr stack needs
  `vault_qbittorrent_webui_password` in the vault anyway, so the widget costs
  nothing extra and is now in `roles/homepage/templates/services.yaml.j2`. It
  calls `http://gluetun:8080` over the shared `media` network, because that is
  where qBittorrent's WebUI answers.
- **Reverse proxy support in qBittorrent** (`WebUI\ReverseProxySupportEnabled`).
  It only affects which IP is logged and banned on failed logins; the source is
  the Docker bridge gateway, whose address comes from the `10.0.0.0/8` pool and
  is not fixed. Authelia is in front, so it earns little.
