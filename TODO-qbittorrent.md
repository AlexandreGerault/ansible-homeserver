# qBittorrent derrière CyberGhost — le lancer

Le rôle `qbittorrent` est écrit, câblé dans `playbook.yml` et documenté dans le
README. Le vault contient les six clés dont il a besoin, toutes vérifiées : les
quatre secrets de la configuration manuelle CyberGhost, le mot de passe WebUI
en clair, et ce même mot de passe en PBKDF2 (le hash a été recalculé depuis le
clair, il correspond). Le certificat et la clé forment bien une paire, valide
jusqu'en 2036, et le nom d'utilisateur correspond au CN du certificat.

**Rien n'a encore tourné sur le serveur.**

Les sections de prérequis qui vivaient ici — générer la configuration manuelle,
les enregistrements DNS, remplir le vault — sont faites et ont été retirées. Ce
qui reste est le lancement et ce qu'il faut vérifier après.

**L'ordre compte.** Le réseau docker `media` est déclaré `external: true` par le
fichier compose de ce rôle et créé par le rôle `docker` : ce tag doit passer en
premier, sinon compose s'arrête sur `network media declared as external, but
could not be found`. Le script `deploy-media-stack.sh` à la racine enchaîne
toute la séquence dans le bon ordre, test du coupe-circuit compris.

## Où les secrets atterrissent sur le serveur

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
