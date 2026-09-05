extends Node

## Exercises everything in dot-user, offline.
##
## [codeblock]
## godot --headless --path . res://examples/user_demo.tscn
## [/codeblock]
##
## Exits non-zero on any failure, so it works as a smoke test as-is.
##
## The cases that matter most are the ones where a mistake is a vulnerability or data
## loss rather than a crash: the scoped-id derivation, the display-name sanitising,
## and the degraded path where a store that cannot answer must not cause a returning
## player's profile to be overwritten.

const SCOPE_KEY := "user://test_scope.key"
const PROFILE_DIR := "user://test_profiles"

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


## A stand-in for DotAuthIdentity, which is not installed here.
##
## dot-user duck-types the identity on purpose, so this is not a shim around a
## missing dependency — it is the whole contract: uid, display_name, is_guest.
class FakeIdentity extends RefCounted:
	var uid: String = ""
	var display_name: String = ""
	var is_guest: bool = false

	static func account(id: String, name: String) -> FakeIdentity:
		var i := FakeIdentity.new()
		i.uid = "backbone:%s" % id
		i.display_name = name
		return i

	static func guest(id: String, name: String) -> FakeIdentity:
		var i := FakeIdentity.new()
		i.uid = "guest:%s" % id
		i.display_name = name
		i.is_guest = true
		return i


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("dot-user self-test")
	print("")

	_cleanup()

	_test_scope()
	_test_names()
	_test_profile()
	await _test_store_contract(DotUserStoreMemory.new(), "memory")
	await _test_store_contract(DotUserStoreLocal.at(PROFILE_DIR), "local")
	await _test_local_store_specifics()
	await _test_manager_resolve()
	await _test_manager_degraded()
	await _test_manager_timeout()
	await _test_manager_names()
	await _test_manager_cache()
	await _test_read_only()

	_cleanup()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)


func _cleanup() -> void:
	DotPaths.remove_tree(PROFILE_DIR)
	if FileAccess.file_exists(SCOPE_KEY):
		DirAccess.open("user://").remove(SCOPE_KEY.get_file())


# --- Assertions ------------------------------------------------------------

func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else " — " + detail])
	return condition


# --- Scope -----------------------------------------------------------------

func _test_scope() -> void:
	print("scoped identity")

	var key := DotHash.random_bytes(32)
	var server_a := DotUserScope.with_key("server:a", key)
	var server_b := DotUserScope.with_key("server:b", key)

	var a1 := server_a.derive("account-1")
	var a2 := server_a.derive("account-1")
	var b1 := server_b.derive("account-1")

	_check(a1.ok and a2.ok and b1.ok, "derivation succeeds")
	_check(a1.value == a2.value, "the same account on the same server is stable")

	# The whole point. Two operators comparing logs must not be able to tell that
	# these are the same person.
	_check(
		a1.value != b1.value,
		"the same account on a different server is a different id"
	)

	var other := server_a.derive("account-2")
	_check(a1.value != other.value, "different accounts differ on one server")

	_check(
		DotUserScope.is_well_formed(a1.value),
		"a derived id is well formed",
		str(a1.value)
	)
	_check(
		String(a1.value).length() == DotUserScope.ID_LENGTH,
		"and the documented length"
	)

	# Without a separator, ("ab", "cd") and ("abc", "d") share a MAC input and two
	# different players share one profile.
	var s1 := DotUserScope.with_key("ab", key).derive("cd")
	var s2 := DotUserScope.with_key("abc", key).derive("d")
	_check(
		s1.value != s2.value,
		"the scope separator stops a boundary collision",
		"%s vs %s" % [s1.value, s2.value]
	)

	# A different key is a different namespace. That is what makes the derivation
	# non-reversible by anyone who does not hold the key.
	var stranger := DotUserScope.with_key("server:a", DotHash.random_bytes(32))
	_check(
		stranger.derive("account-1").value != a1.value,
		"a different key derives a different id, so it cannot be recomputed"
	)

	_check(
		server_a.matches("account-1", a1.value),
		"an id verifies against its account"
	)
	_check(
		not server_a.matches("account-2", a1.value),
		"and does not verify against another"
	)

	var keyless := DotUserScope.new()
	keyless.scope = "server:a"
	_check(
		not keyless.derive("account-1").ok,
		"a scope with no key refuses rather than deriving something useless"
	)
	_check(
		not DotUserScope.with_key("", key).derive("a").ok,
		"an empty scope name is refused"
	)
	_check(
		not server_a.derive("").ok, "an empty account id is refused"
	)

	# The key has to survive a restart, or every profile is renamed.
	var exported := server_a.export_secret_key()
	var restored := DotUserScope.from_secret_key("server:a", exported)

	_check(restored.ok, "a scope key round-trips through storage")
	_check(
		restored.ok and (restored.value as DotUserScope).derive("account-1").value == a1.value,
		"and derives the same ids afterwards"
	)

	_check(
		not DotUserScope.from_secret_key("server:a", "c2hvcnQ").ok,
		"a too-short key is refused rather than silently weakening every id"
	)

	# describe() is pasted into bug reports.
	var described := server_a.describe()
	_check(
		not str(described).contains(exported),
		"describe() never leaks the key"
	)

	for bad in ["", "short", "has spaces in it here!!", "a".repeat(40)]:
		_check(
			not DotUserScope.is_well_formed(bad),
			"'%s' is not mistaken for an id" % bad.substr(0, 20)
		)


