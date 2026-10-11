# dot-user

Player profiles that follow a person between servers without letting those servers correlate them: a keyed per-scope id, hostile-input-safe display names, bounded preferences, and stores (memory, local files, backbone HTTP).

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to profiles.

**The distributable is `addons/dot_user/`.** It requires [dot-core](../dot-core) and nothing else. dot-auth is not a dependency; identities are duck-typed.

## Read before

| Read | Before |
| --- | --- |
| [docs/design.md](docs/design.md) | anything: the scoped id, where the scope key lives, display names, storage rules, bounds, coupling, what is not here |

## Layout

| Path | What |
| --- | --- |
| `core/dot_user_scope.gd` | `DotUserScope`: the HMAC derivation, `shared()`. The security boundary |
| `core/dot_user_name.gd` | `DotUserName`: `sanitise`, `validate`, `comparison_key` |
| `core/dot_user_profile.gd` | `DotUserProfile`: bounds (`validate`), `to_public_dict` |
| `store/` | `DotUserStore` (`_fetch` contract), `...Memory`, `...Local` (one file per profile), `...Backbone` (HTTP) |
| `dot_user_manager.gd` | `DotUserManager`: `resolve`, `key_for`, `_resolve_scope`, `name_filter`, `is_persistable`; registers `dot_user_manager` |
| `dot_user_config.gd` | `DotUserConfig` (`refuse_duplicate_names`, …) |
| `examples/user_demo.tscn` | the suite, offline |

Paths except `examples/` are in `addons/dot_user/`.

## Running and testing

The family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)), then `timeout 60 godot --headless --path . res://examples/user_demo.tscn` (exits non-zero on any failure; `CHECKS` is the total). Run the check-only pass first: a scene whose script fails to parse hangs rather than exiting.

- `_test_store_contract` runs one sequence against the memory and local stores and requires the same answers. **Add any new store to it**, so a bug shows up as a difference.
- **Add a case for any change to `DotUserScope` or `DotUserName`**: there a bug is a vulnerability, not a crash.

## Rules that bite

- The scope key never leaves the issuer; the id is a keyed MAC with the U+001F separator, never a plain hash. [design](docs/design.md#a-server-recognises-a-returning-player-and-nobody-else)
- Cross-server recognition is a separate `shared()` scope, never a boolean. [design](docs/design.md#a-server-recognises-a-returning-player-and-nobody-else)
- The account id goes no further than `key_for`. [design](docs/design.md#a-server-recognises-a-returning-player-and-nobody-else)
- Generate a scope key only when the file is absent; an unreadable file is a refusal, never a regeneration. [design](docs/design.md#where-the-scope-key-lives-and-what-breaks-if-it-moves)
- Sanitise and validate are separate; a control character becomes a space; do not tighten `MAX_BYTES`. [design](docs/design.md#display-names-are-the-hostile-input-surface)
- Offensiveness is the host's `name_filter`, not this addon. [design](docs/design.md#display-names-are-the-hostile-input-surface)
- No store lookup on the join path; a failed read gives a session-only profile (`created_at == 0`) that is never saved. [design](docs/design.md#storage-rules-shared-with-dot-servers-ban-store)
- Absent is a successful null from `_fetch`, never an error; a read failure is never "absent". [design](docs/design.md#storage-rules-shared-with-dot-servers-ban-store)
- A server never holds a player's own account token. [design](docs/design.md#storage-rules-shared-with-dot-servers-ban-store)
- `DotUserStoreBackbone` parents the `DotHttp` it builds to the root in `_open` and frees it in `_close`: an orphan `DotHttp` fails every request with engine error 3 (Unconfigured). `open()` runs one attempt at a time. [design](docs/design.md#the-backbone-protocol)
- `DotUserProfile.validate` runs on read and write; only `to_public_dict` is relayed. [design](docs/design.md#bounds-and-why-they-are-not-optional)
- Never import dot-auth; `register_service` is on by default here. [design](docs/design.md#coupling-nothing-is-imported)

Deliberately not here: friends, parties, presence, save data, global name uniqueness, password hashing, profile history. [design](docs/design.md#deliberately-not-here)
