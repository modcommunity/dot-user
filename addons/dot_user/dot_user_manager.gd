@tool
class_name DotUserManager
extends Node

## Resolves a player's profile when they join, caches it, and writes it back.
##
## [codeblock]
## var manager := DotUserManager.new()
## add_child(manager)
##
## var resolved := await manager.resolve(identity)
## if resolved.ok:
##     var profile: DotUserProfile = resolved.value
## [/codeblock]
##
## [b]No autoload, and dot-auth is not imported.[/b] The identity a caller passes is
## duck-typed: anything with [code]uid[/code], [code]display_name[/code] and
## [code]is_guest[/code] works, which is what [code]DotAuthIdentity[/code] and
## dot-server's [code]DotGuestIdentity[/code] both provide. A hard dependency in
## either direction makes both harder to adopt, and the family rule is that only
## dot-core is one.
##
## [b]The join path never touches the network twice.[/b] A resolved profile stays
## cached for [member DotUserConfig.cache_ttl_sec] after the player leaves, so a
## reconnect or a map change does not re-read the store for everyone at once. That is
## the same rule dot-server's ban store follows and for the same reason: loads may be
## slow, lookups on the join path may not.
##
## [b]A failed read never destroys a profile.[/b] If the store cannot answer, the
## player gets a session-only profile that is explicitly marked as not persistable,
## rather than a fresh one that would be written over the real one on disconnect.
## Silently starting empty is how a network blip becomes data loss.

const CHANNEL := "user"
const SERVICE := &"dot_user_manager"

## Emitted once a profile is resolved, on the peer that resolved it.
signal profile_resolved(profile: DotUserProfile)

## Emitted when a profile is written back.
signal profile_saved(profile: DotUserProfile)

## Emitted when a display name changes, with the old and new values.
signal name_changed(profile: DotUserProfile, from: String, to: String)

## Emitted when a resolve failed and the player got a session-only profile.
##
## Worth surfacing rather than logging: it means the store is unreachable, and an
## operator wants to know that before thirty players have lost their names.
signal resolve_degraded(user_key: String, reason: String)

@export_group("Configuration")

@export var config: DotUserConfig = null

## JSON file layered over the exported defaults. Empty disables the file layer.
@export var config_file: String = "user://dot_user.json"

## Apply the environment and command-line layers. Wanted on a dedicated server.
@export var load_layered_config: bool = true

@export_group("Wiring")

## Register in [DotRegistry] under [constant SERVICE].
##
## On by default, unlike most of the family: a profile manager is genuinely one per
## process, and the components that want it — dot-server's session flow, an avatar
## addon — have no other way to find it without importing this.
@export var register_service: bool = true

## Suffix for the registry name, so two managers can coexist in one process.
@export var service_scope: StringName = &""

## Identifier this server derives its scope from when the config does not name one.
##
## A server id, a community name, anything stable. Changing it renames every profile,
## which is why it is not defaulted to something that varies between runs.
@export var server_id: String = ""

## Where profiles live. Built from the config when this is left empty.
var store: DotUserStore = null

## The scope profiles are keyed under.
var scope: DotUserScope = null

## An extra check on a display name, beyond validity. Return a failed [DotResult] to
## refuse.
##
## The hook for a word filter, a reserved-name list, or a check against a directory.
## [DotUserName] deliberately has no opinion about what is offensive, because the
## answer differs in every community.
var name_filter: Callable = Callable()

## user_key -> {profile, expires_at_ms, active}
var _cache: Dictionary = {}

## Guards profile writes per player.
var _write_limiter: DotRateLimiter = null

var _registered_name: StringName = &""
var _ready_ok: bool = false

## Resolves that fell back to a session-only profile. Watched by an operator.
var degraded_count: int = 0


# --- Lifecycle -------------------------------------------------------------

func _ready() -> void:
	if Engine.is_editor_hint():
		return

	var res := await setup()

	if not res.ok:
		DotLog.result(CHANNEL, "user manager setup", res)


## Builds the config, the scope and the store. Safe to call again after reconfiguring.
func setup() -> DotResult:
	if config == null:
		config = DotUserConfig.new()

	if load_layered_config or config_file != "":
		var loaded := config.load_layered(config_file)
		if not loaded.ok:
			return loaded.wrap("Profile configuration is not usable.")
	else:
		var valid := config.validate()
		if not valid.ok:
			return valid.wrap("Profile configuration is not usable.")

	var scoped := _resolve_scope()
	if not scoped.ok:
		return scoped

	scope = scoped.value

	if store == null:
		var built := _build_store()
		if not built.ok:
			return built
		store = built.value

	var opened := await store.open()
	if not opened.ok:
		# Not fatal. A server whose profile store is down should still let people
		# play, with session-only profiles and a loud warning, rather than refuse
		# every connection.
		DotLog.warn(
			CHANNEL,
			"the profile store did not open; players will get session-only profiles",
			{"store": store._store_name(), "error": str(opened.error)}
		)

	_write_limiter = DotRateLimiter.new(
		float(config.writes_per_minute) / 60.0, float(config.writes_per_minute)
	)

	if register_service:
		_registered_name = (
			DotRegistry.scoped_name(SERVICE, service_scope)
			if service_scope != &"" else SERVICE
		)
		DotRegistry.register(_registered_name, self)

	_ready_ok = true

	DotLog.info(
		CHANNEL,
		"profile manager ready",
		{"config": config.describe_summary(), "scope": scope.scope}
	)

	return DotResult.success(null)