# --- Names -----------------------------------------------------------------

func _test_names() -> void:
	print("display names")

	_check(DotUserName.sanitise("  Ada  ") == "Ada", "spaces are trimmed")
	_check(
		DotUserName.sanitise("Ada    Lovelace") == "Ada Lovelace",
		"runs of spaces collapse"
	)

	# A newline in a name splits one log line into two, one of which the player wrote.
	_check(
		not DotUserName.sanitise("Ada\nAdmin").contains("\n"),
		"newlines are removed"
	)
	_check(
		DotUserName.sanitise("Ada\nAdmin") == "Ada Admin",
		"and become a space rather than joining two words",
		DotUserName.sanitise("Ada\nAdmin")
	)

	# U+202E reverses the text after it, so a name rewrites the sentence it is in.
	var bidi := "Ada%sniamdA" % String.chr(0x202E)
	_check(
		not DotUserName.sanitise(bidi).contains(String.chr(0x202E)),
		"bidirectional overrides are stripped"
	)

	# Two names that render identically is impersonation a moderator cannot see.
	var zero_width := "Ad%sa" % String.chr(0x200B)
	_check(
		DotUserName.sanitise(zero_width) == "Ada",
		"zero-width characters are stripped"
	)

	var zalgo := "Ada" + String.chr(0x0301).repeat(30)
	_check(
		DotUserName.sanitise(zalgo) == "Ada",
		"stacked combining marks are stripped"
	)

	_check(DotUserName.clean("Ada").ok, "an ordinary name is accepted")
	_check(not DotUserName.clean("A").ok, "a one-character name is refused")
	_check(
		not DotUserName.clean("a".repeat(40)).ok, "an over-long name is refused"
	)
	_check(
		not DotUserName.clean("   ").ok,
		"a name that is empty once sanitised is refused"
	)
	_check(
		not DotUserName.clean("!!!...").ok,
		"a name with no letters is refused, so nobody is invisible on a scoreboard"
	)

	# The byte bound and the character bound have to agree, or one of them is
	# unreachable and nobody notices until a name of the wrong shape gets through.
	var widest := String.chr(0x1F600).repeat(DotUserName.MAX_LENGTH)
	_check(
		DotUserName.clean(widest).ok,
		"the widest name inside the character limit is accepted"
	)
	_check(
		widest.to_utf8_buffer().size() <= DotUserName.MAX_BYTES,
		"and is within the byte bound, which the character limit implies",
		"%d bytes, cap %d" % [widest.to_utf8_buffer().size(), DotUserName.MAX_BYTES]
	)
	_check(
		not DotUserName.clean(
			String.chr(0x1F600).repeat(DotUserName.MAX_LENGTH + 1)
		).ok,
		"and one character more is refused"
	)

	# Name squatting.
	_check(
		DotUserName.comparison_key("Ada Lovelace")
			== DotUserName.comparison_key("adalovelace"),
		"case and spaces do not make a distinct name"
	)
	_check(
		DotUserName.comparison_key("Ada") == DotUserName.comparison_key("Ad4"),
		"nor do lookalike digits"
	)
	_check(
		DotUserName.comparison_key("Ada") != DotUserName.comparison_key("Bob"),
		"but genuinely different names stay different"
	)

	var fallback := DotUserName.fallback_for("abcdefghijklmnopqrstuv")
	_check(
		fallback == DotUserName.fallback_for("abcdefghijklmnopqrstuv"),
		"a fallback name is stable for a player"
	)
	_check(
		DotUserName.validate(fallback).ok, "and is itself a valid name"
	)


