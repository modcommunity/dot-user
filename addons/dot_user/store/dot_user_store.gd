class_name DotUserStore
extends RefCounted

## Where profiles live. Subclass to put them somewhere else.
##
## Deliberately shaped like [code]DotBanStore[/code] in dot-server, including its two
## hard-won rules, because the two solve the same problem: a per-player record that a
## community running eight servers wants to share.
##
## [b]Loads may be slow; lookups on the join path may not.[/b] A remote store is
## queried at startup and on writes, never while a player is waiting to spawn. A store
## that reaches the network on [method fetch] turns every join into a round trip, and
## a store that is slow on join is a store that gets removed.
##
## [b]A failed load keeps whatever is already in force.[/b] Silently starting empty
## means every returning player looks new, loses their name and their avatar, and gets
## a fresh profile written over the top of the one that could not be read. That is
## data loss caused by a network blip.
##
## Everything here is a coroutine, because a real store is remote. Note the family
## gotcha: [code]await store.fetch(k).ok[/code] binds the await to the property
## access, not to the call, so the coroutine is never awaited. Assign first.

const CHANNEL := "user.store"


# --- Subclass interface ----------------------------------------------------

## Reads one profile. Returns a null value when there is no such profile.
##
## [b]Absent is not an error.[/b] A first-time player is the common case, and a store
## that failed for them would make every new player a support ticket. A failure here
## means the store could not answer, which is different and which the manager treats
## differently.
func _fetch(_user_key: String) -> DotResult:
	return DotResult.fail(
		DotError.CODE_INTERNAL, "%s does not implement _fetch()." % _store_name()
	)


## Writes one profile.
func _store(_profile: DotUserProfile) -> DotResult:
	return DotResult.fail(
		DotError.CODE_INTERNAL, "%s does not implement _store()." % _store_name()
	)


## Removes one profile. Absent is success: the caller wanted it gone.
func _remove(_user_key: String) -> DotResult:
	return DotResult.fail(
		DotError.CODE_INTERNAL, "%s does not implement _remove()." % _store_name()
	)


## Prepares the store. Called once, before any lookup.
func _open() -> DotResult:
	return DotResult.success(true)


func _close() -> void:
	pass


## Whether this store accepts writes.
##
## [b]False is a legitimate configuration[/b], not a broken one: a server enforcing a
## centrally-managed set of profiles should say so, rather than appearing to save and
## losing the change on the next refresh.
func _writable() -> bool:
	return true


func _store_name() -> String:
	return "DotUserStore"


# --- Public API ------------------------------------------------------------

var _opened: bool = false

## Profiles read since opening. Diagnostic.
var fetch_count: int = 0
var store_count: int = 0
var failure_count: int = 0


func open() -> DotResult:
	if _opened:
		return DotResult.success(true)

	var res := await _open()

	if res.ok:
		_opened = true
	else:
		failure_count += 1

	return res


func close() -> void:
	if not _opened:
		return

	_close()
	_opened = false


func is_open() -> bool:
	return _opened


func is_writable() -> bool:
	return _writable()


## Reads a profile, or null when there is none.
##
## The key is checked before the store is touched: a malformed key must never reach a
## filesystem path or a URL, and refusing it here means every implementation gets that
## guard for free rather than each one remembering it.
func fetch(user_key: String) -> DotResult:
	if not DotUserScope.is_well_formed(user_key):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"That is not a usable profile key.",
			"'%s'" % user_key.substr(0, 64)
		)

	if not _opened:
		var opened := await open()
		if not opened.ok:
			return opened.wrap("The profile store is not available.")

	fetch_count += 1

	var res: DotResult = await _fetch(user_key)

	if not res.ok:
		failure_count += 1

	return res


## Writes a profile, validating it first.
##
## Validation happens here rather than in each implementation so a store cannot be the
## thing that lets an oversized or malformed profile through. The profile is relayed
## to other players, so this is a boundary worth defending once.
func store(profile: DotUserProfile) -> DotResult:
	if profile == null:
		return DotResult.fail(DotError.CODE_INVALID, "No profile to store.")

	if not _writable():
		return DotResult.fail(
			DotError.CODE_FORBIDDEN,
			"This profile store is read-only.",
			_store_name()
		)

	var valid := profile.validate()
	if not valid.ok:
		return valid.wrap("Refusing to store an invalid profile.")

	if not _opened:
		var opened := await open()
		if not opened.ok:
			return opened.wrap("The profile store is not available.")

	profile.updated_at = int(Time.get_unix_time_from_system())

	var res: DotResult = await _store(profile)

	if res.ok:
		store_count += 1
	else:
		failure_count += 1

	return res


func remove(user_key: String) -> DotResult:
	if not DotUserScope.is_well_formed(user_key):
		return DotResult.fail(
			DotError.CODE_INVALID, "That is not a usable profile key."
		)

	if not _writable():
		return DotResult.fail(
			DotError.CODE_FORBIDDEN, "This profile store is read-only."
		)

	if not _opened:
		var opened := await open()
		if not opened.ok:
			return opened

	return await _remove(user_key)


func describe() -> Dictionary:
	return {
		"store": _store_name(),
		"open": _opened,
		"writable": _writable(),
		"fetches": fetch_count,
		"stores": store_count,
		"failures": failure_count,
	}


func _to_string() -> String:
	return "%s(%s)" % [_store_name(), "open" if _opened else "closed"]
