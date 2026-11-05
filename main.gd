extends Node

signal game_started()
signal game_setup()

onready var ui_layer = $UILayer
onready var game_layer = $GameLayer
onready var hud_layer = $HudLayer


var hooks = null
var cpu_director = null
var adapt_ai_director = null

var singleplayer = false
var game
var ghost_game

var afterimages = []

var p1_ghost_action
var p1_ghost_data
var p1_ghost_extra

var p2_ghost_action
var p2_ghost_data
var p2_ghost_extra

var match_data = {}
var has_submitted_a_turn = false
var last_backup_tick = - 1




var style_permission_requested: = {}
var style_permission_pending: = {}

var started_ghost_this_frame = false

var _Global = Network

func _enter_tree():
	pass

func _ready():
	# Offline build: music is started once from Global, but anything that stops the
	# player later (a stalled device, a dropped stream) would leave the menu silent for
	# good. Re-check whenever the main scene comes up.
	Global.play_song_if_idle()
	
	if ModLoader.active:
		hooks = get_node_or_null("Hooks")
		if hooks:
			hooks.host = self
	
	
	
	
	ui_layer.connect("singleplayer_started", self, "_on_game_started", [true])
	ui_layer.connect("loaded_replay", self, "_on_loaded_replay")
	connect("game_started", ui_layer, "on_game_started")
	$"%P1ActionButtons".connect("action_clicked", self, "on_action_clicked", [1])
	$"%P2ActionButtons".connect("action_clicked", self, "on_action_clicked", [2])
	$"%GhostButton".connect("toggled", self, "_on_ghost_button_toggled")
	$"%SaveReplayButton".connect("pressed", self, "save_replay")
	$"%SaveStylesButton".connect("pressed", self, "_show_style_save_menu", [true])
	$"%StyleBackButton".connect("pressed", self, "_show_style_save_menu", [false])
	$"%SaveP1StyleButton".connect("pressed", self, "save_player_style", [1])
	$"%SaveP2StyleButton".connect("pressed", self, "save_player_style", [2])
	if not Global.STYLE_SAVE_FEATURE_ENABLED:
		
		
		$"%SaveStylesButton".hide()
	$"%PausePanel".connect("visibility_changed", self, "_on_pause_panel_visibility_changed")
	$"%CharacterSelect".connect("match_ready", self, "_on_match_ready")
	$"%GhostSpeed".connect("value_changed", self, "_on_ghost_speed_changed")
	$"%GhostWaitTimer".connect("timeout", self, "_on_ghost_wait_timer_timeout")
	$"%FreezeOnMyTurn".connect("pressed", self, "start_ghost")
	$"%FreezeOnMyTurn".connect("toggled", Global, "save_option", ["freeze_ghost_prediction"])
	$"%FreezeSound".connect("toggled", Global, "save_option", ["freeze_ghost_sound"])
	$"%FreezeSound".connect("pressed", self, "start_ghost")
	$"%AfterimageButton".connect("pressed", self, "start_ghost")
	$"%AfterimageButton".connect("toggled", Global, "save_option", ["ghost_afterimages"])
	$"%GameUI".hide()
	$"%MainMenu".show()
	ReplayManager.play_full = false
	$"%FreezeOnMyTurn".set_pressed_no_signal(Global.freeze_ghost_prediction)
	$"%AfterimageButton".set_pressed_no_signal(Global.ghost_afterimages)

	randomize()
	$"%NagWindow".hide()
	$"%NagWindow".rect_position = Vector2(randi() % 640, randi() % 360)
	# offline build: the "buy it on Steam" nag window is not connected
	$"%P1ShowStyle".connect("toggled", self, "_on_show_style_toggled", [1])
	$"%P2ShowStyle".connect("toggled", self, "_on_show_style_toggled", [2])
	ReplayManager.replaying_ingame = false


	
	var mod_toggle = $"%ModToggle" if has_node("%ModToggle") else null
	var container = mod_toggle.get_parent() if mod_toggle else null

	if container and container.get_node_or_null("DeleteCache") == null:
		var btt = Button.new()
		btt.name = "DeleteCache"
		btt.text = "delete character cache"
		container.add_child(btt)
		container.move_child(btt, mod_toggle.get_index())
		btt.connect("pressed", self, "_delete_char_cache", [btt])

	var loaded_mods = false
	while not Global.mods_loaded:
		loaded_mods = true
		hide_main_menu(true)
		$"%LoadingCharactersLabel".show()
		$InputBlocker.show()
		$"%LoadingCharactersLabel2".show()
		$"%LoadingCharactersLabel2".text = Global.loading_character
		yield(get_tree(), "idle_frame")

	if loaded_mods:
		$"%MainMenu".show()
		$InputBlocker.hide()
		$"%LoadingCharactersLabel2".hide()
		$"%LoadingCharactersLabel".hide()

	if hooks:
		hooks.ready()