# --- Profile ---------------------------------------------------------------

func _test_profile() -> void:
	print("profiles")

	var key := DotHash.random_bytes(32)
	var user_key: String = DotUserScope.with_key("s", key).derive("a").value

	var p := DotUserProfile.make(user_key, "s")
	p.display_name = "Ada"

	_check(p.validate().ok, "a fresh profile validates")

	var loose := DotUserProfile.make(user_key, "s")
	loose.user_key = "backbone:12345"
	_check(
		not loose.validate().ok,
		"a profile keyed on an account id is refused, not silently accepted"
	)

	_check(p.set_preference("sensitivity", 0.35).ok, "a preference is stored")
	_check(
		abs(float(p.preference("sensitivity", 0.0)) - 0.35) < 0.0001,
		"and reads back"
	)

	# Bounded, because the profile is relayed to everyone in the match.
	_check(
		not p.set_preference("big", "x".repeat(1000)).ok,
		"an oversized preference value is refused"
	)
	_check(
		not p.set_preference("k".repeat(100), 1).ok,
		"an over-long preference name is refused"
	)

	for i in range(DotUserProfile.MAX_PREFERENCES + 4):
		p.set_preference("pref_%d" % i, i)

	_check(
		p.preferences.size() <= DotUserProfile.MAX_PREFERENCES,
		"the preference count is capped",
		"%d" % p.preferences.size()
	)
	_check(p.validate().ok, "and the profile is still valid at the cap")

	var round_tripped := DotUserProfile.from_dict(p.to_dict())
	_check(round_tripped.ok, "a profile round-trips through a dictionary")
	_check(
		round_tripped.ok
			and (round_tripped.value as DotUserProfile).display_name == "Ada",
		"keeping its name"
	)
	_check(
		round_tripped.ok
			and (round_tripped.value as DotUserProfile).preferences.size()
				== p.preferences.size(),
		"and its preferences"
	)

	# Preferences are private. A profile that relayed them would leak every player's
	# settings to everyone else in the match.
	var public := p.to_public_dict()
	_check(not public.has("preferences"), "the public view omits preferences")
	_check(not public.has("locale"), "and the locale")
	_check(
		public.has("display_name") and public.has("avatar_id"),
		"but keeps what a scoreboard needs"
	)

	# A file that has been hand-edited, or written by another build.
	_check(
		not DotUserProfile.from_dict({}).ok,
		"a dictionary with no key is refused"
	)

	var newer := p.to_dict()
	newer["version"] = DotUserProfile.SCHEMA_VERSION + 5
	_check(
		not DotUserProfile.from_dict(newer).ok,
		"a profile from a newer build is refused rather than silently downgraded"
	)

	var older := p.to_dict()
	older["version"] = 0
	older.erase("onboarded")
	var migrated := DotUserProfile.from_dict(older)
	_check(migrated.ok, "a profile with a missing field is migrated, not rejected")
	_check(
		migrated.ok and (migrated.value as DotUserProfile).version
			== DotUserProfile.SCHEMA_VERSION,
		"and comes back at the current version"
	)


