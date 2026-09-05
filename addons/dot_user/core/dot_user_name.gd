class_name DotUserName
extends RefCounted

## Validation and sanitising for display names. A static utility; never instantiated.
##
## [b]A display name is the most hostile string a platform accepts.[/b] It is shown to
## every other player, in chat, on a scoreboard, in a kill feed and in moderation
## tools, and it is chosen by the person it is shown on behalf of. Every one of the
## following has been used against a shipped game:
##
## - [b]Zero-width characters.[/b] Two players whose names render identically. One is
##   impersonating the other and a moderator cannot tell them apart by looking.
## - [b]Bidirectional overrides.[/b] U+202E reverses everything after it, so a name
##   rewrites the sentence it appears in: "Ada killed Bob" renders as something else.
## - [b]Combining marks.[/b] Stacked diacritics escape the line box and cover the
##   interface around them.
## - [b]Control characters.[/b] A newline in a name splits one log line into two, one
##   of which the player wrote.
## - [b]Leading and trailing spaces.[/b] " Ada" and "Ada " look identical, sort apart,
##   and defeat a name lookup.
##
## So names are sanitised on the way in and validated after, and the two are separate
## calls on purpose: sanitising is a repair a server performs for someone who typed
## something slightly wrong, and validating is a refusal. Doing only the first accepts
## a name that is empty once repaired; doing only the second refuses a name that a
## trailing space would have made fine.
##
## [b]This is not a moderation filter.[/b] It says nothing about whether a name is
## offensive, which is a policy question with a different answer in every community.
## [member DotUserManager.name_filter] is the hook for that.

const CHANNEL := "user.name"

const MIN_LENGTH := 2

## Longest a name may be, in characters.
##
## Characters, not bytes: a limit in bytes gives players whose names are not Latin a
## shorter name than everyone else, which is a bug people rightly complain about.
const MAX_LENGTH := 24

## Bytes a name may occupy once encoded. Bounds what is relayed and stored.
##
## [b]Implied by [constant MAX_LENGTH], and kept anyway.[/b] Godot strings are UTF-32,
## so the widest a valid name of 24 characters can encode to is 24 * 4 = 96 bytes —
## exactly this — and the byte check therefore never fires for well-formed input. It
## stays as a backstop for input that is not well-formed: an unpaired surrogate or a
## codepoint Godot round-trips differently can make [method String.length] and the
## encoded size disagree, and this is the boundary where a name becomes a wire field
## and a filename.
##
## Deliberately not tightened below the implied bound. A byte limit that actually
## bites gives players whose names are not Latin a shorter name than everyone else,
## which is the discrimination the character limit exists to avoid.
const MAX_BYTES := MAX_LENGTH * 4


func _init() -> void:
	push_error("DotUserName is a static utility; do not instantiate it.")


## Strips what is never legitimate and normalises whitespace.
##
## The order matters. Formatting characters go first, so removing them cannot leave
## whitespace the collapse step should have handled; the collapse runs next; trimming
## is last, because collapsing can produce a leading space.
static func sanitise(raw: String) -> String:
	var out := ""

	for i in range(raw.length()):
		var c := raw.unicode_at(i)

		if _is_forbidden(c):
			continue

		# A control character becomes a space rather than vanishing, so "a\nb" is
		# "a b" and not "ab". Silently joining two words is a way to construct a name
		# that does not match what was typed.
		if c < 0x20 or (c >= 0x7F and c <= 0x9F):
			out += " "
			continue

		out += String.chr(c)

	while out.contains("  "):
		out = out.replace("  ", " ")

	return out.strip_edges()