func _delete_char_cache(btt):
	var dir = Directory.new()
	_Global.css_instance.charPackages = {}
	for f in ModLoader._get_all_files("user://char_cache", "pck"):
		dir.remove(f)
	get_tree().quit()

func _on_show_style_toggled(on, player_id):
	if is_instance_valid(game):
		var player = game.get_player(player_id)
		if on:
			player.reapply_style()
		else:
			player.reset_style()
		
		var hud = get_node_or_null("%HudLayer")
		if hud and hud.has_method("refresh_portrait_style"):
			hud.refresh_portrait_style(player_id)

func _on_game_started(singleplayer):
	ui_layer.reset_ui()
	if is_instance_valid(game):
		game.free()
		game = null
		stop_ghost()
	self.singleplayer = singleplayer
	Network.replay_saved = false
	hide_main_menu(true)

	if $"%P1InfoContainer".get_child(0) is PlayerInfo:
		$"%P1InfoContainer".get_child(0).queue_free()
	if $"%P2InfoContainer".get_child(0) is PlayerInfo:
		$"%P2InfoContainer".get_child(0).queue_free()

	$"%CharacterSelect".show()
	$"%CharacterSelect".init(singleplayer)
	if hooks:
		hooks.game_started(singleplayer)

func _on_ghost_wait_timer_timeout():
	if is_instance_valid(game):
		start_ghost()

func _on_loaded_replay(match_data):


	_Global.css_instance.net_loadReplayChars([match_data.selected_characters[1]["name"], match_data.selected_characters[2]["name"], match_data])
	match_data["replay"] = true
	_on_match_ready(match_data)

func _on_match_ready(data):
	Utils.normalize_timer_settings(data)
	match_data = data
	if hooks:
		hooks.match_ready(data)
	
	
	
	
	Network.replay_saved = false
	has_submitted_a_turn = false
	last_backup_tick = - 1
	style_permission_requested.clear()
	style_permission_pending.clear()
	_set_save_style_button_disabled(1, false)
	_set_save_style_button_disabled(2, false)
	if match_data.has("replay_challenge"):
		push_error("Online replay challenges are not supported in this offline project")
		return
	elif match_data.has("replay"):
		singleplayer = true
	else:
		singleplayer = data["singleplayer"]
	if not match_data.has("replay") and not match_data.has("replay_challenge"):
		ReplayManager.playback = false
	setup_game(singleplayer, data)
	emit_signal("game_started")

func setup_game(singleplayer, data):
	_start_cpu_director()
	_start_adapt_ai_director()
	hide_main_menu(true)
	if is_instance_valid(game):
		game.queue_free()
	call_deferred("setup_game_deferred", singleplayer, data)
	emit_signal("game_setup")
	if hooks:
		hooks.game_setup(singleplayer, data)

func setup_main_menu_game():
	game = preload("res://Game.tscn").instance()
	game_layer.add_child(game)