# --- The store contract ----------------------------------------------------

## Runs the same sequence against any store.
##
## Both implementations answer identically or one of them is wrong; running the
## sequence twice is how a bug in the file handling shows up as a difference rather
## than as a plausible-looking result.
func _test_store_contract(store: DotUserStore, label: String) -> void:
	print("store contract: %s" % label)

	var key := DotHash.random_bytes(32)
	var scope := DotUserScope.with_key("s", key)
	var user_key: String = scope.derive("account-1").value

	var opened: DotResult = await store.open()
	_check(opened.ok, "[%s] opens" % label)

	var missing: DotResult = await store.fetch(user_key)
	_check(missing.ok, "[%s] a missing profile is not a failure" % label)
	_check(
		missing.ok and missing.value == null,
		"[%s] and comes back as null" % label
	)

	var p := DotUserProfile.make(user_key, "s")
	p.display_name = "Ada"
	p.set_preference("theme", "dark")

	var stored: DotResult = await store.store(p)
	_check(stored.ok, "[%s] a profile stores" % label)

	var read: DotResult = await store.fetch(user_key)
	_check(read.ok and read.value != null, "[%s] and reads back" % label)

	if read.ok and read.value != null:
		var got: DotUserProfile = read.value
		_check(got.display_name == "Ada", "[%s] with its name" % label)
		_check(
			str(got.preference("theme", "")) == "dark",
			"[%s] and its preferences" % label
		)
		_check(got.updated_at > 0, "[%s] and a write timestamp" % label)

		# A caller mutating what it got back must not reach into the store.
		got.display_name = "Mallory"
		var again: DotResult = await store.fetch(user_key)
		_check(
			again.ok and (again.value as DotUserProfile).display_name == "Ada",
			"[%s] the store hands out copies, not references" % label
		)

	var invalid := DotUserProfile.make(user_key, "s")
	invalid.display_name = "x"
	var refused: DotResult = await store.store(invalid)
	_check(
		not refused.ok,
		"[%s] an invalid profile is refused rather than written" % label
	)

	var bad_key: DotResult = await store.fetch("../../etc/passwd")
	_check(
		not bad_key.ok,
		"[%s] a malformed key never reaches the store" % label
	)

	var removed: DotResult = await store.remove(user_key)
	_check(removed.ok, "[%s] a profile removes" % label)

	var gone: DotResult = await store.fetch(user_key)
	_check(gone.ok and gone.value == null, "[%s] and is then absent" % label)

	var again_removed: DotResult = await store.remove(user_key)
	_check(
		again_removed.ok,
		"[%s] removing an absent profile is success, not an error" % label
	)

	store.close()


func _test_local_store_specifics() -> void:
	print("local store")

	var store := DotUserStoreLocal.at(PROFILE_DIR)
	var scope := DotUserScope.with_key("s", DotHash.random_bytes(32))

	var opened: DotResult = await store.open()
	if not _check(opened.ok, "the directory is created"):
		return

	var keys := PackedStringArray()

	for i in range(3):
		var user_key: String = scope.derive("account-%d" % i).value
		keys.append(user_key)

		var p := DotUserProfile.make(user_key, "s")
		p.display_name = "Player %d" % (i + 1)
		var stored: DotResult = await store.store(p)
		_check(stored.ok, "profile %d writes" % i)

	var listed: DotResult = await store.list_keys()
	_check(listed.ok, "the directory lists")
	_check(
		listed.ok and (listed.value as PackedStringArray).size() == 3,
		"with every profile",
		"%d" % (listed.value as PackedStringArray).size() if listed.ok else "?"
	)

	# A truncated file is a failure, never an absence. Reporting it as "no profile"
	# would make the manager write a fresh one over whatever could be recovered.
	var damaged := "%s/%s.json" % [PROFILE_DIR, keys[0]]
	var f := FileAccess.open(damaged, FileAccess.WRITE)
	f.store_string("{ this is not json")
	f.close()

	var corrupt: DotResult = await store.fetch(keys[0])
	_check(
		not corrupt.ok,
		"a corrupt profile is a failure, not an absence"
	)

	# Anything else in the directory is somebody else's file.
	var stray := FileAccess.open("%s/notes.txt" % PROFILE_DIR, FileAccess.WRITE)
	stray.store_string("hello")
	stray.close()

	var relisted: DotResult = await store.list_keys()
	_check(
		relisted.ok and not Array(relisted.value).has("notes"),
		"a stray file is not listed as a profile key"
	)

	store.close()