## Loads or creates this server's scope, generating a key on first run.
##
## [b]The key is generated once and then must survive.[/b] Regenerating it renames
## every profile on the server, so players lose their names, their avatars and their
## settings all at once. The file is therefore created only when absent, and a
## failure to read an existing one is fatal rather than quietly replaced.
func _resolve_scope() -> DotResult:
	var name := config.scope

	if name.strip_edges() == "":
		# Derived from the server's own id rather than a constant, so two servers
		# that both forgot to configure a scope do not silently share profiles.
		name = "server:%s" % (server_id if server_id != "" else OS.get_unique_id())

	var path := config.scope_key_file

	if path.strip_edges() == "":
		DotLog.warn(
			CHANNEL,
			"no scope key file configured; profiles will not survive a restart"
		)
		return DotResult.success(DotUserScope.generated(name))

	if FileAccess.file_exists(path):
		var read := DotPaths.read_text(path)

		if not read.ok:
			return read.wrap(
				"The scope key file exists but could not be read. Refusing to "
				+ "generate a new one, because that would rename every profile."
			)

		return DotUserScope.from_secret_key(name, String(read.value).strip_edges())

	var fresh := DotUserScope.generated(name)
	var written := DotPaths.write_text(path, fresh.export_secret_key())

	if not written.ok:
		return written.wrap("Could not persist the generated scope key.")

	DotLog.info(
		CHANNEL,
		"generated a scope key; back this file up, losing it renames every profile",
		{"file": path, "scope": name}
	)

	return DotResult.success(fresh)


func _build_store() -> DotResult:
	match config.backend:
		"memory":
			return DotResult.success(DotUserStoreMemory.new())

		"backbone":
			var remote := DotUserStoreBackbone.at(
				config.backbone_url, config.backbone_token
			)
			remote.read_only = config.read_only
			return DotResult.success(remote)

		"local":
			var local := DotUserStoreLocal.at(config.directory)
			return DotResult.success(local)

	return DotResult.fail(
		DotError.CODE_INVALID, "Unknown profile backend.", config.backend
	)


func _exit_tree() -> void:
	if _registered_name != &"":
		DotRegistry.unregister_instance(_registered_name, self)
		_registered_name = &""

	if store != null:
		store.close()


func is_ready() -> bool:
	return _ready_ok


# --- Resolving -------------------------------------------------------------

## The profile key for an identity, without touching the store.
##
## [b]Where the account id stops travelling.[/b] Everything above this call sees a
## scoped id; nothing below it needs the account id again.
func key_for(identity: Object) -> DotResult:
	if identity == null:
		return DotResult.fail(DotError.CODE_INVALID, "No identity.")

	var uid := str(identity.get("uid"))

	if uid.strip_edges() == "":
		return DotResult.fail(
			DotError.CODE_INVALID, "That identity has no uid."
		)

	if bool(identity.get("is_guest")) and not config.allow_guest_profiles:
		return DotResult.fail(
			DotError.CODE_FORBIDDEN,
			"Guest profiles are not enabled on this server.",
			uid
		)

	if scope == null:
		return DotResult.fail(DotError.CODE_STATE, "No scope is configured.")

	return scope.derive(uid)


## Resolves the profile for an identity, creating one if the config allows it.
##
## Returns a [DotUserProfile]. Never returns a failure for "this player is new" — that
## is the common case, not an error.
func resolve(identity: Object) -> DotResult:
	if not _ready_ok:
		return DotResult.fail(
			DotError.CODE_STATE, "The profile manager is not ready yet."
		)

	var keyed := key_for(identity)

	if not keyed.ok:
		return keyed

	var user_key: String = keyed.value
	var cached := _cached(user_key)

	if cached != null:
		_touch(cached, identity)
		profile_resolved.emit(cached)
		return DotResult.success(cached)

	var fetched: DotResult = await _fetch_within(user_key, config.resolve_timeout_sec)

	if not fetched.ok:
		# The store could not answer. A session-only profile keeps the player
		# playing; writing a fresh one would overwrite whatever is really there once
		# the store comes back.
		return _degrade(user_key, identity, str(fetched.error))

	var profile: DotUserProfile = fetched.value

	if profile == null:
		if not config.create_missing:
			return DotResult.fail(
				DotError.CODE_FORBIDDEN,
				"There is no profile for this player and this server does not "
				+ "create them.",
				user_key
			)

		profile = DotUserProfile.make(user_key, scope.scope)
		profile.display_name = _initial_name(identity, user_key)

	_touch(profile, identity)
	_remember(user_key, profile, true)

	profile_resolved.emit(profile)
	return DotResult.success(profile)


