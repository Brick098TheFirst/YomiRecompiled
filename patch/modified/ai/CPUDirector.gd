extends Node
# Offline-recovery addition: the CPU opponent controller.
#
# Sits above AIBrain (what is a good move) and SimSandbox (what would happen). This node owns
# the loop: when the opponent's turn arrives it simulates the candidate moves, picks one by the
# skill level, and submits it through the same ActionButtons path a human press uses.
#
# It also drives the two local modes:
#   * versus CPU           - the CPU plays P2, the player plays P1.
#   * 2 Players (one pad)  - hot seat. P1 locks in, the screen says PASS THE CONTROLLER, P2
#                            plays. Only the panel of whoever is acting is ever on screen, so the
#                            handover cannot leak the other player's move.
#
# The simulation is spread over several frames rather than run in one go: a move can be hundreds
# of ticks, and doing twenty of those in a single frame is a visible freeze. This is the same
# problem the "speed fix" forks of the original AI mod were made to solve.

const BrainScript := preload("res://ai/AIBrain.gd")
const SandboxScript := preload("res://ai/SimSandbox.gd")

const MODE_OFF := "off"
const MODE_CPU := "cpu"
const MODE_HOTSEAT := "hotseat"

# Simulation budget per turn. Frames are cheap; ticks are not.
const SIM_MS_PER_FRAME := 6
const SIM_MS_PER_TURN := 900
const MAX_TICKS_PER_SIM := 600

var brain = null
var sandbox = null
var ui = null
var game = null

var mode := MODE_OFF
var ai_player := 2
var skill := "Medium"

var _state := "idle"          # idle | thinking | waiting
var _queue := []              # moves left to simulate
var _scores := []
var _thinking_side := 0
var _frame_started := 0
var _turn_spent := 0
var _think_started := 0
var _want_wait := 0.0
var _last_actionable := 0
var _sandbox_broken := false
var _busy_frames := 0

var _pass_shown_for := -1
# Set by the probe / a future options toggle. A real pad is detected by Godot; there is no pad
# on the build machine, so the banner is exercised through this.
var _forced_pad := false
var _prompt_until := 0
var _hotseat_prompt = null


func _ready():
	# PAUSE_MODE_PROCESS alone is not enough: a node in a paused tree only gets _process() if
	# pause processing is switched on explicitly. Without this the director sits silent for the
	# whole match, which is a very quiet sort of bug.
	pause_mode = Node.PAUSE_MODE_PROCESS
	set_process(true)
	brain = BrainScript.new(ai_player)
	sandbox = SandboxScript.new(get_tree())


func _process(_delta):
	if mode == MODE_OFF:
		return
	var main = get_parent()
	if not is_instance_valid(main):
		return
	if not is_instance_valid(game):
		game = main.get("game")
	if not is_instance_valid(ui):
		ui = main.get("ui_layer")
	if not is_instance_valid(game) or not is_instance_valid(ui):
		return
	if not game.game_started or game.game_finished:
		return
	if ReplayManager.playback or ReplayManager.resimulating:
		return
	if mode == MODE_CPU:
		# The CPU's bar is not the player's to touch: showing it doubles every move and every
		# Lock In on screen. Only the human's panel is drawn, and it is centred.
		_show_row(human_side())
		_cpu_frame()
	elif mode == MODE_HOTSEAT:
		# Two humans: both halves exist, but only the acting one is drawn.
		_show_both_halves()
		_show_only(_actionable_side())
		_hotseat_frame()


# ------------------------------------------------------------------ CPU

func _cpu_frame():
	var side = _actionable_side()
	if side == 0:
		_reset_think()
		_busy_frames = 0
		return
	if side != ai_player:
		return

	var ab = _buttons_for(ai_player)
	if not is_instance_valid(ab):
		return
	if not bool(ab.get("active")) or not ab.visible:
		# The panel is still opening; a few frames of grace before forcing anything.
		_busy_frames += 1
		if _busy_frames > 240:
			_busy_frames = 0
			_submit(ai_player, "Continue", null, _extra(ab))
		return
	_busy_frames = 0

	match _state:
		"idle":
			_begin_think(ab)
		"thinking":
			_continue_think(ab)
		"waiting":
			if OS.get_ticks_msec() >= _think_started:
				_finish(ab)


func _begin_think(ab):
	var moves = brain.available_moves(ab)
	if moves.size() == 0:
		_submit(ai_player, "Continue", null, _extra(ab))
		return
	var settings = brain.settings()
	_queue = _sample(moves, int(settings["sample"]))
	_scores = []
	_state = "thinking"
	_turn_spent = 0
	_think_started = OS.get_ticks_msec()
	_thinking_side = ai_player