# --- The manager -----------------------------------------------------------

func _make_manager(backend: String = "memory") -> DotUserManager:
	var manager := DotUserManager.new()
	manager.register_service = false
	manager.load_layered_config = false
	manager.config_file = ""
	manager.server_id = "selftest"

	var config := DotUserConfig.new()
	config.backend = backend
	config.directory = PROFILE_DIR
	config.scope = "server:selftest"
	config.scope_key_file = SCOPE_KEY
	config.allow_guest_profiles = true
	manager.config = config

	add_child(manager)
	return manager


func _test_manager_resolve() -> void:
	print("manager: resolving")

	var manager := _make_manager()
	var ready: DotResult = await manager.setup()

	if not _check(ready.ok, "the manager sets up", str(ready.error)):
		manager.queue_free()
		return

	_check(
		FileAccess.file_exists(SCOPE_KEY),
		"a scope key is generated and persisted on first run"
	)

	var ada := FakeIdentity.account("acc-1", "Ada")
	var first: DotResult = await manager.resolve(ada)

	if not _check(first.ok, "a first-time player resolves", str(first.error)):
		manager.queue_free()
		return

	var profile: DotUserProfile = first.value

	_check(profile.display_name == "Ada", "taking their account name")
	_check(profile.visit_count == 1, "with one visit recorded")
	_check(
		DotUserScope.is_well_formed(profile.user_key),
		"and a scoped key, not an account id"
	)
	_check(
		not profile.user_key.contains("acc-1"),
		"the account id does not appear in the key"
	)
	_check(
		DotUserManager.is_persistable(profile),
		"and the profile is a real one"
	)

	var saved: DotResult = await manager.save(profile)
	_check(saved.ok, "it saves")

	# A different scope must not see it. This is the property the whole design is for.
	var other := _make_manager()
	other.config.scope = "server:elsewhere"
	other.config.scope_key_file = SCOPE_KEY
	var other_ready: DotResult = await other.setup()

	if other_ready.ok:
		other.store = manager.store
		var elsewhere: DotResult = await other.resolve(ada)
		_check(
			elsewhere.ok and (elsewhere.value as DotUserProfile).user_key
				!= profile.user_key,
			"the same player on another scope is a different profile"
		)

	other.queue_free()

	var guest := FakeIdentity.guest("device-1", "Visitor")
	var guest_resolved: DotResult = await manager.resolve(guest)
	_check(guest_resolved.ok, "a guest resolves when guests are allowed")

	manager.config.allow_guest_profiles = false
	var refused: DotResult = await manager.resolve(FakeIdentity.guest("d2", "V"))
	_check(
		not refused.ok, "and is refused when they are not"
	)
	manager.config.allow_guest_profiles = true

	# A returning player gets what was stored, not a fresh profile.
	manager.clear_cache()
	var second: DotResult = await manager.resolve(ada)
	_check(second.ok, "a returning player resolves")
	_check(
		second.ok and (second.value as DotUserProfile).visit_count == 2,
		"and their visit count carries over",
		"%d" % (second.value as DotUserProfile).visit_count if second.ok else "?"
	)

	manager.queue_free()