## A profile that exists only for this session and must never be stored.
##
## Marked by having no [member DotUserProfile.created_at], which [method save] refuses
## rather than persisting — the point is that the store's real copy is untouched.
func _degrade(user_key: String, identity: Object, reason: String) -> DotResult:
	degraded_count += 1

	var profile := DotUserProfile.make(user_key, scope.scope)
	profile.display_name = _initial_name(identity, user_key)
	profile.created_at = 0

	DotLog.warn(
		CHANNEL,
		"could not read a profile; the player has a session-only one",
		{"key": user_key, "reason": reason}
	)

	resolve_degraded.emit(user_key, reason)
	profile_resolved.emit(profile)

	return DotResult.success(profile)


## Whether a profile is the real one rather than a degraded stand-in.
static func is_persistable(profile: DotUserProfile) -> bool:
	return profile != null and profile.created_at > 0


func _initial_name(identity: Object, user_key: String) -> String:
	var supplied := str(identity.get("display_name"))
	var cleaned := DotUserName.clean(supplied)

	if cleaned.ok:
		return cleaned.value

	return DotUserName.fallback_for(user_key)


func _touch(profile: DotUserProfile, identity: Object) -> void:
	profile.visit_count += 1

	# An authenticated player's name comes from their account, so it is refreshed on
	# every join. A guest's is theirs to choose, so it is left alone.
	if not bool(identity.get("is_guest")) and not config.allow_name_changes:
		var supplied := str(identity.get("display_name"))
		var cleaned := DotUserName.clean(supplied)

		if cleaned.ok and cleaned.value != profile.display_name:
			var previous := profile.display_name
			profile.display_name = cleaned.value
			name_changed.emit(profile, previous, profile.display_name)


# --- Cache -----------------------------------------------------------------

func _cached(user_key: String) -> DotUserProfile:
	if not _cache.has(user_key):
		return null

	var entry: Dictionary = _cache[user_key]

	if not bool(entry["active"]) and Time.get_ticks_msec() > int(entry["expires_at"]):
		_cache.erase(user_key)
		return null

	return entry["profile"]


func _remember(user_key: String, profile: DotUserProfile, active: bool) -> void:
	_cache[user_key] = {
		"profile": profile,
		"active": active,
		"expires_at": Time.get_ticks_msec() + int(config.cache_ttl_sec * 1000.0),
	}

	_evict_if_needed()


## Drops the oldest inactive entries when the cache is over its limit.
##
## Active players are never evicted: their profile is in use, and re-reading it
## mid-session would lose whatever has changed since they joined.
func _evict_if_needed() -> void:
	if config.max_cached <= 0 or _cache.size() <= config.max_cached:
		return

	var candidates: Array = []

	for key in _cache:
		var entry: Dictionary = _cache[key]
		if not bool(entry["active"]):
			candidates.append([int(entry["expires_at"]), key])

	candidates.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])

	var excess := _cache.size() - config.max_cached
	var dropped := 0

	for candidate in candidates:
		if dropped >= excess:
			break
		_cache.erase(candidate[1])
		dropped += 1

	if dropped < excess:
		# Everything left is an active player. Not evicting them is correct, but a
		# cache permanently over its limit is a configuration problem an operator
		# should hear about rather than discover through memory use.
		DotLog.warn(
			CHANNEL,
			"the profile cache is over its limit and everything in it is in use",
			{"cached": _cache.size(), "max": config.max_cached}
		)


## Marks a player as gone, starting their cache expiry and saving if configured.
func release(user_key: String) -> DotResult:
	if not _cache.has(user_key):
		return DotResult.success(false)

	var entry: Dictionary = _cache[user_key]
	entry["active"] = false
	entry["expires_at"] = Time.get_ticks_msec() + int(config.cache_ttl_sec * 1000.0)

	if not config.save_on_leave:
		return DotResult.success(true)

	var saved: DotResult = await save(entry["profile"])

	if not saved.ok:
		DotLog.result(CHANNEL, "saving a profile on leave", saved)

	return DotResult.success(true)


func cached_count() -> int:
	return _cache.size()


func clear_cache() -> void:
	_cache.clear()


# --- Writing ---------------------------------------------------------------

