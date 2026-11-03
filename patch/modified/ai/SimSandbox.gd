extends Reference
# Offline-recovery addition: sandbox simulation for the CPU opponent.
#
# One sandbox = one instanced copy of Game.tscn with is_ghost set, which is the same trick the
# game already uses for its prediction ghost: a full match with no rendering and no input of its
# own. The live match's state is poured in with copy_to(), a move is queued for one or both
# sides, and the copy is ticked until the turn is over. Whatever is left is scored.
#
# The sim only ever queues the moves it is asked to queue. It is never told the player's move,
# because in this game both sides pick blind - the AI choosing with knowledge of the opponent's
# pick would not be playing the same game.

const GameScene := preload("res://Game.tscn")

var scene_tree: SceneTree = null
var viewport: Viewport = null

# One reusable instance: creating a Game scene per candidate is far too expensive.
var sandbox = null
var ready_for_use := false


func _init(tree: SceneTree):
	scene_tree = tree


func ensure_sandbox():
	if is_instance_valid(sandbox) and ready_for_use:
		return sandbox
	# The game already runs a ghost copy of the match inside a ViewportContainer/Viewport pair,
	# so the same rig is known to work here: a plain Viewport added to the tree, no rendering.
	var vp = Viewport.new()
	vp.usage = Viewport.USAGE_2D
	vp.size = Vector2(320, 180)
	vp.render_target_update_mode = Viewport.UPDATE_DISABLED
	vp.own_world = false
	vp.handle_input_locally = false
	scene_tree.root.add_child(vp)
	viewport = vp
	sandbox = GameScene.instance()
	sandbox.is_ghost = true
	vp.add_child(sandbox)
	# Ghosts run on their own timer; the sim drives ticks by hand instead.
	sandbox.set_physics_process(false)
	sandbox.set_process(false)
	ready_for_use = true
	return sandbox


# Drop the live match into the sandbox and clear whatever the last simulation left behind.
func load_state(live_game, match_data):
	var sb = ensure_sandbox()
	if not is_instance_valid(sb) or not is_instance_valid(live_game):
		return false
	if not live_game.game_started:
		return false
	if not sb.game_started:
		sb.start_game(true, match_data)
		if not sb.game_started:
			return false
		# A ghost only starts once its start timer has run; the sandbox is ticked by hand, so
		# make sure it never sits waiting on that timer.
		sb.get_node("GhostStartTimer").stop()
	live_game.copy_to(sb)
	sb.game_paused = false
	sb.game_finished = false
	sb.forfeit_player = null
	sb.undoing = false
	sb.super_freeze_ticks = 0
	sb.quitter_focus = false
	for p in [sb.p1, sb.p2]:
		if not is_instance_valid(p):
			return false
		p.queued_action = null
		p.queued_data = null
		p.queued_extra = null
	return true


# Queue an action for one side without telling the fighter it has been selected from the menu:
# on_action_selected() fires signals the live game listens to, and the sandbox is not the live
# game, but keeping it quiet also keeps the state honest.
func queue(player, action, data, extra):
	if not is_instance_valid(player):
		return
	player.queued_action = action
	player.queued_data = data
	player.queued_extra = extra


# Tick until the turn resolves (both fighters can act again) or the budget runs out.
# Returns the number of ticks simulated.
func resolve(max_ticks = 900, deadline_ms = 0):
	var sb = sandbox
	if not is_instance_valid(sb):
		return 0
	var ticks = 0
	# The sandbox is already sitting on an actionable state, so is_waiting_on_player() is true at
	# the start. One tick consumes the queued actions; after that we wait for both sides to be
	# interruptable again, exactly like the live game's turn loop.
	sb.tick()
	ticks += 1
	while ticks < max_ticks:
		if is_instance_valid(sb) and sb.game_finished:
			break
		if is_instance_valid(sb.p1) and is_instance_valid(sb.p2):
			if sb.p1.state_interruptable and sb.p2.state_interruptable:
				break
		sb.tick()
		ticks += 1
		if deadline_ms > 0 and ticks % 60 == 0:
			if Time.get_ticks_msec() > deadline_ms:
				break
	return ticks


# Score what the sandbox ended up with, from one side's point of view.
func score(brain, ai_id):
	var sb = sandbox
	if not is_instance_valid(sb):
		return -INF
	var ai = sb.get_player(ai_id)
	var foe = sb.get_player(3 - ai_id)
	if not (is_instance_valid(ai) and is_instance_valid(foe)):
		return -INF
	var s = brain.score_state(ai, foe, sb)
	# A match that finished inside the simulation is decisive.
	if sb.game_finished:
		if ai.hp <= 0:
			s -= 4000.0
		elif foe.hp <= 0:
			s += 4000.0
	return s


func free_sandbox():
	if is_instance_valid(sandbox):
		sandbox.queue_free()
	sandbox = null
	ready_for_use = false
	if is_instance_valid(viewport):
		viewport.queue_free()
	viewport = null
