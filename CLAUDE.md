# dot-user

Player profiles that follow a person between servers, without letting those servers
correlate them.

Read the family-wide conventions in [`../../CLAUDE.md`](../../CLAUDE.md) first — no
autoloads, `DotNodeRef` instead of scene paths, `DotResult` for anything fallible,
`Dot`-prefixed class names, layered configuration, `describe()` on anything stateful.
This file is only what is specific to profiles.

## The one idea

**A server must be able to recognise a returning player without being able to
recognise them anywhere else.**

Those two halves pull in opposite directions and everything here is the shape of the
compromise. Recognising a returning player needs a stable key. Not correlating across
servers needs that key to be different everywhere. A keyed derivation gives both:

```
scoped_id = base64url(HMAC-SHA256(key, scope + U+001F + account_id))[:22]
```

`DotUserScope` is 200 lines and is the security boundary of this addon. Three
properties, and dropping any one makes it theatre:

- **The key never leaves the issuer.** A server that could compute the derivation
  could correlate on its own, and the whole exercise is pointless.
- **It is a keyed MAC, not a hash.** An unkeyed hash of a numeric account id is
  reversible by counting to a million, which takes about a second. This is the
  mistake that looks identical in a code review and is worthless.
- **Opting in is per-scope.** "Recognise me across this community" must not be spelled
  the same way as "recognise me everywhere", so the shared scope is a separate object
  rather than a boolean on the per-server one. A flag invites code that flips it.

The separator matters too and is easy to leave out: without it, `("ab", "cd")` and
`("abc", "d")` share a MAC input, which is two different players sharing one profile.

**The account id stops travelling at `DotUserManager.key_for`.** Everything above that
call sees a scoped id; nothing below it needs the account id again. If a future change
makes an account id available further in, that is the thing to push back on.

## Where the scope key lives, and what breaks if it moves

Normally on a publisher's issuer — the same component that mints dot-auth connect
tickets, which already holds a private key and already scopes tickets by audience.

A standalone server with no issuer generates its own on first run. That key must then
**survive**: regenerating it renames every profile on the server, so every player
loses their name, their avatar and their settings simultaneously and it looks like a
database wipe. `DotUserManager._resolve_scope` therefore generates only when the file
is *absent*, and treats a file that exists but cannot be read as fatal rather than
quietly replacing it. That asymmetry is deliberate and should not be smoothed out.

## Display names are the hostile-input surface

`DotUserName` exists because a display name is shown to every other player and chosen
by the person it is shown for. Everything it strips has been used against a shipped
game:

| | |
| --- | --- |
| Bidirectional overrides (U+202A–U+202E, U+2066–U+2069) | Reverses the text after it, so a name rewrites the sentence it appears in. |
| Zero-width characters | Two names that render identically. One is impersonating the other and a moderator cannot see it. |
| Combining marks | Stacked diacritics escape the line box and cover the surrounding interface. |
| Control characters | A newline splits one log line into two, one of which the player wrote. |
| Leading/trailing spaces | " Ada" and "Ada " look identical, sort apart, defeat a lookup. |

Two things worth keeping as they are:

- **Sanitise and validate are separate calls.** Sanitising is a repair for someone who
  typed something slightly wrong; validating is a refusal. Doing only the first
  accepts a name that is empty once repaired; doing only the second refuses a name a
  trailing space would have made fine.
- **A control character becomes a space, not nothing.** Dropping it turns "a\nb" into
  "ab", which is a way to construct a name that does not match what was typed.

`MAX_BYTES` is `MAX_LENGTH * 4` and therefore **unreachable for well-formed input** —
Godot strings are UTF-32, so 24 characters cannot exceed 96 bytes. It is kept as a
backstop for input where `String.length()` and the encoded size disagree, and it is
deliberately not tightened: a byte limit that actually bites gives players whose names
are not Latin a shorter name than everyone else.

`comparison_key` is aggressive on purpose — it folds case, removes spaces and maps
lookalike digits — because its job is stopping a name visually confusable with
somebody else's, and a comparison that only folds case does not do that.

**It says nothing about whether a name is offensive.** That is policy, it differs per
community, and `DotUserManager.name_filter` is the hook.

