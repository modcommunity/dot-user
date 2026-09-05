@tool
class_name DotUserProfile
extends Resource

## What the platform knows about a player, as opposed to what a game does.
##
## Display name, avatar reference, preferences, and a few flags. Deliberately small:
## anything a specific game needs about a specific player belongs to that game, and a
## profile that grew a "kills" field would have to grow one for every game.
##
## [b]It is relayed to other players, so it is bounded.[/b] Every string has a length
## limit and the preferences bag has a key count and a value size limit, checked in
## [method validate]. An unbounded profile is an amplification vector: one player
## writes a megabyte, and the server sends it to everyone in the match every time
## somebody joins.
##
## [b]The key is a scoped id, never an account id.[/b] See [DotUserScope]. A profile
## keyed on the account id would let any two server operators correlate their players
## by comparing files.

const CHANNEL := "user.profile"

## Bumped when the stored shape changes. See [method migrate].
const SCHEMA_VERSION := 1

## Most preference keys a profile may carry.
const MAX_PREFERENCES := 32

## Longest a preference key may be, in characters.
const MAX_PREFERENCE_KEY := 40

## Longest a preference value may be once serialised, in bytes.
const MAX_PREFERENCE_VALUE := 256

## Longest the avatar reference may be.
const MAX_AVATAR_ID := 64

## Longest the locale tag may be.
const MAX_LOCALE := 16

@export_group("Identity")

## The scoped id this profile belongs to. The store's key.
##
## [b]Never an account id.[/b] [method validate] refuses a key that is not shaped like
## one, which is the cheap structural guard against an account id being written here
## by a caller that had one to hand.
@export var user_key: String = ""

## Which scope [member user_key] was derived for. Diagnostic; not a security control.
@export var scope: String = ""

@export_group("Presentation")

## The name shown to other players. Sanitised and validated by [DotUserName].
@export var display_name: String = ""

## Which avatar document to render. Resolved by dot-user-avatar, if present.
##
## A reference, not the avatar: a profile that embedded the document would have to be
## re-sent whenever a hat changed, and a dedicated server would have to understand
## hats.
@export var avatar_id: String = ""

## BCP-47 tag, for a game that localises. Advisory.
@export var locale: String = ""

@export_group("State")

## Unix seconds the profile was created.
@export var created_at: int = 0

## Unix seconds it was last written.
@export var updated_at: int = 0

## Times this player has been seen. Cheap, and the single most useful number in a
## moderation queue.
@export var visit_count: int = 0

## Schema version this profile was written with.
@export var version: int = SCHEMA_VERSION

## Whether the player has finished first-time setup.
##
## What the join flow branches on: a player who is signed in but has not been through
## the avatar editor is held at the profile stage rather than spawned. See dot-user's
## CLAUDE.md.
@export var onboarded: bool = false

@export_group("Preferences")

## Free-form per-player settings, bounded by [method validate].
##
## For the platform's own preferences, not a game's save data. A game that puts its
## save here discovers that the limits are far too small, which is the intended
## outcome: a save belongs in the game's own store.
@export var preferences: Dictionary = {}


static func make(p_user_key: String, p_scope: String = "") -> DotUserProfile:
	var p := DotUserProfile.new()
	p.user_key = p_user_key
	p.scope = p_scope
	p.created_at = int(Time.get_unix_time_from_system())
	p.updated_at = p.created_at
	p.version = SCHEMA_VERSION
	return p


# --- Preferences -----------------------------------------------------------

func preference(key: String, default: Variant = null) -> Variant:
	return preferences.get(key, default)


## Sets a preference. Returns a failure rather than silently dropping an oversized
## value, because a preference that appears to save and does not is worse than one
## that refuses.
func set_preference(key: String, value: Variant) -> DotResult:
	if key.strip_edges() == "" or key.length() > MAX_PREFERENCE_KEY:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"That preference name is not usable.",
			"length %d, maximum %d" % [key.length(), MAX_PREFERENCE_KEY]
		)

	if not preferences.has(key) and preferences.size() >= MAX_PREFERENCES:
		return DotResult.fail(
			DotError.CODE_QUOTA,
			"This profile already has as many preferences as it can hold.",
			"maximum %d" % MAX_PREFERENCES
		)

	var encoded := JSON.stringify(value)

	if encoded.to_utf8_buffer().size() > MAX_PREFERENCE_VALUE:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"That preference value is too large.",
			"%d bytes, maximum %d" % [
				encoded.to_utf8_buffer().size(), MAX_PREFERENCE_VALUE
			]
		)

	preferences[key] = value
	return DotResult.success(true)


func clear_preference(key: String) -> bool:
	return preferences.erase(key)


# --- Validation ------------------------------------------------------------