func save_replay():
	var filename = ReplayManager.save_replay(match_data, $"%ReplayName".text)
	$"%SaveReplayButton".disabled = true
	$"%SaveReplayButton".text = "saved"
	$"%SaveReplayLabel".text = "saved replay to " + filename
	if hooks:
		hooks.replay_saved(filename)





func _unhandled_key_input(event):
	if not event.pressed or event.echo:
		return
	if not event.is_action_pressed(Hotkeys.SAVE_REPLAY):
		return
	if _style_menu_active:
		return
	var btn = get_node_or_null("%SaveReplayButton")
	if btn == null or btn.disabled:
		return
	var pause_open = has_node("%PausePanel") and $"%PausePanel".visible
	save_replay()
	if not pause_open:
		_show_save_replay_toast()
	get_tree().set_input_as_handled()








const _TOAST_NODE_NAME: = "_SaveReplayToast"
const _TOAST_DURATION: = 1.5
var _toast_baseline_label_text: = ""

func _get_save_replay_toast():
	var host = get_node_or_null("%GameUI")
	if host == null:
		return null
	return host.get_node_or_null(_TOAST_NODE_NAME)

func _show_save_replay_toast():
	
	var existing = _get_save_replay_toast()
	if existing:
		existing.queue_free()
	var pause_label: Label = get_node_or_null("%SaveReplayLabel")
	if pause_label == null:
		return
	
	
	
	
	var host = get_node_or_null("%GameUI")
	if host == null:
		return
	_toast_baseline_label_text = pause_label.text
	var label_copy: Label = pause_label.duplicate()
	label_copy.name = _TOAST_NODE_NAME
	
	
	label_copy.set_anchors_preset(Control.PRESET_CENTER)
	label_copy.margin_left = - 274
	label_copy.margin_top = 42
	label_copy.margin_right = 274
	label_copy.margin_bottom = 58
	label_copy.visible = true
	host.add_child(label_copy)
	var timer = Timer.new()
	timer.wait_time = _TOAST_DURATION
	timer.one_shot = true
	label_copy.add_child(timer)
	timer.start()
	timer.connect("timeout", label_copy, "queue_free")

var _style_menu_main_visibility: = {}
var _style_menu_active: = false





func _show_style_save_menu(show_styles: bool):
	if show_styles == _style_menu_active:
		return
	_style_menu_active = show_styles
	var main_buttons = ["%ResumeButton", "%ReplayName", "%SaveReplayButton", 
			"%SaveStylesButton", "%PauseOptionsButton", 
			"%QuitToMainMenuButton", "%ForfeitButton"]
	var style_buttons = ["%StyleName", "%SaveP1StyleButton", 
			"%SaveP2StyleButton", "%StyleBackButton"]
	if show_styles:
		_style_menu_main_visibility.clear()
		for path in main_buttons:
			var n = get_node_or_null(path)
			if n:
				_style_menu_main_visibility[path] = n.visible
				n.visible = false
	else:
		for path in main_buttons:
			var n = get_node_or_null(path)
			if n:
				n.visible = _style_menu_main_visibility.get(path, true)
		_style_menu_main_visibility.clear()
	for path in style_buttons:
		var n = get_node_or_null(path)
		if n:
			n.visible = show_styles




func _on_pause_panel_visibility_changed():
	if not $"%PausePanel".visible and _style_menu_active:
		_show_style_save_menu(false)

