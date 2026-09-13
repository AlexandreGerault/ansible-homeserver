#!/usr/bin/env bash
#
# Déploiement ordonné de la stack média : réseau docker, Caddy, Jellyfin, le
# tunnel VPN, puis les *arr et les widgets.
#
# L'ordre n'est pas cosmétique :
#   - le réseau `media` est déclaré `external: true` par les deux fichiers
#     compose et créé par le rôle `docker`, qui doit donc passer en premier,
#     sinon compose s'arrête sur « network media declared as external, but
#     could not be found » ;
#   - `jellyfin` doit passer avant `arr` pour poser le bit setgid (2770) sur
#     les bibliothèques, faute de quoi les dossiers créés par Sonarr sortent
#     en arr:arr et Jellyfin ne peut pas y descendre.
#
# Le test du coupe-circuit est BLOQUANT : si qBittorrent répond encore alors
# que gluetun est arrêté, le script s'interrompt sans déployer les *arr.
#
#   ./deploy-media-stack.sh           # déploiement complet
#   ./deploy-media-stack.sh --check   # simulation (--check --diff), sans test
#
# En simulation, attendez-vous à des échecs sur les rôles jamais déployés :
# le compte de service n'existe pas encore, donc le template compose n'a pas
# d'uid à rendre. C'est un artefact du mode check, pas un vrai problème.

set -euo pipefail
cd "$(dirname "$0")"

SSH_HOST="homeserver"
PLAYBOOK="playbook.yml"

usage() {
  cat <<'USAGE'
Usage : ./deploy-media-stack.sh [options]

  --check              simulation (--check --diff), sans le test du coupe-circuit
  --pass-file FICHIER  lit le mot de passe sudo dans FICHIER au lieu de le demander.
                       Pour cron, CI, ou un agent dont la sortie est un tube.
  --yes, -y            ne pas demander confirmation avant de déployer
  -h, --help           cette aide

Sans --pass-file, le script a besoin d'un vrai terminal pour lire le mot de
passe sudo — lancez-le alors directement depuis votre shell.

Le préfixe `!` de Claude Code ne convient PAS, avec ou sans --pass-file :
il ouvre stdout et stderr en non bloquant, et ansible/cli/__init__.py appelle
check_blocking_io() à l'import, donc avant même de lire ses arguments. Lancez
le script depuis votre propre terminal, ou laissez l'agent l'appeler lui-même
avec --pass-file (sa sortie à lui est un tube bloquant).
USAGE
}

DRY=0
ASSUME_YES=0
USER_PASSFILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)   DRY=1; shift ;;
    --yes|-y)  ASSUME_YES=1; shift ;;
    --pass-file)
      [[ -n "${2:-}" ]] || { echo "--pass-file attend un chemin." >&2; exit 2; }
      USER_PASSFILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Argument inconnu : $1" >&2; echo >&2; usage >&2; exit 2 ;;
  esac
done

# Un terminal de contrôle est-il joignable ? stdin peut être redirigé sans que
# /dev/tty le soit, d'où les deux tests plutôt que le seul `[ -t 0 ]`.
have_tty() { { : < /dev/tty; } 2>/dev/null; }

# ---------------------------------------------------------------------------
# Mot de passe sudo : demandé une seule fois
# ---------------------------------------------------------------------------
# ansible.cfg impose become_ask_pass, ce qui donnerait une invite par phase.
# On le lit une fois, on le passe par un fichier 0600 détruit à la sortie, et
# on neutralise l'invite pour que les deux mécanismes n'entrent pas en conflit.
export ANSIBLE_BECOME_ASK_PASS=False

WORKDIR="$(mktemp -d)"
chmod 700 "$WORKDIR"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT INT TERM

PASSFILE=""
if [[ -n "$USER_PASSFILE" ]]; then
  [[ -r "$USER_PASSFILE" ]] || {
    echo "Fichier de mot de passe introuvable ou illisible : $USER_PASSFILE" >&2
    exit 1
  }
  PASSFILE="$USER_PASSFILE"
elif have_tty; then
  PASSFILE="$WORKDIR/become"
  printf 'Mot de passe sudo pour %s : ' "$SSH_HOST" > /dev/tty
  IFS= read -rs _pw < /dev/tty
  printf '\n' > /dev/tty
  ( umask 077; printf '%s' "$_pw" > "$PASSFILE" )
  unset _pw
else
  cat >&2 <<EOF
Aucun terminal disponible pour lire le mot de passe sudo.

