This is the **user** asset for TMC's **Dot** collection. It carries a player's profile between servers while making sure those servers cannot work out that it is the same person.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## Profiles That Follow a Player
Player profiles that follow a person between servers, without letting those servers
work out that it is the same person.

Display name, avatar reference, preferences. Pluggable storage — a JSON directory, an
in-memory store, or an open HTTP backbone anyone can self-host. Resolved once on join,
cached, and never re-read on the hot path.

Part of the [dot-\*](../) family. Requires [dot-core](../dot-core). Works with
[dot-auth](../dot-auth), [dot-server](../dot-server) and
[dot-user-avatar](../dot-user-avatar), and imports none of them.

## Install

Copy `addons/dot_user/` and `addons/dot_core/` into your project and enable both in
*Project → Project Settings → Plugins*.

## Use

```gdscript
var manager := DotUserManager.new()
manager.server_id = "eu-west-1"
add_child(manager)

# identity is anything with uid, display_name and is_guest — DotAuthIdentity,
# dot-server's DotGuestIdentity, or your own.
var resolved := await manager.resolve(identity)
if resolved.ok:
    var profile: DotUserProfile = resolved.value
    print(profile.display_name)
```

Nothing is imported and nothing is an autoload. `DotUserManager` registers itself in
`DotRegistry` as `dot_user_manager`, which is how dot-server and dot-user-avatar find
it.

## The identity problem, and the answer

The natural key for a profile is the account id. Hand it to every community-run server
and any two operators can compare logs and reconstruct where a person has been. Nobody
has to be malicious; it is a property of the identifier.

So a server never sees the account id. It sees a **scoped id**:

```
scoped_id = base64url(HMAC-SHA256(key, scope + U+001F + account_id))[:22]
```

Stable for that player on that server, so bans and profiles work. Different on every
other scope, so operators cannot correlate. Not reversible, because the key never
leaves whoever mints identities.

A player who *wants* to be recognised across a set of servers opts into a shared
scope. A standalone server with no issuer generates its own key on first run and gets
the same isolation for free.

Three properties, and dropping any one makes it theatre: the key never leaves the
issuer, the derivation is a keyed MAC rather than a hash, and opting into a shared
scope is per-scope rather than global.

## What is in the box

| | |
| --- | --- |
| `DotUserScope` | The derivation above, plus verification and key persistence. |
| `DotUserName` | Display-name sanitising and validation. The hostile-string layer. |
| `DotUserProfile` | The record. Bounded, versioned, migratable, with a public subset. |
| `DotUserStore` | Where profiles live. `Memory`, `Local` (JSON files), `Backbone` (HTTP). |
| `DotUserManager` | Resolve on join, cache, write back, rename, rate-limit. |
| `DotUserConfig` | Layered: exported defaults < JSON < `DOT_USER_*` < `--user-*`. |

## Display names

A display name is the most hostile string a platform accepts — it is shown to every
other player and chosen by the person it is shown for. `DotUserName` strips
bidirectional overrides, zero-width characters, stacked combining marks and control
characters, collapses whitespace, and refuses names that are empty, over-long, or made
entirely of punctuation.

It says nothing about whether a name is *offensive*. That is a policy question with a
different answer in every community, and `DotUserManager.name_filter` is the hook.

By default an authenticated player cannot rename themselves — their name comes from
their account, and a player who can override it can appear as somebody else. Guests
have no account name, so they can pick one.

## Storage

`DotUserStore` follows the same two rules as dot-server's ban store, for the same
reasons:

- **Loads may be slow; lookups on the join path may not.** A resolved profile stays
  cached after the player leaves, so a map change does not re-read for everyone at
  once.
- **A failed read never destroys a profile.** If the store cannot answer, the player
  gets a session-only profile that `save()` refuses to persist. Writing a fresh one
  would overwrite the real profile on disconnect — a network blip turned into data
  loss.

## Validating

```bash
godot --headless --path . --import
godot --headless --path . res://examples/user_demo.tscn     # 137 checks
```

Exits non-zero on failure.

MIT licensed.
