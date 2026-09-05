@tool
extends EditorPlugin

## Editor entry point for dot-user. Registers inspector types only.
##
## No autoload, for the family's reason: a process may run a server and a client at
## once, or two servers in one editor session, and a singleton profile manager makes
## both impossible. [DotUserManager] registers itself in [DotRegistry] instead, which
## anything can look up without importing this addon.

const _ICON := "res://addons/dot_user/icon_placeholder.svg"

const _TYPES := [
	["DotUserManager", "Node", "res://addons/dot_user/dot_user_manager.gd"],
]


func _enter_tree() -> void:
	var icon: Texture2D = null
	if ResourceLoader.exists(_ICON):
		icon = load(_ICON) as Texture2D

	for entry in _TYPES:
		add_custom_type(entry[0], entry[1], load(entry[2]), icon)


func _exit_tree() -> void:
	for i in range(_TYPES.size() - 1, -1, -1):
		remove_custom_type(_TYPES[i][0])
