"""Turn Authelia's file backend into Keycloak user representations.

Authelia stores PHC strings — $argon2id$v=19$m=65536,t=3,p=4$<salt>$<hash>,
both in unpadded base64. Keycloak's argon2 provider stores the same numbers
split into a credential: the salt and the hash in padded base64 in secretData,
the parameters in credentialData. Nothing is re-hashed, so the password itself
never has to be known: Keycloak verifies the first login against the Authelia
hash, then re-hashes with its own parameters on the spot.
"""

import base64
import json

from ansible.errors import AnsibleFilterError

# Authelia's v= field is the decimal of the version byte, Keycloak wants the
# dotted form.
ARGON2_VERSIONS = {"19": "1.3", "16": "1.0"}


def _rebase64(value):
    """Unpadded base64 (standard or url-safe alphabet) to padded standard."""
    value = value.replace("-", "+").replace("_", "/")
    raw = base64.b64decode(value + "=" * (-len(value) % 4))
    return raw, base64.b64encode(raw).decode("ascii")


def _argon2_credential(username, digest):
    parts = digest.split("$")
    # ['', 'argon2id', 'v=19', 'm=65536,t=3,p=4', '<salt>', '<hash>']
    if len(parts) != 6 or not parts[1].startswith("argon2"):
        raise AnsibleFilterError(
            "%s: the password is not an argon2 digest (%s...). Keycloak can only "
            "take over argon2 hashes as they are; reset this account's password "
            "in Authelia with argon2id first." % (username, digest[:12])
        )
    variant = parts[1][len("argon2"):]
    version = ARGON2_VERSIONS.get(parts[2].removeprefix("v="))
    params = dict(p.split("=", 1) for p in parts[3].split(","))
    if variant not in ("id", "i", "d") or version is None or set(params) != {"m", "t", "p"}:
        raise AnsibleFilterError("%s: unexpected argon2 digest header %s" % (username, "$".join(parts[:4])))
    _, salt = _rebase64(parts[4])
    raw_hash, hash_ = _rebase64(parts[5])

    return {
        "type": "password",
        "userLabel": "Migrated from Authelia",
        "secretData": json.dumps({"value": hash_, "salt": salt, "additionalParameters": {}}),
        "credentialData": json.dumps({
            "hashIterations": int(params["t"]),
            "algorithm": "argon2",
            "additionalParameters": {
                "type": [variant],
                "version": [version],
                "hashLength": [str(len(raw_hash))],
                "memory": [params["m"]],
                "parallelism": [params["p"]],
            },
        }),
    }


def _split_name(displayname):
    """'Alexandre Gérault' -> ('Alexandre', 'Gérault'). Keycloak rebuilds the
    `name` claim as firstName + ' ' + lastName, so the round trip is exact for
    every name but those with no space, which keep an empty lastName."""
    first, _, last = (displayname or "").strip().partition(" ")
    return first, last.strip()


def authelia_to_keycloak_users(users_database, identifiers=None):
    """users_database: the parsed users_database.yml.
    identifiers: the parsed `authelia storage user identifiers export`, or None.

    The OpenID Connect subject Authelia handed out becomes the Keycloak user id,
    so Forgejo, AFFiNE and Penpot see the same `sub` claim as before and keep
    their account links instead of matching on the email again."""
    subjects = {}
    for entry in (identifiers or {}).get("identifiers") or []:
        if entry.get("service") == "openid" and not entry.get("sector_id"):
            # Keycloak lowercases usernames, and Authelia's own lookups were
            # case-insensitive: the two files need not agree on the case.
            subjects[entry["username"].lower()] = entry["identifier"]

    users = []
    for username, user in sorted((users_database.get("users") or {}).items()):
        first, last = _split_name(user.get("displayname"))
        rep = {
            "username": username,
            "email": user.get("email"),
            # Authelia never verified addresses either: they were written by
            # hand in the vault, which is as verified as it gets.
            "emailVerified": bool(user.get("email")),
            "firstName": first,
            "lastName": last,
            "enabled": not user.get("disabled", False),
            "groups": ["/" + g for g in user.get("groups") or []],
            "credentials": [_argon2_credential(username, user["password"])],
            "requiredActions": [],
        }
        if username.lower() in subjects:
            rep["id"] = subjects[username.lower()]
        users.append(rep)
    return users


def authelia_groups(users_database):
    """Every group some Authelia account belongs to."""
    groups = set()
    for user in (users_database.get("users") or {}).values():
        groups.update(user.get("groups") or [])
    return sorted(groups)


class FilterModule:
    def filters(self):
        return {
            "authelia_to_keycloak_users": authelia_to_keycloak_users,
            "authelia_groups": authelia_groups,
        }
