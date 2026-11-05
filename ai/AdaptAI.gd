extends Node
# Offline-recovery addition: the Adapt AI opponent.
#
# Unlike the simulation CPU in AIBrain (which tries moves in a ghost copy and picks the best
# one), Adapt AI is behavioural cloning: it watches what the human does in each situation and
# replays it when the same situation comes up for the AI side. There are no skill levels - it
# is exactly as good as the player it copied, which is what makes it feel like playing a copy
# of yourself.
#
# What it learns, per recorded turn:
#   * the acting fighter's state name (Wait, DashForward, Parry, ...)
#   * own health % and meter %
#   * foe health % and meter %
#   * whether the foe is in range (within one dash)
#   * the action that was chosen
#
# When the AI needs to act it scores every remembered situation against the current one and
# replays the action from the closest match. If nothing close enough is remembered yet it falls
# back to waiting.
#
# Everything is saved to user://adapt_ai.json so the copy carries across sessions.

const BrainScript := preload("res://ai/AIBrain.gd")
const SandboxScript := preload("res://ai/SimSandbox.gd")

const MODE_OFF := "off"
const MODE_ADAPT := "adapt"

# How close a remembered situation must be to be used. Score is 0..1, above this is usable.
const MATCH_THRESHOLD := 0.55

# Maximum situations remembered per side. Older ones are dropped when full.
const MAX_MEMORY := 2000

# Save file, next to playerdata.json.
const SAVE_PATH := "user://adapt_ai.json"

var brain = null
var sandbox = null
var ui = null
var game = null

var mode := MODE_OFF
var ai_player := 2

var _state := "idle"          # idle | thinking | waiting
var _queue := []              # remembered situations to score
var _scores := []             # {situation, action, score}
var _turn_spent := 0
var _think_started := 0
var _match_data = null

# Memory: array of {state, own_hp_pct, own_meter_pct, foe_hp_pct, foe_meter_pct, in_range,
#                   action, data, extra, tick}
var memory := []

var _sandbox_broken := false

func _ready():
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

	var side = _actionable_side()
	if side == 0:
		_reset_think()
		return
	if side != ai_player:
		return

	# Record what the human just did (if P1 just acted, remember it for P2).
	if side == (3 - ai_player) and _last_human_action != null:
		_remember(_last_human_action)
		_last_human_action = null

	var ab = _buttons_for(ai_player)
	if not is_instance_valid(ab):
		return
	if not bool(ab.get("active")) or not ab.visible:
		return

	match _state:
		"idle":
			_begin_think(ab)
		"thinking":
			_continue_think(ab)
		"waiting":
			if OS.get_ticks_msec() >= _think_started:
				_finish(ab)

# ------------------------------------------------------------------ recording

# Called by main.gd whenever the human submits an action. Captures the situation so the AI can
# copy it later.
func record_human_action(action, data, extra, player_id):
	if mode != MODE_ADAPT:
		return
	if player_id == ai_player:
		return                          # only learn from the human
	if not is_instance_valid(game):
		return
	var fighter = game.get_player(player_id)
	var foe = game.get_player(3 - player_id)
	if not is_instance_valid(fighter) or not is_instance_valid(foe):
		return
	_last_human_action = {
		"action": action,
		"data": data,
		"extra": extra,
		"state": _state_name(fighter),
		"own_hp": float(fighter.hp) / float(fighter.MAX_HEALTH),
		"own_meter": _meter_pct(fighter),
		"foe_hp": float(foe.hp) / float(foe.MAX_HEALTH),
		"foe_meter": _meter_pct(foe),
		"in_range": _in_range(fighter, foe),
		"tick": game.current_tick,
	}

func _remember(entry):
	# Drop duplicates: same situation, same action, keep the newest.
	for i in range(memory.size() - 1, -1, -1):
		var old = memory[i]
		if old["state"] == entry["state"] and old["action"] == entry["action"]:
			memory.remove_at(i)
			break
	if memory.size() >= MAX_MEMORY:
		memory.remove_front()
	memory.append(entry)
	_dirty = true

# ------------------------------------------------------------------ thinking