func save_player_style(player_id: int):
	if not Global.STYLE_SAVE_FEATURE_ENABLED:
		return
	if not is_instance_valid(game):
		return
	var player = game.get_player(player_id)
	if not is_instance_valid(player) or player.applied_style == null:
		$"%SaveReplayLabel".text = "p%d has no style to save" % player_id
		return
	
	
	
	
	
	
	
	
	var src = player.applied_style
	
	
	
	
	
	var is_replay = match_data.get("replay", false) or match_data.get("replay_challenge", false)
	
	
	
	
	var saving_own = not is_replay and ( not Network.multiplayer_active or Network.player_id == player_id)
	var i_am_chain_owner = _is_chain_latest(src)
	if Global.STYLE_SAVE_FEATURE_ENABLED and not saving_own and not i_am_chain_owner and src is Dictionary and not src.get("allow_others_save", true):
		
		
		
		var in_lobby = Network.multiplayer_active
		if not in_lobby:
			$"%SaveReplayLabel".text = "p%d's style is not shareable" % player_id
			return
		if style_permission_requested.has(player_id):
			
			return
		style_permission_requested[player_id] = true
		style_permission_pending[player_id] = true
		var requester = Global.get_player_data().username
		var style_name = src.get("style_name", "") if src is Dictionary else ""
		Network.broadcast_rpc("receive_style_save_request", [player_id, requester, style_name])
		$"%SaveReplayLabel".text = "asked p%d for permission..." % player_id
		_set_save_style_button_disabled(player_id, true)
		return
	_do_save_player_style(player_id, _duplicate_style_object(player.applied_style))

func _is_chain_latest(style) -> bool:
	if not (style is Dictionary):
		return false
	var sid = OfflineCapabilities.STEAM_ID
	if sid == null or typeof(sid) != TYPE_INT or sid <= 0:
		return false
	var my_id = str(sid)
	var latest_id = ""
	var mod_ids = style.get("modifier_ids", [])
	if mod_ids is Array and not mod_ids.empty():
		latest_id = str(mod_ids[mod_ids.size() - 1])
	else:
		latest_id = str(style.get("creator_id", ""))
	return latest_id != "" and latest_id == my_id

func _set_save_style_button_disabled(player_id: int, disabled: bool):
	var path = "%%SaveP%dStyleButton" % player_id
	if has_node(path):
		get_node(path).disabled = disabled

func _do_save_player_style(player_id: int, style):
	var requested_name = $"%StyleName".text.strip_edges()
	if requested_name == "":
		
		
		
		requested_name = style.get("style_name", "") if style is Dictionary else ""
		if requested_name == "":
			var ud = match_data.get("user_data", {}) if match_data else {}
			requested_name = ud.get("p%d" % player_id, "untitled")
	requested_name = Utils.filter_filename(requested_name)
	if requested_name == "":
		requested_name = "untitled"
	var unique_name = _next_available_style_name(requested_name)
	style["style_name"] = unique_name
	Custom.save_style(style)
	$"%SaveReplayLabel".text = "saved p%d style as %s.style" % [player_id, unique_name]



func _on_style_save_response_received(target_player_id, requester_id, requester_name, allowed):
	if not _style_response_for_me(requester_id, requester_name):
		return
	if not style_permission_pending.has(target_player_id):
		return
	style_permission_pending.erase(target_player_id)
	if not allowed:
		
		return
	if not is_instance_valid(game):
		return
	var player = game.get_player(target_player_id)
	if not is_instance_valid(player) or player.applied_style == null:
		$"%SaveReplayLabel".text = "p%d's style is gone" % target_player_id
		return
	_do_save_player_style(target_player_id, _duplicate_style_object(player.applied_style))

func _style_response_for_me(requester_id, requester_name) -> bool:
	if Network.steam:
		return requester_id != 0 and requester_id == OfflineCapabilities.STEAM_ID
	return requester_name == Global.get_player_data().username



func _next_available_style_name(base: String) -> String:
	var dir = Directory.new()
	var name = base
	var n = 2
	while dir.file_exists("user://custom/" + name + ".style"):
		name = base + str(n)
		n += 1
	return name

func _duplicate_style_object(style):
	if style is Dictionary:
		return style.duplicate(true)
	
	if style and style.has_method("duplicate"):
		return style.duplicate(true)
	return style

func hide_main_menu(all = false):
	ui_layer.hide_main_menu(all)

func _format_p2_name(p2_name: String):
	if p2_name.begins_with("F-") and "__" in p2_name and p2_name.split("__").size() > 1:
		return p2_name.split("__")[1]
	return p2_name