func _continue_think(ab):
	var started = OS.get_ticks_msec()
	while _queue.size() > 0:
		if OS.get_ticks_msec() - started > SIM_MS_PER_FRAME:
			return
		if _turn_spent > SIM_MS_PER_TURN:
			# Out of budget: score the rest on hints so every move still gets a number.
			var rest = _queue.pop_front()
			_scores.append({"move": rest, "score": brain.move_hint(rest) * 10.0})
			continue
		var move = _queue.pop_front()
		var t0 = OS.get_ticks_msec()
		var s = _simulate(move, ab)
		_turn_spent += OS.get_ticks_msec() - t0
		_scores.append({"move": move, "score": s})

	if _queue.size() > 0:
		return

	_scores.sort_custom(self, "_by_score")

	# How often the best option is actually taken is the main difficulty dial.
	var settings = brain.settings()
	var pick = _scores[0]
	if _scores.size() > 1 and brain.rng.randf() > float(settings["best_move_chance"]):
		pick = _scores[brain.rng.randi_range(1, int(min(_scores.size() - 1, 3)))]
	var noise = float(settings["noise"])
	if noise > 0.0 and _scores.size() > 1 and brain.rng.randf() < noise:
		pick = _scores[brain.rng.randi_range(0, _scores.size() - 1)]

	brain.last_scores = _scores
	brain.last_choice = pick["move"]["action"]
	brain.last_ms = OS.get_ticks_msec() - _think_started

	# A visible pause before it commits, so it reads as thinking instead of snapping.
	_state = "waiting"
	_think_started = OS.get_ticks_msec() + int(float(settings["think"]) * 1000.0)
	_want_wait = float(settings["think"])


func _finish(ab):
	if not is_instance_valid(ab):
		_reset_think()
		return
	var pick = _scores[0]
	if _scores.size() > 0:
		# Re-run the same choice logic on the final list (it was sorted already).
		var settings = brain.settings()
		pick = _scores[0]
		if _scores.size() > 1 and brain.rng.randf() > float(settings["best_move_chance"]):
			pick = _scores[brain.rng.randi_range(1, int(min(_scores.size() - 1, 3)))]
		var noise = float(settings["noise"])
		if noise > 0.0 and _scores.size() > 1 and brain.rng.randf() < noise:
			pick = _scores[brain.rng.randi_range(0, _scores.size() - 1)]
		_submit(ai_player, pick["move"]["action"], pick["move"].get("data"), _extra(ab))
	_reset_think()


func _reset_think():
	_state = "idle"
	_queue = []
	_scores = []
	_thinking_side = 0


func _sample(moves, count):
	if count <= 0 or count >= moves.size():
		return moves.duplicate()
	var keep = []
	var rest = []
	for m in moves:
		var n = str(m["action"]).to_lower()
		if n == "wait" or n == "continue" or n.find("block") >= 0 or n.find("parry") >= 0 or n.find("burst") >= 0:
			keep.append(m)
		else:
			rest.append(m)
	rest.shuffle()
	var out = keep
	var i = 0
	while out.size() < count and i < rest.size():
		out.append(rest[i])
		i += 1
	return out


func _by_score(a, b):
	return a["score"] > b["score"]


# Submit a move. ActionButtons.on_action_selected is the *button selection* handler (it takes a
# button, not an action), so the move goes to the fighter's own on_action_selected, which is the
# entry point the game uses for a submitted turn: it queues the action, clears the interruptable
# flags and emits the signals the UI and the ghost listen to.
func _submit(id, action, data, extra):
	if not is_instance_valid(game):
		return
	var fighter = game.get_player(id)
	if not is_instance_valid(fighter):
		return
	fighter.on_action_selected(action, data, extra)


func _extra(ab):
	var extra = {"DI": Vector2.ZERO, "reverse": false, "feint": false, "prediction": -1}
	if not is_instance_valid(ab):
		return extra
	var di = ab.get_node_or_null("%DI")
	if is_instance_valid(di) and di.has_method("get_data"):
		extra["DI"] = di.get_data()
	return extra


# ------------------------------------------------------------------ simulation

func _simulate(move, ab):
	if _sandbox_broken or not is_instance_valid(sandbox) or not is_instance_valid(game):
		return brain.move_hint(move) * 10.0
	if not sandbox.load_state(game, game.match_data):
		_sandbox_broken = true
		push_warning("CPU: sandbox could not take the match state; falling back to move hints")
		return brain.move_hint(move) * 10.0
	var sb = sandbox.sandbox
	var ai = sb.get_player(ai_player)
	var foe = sb.get_player(3 - ai_player)
	# The AI never sees the player's pick - that is the game. Model the opponent as holding
	# still, which is the neutral assumption and what makes a block a real answer.
	sandbox.queue(ai, move["action"], move.get("data"), _extra(ab))
	sandbox.queue(foe, "Continue", null, null)
	var ticks = sandbox.resolve(MAX_TICKS_PER_SIM, OS.get_ticks_msec() + 120)
	var s = sandbox.score(brain, ai_player)
	# A move that never resolved did not change the position; do not reward it.
	if ticks >= MAX_TICKS_PER_SIM:
		s -= 5.0
	return s


# ------------------------------------------------------------------ hot seat