func _test_manager_degraded() -> void:
	print("manager: a store that cannot answer")

	var manager := _make_manager()
	var ready: DotResult = await manager.setup()

	if not _check(ready.ok, "sets up"):
		manager.queue_free()
		return

	var memory := manager.store as DotUserStoreMemory
	var ada := FakeIdentity.account("acc-degraded", "Ada")

	var first: DotResult = await manager.resolve(ada)
	var real: DotUserProfile = first.value
	real.set_preference("theme", "dark")
	var saved: DotResult = await manager.save(real)
	_check(saved.ok, "a real profile is stored first")

	manager.clear_cache()
	memory.fail_next_fetch = true

	var degraded: DotResult = await manager.resolve(ada)

	_check(degraded.ok, "a failed read still lets the player in")
	_check(
		manager.degraded_count == 1,
		"and is counted so an operator can see it"
	)

	var stand_in: DotUserProfile = degraded.value

	_check(
		not DotUserManager.is_persistable(stand_in),
		"the stand-in is marked as session-only"
	)

	# The whole point: storing the stand-in would overwrite the real profile the
	# store could not read, turning a network blip into data loss.
	var refused: DotResult = await manager.save(stand_in)
	_check(
		not refused.ok,
		"and saving it is refused rather than overwriting the real one"
	)

	manager.clear_cache()
	var recovered: DotResult = await manager.resolve(ada)
	_check(
		recovered.ok
			and str((recovered.value as DotUserProfile).preference("theme", "")) == "dark",
		"so when the store recovers, the real profile is intact"
	)

	manager.queue_free()


func _test_manager_names() -> void:
	print("manager: names")

	var manager := _make_manager()
	var ready: DotResult = await manager.setup()

	if not _check(ready.ok, "sets up"):
		manager.queue_free()
		return

	var ada := FakeIdentity.account("acc-name", "Ada")
	var resolved: DotResult = await manager.resolve(ada)
	var profile: DotUserProfile = resolved.value

	# An account's name comes from the account. A player who can override it can
	# appear as somebody else.
	var refused := manager.set_display_name(profile, "Administrator")
	_check(
		not refused.ok,
		"an authenticated player cannot rename themselves by default"
	)
	_check(
		profile.display_name == "Ada", "and their name is unchanged"
	)

	var guest := FakeIdentity.guest("dev-name", "Visitor")
	var guest_resolved: DotResult = await manager.resolve(guest)
	var guest_profile: DotUserProfile = guest_resolved.value

	var allowed := manager.set_display_name(guest_profile, "  Grace  ", true)
	_check(allowed.ok, "a guest can name themselves")
	_check(
		guest_profile.display_name == "Grace",
		"and the name is sanitised on the way in",
		guest_profile.display_name
	)

	var hostile := manager.set_display_name(
		guest_profile, "Ada%sniamdA" % String.chr(0x202E), true
	)
	_check(
		hostile.ok and not guest_profile.display_name.contains(String.chr(0x202E)),
		"a name with a bidirectional override is cleaned, not stored"
	)

	# Impersonation by confusable name.
	var squatter := FakeIdentity.guest("dev-squat", "Someone")
	var squat_resolved: DotResult = await manager.resolve(squatter)
	var squat_profile: DotUserProfile = squat_resolved.value

	var taken := manager.set_display_name(squat_profile, "Ada", true)
	_check(
		not taken.ok,
		"a name another player here is using is refused"
	)

	var lookalike := manager.set_display_name(squat_profile, "Ad4", true)
	_check(
		not lookalike.ok,
		"including a lookalike of it"
	)

	# The policy hook, which is where a word filter belongs.
	manager.name_filter = func(name: String, _p: DotUserProfile) -> DotResult:
		if name.to_lower().contains("banned"):
			return DotResult.fail(DotError.CODE_FORBIDDEN, "Not that one.")
		return DotResult.success(true)

	_check(
		not manager.set_display_name(squat_profile, "bannedword", true).ok,
		"the name filter can refuse a name"
	)
	_check(
		manager.set_display_name(squat_profile, "Katherine", true).ok,
		"and lets everything else through"
	)

	# A client can ask as fast as it can send packets, and each one is a store write.
	manager.config.allow_name_changes = true
	var limited := false

	for i in range(30):
		var res: DotResult = await manager.save(profile)
		if not res.ok and res.code() == DotError.CODE_RATE_LIMITED:
			limited = true
			break

	_check(limited, "profile writes are rate limited per player")

	manager.queue_free()


