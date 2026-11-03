extends Reference
# Offline-recovery addition: a CPU opponent.
#
# This is an independent reimplementation of the idea behind the well-known YOMI AI mods
# (AxNoodle's "General AI", and later simulation-based opponents): copy the match, try every
# move in the copy, score the result, pick the best one, and tune how often the pick is the best
# one to make the difficulty levels. Nothing here is copied from those mods; it is written
# against this build's own game code.
#
# What the game already gives us for free:
#   * Game.tscn can be instanced as a "ghost" - main.gd does exactly that for the prediction
#     ghost. A ghost runs a full copy of the match with no rendering, and `copy_to()` drops the
#     live match's state into it.
#   * A fighter applies whatever is in `queued_action` / `queued_data` / `queued_extra` on its
#     next tick, which is how replays and the ghost both feed input in.
# So a simulation is: instance a ghost, copy the state, queue one move for one side, tick until
# the turn resolves, and read the result.
#
# The rules of the format matter here and the AI obeys them: it never sees the player's move.
# Both sides pick blind. That is the whole game.

const SKILL_LEVELS := {
	# best_move_chance: how often the top-scoring option is the one taken.
	# sample: how many of the available moves get simulated (<= 0 means all).
	# noise: how much random jitter is added to every score, as a fraction of the score range.
	# think: seconds spent "thinking" so it does not feel instant.
	"Easy": {"best_move_chance": 0.35, "sample": 8, "noise": 0.55, "think": 0.55},
	"Medium": {"best_move_chance": 0.62, "sample": 12, "noise": 0.30, "think": 0.5},
	"Hard": {"best_move_chance": 0.85, "sample": 18, "noise": 0.14, "think": 0.45},
	"Very Hard": {"best_move_chance": 0.97, "sample": 0, "noise": 0.05, "think": 0.4},
}

const SKILL_ORDER := ["Easy", "Medium", "Hard", "Very Hard"]

# Simulation budget. A simulation step is cheap but a move can take hundreds of ticks, so the
# budget is in ticks, not in calls: past this the result is scored on what happened so far.
const MAX_TICKS_PER_SIM := 900
const MAX_SIM_MS_PER_TURN := 700

# How far ahead "Hard" and up look. Depth 2 = it also tries to answer its own move.
const DEPTH := {"Easy": 1, "Medium": 1, "Hard": 2, "Very Hard": 2}

var skill := "Medium"
var player_id := 2
var rng := RandomNumberGenerator.new()

# Populated by the think pass so the log / debug overlay can show what it decided.
var last_scores := []
var last_choice := ""
var last_ms := 0


func _init(ai_player_id = 2):
	player_id = ai_player_id
	rng.randomize()


func set_skill(name):
	if name in SKILL_LEVELS:
		skill = name


func settings():
	return SKILL_LEVELS[skill]


# ------------------------------------------------------------------ scoring

# What a position is worth to the AI. Everything is relative: the two fighters' health, meter,
# burst and position, plus the state the AI is left in when the turn resolves (a move that ends
# in its own hurt state is bad even if it deals damage first).
func score_state(ai, foe, game):
	if not (is_instance_valid(ai) and is_instance_valid(foe)):
		return 0.0
	var s = 0.0
	# Health swing is the foundation of the game; weight it highest. MAX_HEALTH is a per
	# character constant, so modded characters with different health pools compare fairly.
	var ai_hp = float(ai.hp)
	var foe_hp = float(foe.hp)
	var total = max(1.0, float(ai.MAX_HEALTH + foe.MAX_HEALTH))
	s += (foe_hp - ai_hp) / total * 400.0

	# Ending the turn in a state we control is worth a lot: this game is about whose turn it is.
	var ai_hurt = ai.is_in_hurt_state()
	var foe_hurt = foe.is_in_hurt_state()
	if ai_hurt:
		s -= 55.0
	if foe_hurt:
		s += 65.0
		# Being hit while already being comboed is much worse than taking one hit.
		s += 6.0 * float(min(8, foe.combo_count))
	if ai.state_interruptable and not ai_hurt:
		s += 18.0
	if foe.state_interruptable and not foe_hurt:
		s -= 8.0

	# Resources. Worth having, not worth farming forever.
	s += 0.9 * float(ai.super_meter) - 0.9 * float(foe.super_meter)
	if ai.burst_meter >= 100.0 and ai.bursts_available > 0:
		s += 10.0
	if foe.burst_meter >= 100.0 and foe.bursts_available > 0:
		s -= 8.0

	# Ground state: airborne with no air options left is a bad place to be in this game.
	if not ai.is_grounded():
		s -= 6.0
		if ai.air_movements_left <= 0:
			s -= 10.0
	if not foe.is_grounded():
		s += 4.0

	# Walls: being cornered removes options.
	var room = 0.0
	if is_instance_valid(game) and game.has_method("get_side_positions"):
		pass
	if ai.clipping_wall:
		s -= 14.0
	if foe.clipping_wall:
		s += 12.0
	return s


# ------------------------------------------------------------------ move list

# Every selectable move the fighter has right now, as {action, button, data, category}.
# Comes from the same ActionButtons the player uses, so modded characters work: whatever they
# registered as a move is on this list.
func available_moves(action_buttons):
	var out := []
	if not is_instance_valid(action_buttons):
		return out
	for category in action_buttons.button_category_containers:
		var container = action_buttons.button_category_containers[category]
		if not is_instance_valid(container):
			continue
		var live = container.get_node_or_null("%ButtonContainer")
		if not is_instance_valid(live):
			continue
		for button in container.get("category_buttons"):
			if not is_instance_valid(button) or not button.visible:
				continue
			# Only moves actually drawn in the grid belong here; the turn column buttons
			# (Continue, Undo, ...) are added to a category's list too.
			if button.get_parent() != live:
				continue
			if button.action_name == "":
				continue
			out.append({
				"action": button.action_name,
				"button": button,
				"data": button.get_data() if button.has_method("get_data") else null,
				"category": str(category),
			})
	return out


# Extra data for a move: its aim plot and the toggles that go with it, read from the same data
# node the player sees. Blind pick rules still apply - this is all information about the AI's
# own move, nothing about the opponent's.
func extra_for(action_buttons, move):
	var extra = {"DI": Vector2.ZERO, "reverse": false, "feint": false, "prediction": -1}
	if not is_instance_valid(action_buttons):
		return extra
	var di = action_buttons.get_node_or_null("%DI")
	if is_instance_valid(di) and di.has_method("get_data"):
		extra["DI"] = di.get_data()
	var rev = action_buttons.get_node_or_null("%ReverseButton")
	if is_instance_valid(rev) and not rev.disabled:
		extra["reverse"] = bool(rev.pressed)
	var feint = action_buttons.get_node_or_null("%FeintButton")
	if is_instance_valid(feint) and not feint.disabled:
		extra["feint"] = bool(feint.pressed)
	return extra


# A rough idea of what a move is going to do, used to break ties and to aim.
func move_hint(move):
	var name = str(move.get("action", "")).to_lower()
	var h = 0.0
	if name.find("parry") >= 0 or name.find("block") >= 0:
		h += 4.0
	if name.find("burst") >= 0:
		h += 2.0
	if name.find("dash") >= 0 or name.find("step") >= 0 or name.find("jump") >= 0:
		h += 1.0
	if name == "wait" or name == "continue":
		h -= 1.0
	return h