# The CPU opponent and the hot-seat handover are both driven from here: they need to see the
# match and the action panels, and Main owns both.
func _start_cpu_director():
	if is_instance_valid(cpu_director):
		cpu_director.stop()
		cpu_director.queue_free()
		cpu_director = null
	var mode = str(Global.ai_settings.get("mode", "off"))
	if mode == "off":
		return
	cpu_director = preload("res://ai/CPUDirector.gd").new()
	cpu_director.name = "CPUDirector"
	# Add it first: _ready() is what builds the brain and the sandbox, so the settings below
	# have something to talk to.
	add_child(cpu_director)
	cpu_director.mode = mode
	cpu_director.ai_player = int(Global.ai_settings.get("ai_player", 2))
	cpu_director.skill = str(Global.ai_settings.get("skill", "Medium"))
	cpu_director.brain.set_skill(cpu_director.skill)


# The Adapt AI director is started the same way as the CPU director, but reads
# Global.adapt_ai_settings instead of Global.ai_settings.
func _start_adapt_ai_director():
	if is_instance_valid(adapt_ai_director):
		adapt_ai_director.stop()
		adapt_ai_director.queue_free()
		adapt_ai_director = null
	var mode = str(Global.adapt_ai_settings.get("mode", "off"))
	if mode != "adapt":
		return
	adapt_ai_director = preload("res://ai/AdaptAI.gd").new()
	adapt_ai_director.name = "AdaptAIDirector"
	add_child(adapt_ai_director)
	adapt_ai_director.mode = mode
	adapt_ai_director.ai_player = int(Global.adapt_ai_settings.get("ai_player", 2))

func setup_game_deferred(singleplayer, data):
	game = preload("res://Game.tscn").instance()
	game_layer.add_child(game)
	game.connect("simulation_continue", self, "_on_simulation_continue")
	game.connect("player_actionable", self, "_on_player_actionable")
	game.connect("playback_requested", self, "_on_playback_requested")
	game.connect("zoom_changed", self, "_on_zoom_changed")
	
	Network.game = game
	
	if not data.has("user_data"):
		var ud = {}
		ud["p1"] = Global.get_player_data().username
		ud["p2"] = _format_p2_name(data.selected_characters[2]["name"])
		if Global.has_name_color():
			ud["p1_color"] = Global.get_name_color().to_html(false)
		data["user_data"] = ud
	
	if game.start_game(singleplayer, data) is bool:
		return
	var timer_mode = data.get("timer_mode", "default")
	
	
	
	if timer_mode != "none":
		if not Network.undo or timer_mode != "chess":
			if timer_mode == "increment":
				
				
				
				var starting = int(data.get("increment_starting_time", 60))
				var inc = int(data.get("increment_per_turn", 10))
				var bank = int(max(starting, inc))
				
				
				
				var max_minutes = int(data.get("increment_max_time", 0))
				if max_minutes > 0:
					bank = int(min(bank, max_minutes * 60))
				ui_layer.set_turn_time(bank, false)
			elif data.has("turn_time"):
				ui_layer.set_turn_time(data.turn_time, timer_mode == "chess")
		else:
			ui_layer.start_timers()
	ui_layer.init(game)
	if data.has("replay_challenge") and data.replay_challenge and data.get("restore_timers") and data.has("chess_timer_state"):
		ui_layer.restore_chess_timer_state(data.chess_timer_state)
	hud_layer.init(game)
	var p1 = game.get_player(1)
	var p2 = game.get_player(2)
	p1.debug_label = $"%DebugLabelP1"
	p2.debug_label = $"%DebugLabelP2"
	var p1_info_scene = p1.player_info_scene.instance()
	var p2_info_scene = p2.player_info_scene.instance()
	p1_info_scene.set_fighter(p1)
	p2_info_scene.set_fighter(p2)
	if $"%P1InfoContainer".get_child(0) is PlayerInfo:

		$"%P1InfoContainer".get_child(0).queue_free()
	if $"%P2InfoContainer".get_child(0) is PlayerInfo:

		$"%P2InfoContainer".get_child(0).queue_free()
	for child in $"%ActivePlayerInfoContainer".get_children():
		child.queue_free()

	$"%P1InfoContainer".add_child(p1_info_scene)
	$"%P1InfoContainer".move_child(p1_info_scene, 0)
	$"%P2InfoContainer".add_child(p2_info_scene)
	$"%P2InfoContainer".move_child(p2_info_scene, 0)
	ui_layer.p1_info_scene = p1_info_scene
	ui_layer.p2_info_scene = p2_info_scene

