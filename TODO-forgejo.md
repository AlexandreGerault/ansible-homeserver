# Forgejo — la lancer

Le rôle `forgejo` est écrit, câblé dans `playbook.yml`, déclaré dans
`caddy_sites` et documenté dans le README. Le rôle `authelia` gagne un
fournisseur OpenID Connect, et son image passe de 4.38 à 4.39.

**Déployé le 2026-09-15.** Il ne reste que la première connexion.

## Avant le premier run

- [x] **DNS.** Un enregistrement A `git.alexandre-gerault.fr` vers l'IP
      publique, explicite, pas un joker — comme les cinq du stack \*arr.

- [x] **Les secrets du vault.** Huit et non sept :
      `vault_forgejo_oauth2_jwt_secret` s'est ajouté, voir plus bas. Générés
      localement (openssl pour la clé RSA, pbkdf2-sha512 à 310000 itérations
      pour le digest du client), jamais affichés.

- [x] **Le mot de passe sudo** est `ansible_become_password` dans le vault, et
      `ansible.cfg` ne le demande plus (`become_ask_pass = False`).

- [x] **Le port 22.** Publié sur `0.0.0.0`, choix assumé. Sonde du 2026-09-15
      sur l'IP publique : 22, 80, 443, 35123 et 8096 répondent ; 1080, 2222,
      3000, 3001, 3010, 3030, 4444, 5000, 8000, 8097, 8098 et 9091 sont
      fermés. La phrase du README est corrigée.

## Le run

- [x] `--tags authelia` : Authelia v4.39.26 démarre, healthy, la migration de
      schéma 15 → 29 est passée (elle ne se défait pas), le filtre de template
      fonctionne, `/.well-known/openid-configuration` répond 200. Les vhosts
      `protect: true` redirigent toujours vers le portail.
- [x] `--tags forgejo` : `healthz` passe, `auth list` montre
      `1|authelia|OAuth2|true`.
- [x] `--tags caddy` : oublié dans la liste d'origine, mais nécessaire — c'est
      lui qui crée le vhost. `https://git.alexandre-gerault.fr` redirige vers
      `/user/login`, `/user/oauth2/authelia` vers Authelia avec
      `client_id=forgejo` et PKCE S256, l'API anonyme répond 403.
- [x] Deux runs `--tags forgejo` d'affilée : `changed=0`.

### Ce que le premier run a cassé, et corrigé

- **Le port 22 dans le conteneur.** L'image rootful lance son propre OpenSSH
  sur 22 ; le serveur intégré de Forgejo mourait sur « address already in
  use » et entraînait le conteneur dans une boucle de redémarrage. Il écoute
  maintenant sur `forgejo_ssh_listen_port: 2222`, et c'est ce port qui est
  publié en 22 sur l'hôte.
- **`app.ini` réécrit à chaque démarrage.** Pas par l'entrypoint (les
  commentaires restaient) : Forgejo lui-même ajoute `WORK_PATH` et génère un
  `[oauth2] JWT_SECRET`, même fournisseur OAuth2 désactivé. Les deux sont
  maintenant dans le template, le second depuis le vault.
- **`[oauth2] ENABLE`** est obsolète, remplacé par `ENABLED`.
- **La source Authelia réenregistrée à chaque run.** `auth list
  --vertical-bars` sépare encore les colonnes par des tabulations ; le motif
  `^1|authelia|` ne trouvait rien, `add-oauth` repartait et échouait sur le nom
  existant. Les blancs sont retirés avant de chercher.

## La première connexion — à toi

Le formulaire mot de passe n'existe pas (`ENABLE_INTERNAL_SIGNIN = false`) et
aucun compte local n'existe : `INSTALL_LOCK = true` fait sauter l'installeur web.
La première connexion passe donc forcément par Authelia, et c'est elle qui crée
le compte.

- [ ] Ouvrir `https://git.alexandre-gerault.fr`, cliquer sur Authelia, se
      connecter avec `alexandregerault` (qui est bien dans `admins` dans le
      vault).
- [ ] Vérifier que le compte créé est bien administrateur. C'est le claim
      `groups` qui le décide. S'il n'arrive pas, le compte est un utilisateur
      ordinaire — voir plus bas.
- [ ] Ajouter une clé SSH dans Forgejo, puis `ssh -T git@git.alexandre-gerault.fr`.
      La clé d'hôte est celle de Forgejo (RSA), pas celle du serveur.

**Si la connexion échoue, il n'y a pas d'autre porte.** Le déverrouillage :

```bash
# un compte local d'urgence
docker exec -u git forgejo forgejo admin user create \
  --admin --username secours --email secours@alexandre-gerault.fr --random-password
# puis forgejo_enable_internal_signin: true, le temps d'un run
```

## Encore à vérifier

- [x] **`app.ini` réécrit.** Réglé, voir plus haut.

- [ ] **Le claim `groups`.** Forgejo le lit sur `/api/oidc/userinfo`, qui le
      renvoie dès que le scope est accordé — c'est le cas. Si l'administration
      n'arrive pas malgré ça, 4.39 a introduit les `claims_policies` pour les
      claims non standard : il faut alors en déclarer une et l'attacher au
      client. En attendant, la promotion se fait depuis l'interface, par un
      admin — c'est-à-dire par le compte de secours ci-dessus, créé avec
      `--admin`, qui est la seule façon d'obtenir le premier administrateur sans
      passer par le claim.

## Pas fait, volontairement

- ~~**Forgejo Actions** est à `false`~~ : activé, avec le rôle
  `forgejo_runner` (runner v13 sur un démon Docker-in-Docker). Voir le README,
  « Forgejo Actions ».
- **Aucune tuile Homepage.** Le rôle `homepage` n'est pas touché.
- **Pas de sauvegarde.** `/var/lib/forgejo` contient les dépôts et le SQLite ;
  rien dans ce dépôt ne le sauvegarde, comme pour tout le reste.