## Checks everything a profile arriving from a store or a client could get wrong.
##
## [b]Called on read as well as on write.[/b] A file on disk is not trusted input in
## the usual sense, but it is input: it may have been written by an older version,
## edited by an operator, or restored from a backup of a different server.
func validate() -> DotResult:
	if not DotUserScope.is_well_formed(user_key):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A profile key must be a scoped id.",
			"got '%s' (%d characters)" % [user_key, user_key.length()]
		)

	if display_name != "":
		var name_check := DotUserName.validate(display_name)
		if not name_check.ok:
			return name_check.wrap("The profile's display name is not usable.")

	if avatar_id.length() > MAX_AVATAR_ID:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"The avatar reference is too long.",
			"%d characters, maximum %d" % [avatar_id.length(), MAX_AVATAR_ID]
		)

	if locale.length() > MAX_LOCALE:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"The locale tag is too long.",
			"%d characters, maximum %d" % [locale.length(), MAX_LOCALE]
		)

	if preferences.size() > MAX_PREFERENCES:
		return DotResult.fail(
			DotError.CODE_QUOTA,
			"This profile has too many preferences.",
			"%d, maximum %d" % [preferences.size(), MAX_PREFERENCES]
		)

	for key in preferences:
		var name := str(key)

		if name.length() > MAX_PREFERENCE_KEY:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"A preference name is too long.",
				name.substr(0, 40)
			)

		var encoded := JSON.stringify(preferences[key])

		if encoded.to_utf8_buffer().size() > MAX_PREFERENCE_VALUE:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"A preference value is too large.",
				"'%s' is %d bytes" % [name, encoded.to_utf8_buffer().size()]
			)

	if visit_count < 0:
		return DotResult.fail(
			DotError.CODE_INVALID, "visit_count cannot be negative."
		)

	return DotResult.success(true)


# --- Serialisation ---------------------------------------------------------

func to_dict() -> Dictionary:
	return {
		"version": version,
		"user_key": user_key,
		"scope": scope,
		"display_name": display_name,
		"avatar_id": avatar_id,
		"locale": locale,
		"created_at": created_at,
		"updated_at": updated_at,
		"visit_count": visit_count,
		"onboarded": onboarded,
		"preferences": preferences.duplicate(true),
	}


## Rebuilds a profile from stored or received data.
##
## Every field is read defensively and the result is validated, because this is the
## boundary where a hand-edited file, an older version and a hostile HTTP response all
## arrive. A missing field takes its default rather than failing: a profile written
## before a field existed is not corrupt.
static func from_dict(data: Dictionary) -> DotResult:
	if not data.has("user_key"):
		return DotResult.fail(
			DotError.CODE_PARSE, "A profile needs a user_key."
		)

	var p := DotUserProfile.new()

	p.version = int(data.get("version", 0))
	p.user_key = str(data.get("user_key", ""))
	p.scope = str(data.get("scope", ""))
	p.display_name = str(data.get("display_name", ""))
	p.avatar_id = str(data.get("avatar_id", ""))
	p.locale = str(data.get("locale", ""))
	p.created_at = int(data.get("created_at", 0))
	p.updated_at = int(data.get("updated_at", 0))
	p.visit_count = int(data.get("visit_count", 0))
	p.onboarded = bool(data.get("onboarded", false))

	var prefs: Variant = data.get("preferences", {})
	p.preferences = (prefs as Dictionary).duplicate(true) if prefs is Dictionary else {}

	var migrated := p.migrate()
	if not migrated.ok:
		return migrated

	var valid := p.validate()
	if not valid.ok:
		return valid.wrap("Stored profile is not usable.")

	return DotResult.success(p)


## Brings an older profile up to the current schema.
##
## [b]Separate from [method validate] on purpose.[/b] Validation says whether a
## profile is usable now; migration is what makes an old one usable. Collapsing them
## produces a validator that quietly rewrites its input, which is the kind of thing
## that turns a read into a lossy operation.
##
## Empty today because there is only one version. It exists so the first migration is
## a change to this function rather than a change to the design.
func migrate() -> DotResult:
	if version > SCHEMA_VERSION:
		# Written by a newer build. Refusing is right: the alternative is silently
		# dropping fields we do not know about and writing the profile back without
		# them, which loses data the newer build was relying on.
		return DotResult.fail(
			DotError.CODE_VERSION,
			"This profile was written by a newer version.",
			"profile v%d, this build understands v%d" % [version, SCHEMA_VERSION]
		)

	version = SCHEMA_VERSION
	return DotResult.success(true)


func duplicate_profile() -> DotUserProfile:
	var copy := DotUserProfile.new()
	var rebuilt := from_dict(to_dict())
	return rebuilt.value if rebuilt.ok else copy


## The subset another player is allowed to see.
##
## [b]The default is that nothing is public.[/b] Preferences are private by
## construction: a player's chosen sensitivity, their locale and their accessibility
## settings are nobody else's business, and a profile that relayed them wholesale
## would leak them to every other player in the match.
func to_public_dict() -> Dictionary:
	return {
		"user_key": user_key,
		"display_name": display_name,
		"avatar_id": avatar_id,
	}


func describe() -> Dictionary:
	return {
		"user_key": user_key,
		"scope": scope,
		"display_name": display_name,
		"avatar": avatar_id if avatar_id != "" else "<none>",
		"visits": visit_count,
		"onboarded": onboarded,
		"preferences": preferences.size(),
	}


func _to_string() -> String:
	return "DotUserProfile(%s '%s')" % [user_key, display_name]