func _on_ghost_button_toggled(toggled):
	if toggled:
		start_ghost()
	else:
		stop_ghost()

func _on_player_actionable():

	ui_layer.on_player_actionable()
	if hooks:
		hooks.turn_ui_opened()
	$"%GhostWaitTimer".start()
	start_ghost()
	_maybe_save_backup()
	_reset_save_replay_button()

func _reset_save_replay_button():
	var btn = get_node_or_null("%SaveReplayButton")
	if btn == null:
		return
	btn.disabled = false
	btn.text = "save replay"

func _maybe_save_backup():
	if not is_instance_valid(game):
		return
	if game.current_tick == last_backup_tick:
		return
	last_backup_tick = game.current_tick
	if Global.enable_replay_backups and has_submitted_a_turn and not ReplayManager.playback and not game.game_finished:
		ReplayManager.save_replay_backup(match_data)
	has_submitted_a_turn = true

func on_action_clicked(action, data, extra, player_id):
	if hooks:
		hooks.action_clicked(player_id, action, data, extra)
	if player_id == 1:
		p1_ghost_action = action
		p1_ghost_data = data
		p1_ghost_extra = extra
	else:
		p2_ghost_action = action
		p2_ghost_data = data
		p2_ghost_extra = extra
	start_ghost()
	$"%AdvantageLabel".text = ""
	# Remember what the human did so the Adapt AI can copy it later.
	if is_instance_valid(adapt_ai_director) and adapt_ai_director.mode == "adapt":
		adapt_ai_director.record_human_action(action, data, extra, player_id)
	pass

func start_ghost():
	call_deferred("_start_ghost")

func _process(_delta):
	align_afterimages()
	if is_instance_valid(game):
		$"%SpeedLines".set_direction(game.camera.current_direction)
		$"%SpeedLines".set_speed(game.camera.current_speed / game.camera.zoom.x)
		$"%SpeedLines".tick = game.current_tick
		
		
		
		
		
		if is_instance_valid(game.p1) and is_instance_valid(game.p2):
			var screen_center = game.get_viewport_rect().size / 2
			var cam_pos = game.camera.global_position
			var zoom = game.camera.zoom.x
			var p1_screen = (game.p1.global_position - cam_pos) / zoom + screen_center
			var p2_screen = (game.p2.global_position - cam_pos) / zoom + screen_center
			$"%SpeedLines".set_player_anchors(p1_screen, p2_screen)
		
		
		
		
		$"%SpeedLines".on = not game.is_waiting_on_player() and game.super_freeze_ticks <= 0
	_tick_save_replay_toast()

func _tick_save_replay_toast():
	var toast = _get_save_replay_toast()
	if toast == null:
		return
	if has_node("%PausePanel") and $"%PausePanel".visible:
		toast.queue_free()
		return
	var pause_label = get_node_or_null("%SaveReplayLabel")
	if pause_label and pause_label.text != _toast_baseline_label_text:
		toast.queue_free()

func _physics_process(delta):
	set_deferred("started_ghost_this_frame", false)

func align_afterimages():
	if is_instance_valid(game):
		var zoom = game.camera.zoom.x * game.camera_zoom
		var center = - game.camera_snap_position / zoom

		for image in $"%Afterimages".get_children():
			image.rect_position = center + image.start_position / zoom + game.camera.offset / zoom
			image.visible = $"%AfterimageButton".pressed

