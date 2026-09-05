@tool
class_name DotUserConfig
extends DotConfig

## Everything configurable about profiles. Layered like every [DotConfig]: exported
## defaults, then a JSON file, then [code]DOT_USER_*[/code] environment variables,
## then [code]--user-*[/code] arguments.

@export_group("Identity")

## The scope profiles on this server are keyed under.
##
## Two servers sharing a scope share profiles; two servers with different scopes
## cannot correlate their players at all. See [DotUserScope].
##
## Empty means "derive one from the server's own id", which is the safe default: a
## server that forgot to configure this gets isolation rather than accidentally
## joining a shared pool.
@export var scope: String = ""

## Path to the file holding this server's scope key.
##
## [b]Not the key itself.[/b] The key is a secret, and a secret in a config resource
## ends up in version control. A path can be pointed at a file with restricted
## permissions. Generated on first run when the file is missing.
@export var scope_key_file: String = "user://user_scope.key"

## Accept profiles for players who were never authenticated.
##
## Guests get a per-device id, so a guest profile survives a reconnect and nothing
## more. Off means guests are anonymous for the session, which is the right default
## for a server that does not want to accumulate records it cannot attribute.
@export var allow_guest_profiles: bool = false

@export_group("Storage")

## Where profiles live: [code]local[/code], [code]memory[/code] or
## [code]backbone[/code].
@export_enum("local", "memory", "backbone") var backend: String = "local"

## Directory for the [code]local[/code] backend.
@export var directory: String = "user://profiles"

## Base URL for the [code]backbone[/code] backend.
@export var backbone_url: String = ""

## Server token for the [code]backbone[/code] backend. A secret.
@export var backbone_token: String = ""

## Treat the store as read-only. Profiles are read and never written.
@export var read_only: bool = false

@export_group("Behaviour")

## Create a profile for a player who does not have one.
##
## Off makes the store authoritative about who exists, which is what a server joined
## to a managed pool wants: a player with no profile is refused rather than silently
## given a blank one that then overwrites the real one when it syncs.
@export var create_missing: bool = true

## Write a profile back when a player disconnects.
@export var save_on_leave: bool = true

## Seconds a resolved profile stays cached after the player leaves.
##
## A player who reconnects inside this window skips the store entirely, which matters
## on a map change: without it, a thirty-player server does thirty store reads in the
## few seconds when it is also loading a level.
@export_range(0.0, 3600.0, 5.0) var cache_ttl_sec: float = 300.0

## Most profiles held in memory at once. 0 is unlimited.
@export_range(0, 100000, 64) var max_cached: int = 4096

## Profile writes allowed per player per minute.
##
## A client can ask for a name change as fast as it can send packets, and each one is
## a store write. Without a limit that is a way to make the server hammer a backbone
## on the player's behalf.
@export_range(1, 600, 1) var writes_per_minute: int = 6

## Seconds to wait for the store before giving up on a join.
##
## A player must not be held at the profile stage indefinitely because a backbone is
## slow. Past this they proceed with a session-only profile and a warning.
@export_range(0.5, 60.0, 0.5) var resolve_timeout_sec: float = 5.0

@export_group("Names")

## Let a player choose their own display name.
##
## [b]Off for authenticated players is the safe default[/b] and matches dot-auth and
## dot-server: an account's name comes from the account, and a player who can override
## it can appear as somebody else. Guests have no name of their own, so they must be
## able to pick one.
@export var allow_name_changes: bool = false

## Refuse a name whose comparison key matches another cached profile's.
##
## Only sees what this server has cached, so it is not a global uniqueness guarantee
## and is not meant to be — a backbone that wants unique names enforces it where it
## can actually see all of them.
@export var refuse_duplicate_names: bool = true


func env_prefix() -> String:
	return "DOT_USER_"


func cli_prefix() -> String:
	return "--user-"


## Secrets, refused from the environment and argv.
##
## Both are readable by other processes on most systems and both end up in `ps` output
## and in pasted bug reports. A token that can read every connected player's profile
## belongs in a file with restricted permissions.
func sensitive_keys() -> PackedStringArray:
	return PackedStringArray(["backbone_token", "scope_key_file"])


func validate() -> DotResult:
	if backend == "backbone":
		if backbone_url.strip_edges() == "":
			return DotResult.fail(
				DotError.CODE_INVALID,
				"The backbone backend needs backbone_url."
			)
		if backbone_token.strip_edges() == "" and not read_only:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"The backbone backend needs backbone_token to write."
			)

	if backend == "local" and directory.strip_edges() == "":
		return DotResult.fail(
			DotError.CODE_INVALID, "The local backend needs a directory."
		)

	if read_only and save_on_leave:
		# Not fatal, but it describes a server that will log a failed write every
		# time anybody disconnects. Saying so at boot beats a log full of them.
		DotLog.warn(
			"user.config",
			"read_only is set but save_on_leave is on; every save will be refused"
		)

	return DotResult.success(null)


func describe_summary() -> String:
	return "%s scope='%s' %s%s" % [
		backend,
		scope if scope != "" else "<derived>",
		"read-only " if read_only else "",
		"guests" if allow_guest_profiles else "accounts-only",
	]
