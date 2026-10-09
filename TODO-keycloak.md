# Keycloak — remplacer Authelia

Le rôle `keycloak` remplace le rôle `authelia` dans `playbook.yml` : Keycloak,
son Postgres et oauth2-proxy (pour le `forward_auth` de Caddy) dans un projet
compose sous `/etc/keycloak`. Au premier run il reprend les comptes d'Authelia
avec leurs mots de passe, puis supprime le conteneur `authelia`. Forgejo, AFFiNE
et Penpot pointent sur Keycloak. Tout est décrit dans le README, « Putting a
site behind the SSO », « Accounts » et « Migrating from Authelia ».

**Pas encore déployé.**

## Testé en local (2026-10-09)

Keycloak 26.7.5, oauth2-proxy v7.15.5, Caddy 2.6.2 (celui de bookworm), sur
Docker Desktop, avec les templates du rôle rendus tels quels :

- [x] Un hash argon2id généré par Authelia 4.39 (mot de passe avec accents,
      espaces et `&`) est accepté par Keycloak après conversion ; un mauvais
      mot de passe est refusé.
- [x] L'identifiant OIDC exporté d'Authelia devient l'id Keycloak, donc le
      `sub` des tokens ne change pas.
- [x] Un compte sans nom de famille se connecte (profil utilisateur assoupli).
- [x] `configure.yml` passé deux fois : zéro changement au second.
- [x] Un second import ne fait que des `skipped`.
- [x] Le projet compose démarre : secrets lus par l'entrypoint, healthcheck
      Keycloak OK.
- [x] Le parcours complet : `https://app…/series/42?a=1&b=two` sans cookie →
      Keycloak → `/oauth2/callback` → retour sur la même URL, query comprise ;
      un appel XHR sans cookie reçoit 401, pas une redirection.
- [x] Claims : `groups` en noms nus pour Forgejo et oauth2-proxy, absent pour
      AFFiNE et Penpot ; `aud` d'oauth2-proxy correct.

Pas testable en local : les permissions des fichiers de secrets (uid 1000,
999, 65532 — Docker Desktop ne les applique pas comme Linux), le DNS et le
certificat Let's Encrypt, les vraies applications.

## Avant le premier run

- [ ] **DNS.** Un enregistrement A `auth.alexandre-gerault.fr` vers l'IP
      publique, explicite comme les autres. oauth2-proxy lit la découverte
      OIDC par le nom public au démarrage : sans DNS ni certificat, le rôle
      échoue à « Wait for oauth2-proxy to answer ».

- [x] **Les secrets du vault.** `vault_keycloak_admin_password`,
      `vault_keycloak_db_password`, `vault_oauth2_proxy_client_secret` et
      `vault_oauth2_proxy_cookie_secret`, générés localement, jamais affichés.
      Les secrets clients de Forgejo, AFFiNE et Penpot sont réutilisés tels
      quels. Les clés Authelia sont toujours là, pour le retour arrière.

- [ ] **Committer le travail en cours AFFiNE/Penpot d'abord**, en commit
      séparé, `roles/authelia` compris : c'est le point de retour arrière.
      Puis la migration dans un second commit.

- [ ] `community.general` ≥ 13.4.0 sur le poste (`requirements.yml`).

## Le run

Caddy d'abord (le vhost `auth.` doit exister pour qu'oauth2-proxy démarre),
Keycloak ensuite. Entre les deux, les vhosts `protect: true` répondent 502 :
quelques minutes, le premier démarrage de Keycloak compris.

```bash
ansible-playbook playbook.yml --tags caddy,keycloak,forgejo,compose
```

- [ ] `cat /etc/keycloak/authelia-migrated` : chaque compte en `ADDED`, avec
      son id. Le run affiche aussi la liste (« Report what was imported »).
- [ ] `docker ps` : `keycloak`, `keycloak_postgres`, `oauth2-proxy` ; plus
      d'`authelia`.
- [ ] Forgejo : la source s'appelle `keycloak`, même id qu'avant —
      `docker exec --user git forgejo forgejo admin auth list --vertical-bars`.

## Après le run

- [ ] Ouvrir `https://dashboard.homelab.alexandre-gerault.fr` en navigation
      privée : page de login Keycloak, mot de passe **actuel** d'Authelia,
      retour sur le dashboard. Puis `sonarr.` : pas de second login.
- [ ] `https://git.alexandre-gerault.fr` : bouton `keycloak`, retour sur le
      **même** compte Forgejo, toujours administrateur.
- [ ] AFFiNE et Penpot : même compte qu'avant.
- [ ] Le mail : « Mot de passe oublié ? » sur la page de login, pour son
      propre compte. (« Test connection » dans la console écrit à l'adresse de
      l'admin connecté, et `admin` du realm master n'en a pas.)
- [ ] Console : `https://auth.alexandre-gerault.fr/admin/`, `admin` et
      `vault_keycloak_admin_password` — vérifier qu'on y entre.
- [ ] Supprimer l'enregistrement DNS `authelia.alexandre-gerault.fr`.

## Le ménage, une fois tout vérifié

- [ ] `git rm -r roles/authelia` (laissé sur disque, il porte des
      modifications pas encore commitées).
- [ ] Retirer du vault les clés que plus rien ne lit : `vault_authelia_*`,
      `vault_forgejo_oidc_client_secret_digest`,
      `vault_affine_oidc_client_secret_digest`,
      `vault_penpot_oidc_client_secret_digest`.
- [ ] `ansible-playbook playbook.yml --tags keycloak -e authelia_remove_data=true`
      supprime `/etc/authelia` et `/var/lib/authelia` (copie des hash, secrets
      TOTP).

## Retour arrière

Revenir au commit d'avant et `--tags caddy,authelia,forgejo,compose` : le rôle
`authelia` recrée le conteneur sur ses fichiers, restés en place. Une chose ne
revient pas seule : la source Forgejo a été renommée `keycloak`. La remettre :

```bash
docker exec --user git forgejo forgejo admin auth update-oauth --id 1 \
  --name authelia \
  --auto-discover-url https://authelia.alexandre-gerault.fr/.well-known/openid-configuration
```

## Trouvé en route

- **`roles/forgejo/tasks/oidc.yml` ne trouvait jamais la source.** Dans un
  scalaire replié (`>-`), `'\\|'` reste deux antislashs, et la regex
  `^[0-9]+\\|authelia\\|` veut dire « un antislash, ou n'importe quoi » : elle
  matchait la ligne d'en-tête et renvoyait `ID`. Ça marchait par accident
  (`add-oauth` sautée parce que l'id n'était pas vide), mais
  `forgejo_oidc_update: true` aurait lancé `update-oauth --id ID`. Corrigé, et
  testé contre une sortie de `auth list`.
