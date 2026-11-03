extends Node
# Local compatibility state only. There are intentionally no networking, Steam, RPC,
# lobby, matchmaking, or packet methods here. The original defaults are retained.
const multiplayer_active = false
const steam = false
const isSteamGame = false
var player_id = 2
var player_name = "Me"
var game = null
var replay_saved = false
var rematch_menu = false
var undo = false
var auto = false
var action_submitted = false
var action_button_panels = {}
var turns_ready = {}
var player_objects = {}
var network_ids = {}
var p1_undo_action = null
var p2_undo_action = null
# Character loader/replay state, inherited from the supplied cl_port layer.
var css_instance = null
var default_chars = 0
var hash_to_folder = {}
var normal_mods = []
var char_mods = []
var player1_chars = []
var player2_chars = []
var ogVersion = Global.VERSION

# This is the exact single-player path of the recovered pid_to_username function.
func pid_to_username(player_id):
	if (player_id != 1 and player_id != 2) or not is_instance_valid(game):
		return ""
	return Global.current_game.match_data.user_data["p" + str(player_id)]