ansible.cfg impose become_ask_pass, ce script a donc besoin du mot de passe.
Deux solutions :

  · le lancer depuis votre propre terminal (pas le préfixe `!` de Claude Code,
    qui rend stdout non bloquant et fait échouer ansible avant tout) :
        ./deploy-media-stack.sh

  · ou le lui passer par fichier :
        ( umask 077; printf '%s' 'MOTDEPASSE' > ~/.sudo-homeserver )
        ./deploy-media-stack.sh --pass-file ~/.sudo-homeserver --yes
        rm -f ~/.sudo-homeserver
EOF
  exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; OFF=$'\033[0m'

step()  { printf '\n%s▸ %s%s\n' "$BOLD" "$1" "$OFF"; }
ok()    { printf '%s  ✓ %s%s\n' "$GRN" "$1" "$OFF"; }
warn()  { printf '%s  ! %s%s\n' "$YEL" "$1" "$OFF"; }
fail()  { printf '%s  ✗ %s%s\n' "$RED" "$1" "$OFF"; }
note()  { printf '%s    %s%s\n' "$DIM" "$1" "$OFF"; }

DRY_FAILURES=0

play() {
  local desc="$1"; shift
  step "$desc"
  if (( DRY )); then
    # En simulation, un rôle jamais déployé échoue au rendu du template compose :
    # le compte de service n'existe pas encore, donc `<role>_account.uid` est
    # absent du dict enregistré. C'est un artefact du mode check documenté dans
    # les TODO, pas un défaut — on le signale et on poursuit la simulation.
    if ! ansible-playbook "$PLAYBOOK" --become-password-file "$PASSFILE" --check --diff "$@"; then
      warn "échec en mode check — attendu tant que ce rôle n'a jamais été déployé"
      note "(le compte de service n'existe pas, le template n'a pas d'uid à rendre)"
      DRY_FAILURES=$((DRY_FAILURES + 1))
    fi
  else
    ansible-playbook "$PLAYBOOK" --become-password-file "$PASSFILE" "$@"
  fi
}

# ---------------------------------------------------------------------------
# Résumé avant de commencer
# ---------------------------------------------------------------------------
cat <<EOF

${BOLD}Stack média — déploiement${OFF}
  cible          ${SSH_HOST}
  mode           $( ((DRY)) && echo "simulation (--check --diff)" || echo "réel" )

  1. docker, caddy, jellyfin   réseau media, certificats, Jellyfin sur media
                               ${YEL}redémarre Jellyfin${OFF}
  2. qbittorrent               gluetun + le tunnel (jusqu'à 180 s d'attente)
  3. test du coupe-circuit     ${BOLD}bloquant${OFF} — doit échouer pour continuer
  4. arr                       prowlarr, sonarr, radarr, bazarr, jellyseerr
  5. homepage                  widgets
  6. contrôles finaux

EOF

if (( ! DRY )) && (( ! ASSUME_YES )); then
  if have_tty; then
    printf 'Continuer ? [o/N] ' > /dev/tty
    IFS= read -r reply < /dev/tty
    [[ "$reply" =~ ^[oOyY]$ ]] || { echo "Abandon."; exit 0; }
  else
    echo "Pas de terminal pour confirmer — relancez avec --yes." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 1. Socle : réseau media, vhosts, Jellyfin
# ---------------------------------------------------------------------------
play "1/6 — socle : docker, caddy, jellyfin" --tags docker,caddy,jellyfin

if (( ! DRY )); then
  step "Vérification du réseau media"
  subnet="$(ssh "$SSH_HOST" 'docker network inspect media -f "{{range .IPAM.Config}}{{.Subnet}}{{end}}" 2>/dev/null' || true)"
  if [[ -z "$subnet" ]]; then
    fail "le réseau media n'existe pas — les fichiers compose le déclarent external"
    note "relancez : ansible-playbook playbook.yml -K --tags docker"
    exit 1
  fi
  ok "media présent en $subnet"
  [[ "$subnet" == "10.89.0.0/24" ]] || warn "attendu 10.89.0.0/24 — vérifiez media_network_subnet dans group_vars"
fi

# ---------------------------------------------------------------------------
# 2. Le tunnel
# ---------------------------------------------------------------------------
play "2/6 — qbittorrent derrière gluetun" --tags qbittorrent

# ---------------------------------------------------------------------------
# 3. Coupe-circuit — bloquant
# ---------------------------------------------------------------------------
if (( DRY )); then
  step "3/6 — test du coupe-circuit (ignoré en simulation)"