func _begin_think(ab):
	var moves = brain.available_moves(ab)
	if moves.size() == 0:
		_submit(ai_player, "Continue", null, _extra(ab))
		return
	# Score remembered situations against the current game state.
	var ai = game.get_player(ai_player)
	var foe = game.get_player(3 - ai_player)
	var ctx = {
		"state": _state_name(ai),
		"own_hp": float(ai.hp) / float(ai.MAX_HEALTH),
		"own_meter": _meter_pct(ai),
		"foe_hp": float(foe.hp) / float(foe.MAX_HEALTH),
		"foe_meter": _meter_pct(foe),
		"in_range": _in_range(ai, foe),
	}
	_scores = []
	for m in memory:
		var s = _situation_score(ctx, m)
		if s >= MATCH_THRESHOLD:
			_scores.append({"situation": m, "score": s})
	_scores.sort_custom(self, "_by_score")

	if _scores.size() > 0:
		# Replay the best-remembered action, with a little noise so it isn't identical.
		var pick = _scores[0]
		if _scores.size() > 1 and brain.rng.randf() < 0.15:
			pick = _scores[brain.rng.randi_range(0, _scores.size() - 1)]
		_submit(ai_player, pick["situation"]["action"], pick["situation"].get("data"), pick["situation"].get("extra"))
		_reset_think()
	else:
		# Nothing close enough remembered yet: wait and observe.
		_submit(ai_player, "Continue", null, _extra(ab))
		_reset_think()

func _continue_think(_ab):
	# Adapt AI decides immediately from memory; no multi-frame simulation needed.
	pass

func _finish(_ab):
	_reset_think()

func _reset_think():
	_state = "idle"
	_queue = []
	_scores = []

# ------------------------------------------------------------------ scoring

# Score how well a remembered situation matches the current context. 1.0 = identical.
func _situation_score(ctx, mem) -> float:
	var s = 0.0
	# State match is the strongest signal.
	if ctx["state"] == mem["state"]:
		s += 0.35
	# Health bands (within 15%).
	if abs(ctx["own_hp"] - mem["own_hp"]) < 0.15:
		s += 0.15
	if abs(ctx["foe_hp"] - mem["foe_hp"]) < 0.15:
		s += 0.10
	# Meter bands.
	if abs(ctx["own_meter"] - mem["own_meter"]) < 0.2:
		s += 0.10
	if abs(ctx["foe_meter"] - mem["foe_meter"]) < 0.2:
		s += 0.10
	# In-range agreement.
	if ctx["in_range"] == mem["in_range"]:
		s += 0.10
	# Recency bonus: newer memories are slightly better.
	var age = _match_data.current_tick - mem["tick"]
	if age >= 0:
		s += min(0.10, float(age) / 600.0 * 0.10)
	return clamp(s, 0.0, 1.0)

# ------------------------------------------------------------------ helpers

func _state_name(fighter) -> String:
	if fighter == null:
		return ""
	var s = fighter.current_state()
	if s == null:
		return ""
	return s.name

func _meter_pct(fighter) -> float:
	if fighter == null:
		return 0.0
	var max_meter = fighter.get("MAX_SUPER_METER")
	if max_meter == null or max_meter == 0:
		return 0.0
	var cur = fighter.get("super_meter")
	if cur == null:
		return 0.0
	return clamp(float(cur) / float(max_meter), 0.0, 1.0)

func _in_range(a, b) -> bool:
	if a == null or b == null:
		return false
	var d = a.global_position.distance_to(b.global_position)
	return d < 300.0

func _extra(ab):
	var extra = {"DI": Vector2.ZERO, "reverse": false, "feint": false, "prediction": -1}
	if not is_instance_valid(ab):
		return extra
	var di = ab.get_node_or_null("%DI")
	if is_instance_valid(di) and di.has_method("get_data"):
		extra["DI"] = di.get_data()
	return extra

func _submit(id, action, data, extra):
	if not is_instance_valid(game):
		return
	var fighter = game.get_player(id)
	if not is_instance_valid(fighter):
		return
	fighter.on_action_selected(action, data, extra)

func _buttons_for(id):
	if not is_instance_valid(ui):
		return null
	return ui.get_node_or_null("%P1ActionButtons") if id == 1 else ui.get_node_or_null("%P2ActionButtons")

func _actionable_side() -> int:
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

func _by_score(a, b):
	return a["score"] > b["score"]

# ------------------------------------------------------------------ save / load

var _dirty := false

func save():
	if not _dirty:
		return
	var file = File.new()
	var tmp = SAVE_PATH + ".tmp"
	file.open(tmp, File.WRITE)
	var data = {
		"memory": memory,
	}
	file.store_string(JSON.print(data, "  "))
	file.close()
	var dir = Directory.new()
	dir.rename(tmp, SAVE_PATH)
	_dirty = false

func load():
	var file = File.new()
	if not file.file_exists(SAVE_PATH):
		memory = []
		return
	file.open(SAVE_PATH, File.READ)
	var data = parse_json(file.get_as_text())
	file.close()
	if data is Dictionary and data.has("memory") and data["memory"] is Array:
		memory = data["memory"]
		if memory.size() > MAX_MEMORY:
			memory = memory[MAX_MEMORY - MAX_MEMORY:]  # keep newest
	else:
		memory = []

func clear_memory():
	memory = []
	_dirty = true

func memory_size() -> int:
	return memory.size()

func stop():
	_reset_think()
	if is_instance_valid(sandbox):
		sandbox.free_sandbox()

var _last_human_action = null