func _test_manager_cache() -> void:
	print("manager: caching")

	var manager := _make_manager()
	var ready: DotResult = await manager.setup()

	if not _check(ready.ok, "sets up"):
		manager.queue_free()
		return

	var ada := FakeIdentity.account("acc-cache", "Ada")
	var first: DotResult = await manager.resolve(ada)

	var before := manager.store.fetch_count
	var second: DotResult = await manager.resolve(ada)

	_check(
		manager.store.fetch_count == before,
		"a cached profile does not touch the store",
		"%d fetches" % (manager.store.fetch_count - before)
	)
	_check(
		first.value == second.value,
		"and is the same object, so a change in flight is not lost"
	)

	var released: DotResult = await manager.release(
		(first.value as DotUserProfile).user_key
	)
	_check(released.ok, "releasing a player succeeds")

	# Still cached, so a reconnect or a map change does not re-read for everybody.
	var reconnect: DotResult = await manager.resolve(ada)
	_check(
		manager.store.fetch_count == before,
		"a reconnect inside the cache window still does not touch the store"
	)

	# An active player is never evicted; their profile is in use.
	manager.config.max_cached = 1

	for i in range(5):
		var other: DotResult = await manager.resolve(
			FakeIdentity.account("filler-%d" % i, "Filler")
		)

	_check(
		manager.cached_count() >= 1,
		"eviction keeps the cache populated",
		"%d" % manager.cached_count()
	)

	var described := manager.describe_lines()
	_check(described.size() >= 4, "describe_lines produces something usable")

	manager.queue_free()


func _test_read_only() -> void:
	print("manager: read-only")

	var manager := _make_manager()
	manager.config.read_only = true
	manager.config.save_on_leave = false

	var ready: DotResult = await manager.setup()

	if not _check(ready.ok, "sets up"):
		manager.queue_free()
		return

	var resolved: DotResult = await manager.resolve(
		FakeIdentity.account("acc-ro", "Ada")
	)

	_check(resolved.ok, "a player still resolves on a read-only server")

	var refused: DotResult = await manager.save(resolved.value)
	_check(
		not refused.ok,
		"but saving is refused, rather than appearing to work and vanishing"
	)

	manager.queue_free()


class HangingStore extends DotUserStoreMemory:
	func fetch(_user_key: String) -> DotResult:
		for _i in range(1000000):
			await Engine.get_main_loop().process_frame
		return DotResult.fail(DotError.CODE_STATE, "never")


func _test_manager_timeout() -> void:
	print("manager: a store that never answers")

	var manager := _make_manager()
	var ready: DotResult = await manager.setup()
	if not _check(ready.ok, "sets up"):
		manager.queue_free()
		return

	manager.config.resolve_timeout_sec = 0.5
	manager.store = HangingStore.new()
	manager.clear_cache()

	var started := Time.get_ticks_msec()
	var res: DotResult = await manager.resolve(FakeIdentity.account("acc-slow", "Slow"))
	var took := Time.get_ticks_msec() - started
	_check(res.ok, "the player is let in on a session-only profile", str(res.error) if not res.ok else "")
	_check(took < 3000, "within resolve_timeout_sec rather than for ever", "%d ms" % took)
	_check(took >= 400, "and not before it", "%d ms" % took)

	manager.queue_free()
