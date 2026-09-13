# Stack *arr — la lancer

Le rôle `arr_stack` est écrit, câblé dans `playbook.yml` et documenté dans le
README. Les quatre clés d'API et le mot de passe WebUI de qBittorrent sont dans
le vault et vérifiés (32 caractères chacune) ; les cinq enregistrements DNS
résolvent, en A explicites, pas en joker.

**Rien n'a encore tourné sur le serveur.**

La section de prérequis qui vivait ici — DNS, génération des clés d'API,
remplissage du vault — est faite et a été retirée.

**Elle dépend du rôle qbittorrent, lancé avant.** Sonarr et Radarr sont câblés
sur un client de téléchargement à `gluetun:8080`, et le widget Homepage appelle
la même adresse. Ce conteneur doit exister. Le script `deploy-media-stack.sh` à
la racine enchaîne toute la séquence dans le bon ordre.

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

- [ ] Sonarr can actually reach the download client, and qBittorrent accepts the
      request. Two different things go wrong here and they need different fixes,
      so read the status code rather than just checking it answered:

      ssh homeserver 'docker exec sonarr curl -s -o /dev/null -w "%{http_code}\n" http://gluetun:8080/api/v2/app/version'

      **`403` is the result you want.** That endpoint needs a login and this
      curl does not have one, so 403 means the connection crossed the network
      and qBittorrent processed it — which is everything this check can prove.

      **A hang or a connection refused** is gluetun's firewall dropping it, and
      depends on `FIREWALL_OUTBOUND_SUBNETS` matching the network's subnet.
      Check that `media_network_subnet` in group_vars is the subnet the network
      actually got:

      ssh homeserver 'docker network inspect media -f "{{range .IPAM.Config}}{{.Subnet}}{{end}}"'

      **`401` is the host header check**, which qBittorrent applies before it
      looks at credentials: it matches the `Host` header — `gluetun:8080` here —
      against `WebUI\ServerDomains`, and refuses anything not in the list.
      `gluetun` is in the seeded config, but that file is seed-only, so an
      installation seeded before it was there keeps the old list. Make the
      template authoritative again for one run — it discards WebUI changes:

      ansible-playbook playbook.yml -K --tags qbittorrent -e qbittorrent_reset_config=true

      A **failing Test button in Sonarr's UI** while this curl returns 403 is
      the other cause: `vault_qbittorrent_password_pbkdf2` and
      `vault_qbittorrent_webui_password` are not the same password. Nothing
      asserts that they match — the hash cannot be checked against the cleartext
      without redoing the PBKDF2 — so it is worth re-deriving the hash from the
      cleartext with the snippet in TODO-qbittorrent.md before looking further.

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