## Storage rules, inherited from dot-server's ban store

Both solve the same problem — a per-player record a community running eight servers
wants to share — so `DotUserStore` deliberately mirrors `DotBanStore`, including the
two rules that were learned the hard way there:

- **Loads may be slow; lookups on the join path may not.** A remote store is queried
  at startup and on writes, never while a player waits to spawn. A profile stays
  cached after the player leaves so a map change does not re-read for thirty people at
  once.
- **A failed read keeps whatever is in force.** This is the one that matters. If the
  store cannot answer, the player gets a *session-only* profile — marked by
  `created_at == 0`, which `save()` refuses to persist. Writing a fresh profile
  instead would overwrite the real one on disconnect, turning a network blip into data
  loss for a returning player. `DotUserManager.is_persistable` is the check.

**Absent is not a failure.** A first-time player is the common case. A store that
reported "no profile" as an error would make every new player a support ticket; one
that reported a *read failure* as "no profile" would destroy data. `_fetch` returning
a successful null is the distinction, and it is load-bearing.

The local store writes one file per profile, not one file for all of them. A single
file is simpler until a server has a few thousand returning players and rewrites the
whole thing on every change, and until a crash midway through loses every profile
rather than one.

## Bounds, and why they are not optional

A profile is relayed to every other player in the match, so an unbounded one is an
amplification vector: one player writes a megabyte and the server sends it to everyone
each time somebody joins. `DotUserProfile.validate` caps the preference count, the key
length, the serialised value size, the avatar reference and the locale tag, and it is
called on **read as well as write** — a file on disk is not trusted input in the usual
sense, but it is input, and it may have been hand-edited or restored from another
server's backup.

`to_public_dict` is the other half: preferences are private by construction. A
player's sensitivity, locale and accessibility settings are nobody else's business,
and a profile relayed wholesale leaks them to everyone in the match.

## Coupling: nothing is imported

dot-auth is **not** a dependency. The identity passed to `resolve()` is duck-typed:
anything with `uid`, `display_name` and `is_guest` works, which is what
`DotAuthIdentity` and dot-server's `DotGuestIdentity` both already provide. Keep it
that way — a hard dependency in either direction makes both harder to adopt, and this
addon has to work on a server with no authentication at all.

`DotUserManager` registers as `dot_user_manager` in `DotRegistry`. That is how
dot-user-avatar and dot-server find it without importing anything.

`register_service` defaults to **on** here, unlike most of the family, because a
profile manager genuinely is one per process and the things that need it have no other
way to find it. `service_scope` exists for the two-in-one-process case.

## Validating changes

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done

# 137 checks, all offline. Exits non-zero on any failure.
godot --headless --path . res://examples/user_demo.tscn
```

**Run the check-only pass before the scene.** A script that fails to parse makes the
scene fail to load and the process hangs rather than exiting, because nothing reaches
`get_tree().quit()`.

`_test_store_contract` runs the identical sequence against the memory store and the
local store and requires the same answers from both. **Add any new store to it** — a
bug in one implementation then shows up as a difference rather than as a
plausible-looking result.

**Add a case for any change to `DotUserScope` or `DotUserName`.** Those are the two
files where a bug is a vulnerability rather than a crash.

## Things deliberately not here

- **Friends, parties, presence.** Social graph, not a profile. It needs its own
  privacy model and a backbone that can answer "who is online", and bolting it onto a
  per-server profile cache would get both wrong.
- **Game save data.** The preference bounds are far too small on purpose. A save
  belongs in the game's own store; a platform profile that grew a `kills` field would
  have to grow one for every game.
- **Global name uniqueness.** `refuse_duplicate_names` only sees this server's cache
  and says so. A backbone that wants unique names enforces it where it can see all of
  them.
- **Argon2 or bcrypt.** dot-user never holds a password. Anything with real credentials
  belongs on the backbone, which does it properly — see dot-auth's CLAUDE.md for why
  its own `hash_password` is explicitly not adequate for that.
- **Profile history or audit.** A moderator wants to know what a name used to be.
  That is a store concern and the backbone protocol is the place for it.