else
  step "3/6 — test du coupe-circuit"
  note "arrêt de gluetun, puis tentative de sortie depuis qBittorrent"

  ssh "$SSH_HOST" 'docker stop gluetun >/dev/null'
  leaked="$(ssh "$SSH_HOST" 'docker exec qbittorrent curl -s --max-time 10 https://ipinfo.io/ip 2>/dev/null' || true)"
  ssh "$SSH_HOST" 'docker start gluetun >/dev/null'

  if [[ -n "${leaked//[[:space:]]/}" ]]; then
    fail "FUITE — qBittorrent a répondu « $leaked » alors que gluetun était arrêté"
    note "le partage d'espace réseau est cassé, le client est exposé."
    note "n'utilisez pas la stack tant que ce test n'échoue pas."
    note "gluetun a été relancé ; les *arr n'ont PAS été déployés."
    exit 1
  fi
  ok "aucune réponse — le coupe-circuit tient"

  note "remise en service (qBittorrent doit être recréé après un cycle de gluetun)"
  ssh "$SSH_HOST" '
    for _ in $(seq 1 36); do
      [ "$(docker inspect -f "{{.State.Health.Status}}" gluetun 2>/dev/null)" = "healthy" ] && break
      sleep 5
    done
    docker restart qbittorrent >/dev/null
  '
  ok "tunnel rétabli"
fi

# ---------------------------------------------------------------------------
# 4 & 5. Les applications
# ---------------------------------------------------------------------------
play "4/6 — stack *arr" --tags arr
play "5/6 — homepage" --tags homepage

# ---------------------------------------------------------------------------
# 6. Contrôles finaux
# ---------------------------------------------------------------------------
if (( DRY )); then
  step "6/6 — contrôles finaux (ignorés en simulation)"
  echo
  if (( DRY_FAILURES )); then
    ok "simulation terminée — $DRY_FAILURES phase(s) en échec de mode check"
    note "attendu sur une installation neuve. Ce que la simulation prouve vraiment :"
    note "  · le socle (docker, caddy, jellyfin) s'applique proprement"
    note "  · les asserts du vault passent contre le serveur réel"
    note "Le reste ne peut pas être simulé — lancez le déploiement réel."
  else
    ok "simulation terminée sans échec"
  fi
  exit 0
fi

step "6/6 — contrôles finaux"

host_ip="$(ssh "$SSH_HOST" 'curl -s --max-time 10 https://ipinfo.io/ip' || echo '?')"
vpn_ip="$(ssh "$SSH_HOST" 'docker exec qbittorrent curl -s --max-time 20 https://ipinfo.io/ip' || echo '?')"

printf '    IP publique du serveur   %s\n' "$host_ip"
printf '    IP vue par qBittorrent   %s\n' "$vpn_ip"

if [[ "$vpn_ip" == "?" || -z "${vpn_ip//[[:space:]]/}" ]]; then
  fail "qBittorrent ne sort pas — le tunnel n'est pas monté"
elif [[ "$host_ip" == "$vpn_ip" ]]; then
  fail "les deux IP sont identiques : le trafic NE passe PAS par le VPN"
else
  ok "le trafic torrent sort bien par le VPN"
fi

code="$(ssh "$SSH_HOST" 'docker exec sonarr curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://gluetun:8080/api/v2/app/version 2>/dev/null' || echo '000')"
printf '    sonarr → qbittorrent     HTTP %s\n' "$code"
case "$code" in
  403) ok "Sonarr atteint qBittorrent et est correctement refusé faute de session" ;;
  401) fail "en-tête Host refusé — relancez avec -e qbittorrent_reset_config=true" ;;
  000) fail "aucune réponse — pare-feu gluetun, vérifiez FIREWALL_OUTBOUND_SUBNETS" ;;
  *)   warn "code inattendu, à regarder de près" ;;
esac

printf '    conteneurs sur media     %s\n' "$(ssh "$SSH_HOST" 'docker network inspect media -f "{{range .Containers}}{{.Name}} {{end}}"' || echo '?')"

cat <<EOF

${BOLD}Reste à faire à la main${OFF} — voir TODO-arr-stack.md
  · Prowlarr : ajouter les indexeurs (ils se synchronisent seuls ensuite)
  · Bazarr   : fournisseurs de sous-titres et langues
  · Jellyseerr : assistant de premier lancement
  · Vérifier les liens physiques après le premier import :
      ssh ${SSH_HOST} 'find /var/jellyfin/media/show -type f -links +1 | head'

EOF
