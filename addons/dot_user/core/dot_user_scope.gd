class_name DotUserScope
extends RefCounted

## Turns "who is this account" into "who is this player, here", without letting the
## here correlate with the elsewhere.
##
## [b]The problem.[/b] The natural key for a profile is the backbone account id. Pass
## it to every community-run server and you have handed every operator a stable,
## global identifier for every one of their players, so any two operators can compare
## logs and reconstruct a person's movements across the platform. Nobody has to be
## malicious for that to be true; it is a property of the identifier.
##
## [b]The answer.[/b] A server sees a keyed derivation of the account id, scoped to
## that server:
##
## [codeblock]
## scoped_id = base64url(HMAC-SHA256(key, scope + U+001F + account_id))[:22]
## [/codeblock]
##
## Stable for that player on that server, so bans and profiles work. Different on
## every other scope, so operators cannot correlate. Not reversible, because the key
## never leaves whoever mints identities.
##
## [b]Three properties, and dropping any one makes this theatre:[/b]
##
## - [b]The key never leaves the issuer.[/b] A server that could compute the
##   derivation could correlate on its own.
## - [b]It is a keyed MAC, not a hash.[/b] An unkeyed hash of a numeric account id is
##   reversible by counting to a million, which takes about a second.
## - [b]Opting in is per-scope.[/b] "Recognise me across this community" must not be
##   spelled the same way as "recognise me everywhere". See [method shared].
##
## [b]Where this runs.[/b] Normally on a publisher's issuer, the same component that
## mints dot-auth connect tickets, which already holds a private key and already
## scopes tickets by audience. A game server consuming a scoped id needs none of this.
## It is here rather than in dot-auth because the scoping is a profile concern: it
## decides which profiles are the same profile, and dot-auth does not have profiles.
##
## A standalone server with no issuer derives its own scope from a local secret, which
## gives it stable per-player profiles that no other server can correlate: the same
## guarantee, without the platform.

const CHANNEL := "user.scope"

## Separator between the scope and the account id inside the MAC input.
##
## A byte that cannot occur in either, so [code]("ab", "cd")[/code] and
## [code]("abc", "d")[/code] cannot produce the same input. Concatenating without one
## means two different (scope, account) pairs can collide, which is two different
## players sharing one profile.
const SEPARATOR := "\u001f"

## Characters in a derived id. 22 base64url characters is 132 bits.
##
## Truncated because a scoped id is pasted into logs, ban files and URLs, and 43
## characters of base64 is unusable. 132 bits is far past any collision concern for a
## population that will never exceed 2^40.
const ID_LENGTH := 22

## Scope every participating server shares. See [method shared].
const SCOPE_GLOBAL := "global"

## The scope this instance derives for: a server id, a community id, or
## [constant SCOPE_GLOBAL].
var scope: String = ""

## The MAC key. [b]Never transmit this and never log it.[/b]
var _key: PackedByteArray = PackedByteArray()


## Builds a scope from a key held as bytes.
static func with_key(p_scope: String, key: PackedByteArray) -> DotUserScope:
	var s := DotUserScope.new()
	s.scope = p_scope
	s._key = key
	return s


## Builds a scope from a secret string, hashed to key material.
##
## Hashed rather than used raw so a short or low-entropy secret still produces a
## full-width key: the MAC is only as good as its key, and an operator will type a
## passphrase.
static func with_secret(p_scope: String, secret: String) -> DotUserScope:
	return with_key(p_scope, DotHash.sha256_text(secret).to_utf8_buffer())


## Builds a scope with a freshly generated key. For a standalone server's first run.
##
## The key must then be [b]persisted[/b]: regenerating it renames every profile on the
## server, which reads to players as having lost everything.
static func generated(p_scope: String) -> DotUserScope:
	return with_key(p_scope, DotHash.random_bytes(32))


## The scope participating servers share, for players who opt into being recognised
## across all of them.
##
## [b]Deliberately a separate object rather than a flag on this one.[/b] A boolean
## invites code that flips it, and a scope that can be changed after an id has been
## issued is a scope that will be. Two scopes means a caller has to hold the one it
## means.
static func shared(key: PackedByteArray) -> DotUserScope:
	return with_key(SCOPE_GLOBAL, key)


func has_key() -> bool:
	return _key.size() > 0


## Derives the scoped id for an account.
##
## [param account_id] is the real, global identifier: a backbone user id, or a
## platform account id.
## It never leaves the process that calls this.
func derive(account_id: String) -> DotResult:
	if not has_key():
		return DotResult.fail(
			DotError.CODE_STATE,
			"This scope has no key, so it cannot derive an id.",
			"scope '%s'" % scope
		)

	if account_id.strip_edges() == "":
		return DotResult.fail(DotError.CODE_INVALID, "An account id is required.")

	if scope.strip_edges() == "":
		return DotResult.fail(DotError.CODE_INVALID, "A scope name is required.")

	var message := "%s%s%s" % [scope, SEPARATOR, account_id]
	var mac := DotHash.hmac_sha256(_key, message.to_utf8_buffer())

	return DotResult.success(DotHash.base64url_encode(mac).substr(0, ID_LENGTH))


## Whether [param candidate] is the id this scope derives for [param account_id].
##
## Constant-time, because the alternative leaks how many leading characters were right
## and turns forging an id into 22 rounds of 64 tries.
func matches(account_id: String, candidate: String) -> bool:
	var derived := derive(account_id)

	if not derived.ok:
		return false

	return DotHash.constant_time_equal(
		String(derived.value).to_utf8_buffer(), candidate.to_utf8_buffer()
	)


## Whether a string is shaped like a scoped id.
##
## A cheap structural check for anything arriving from a client or a file, so a
## malformed key cannot become a filename or a store lookup. It says nothing about
## whether the id is [i]genuine[/i]; only a MAC comparison does that.
static func is_well_formed(id: String) -> bool:
	if id.length() != ID_LENGTH:
		return false

	for i in range(id.length()):
		var c := id.unicode_at(i)
		var ok := (
			(c >= 65 and c <= 90)
			or (c >= 97 and c <= 122)
			or (c >= 48 and c <= 57)
			or c == 45
			or c == 95
		)
		if not ok:
			return false

	return true


## The key as a storable string. For persisting a generated key.
##
## Named to be conspicuous at the call site: anything that writes this belongs in a
## file with restricted permissions, never in a config a client receives, never in a
## log, and never in a bug report.
func export_secret_key() -> String:
	return DotHash.base64url_encode(_key)


static func from_secret_key(p_scope: String, encoded: String) -> DotResult:
	var raw := DotHash.base64url_decode(encoded)

	if raw.size() < 16:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A scope key must be at least 16 bytes.",
			"got %d" % raw.size()
		)

	return DotResult.success(with_key(p_scope, raw))


## Never includes the key. Everything here is safe to log.
func describe() -> Dictionary:
	return {
		"scope": scope,
		"has_key": has_key(),
		"key_bytes": _key.size(),
	}


func _to_string() -> String:
	return "DotUserScope(%s)" % scope
