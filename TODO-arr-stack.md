# *arr stack — what is left before it works

The `arr_stack` role is written, wired into `playbook.yml` and documented in the
README. Nothing has run against the server yet. Like the qBittorrent role, it
asserts on vault keys that do not exist, so `--tags arr` fails fast rather than
deploying a half-configured stack.

**It depends on the qBittorrent role having run first.** Sonarr and Radarr are
wired to a download client at `gluetun:8080`, and Homepage's widget calls the
same address. That container has to exist. Finish `TODO-qbittorrent.md` first —
the VPN account is still the critical path for both.

## Can be done now

- [ ] **DNS.** Five new names, unless there is already a wildcard
      `*.alexandre-gerault.fr`:

      prowlarr.alexandre-gerault.fr
      sonarr.alexandre-gerault.fr
      radarr.alexandre-gerault.fr
      bazarr.alexandre-gerault.fr
      requests.alexandre-gerault.fr

      This is the one step with a propagation delay, so it is worth doing first.
      Caddy needs each to resolve publicly before it can get a certificate.

- [ ] Generate the four API keys and keep them until the vault edit:

      for a in prowlarr sonarr radarr bazarr; do
        echo "vault_${a}_api_key: $(python3 -c 'import secrets; print(secrets.token_hex(16))')"
      done

- [ ] Add them to the vault, along with the qBittorrent WebUI password in clear.
      That last one is new: `TODO-qbittorrent.md` listed it as optional, for the
      Homepage widget only. It is now required — it is what Sonarr and Radarr
      authenticate to the download client with.

      ansible-vault edit group_vars/all/vault.yml

      ```yaml
      vault_prowlarr_api_key: ...
      vault_sonarr_api_key: ...
      vault_radarr_api_key: ...
      vault_bazarr_api_key: ...
      vault_qbittorrent_webui_password: ...   # the same one behind the PBKDF2 hash
      ```

- [ ] Nothing to do for Authelia: its default rule is `*.alexandre-gerault.fr`
      with `one_factor`, so the four protected vhosts are covered by the accounts
      already in `vault_authelia_users`. Jellyseerr is intentionally not
      protected — it signs people in against Jellyfin.

- [ ] Nothing to do for UFW: every port is published on `127.0.0.1` and Caddy is
      the only way in.

- [ ] Check nothing is squatting the container names or the ports:

      ssh homeserver 'docker ps -a --format "{{.Names}}" | grep -E "prowlarr|sonarr|radarr|bazarr|jellyseerr"'
      ssh homeserver 'ss -lntp | grep -E ":(9696|8989|7878|6767|5055)"'

## Two existing roles change, and they move containers

Reading these before the first run is worth it — they are not additive.

- [ ] **`docker`** now creates a `media` network (10.89.0.0/24). New task, no
      effect on anything already running.

- [ ] **`jellyfin`** moves the container from the default bridge onto `media`,
      and sets the library directories setgid (`0770` → `2770`). The container is
      recreated, so Jellyfin restarts. Its config and cache are named volumes, so
      nothing is lost — but time the run.

- [ ] **`qbittorrent`** changes its mount from
      `/var/jellyfin/media/downloads:/downloads` to `/var/jellyfin/media:/data`,
      and the seeded save paths follow. Harmless today because the role has never
      run; **if it has run by the time you read this**, anything already
      downloading has `/downloads/...` in the qBittorrent session and will error
      on the missing path. Fix it in the WebUI with Set location, or re-seed:

      ansible-playbook playbook.yml -K --tags qbittorrent -e qbittorrent_reset_config=true

- [ ] **`homepage`** also moves onto `media`, so the widgets can call the APIs by
      container name. Recreated, config is a bind mount, nothing lost.

## Running it

- [ ] Dry run — it shows the drift without touching anything:

      ansible-playbook playbook.yml -K --tags arr --check --diff

      Expect it to fail in check mode on a fresh install: the `arr` account does
      not exist yet, so the compose template has no uid to render. That failure
      is the check-mode artefact, not a real problem. The assert at the top is
      the part worth reading.

- [ ] Run it:

      ansible-playbook playbook.yml -K --tags arr

      The wiring tasks wait up to `arr_wait_retries × arr_wait_delay` (200s) for
      each application to answer `/ping`. First start of a Servarr application
      builds its database, which takes a while on a cold disk.

