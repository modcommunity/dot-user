# Design

Why dot-user is shaped the way it is. The one-line rules are in [CLAUDE.md](../CLAUDE.md).

## A server recognises a returning player and nobody else

**A server must be able to recognise a returning player without being able to recognise them anywhere else.** Recognising needs a stable key; not correlating needs that key to differ everywhere. A keyed derivation gives both:

```
scoped_id = base64url(HMAC-SHA256(key, scope + U+001F + account_id))[:22]
```

`DotUserScope` is the security boundary of this addon. Three properties, and dropping any one makes it theatre:

- **The key never leaves the issuer.** A server that could compute the derivation could correlate on its own.
- **It is a keyed MAC, not a hash.** An unkeyed hash of a numeric account id is reversed by counting to a million, which takes about a second. It looks identical in a code review and is worthless.
- **Opting in is per scope.** "Recognise me across this community" must not be spelled like "recognise me everywhere", so the shared scope is its own object (`DotUserScope.shared()`) rather than a boolean on the per-server one. A flag invites code that flips it.

The separator matters and is easy to leave out: without it, `("ab", "cd")` and `("abc", "d")` share a MAC input, which is two players sharing one profile. 22 base64url characters is 132 bits.

**The account id stops travelling at `DotUserManager.key_for`.** Everything above that call sees a scoped id; nothing below needs the account id again. A change that makes the account id available further in is the thing to push back on.

## Where the scope key lives, and what breaks if it moves

Normally on a publisher's issuer: the component that mints dot-auth connect tickets, which already holds a private key and scopes tickets by audience.

A standalone server with no issuer generates its own on first run, and that key must **survive**: regenerating it renames every profile, so every player loses their name, avatar and settings at once and it looks like a database wipe. `DotUserManager._resolve_scope` therefore generates only when the file is *absent*, and refuses when a file exists but cannot be read rather than quietly replacing it. The asymmetry is deliberate.

## Display names are the hostile-input surface

A display name is shown to every other player and chosen by the person it is shown for. Everything `DotUserName` strips has been used against a shipped game:

| | |
| --- | --- |
| Bidirectional overrides (U+202A–U+202E, U+2066–U+2069) | Reverses the text after it, so a name rewrites the sentence it appears in. |
| Zero-width characters | Two names that render identically; one impersonates the other and a moderator cannot see it. |
| Combining marks | Stacked diacritics escape the line box and cover the interface. |
| Control characters | A newline splits one log line into two, one of which the player wrote. |
| Leading/trailing spaces | " Ada" and "Ada " look identical, sort apart, defeat a lookup. |

- **`sanitise` and `validate` are separate calls.** Sanitising repairs someone who typed something slightly wrong; validating refuses. Only the first accepts a name that is empty once repaired; only the second refuses a name a trailing space would have made fine.
- **A control character becomes a space, not nothing.** Dropping it turns "a\nb" into "ab", a way to construct a name that does not match what was typed.

`MAX_BYTES` is `MAX_LENGTH * 4` and so **unreachable for well-formed input** (Godot strings are UTF-32; 24 characters cannot exceed 96 bytes). It is a backstop for input where `length()` and the encoded size disagree, and it is deliberately not tightened: a byte limit that bites gives players whose names are not Latin a shorter name than everyone else.

`comparison_key` is aggressive on purpose (folds case, removes spaces, maps lookalike digits), because its job is stopping a name visually confusable with somebody else's. `refuse_duplicate_names` uses it, and sees only this server's cache.

**It says nothing about whether a name is offensive.** That is policy, it differs per community, and `DotUserManager.name_filter` is the hook.

## Storage rules, shared with dot-server's ban store

Both solve the same problem (a per-player record a community running eight servers wants to share), so `DotUserStore` deliberately mirrors dot-server's `DotBanStore`, including its two hard-learned rules:

- **Loads may be slow; lookups on the join path may not.** A remote store is queried at startup and on writes, never while a player waits to spawn. A profile stays cached after the player leaves so a map change does not re-read for thirty people at once.
- **A failed read keeps whatever is in force.** If the store cannot answer, the player gets a *session-only* profile, marked by `created_at == 0`, which `save()` refuses to persist (`DotUserManager.is_persistable`). Writing a fresh profile instead would overwrite the real one on disconnect, turning a network blip into data loss.

**Absent is not a failure.** A first-time player is the common case. A store that reported "no profile" as an error makes every new player a support ticket; one that reported a read failure as "no profile" destroys data. `DotUserStore._fetch` returning a successful null is the distinction, and it is load-bearing.

`DotUserStoreLocal` writes one file per profile, not one for all: a single file rewrites everything on every change once there are a few thousand returning players, and a crash midway loses every profile rather than one.

`DotUserStoreBackbone` speaks four endpoints (`GET`/`PUT`/`DELETE /user/profile`, `GET /user/{key}/public`) and must never hold a credential that works anywhere else: a server holds a token scoped to profiles of players connected to it, never a player's own account token (dot-auth's [tickets](../../dot-auth/docs/tickets.md) are why).

## Bounds, and why they are not optional

A profile is relayed to every other player in the match, so an unbounded one is an amplification vector: one player writes a megabyte and the server sends it to everyone each time somebody joins. `DotUserProfile.validate` caps the preference count, key length, serialised value size, avatar reference and locale tag, and it runs on **read as well as write**: a file on disk may have been hand-edited or restored from another server's backup.

`to_public_dict` is the other half: preferences are private by construction. Sensitivity, locale and accessibility settings are nobody else's business, and a profile relayed wholesale leaks them to the match.

## Coupling: nothing is imported

dot-auth is **not** a dependency. The identity passed to `resolve()` is duck-typed: anything with `uid`, `display_name` and `is_guest`, which `DotAuthIdentity` and dot-server's `DotGuestIdentity` both provide. A hard dependency either way makes both harder to adopt, and this addon has to work on a server with no authentication at all.

`DotUserManager` registers as `dot_user_manager` in `DotRegistry`, which is how dot-user-avatar finds it without importing anything. `register_service` defaults to **on** here, unlike most of the family, because a profile manager genuinely is one per process and its consumers have no other way to find it; `service_scope` covers two in one process.

## Deliberately not here

- **Friends, parties, presence.** A social graph, not a profile (dot-friends, dot-party). It needs its own privacy model and a backbone that answers "who is online".
- **Game save data.** The preference bounds are far too small on purpose. A platform profile that grew a `kills` field would grow one for every game.
- **Global name uniqueness.** A backbone that wants unique names enforces it where it can see all of them.
- **Argon2 or bcrypt.** dot-user never holds a password. Real credentials belong on the backbone; dot-auth's [security notes](../../dot-auth/docs/security.md#two-things-that-are-weaker-than-they-look) say why its own `hash_password` is not adequate for that.
- **Profile history or audit.** What a name used to be is a store concern, and the backbone protocol is the place for it.