## Writes a profile back to the store.
##
## Rate-limited per player, because every path that reaches this is ultimately driven
## by something a client asked for.
func save(profile: DotUserProfile) -> DotResult:
	if profile == null:
		return DotResult.fail(DotError.CODE_INVALID, "No profile to save.")

	if not is_persistable(profile):
		# A degraded, session-only profile. Storing it would overwrite the real one
		# the store could not read, which is the data loss this whole path exists to
		# avoid.
		return DotResult.fail(
			DotError.CODE_STATE,
			"This is a session-only profile and must not be stored.",
			profile.user_key
		)

	if config.read_only:
		return DotResult.fail(
			DotError.CODE_FORBIDDEN, "This server does not write profiles."
		)

	if _write_limiter != null and not _write_limiter.allow(profile.user_key):
		var wait := _write_limiter.retry_after(profile.user_key)
		var error := DotError.make(
			DotError.CODE_RATE_LIMITED,
			"That is too many profile changes in a row.",
			"retry in %.1fs" % wait
		)
		error.retry_after = wait
		return DotResult.failure(error)

	var stored: DotResult = await store.store(profile)

	if stored.ok:
		profile_saved.emit(profile)

	return stored


## Changes a display name, with every check a name change needs.
##
## [b]Refused for an authenticated player unless the config opens it.[/b] An account's
## name comes from the account; a player who can override it can appear as somebody
## else, which is the impersonation dot-auth and dot-server both refuse for the same
## reason.
func set_display_name(
	profile: DotUserProfile,
	requested: String,
	is_guest: bool = false
) -> DotResult:
	if profile == null:
		return DotResult.fail(DotError.CODE_INVALID, "No profile.")

	if not is_guest and not config.allow_name_changes:
		return DotResult.fail(
			DotError.CODE_FORBIDDEN,
			"Your name comes from your account.",
			profile.user_key
		)

	var cleaned := DotUserName.clean(requested)

	if not cleaned.ok:
		return cleaned

	var name: String = cleaned.value

	if config.refuse_duplicate_names and _name_taken(name, profile.user_key):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Somebody else here is using that name.",
			name
		)

	if name_filter.is_valid():
		var filtered: Variant = name_filter.call(name, profile)

		if filtered is DotResult and not (filtered as DotResult).ok:
			return filtered

	var previous := profile.display_name
	profile.display_name = name

	name_changed.emit(profile, previous, name)

	return DotResult.success(name)


## Whether another cached profile is using a confusably similar name.
##
## Only what this server has cached; see [member DotUserConfig.refuse_duplicate_names].
func _name_taken(name: String, except_key: String) -> bool:
	var key := DotUserName.comparison_key(name)

	for cached_key in _cache:
		if cached_key == except_key:
			continue

		var entry: Dictionary = _cache[cached_key]
		var other: DotUserProfile = entry["profile"]

		if DotUserName.comparison_key(other.display_name) == key:
			return true

	return false


# --- Diagnostics -----------------------------------------------------------

func describe() -> Dictionary:
	return {
		"ready": _ready_ok,
		"config": config.describe_summary() if config != null else "<none>",
		"scope": scope.describe() if scope != null else {},
		"store": store.describe() if store != null else {},
		"cached": _cache.size(),
		"degraded": degraded_count,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	out.append("profiles     %s" % (
		config.describe_summary() if config != null else "<unconfigured>"
	))
	out.append("scope        %s" % (scope.scope if scope != null else "<none>"))
	out.append("store        %s" % (
		store._store_name() if store != null else "<none>"
	))
	out.append("cached       %d profile(s)" % _cache.size())

	if degraded_count > 0:
		out.append("degraded     %d resolve(s) fell back to session-only" % degraded_count)

	return out


## [method DotUserStore.fetch], bounded by [member DotUserConfig.resolve_timeout_sec].
##
## A store that never answers — a backbone mid-deploy, a socket that hangs — must
## not hold a player at the profile stage for ever. Past the limit the fetch is
## abandoned and the caller degrades to a session-only profile; if the store does
## answer later, its answer is dropped, because the player has already been let in.
## The knob was documented from the start and enforced by nothing.
func _fetch_within(user_key: String, seconds: float) -> DotResult:
	var box: Array = []
	_fetch_into(box, user_key)
	var deadline := Time.get_ticks_msec() + int(maxf(seconds, 0.1) * 1000.0)
	while box.is_empty():
		if Time.get_ticks_msec() >= deadline or not is_inside_tree():
			return DotResult.fail(
				DotError.CODE_TIMEOUT, "The profile store did not answer in time.",
				"%.1f s" % seconds
			)
		await get_tree().process_frame
	return box[0]


func _fetch_into(box: Array, user_key: String) -> void:
	var fetched: DotResult = await store.fetch(user_key)
	box.append(fetched)