- [ ] Re-run `caddy` if the vhosts were not picked up, and confirm the five
      certificates were issued:

      ansible-playbook playbook.yml -K --tags caddy
      ssh homeserver 'journalctl -u caddy -n 80 | grep -i certificate'

## Verify

- [ ] The containers all landed on the shared network:

      ssh homeserver 'docker network inspect media -f "{{range .Containers}}{{.Name}} {{end}}"'

      Expect jellyfin, homepage, gluetun, prowlarr, sonarr, radarr, bazarr,
      jellyseerr.

- [ ] Sonarr can actually reach the download client through gluetun's firewall.
      This is the one thing most likely to be wrong, because it depends on
      `FIREWALL_OUTBOUND_SUBNETS` matching the network's subnet:

      ssh homeserver 'docker exec sonarr curl -s -o /dev/null -w "%{http_code}\n" http://gluetun:8080/api/v2/app/version'

      A hang or a connection refused means gluetun is dropping it. Check that
      `media_network_subnet` in group_vars is the subnet the network actually
      got:

      ssh homeserver 'docker network inspect media -f "{{range .IPAM.Config}}{{.Subnet}}{{end}}"'

- [ ] The wiring took. In each web interface, or over the API:

      # root folders
      curl -s -H "X-Api-Key: $SONARR_KEY" http://127.0.0.1:8989/api/v3/rootfolder | jq '.[].path'
      # download client, and whether its connection test passes
      curl -s -H "X-Api-Key: $SONARR_KEY" http://127.0.0.1:8989/api/v3/downloadclient | jq '.[].name'
      # applications prowlarr syncs to
      curl -s -H "X-Api-Key: $PROWLARR_KEY" http://127.0.0.1:9696/api/v1/applications | jq '.[].name'

      The download client was saved with `forceSave=true`, which skips the
      connection test — so its presence in the list does not prove it works. Hit
      Test in Sonarr's UI to actually check.

- [ ] The five vhosts answer and redirect to Authelia, except `requests.` which
      should show Jellyseerr's own setup wizard.

- [ ] **Hardlinks work.** This is the check that justifies the whole `/data`
      arrangement, and the easy one to skip. After the first import, the file
      should have a link count of 2 and the same inode at both ends:

      ssh homeserver 'find /var/jellyfin/media/show -type f -links +1 -printf "%n %i %p\n" | head'

      A link count of 1 everywhere means every import is being copied. Check that
      Sonarr's root folder and the download path are both under `/data`.

- [ ] Jellyfin still reads the libraries after the setgid change, and the
      directories Sonarr creates come out with the right group:

      ssh homeserver 'ls -ld /var/jellyfin/media/show/*'

      Expect `arr:jellyfin` and group-writable, not `arr:arr`.

## First-run, in the web interfaces

None of this is manageable from Ansible — it depends on accounts you hold.

- [ ] **Prowlarr:** add the indexers. They sync to Sonarr and Radarr on their own
      once added; Prowlarr → Settings → Apps should already list both.
- [ ] **Sonarr:** set the anime root folder as the default for series you add
      with type Anime. The two root folders are already there.
- [ ] **Bazarr:** add the subtitle providers and pick the languages. The Sonarr
      and Radarr connections are already seeded.
- [ ] **Jellyseerr:** the first-run wizard — sign in with a Jellyfin admin
      account, import the libraries, then add Sonarr and Radarr with the same API
      keys from the vault, at `http://sonarr:8989` and `http://radarr:7878`.
- [ ] **Jellyfin:** nothing, if the libraries stay `anime`/`movie`/`show`. Sonarr
      and Radarr write into the directories it already scans.

## Deliberately left out

- **Recyclarr** (quality profiles and custom formats synced from TRaSH guides).
  It is the usual next step and would fit the same pattern, but it encodes taste
  about release quality — worth choosing by hand once rather than templating
  blind.
- **FlareSolverr**, the proxy for Cloudflare-protected indexers. It is a headless
  Chromium sitting in memory permanently, and it is only needed if an indexer you
  actually add requires it. Add it to `arr_apps` when one does.
- **Lidarr.** The `music` library is unmanaged, as decided.
- **A second Sonarr for anime.** One instance with two root folders instead, as
  decided; split it later if the quality profiles start fighting each other.