func _start_ghost():
	if started_ghost_this_frame:
		return
	started_ghost_this_frame = true

	if not $"%GhostWaitTimer".is_stopped():
		yield($"%GhostWaitTimer", "timeout")
		return
	stop_ghost()
	for child in $"%GhostViewport".get_children():
		child.queue_free()
	afterimages = []
	$"%AfterImage1".texture = null
	$"%AfterImage2".texture = null
	if not $"%GhostButton".pressed:
		return
	if ReplayManager.playback:
		return
	if not is_instance_valid(game):
		return
	if not game.prediction_enabled:
		return

	ghost_game = preload("res://Game.tscn").instance()
	ghost_game.is_ghost = true
	$"%GhostViewport".add_child(ghost_game)
	ghost_game.start_game(true, match_data)
	ghost_game.connect("ghost_finished", self, "ghost_finished")
	ghost_game.connect("make_afterimage", self, "make_afterimage", [], CONNECT_DEFERRED)
	ghost_game.connect("ghost_my_turn", self, "ghost_my_turn", [], CONNECT_DEFERRED)
	ghost_game.ghost_speed = $"%GhostSpeed".get_speed()
	ghost_game.ghost_freeze = $"%FreezeOnMyTurn".pressed
	game.call_deferred("copy_to", ghost_game)
	game.ghost_game = ghost_game
	var p1 = ghost_game.get_player(1)
	var p2 = ghost_game.get_player(2)

	p1.queued_action = p1_ghost_action
	p1.queued_data = p1_ghost_data
	p1.queued_extra = p1_ghost_extra
	p1.is_ghost = true

	p2.queued_action = p2_ghost_action
	p2.queued_data = p2_ghost_data
	p2.queued_extra = p2_ghost_extra
	p2.is_ghost = true
	call_deferred("fix_ghost_objects", ghost_game)


func ghost_my_turn():
	if Global.freeze_ghost_sound:
		$GhostMyTurnSound.play()

func make_afterimage():
	if not $"%AfterimageButton".pressed:
		return
	var img = $"%GhostViewport".get_texture().get_data()
	
	var img_dest = Image.new()
	img_dest.create(img.get_width(), img.get_height(), false, img.get_format())
	img_dest.blit_rect(img, Rect2(Vector2(), Vector2(img.get_width(), img.get_height())), Vector2.ZERO)
	img_dest.flip_y()
	
	var tex = ImageTexture.new()
	tex.create_from_image(img_dest)
	
	var texture_rect = $"%AfterImage1" if $"%AfterImage1".texture == null else $"%AfterImage2"
	texture_rect.start_position = game.camera_snap_position
	texture_rect.texture = tex

func ghost_finished():

	start_ghost()

func fix_ghost_objects(ghost_game_):
	for obj_name in ghost_game_.objs_map:
		var object = ghost_game_.objs_map[obj_name]
		if object:
			object.is_ghost = true
func stop_ghost():
	if is_instance_valid(game):
		game.ghost_game = null
	for child in $"%GhostViewport".get_children():
		child.hide()
		child.ghost_hidden = true
	for child in $"%Afterimages".get_children():
		child.texture = null

func _on_zoom_changed():
	for child in $"%Afterimages".get_children():
		child.texture = null

func _on_simulation_continue():
	p1_ghost_action = null
	p1_ghost_data = null
	p1_ghost_extra = null
	p2_ghost_action = null
	p2_ghost_data = null
	p2_ghost_extra = null
	call_deferred("stop_ghost")

func _on_ghost_speed_changed(_value):
	if is_instance_valid(game):
		_start_ghost()

func _on_playback_requested():
	ReplayManager.playback = true
	setup_game(singleplayer, match_data)

func _on_ReplayName_text_entered(_new_text):
	save_replay()