## Characters with no legitimate use in a name.
static func _is_forbidden(c: int) -> bool:
	# Bidirectional overrides, embeddings and isolates. U+202E is the one that
	# rewrites the text around it; the rest are here because allowing any of them
	# allows nesting tricks that reach the same result.
	if c >= 0x202A and c <= 0x202E:
		return true
	if c >= 0x2066 and c <= 0x2069:
		return true

	# Zero-width space, non-joiner, joiner, word joiner: invisible, so two names
	# differing only by these render identically.
	if c == 0x200B or c == 0x200C or c == 0x200D or c == 0x2060:
		return true

	# Zero-width no-break space, also used as a byte-order mark.
	if c == 0xFEFF:
		return true

	# Soft hyphen: invisible in most renderers and visible in some, which is worse.
	if c == 0x00AD:
		return true

	# Combining marks. Stacking these is how a name escapes its line box and covers
	# the interface around it. A name that legitimately needs one is written with a
	# precomposed character in every language that has one.
	if c >= 0x0300 and c <= 0x036F:
		return true
	if c >= 0x1AB0 and c <= 0x1AFF:
		return true
	if c >= 0x20D0 and c <= 0x20FF:
		return true
	if c >= 0xFE20 and c <= 0xFE2F:
		return true

	# Private-use area, which renders as whatever the player's font happens to define
	# and as a replacement glyph for everyone else.
	if c >= 0xE000 and c <= 0xF8FF:
		return true

	return false


## Whether a [b]sanitised[/b] name is acceptable. Call after [method sanitise].
static func validate(name: String) -> DotResult:
	if name.length() < MIN_LENGTH:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"That name is too short.",
			"%d characters, minimum %d" % [name.length(), MIN_LENGTH]
		)

	if name.length() > MAX_LENGTH:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"That name is too long.",
			"%d characters, maximum %d" % [name.length(), MAX_LENGTH]
		)

	var byte_length := name.to_utf8_buffer().size()

	if byte_length > MAX_BYTES:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"That name is too long.",
			"%d bytes, maximum %d" % [byte_length, MAX_BYTES]
		)

	# A name that is only punctuation passes every length check and is unusable as a
	# label. More to the point, it is how a player becomes visually absent from a
	# scoreboard.
	var has_letter := false

	for i in range(name.length()):
		if not _is_punctuation_or_space(name.unicode_at(i)):
			has_letter = true
			break

	if not has_letter:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"That name needs at least one letter or number."
		)

	return DotResult.success(name)


static func _is_punctuation_or_space(c: int) -> bool:
	if c == 32:
		return true
	if c >= 33 and c <= 47:
		return true
	if c >= 58 and c <= 64:
		return true
	if c >= 91 and c <= 96:
		return true
	if c >= 123 and c <= 126:
		return true
	return false


## Sanitise and validate in one call. The form most callers want.
static func clean(raw: String) -> DotResult:
	var cleaned := sanitise(raw)
	var checked := validate(cleaned)

	if not checked.ok:
		return checked

	return DotResult.success(cleaned)


## A name reduced to a comparison key, for "is this name already taken".
##
## Case-folded, spaces removed, and the obvious lookalike substitutions applied, so
## "Ada Lovelace", "ada lovelace" and "Ad4Love1ace" collide. Deliberately aggressive:
## the purpose is to stop someone registering a name visually confusable with
## another player's, and a comparison that only folds case does not achieve that.
##
## [b]Not a substitute for [method sanitise].[/b] This produces a key for comparison;
## the name that is stored and shown is the sanitised one.
static func comparison_key(name: String) -> String:
	var folded := sanitise(name).to_lower().replace(" ", "")

	# Not exhaustive; the exhaustive version is a Unicode confusables table and a
	# moving target. These are the substitutions a name-squatter reaches for first.
	var swaps := {
		"0": "o", "1": "l", "3": "e", "4": "a", "5": "s", "7": "t",
		"|": "l", "!": "i",
	}

	var out := ""
	for i in range(folded.length()):
		var ch := folded[i]
		out += swaps.get(ch, ch)

	return out


## A fallback name for a player whose own is unusable.
##
## Derived from their key rather than random, so the same player gets the same
## fallback every time. A guest whose name was refused should not be a different
## "Player 4821" on every reconnect.
static func fallback_for(user_key: String) -> String:
	return "Player %s" % DotHash.sha256_text(user_key).substr(0, 4).to_upper()