func _hotseat_frame():
	var side = _actionable_side()
	if side == 0:
		_hide_prompt()
		_pass_shown_for = -1
		_show_only(0)
		return
	_show_only(side)
	# The handover message belongs to P2's turn: that is the moment the pad changes hands. It
	# clears itself after a couple of seconds so it is not sitting on top of the move bar while
	# the second player is choosing.
	if side == 2 and _pass_shown_for != game.current_tick:
		_pass_shown_for = game.current_tick
		# Only worth saying when there is something to pass. Keyboard and mouse already hide
		# the other player's panel, so the handover is obvious without a banner.
		if _controller_plugged_in():
			_show_prompt("PASS THE CONTROLLER\n   TO PLAYER 2")
			_prompt_until = OS.get_ticks_msec() + 2400
	if is_instance_valid(_hotseat_prompt) and _hotseat_prompt.visible:
		if OS.get_ticks_msec() > _prompt_until:
			_hide_prompt()


func _controller_plugged_in():
	return Input.get_connected_joypads().size() > 0 or _forced_pad


func human_side():
	return 1 if int(ai_player) == 2 else 2


# In versus CPU there is only one player, so the whole other half of the bar goes away: the
# wrapper that holds P2's panel *and* P2's info meters, not just the panel. Hiding only the
# panel leaves an empty half-row and player 1 stays pushed to the left; with the wrapper hidden
# the row has one child with expand-and-fill set, so player 1's bar spans the full width on its
# own. No positions are hard-coded, which is why this also survives a different screen size.
func _show_row(side):
	var row = _action_buttons_row()
	if not is_instance_valid(row):
		return
	for id in [1, 2]:
		var vbox = _panel_vbox(id)
		if not is_instance_valid(vbox):
			continue
		var want = (id == side)
		if vbox.visible != want:
			vbox.visible = want
		var ab = _buttons_for(id)
		if is_instance_valid(ab) and ab.has_method("set_solo_layout"):
			# Solo bar: one side on screen, so its rows centre on the whole screen rather than
			# sitting in the half they would have shared.
			ab.set_solo_layout(true)


# Put both halves back, for hot seat and for replays.
func _show_both_halves():
	var row = _action_buttons_row()
	if not is_instance_valid(row):
		return
	for id in [1, 2]:
		var vbox = _panel_vbox(id)
		if is_instance_valid(vbox) and not vbox.visible:
			vbox.visible = true
		var ab = _buttons_for(id)
		if is_instance_valid(ab) and ab.has_method("set_solo_layout"):
			ab.set_solo_layout(false)


func _action_buttons_row():
	if not is_instance_valid(ui):
		return null
	return ui.get_node_or_null("GameUI/BottomBar/ActionButtons")


func _panel_vbox(id):
	if not is_instance_valid(ui):
		return null
	return ui.get_node_or_null("GameUI/BottomBar/ActionButtons/VBoxContainer" if id == 1 else "GameUI/BottomBar/ActionButtons/VBoxContainer2")


# Both panels are on screen in a normal match. In hot seat that gives away the other player's
# pick, so only the acting side's panel is shown.
func _show_only(side):
	for id in [1, 2]:
		var ab = _buttons_for(id)
		if not is_instance_valid(ab):
			continue
		var want = (id == side)
		if ab.visible != want:
			ab.visible = want


# ------------------------------------------------------------------ shared

func _buttons_for(id):
	if not is_instance_valid(ui):
		return null
	return ui.get_node_or_null("%P1ActionButtons") if id == 1 else ui.get_node_or_null("%P2ActionButtons")


func _actionable_side():
	if not is_instance_valid(game):
		return 0
	if not game.is_waiting_on_player():
		return 0
	if not (is_instance_valid(game.p1) and is_instance_valid(game.p2)):
		return 0
	var p1_ready = game.p1.state_interruptable
	var p2_ready = game.p2.state_interruptable
	if p1_ready and not p2_ready:
		return 1
	if p2_ready and not p1_ready:
		return 2
	if p1_ready and p2_ready:
		if game.p1_turn:
			return 1
		if game.p2_turn:
			return 2
		return 1
	return 0


# ------------------------------------------------------------------ hot seat banner

func _show_prompt(text):
	if is_instance_valid(_hotseat_prompt):
		var l = _hotseat_prompt.get_node_or_null("Label")
		if is_instance_valid(l):
			l.text = text
		_hotseat_prompt.visible = true
		return
	var layer = CanvasLayer.new()
	layer.layer = 90
	layer.pause_mode = Node.PAUSE_MODE_PROCESS
	add_child(layer)
	var panel = ColorRect.new()
	panel.color = Color(0.04, 0.05, 0.07, 0.92)
	panel.rect_position = Vector2(160, 132)
	panel.rect_size = Vector2(320, 92)
	layer.add_child(panel)
	var label = Label.new()
	label.name = "Label"
	label.text = text
	label.align = Label.ALIGN_CENTER
	label.valign = Label.VALIGN_CENTER
	label.rect_size = Vector2(320, 92)
	label.autowrap = true
	panel.add_child(label)
	_hotseat_prompt = panel


func _hide_prompt():
	if is_instance_valid(_hotseat_prompt):
		_hotseat_prompt.visible = false


func stop():
	_reset_think()
	_hide_prompt()
	_show_only(1)
	if is_instance_valid(sandbox):
		sandbox.free_sandbox()
