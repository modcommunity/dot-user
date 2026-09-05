class_name DotUserStoreBackbone
extends DotUserStore

## Profiles over the open HTTP protocol, so they follow a player between servers.
##
## [b]The protocol is the product here.[/b] TMC runs an instance and anyone can run
## their own, which is only true if the reference implementation is the thing TMC
## runs and if a self-hoster gets the same functionality rather than a degraded
## version. So this speaks four boring endpoints and has no opinion about storage:
##
## [codeblock]
## GET    /user/profile              the caller's own profile
## PUT    /user/profile              publish it
## GET    /user/{key}/public         the public half of somebody else's
## DELETE /user/profile              erase it
## [/codeblock]
##
## [b]What this must never do is hold a credential that works anywhere else.[/b] A
## game server running this holds a server token scoped to reading and writing
## profiles for players currently connected to it, and nothing more. The moment a
## server can present a player's own account token, every operator has a live
## credential for every player's whole account, which is the exact failure dot-auth's
## ticket flow exists to prevent. See dot-auth's CLAUDE.md.

const BACKBONE_CHANNEL := "user.store.backbone"

## Where the backbone lives. Required.
var base_url: String = ""

## Token identifying this server to the backbone.
##
## [b]Not a player credential.[/b] See the class documentation. Never logged, never
## sent to a client, and refused from the environment and argv by
## [method DotUserConfig.sensitive_keys] for the usual reason: both are readable by
## other processes and end up in pasted bug reports.
var server_token: String = ""

## HTTP client. One is built if none is supplied.
var http: DotHttp = null

## Whether writes are permitted. A read-only mirror is a legitimate deployment.
var read_only: bool = false

## Seconds a request may take before it is abandoned.
var timeout_sec: float = 8.0


static func at(url: String, token: String) -> DotUserStoreBackbone:
	var s := DotUserStoreBackbone.new()
	s.base_url = url
	s.server_token = token
	return s


func _store_name() -> String:
	return "DotUserStoreBackbone"


func _writable() -> bool:
	return not read_only


func _open() -> DotResult:
	if base_url.strip_edges() == "":
		return DotResult.fail(
			DotError.CODE_INVALID,
			"The backbone profile store needs a base URL."
		)

	if not (base_url.begins_with("https://") or base_url.begins_with("http://")):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"The backbone URL needs a scheme.",
			base_url
		)

	# Plain HTTP carries the server token in the clear, and that token can read and
	# write every connected player's profile. Refusing outright would break local
	# development against a loopback backbone, so it is a warning — but a loud one,
	# because the failure is silent and total.
	if base_url.begins_with("http://") and not _is_loopback(base_url):
		DotLog.warn(
			BACKBONE_CHANNEL,
			"the backbone URL is plain HTTP; the server token travels in the clear",
			{"url": base_url}
		)

	if server_token.strip_edges() == "":
		return DotResult.fail(
			DotError.CODE_AUTH,
			"The backbone profile store needs a server token."
		)

	if http == null:
		http = DotHttp.new()

	http.base_url = base_url
	http.timeout_sec = timeout_sec

	return DotResult.success(true)


static func _is_loopback(url: String) -> bool:
	return (
		url.begins_with("http://127.0.0.1")
		or url.begins_with("http://localhost")
		or url.begins_with("http://[::1]")
	)


func _headers() -> Dictionary:
	return {
		"Authorization": "Bearer %s" % server_token,
		"Accept": "application/json",
	}


func _fetch(user_key: String) -> DotResult:
	var res: DotResult = await http.get_json(
		"/user/%s/profile" % user_key.uri_encode(), _headers()
	)

	if not res.ok:
		# A profile that is not there is not a failure — a first-time player is the
		# common case. Anything else is, and the manager treats the two very
		# differently: absent means create one, failed means keep what is in force.
		if res.error != null and res.error.http_status == 404:
			return DotResult.success(null)

		return res.wrap("Could not read the profile from the backbone.")

	var body: Variant = res.value

	if not (body is Dictionary):
		return DotResult.fail(
			DotError.CODE_PARSE,
			"The backbone returned something that is not a profile."
		)

	var data := body as Dictionary

	# Servers should not have to care whether a backbone wraps its payloads.
	if data.has("profile") and data["profile"] is Dictionary:
		data = data["profile"] as Dictionary

	return DotUserProfile.from_dict(data)


func _store(profile: DotUserProfile) -> DotResult:
	var res: DotResult = await http.put_json(
		"/user/%s/profile" % profile.user_key.uri_encode(),
		profile.to_dict(),
		_headers()
	)

	if not res.ok:
		return res.wrap("Could not publish the profile to the backbone.")

	return DotResult.success(true)


func _remove(user_key: String) -> DotResult:
	var res: DotResult = await http.request(
		HTTPClient.METHOD_DELETE,
		"/user/%s/profile" % user_key.uri_encode(),
		PackedByteArray(),
		_headers()
	)

	if not res.ok:
		if res.error != null and res.error.http_status == 404:
			return DotResult.success(true)
		return res.wrap("Could not erase the profile.")

	return DotResult.success(true)


## The public half of another player's profile, for a scoreboard.
##
## Separate from [method fetch] because it returns less and is permitted for a key
## that is not the caller's. A server showing thirty players' names must not need
## thirty full profiles, and must not be able to read thirty players' preferences.
func fetch_public(user_key: String) -> DotResult:
	if not DotUserScope.is_well_formed(user_key):
		return DotResult.fail(
			DotError.CODE_INVALID, "That is not a usable profile key."
		)

	if not is_open():
		var opened := await open()
		if not opened.ok:
			return opened

	var res: DotResult = await http.get_json(
		"/user/%s/public" % user_key.uri_encode(), _headers()
	)

	if not res.ok:
		if res.error != null and res.error.http_status == 404:
			return DotResult.success(null)
		return res

	return DotResult.success(res.value)


func describe() -> Dictionary:
	var out := super.describe()
	out["base_url"] = base_url
	out["read_only"] = read_only
	# Deliberately reports presence, never the value.
	out["has_token"] = server_token != ""
	return out
