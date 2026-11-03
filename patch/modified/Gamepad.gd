extends Node

# Offline-recovery addition: controller / gamepad support.
#
# The game was built around a mouse: menus use hover states, the move bar is a grid of
# hover-highlighted toggle buttons, DI and move aim are drag widgets, and character select is a
# wall of clickable cards. Focus navigation alone cannot reach any of that, so this does two
# things:
#
#   1. Direct navigation where the screen has a natural order (menus, character select, the move
#      grid, option rows). D-pad moves, A accepts, B backs out.
#   2. A virtual cursor for everything else. The right stick moves a cursor; A clicks. It snaps
#      to the widget the game is asking for: over the move-data panel while a move is selected,
#      over the DI wheel while you are being hit and DI matters, back to centre when aiming.
#      That is what turns "the pad sort of works" into "the pad plays the game".
#
# The cursor is not a separate input path: A synthesises a real left click at the cursor
# position, so it goes through exactly the same code a mouse click does.
#
# Layout (standard console conventions):
#   D-pad ............... menus, move grid, option rows
#   Left stick .......... same as d-pad, plus adjusts sliders
#   Right stick ......... virtual cursor / aim / DI
#   A ................... accept, select, lock in, click
#   B ................... back, clear, close
#   X ................... feint
#   Y ................... reverse facing
#   LB / RB ............. previous / next category (menus: previous / next tab)
#   LT .................. prediction (afterimage)
#   RT .................. hold to lock the cursor into an aim widget
#   Start ............... pause / resume
#   Back ................ help
#
# Mouse and keyboard are untouched. The pad takes over when it is used and hands control back the
# moment a mouse button or key is pressed, or the mouse moves after a pause.

const DEADZONE := 0.45
const REPEAT_DELAY := 0.34
const REPEAT_INTERVAL := 0.10
const CURSOR_SPEED := 1150.0
const CURSOR_SPEED_SLOW := 260.0
const STICK_CURVE := 1.9
# Full-stick aim travel across the whole widget, in seconds. Slow mode (Y held) is for
# fine adjustment; these are per-second so a slow machine behaves the same as a fast one.
const AIM_SECONDS_FULL := 0.85
const AIM_SECONDS_SLOW := 2.2
# Ignore mouse motion for this long after the pad was used, so our own cursor warps do not look
# like the player reaching for the mouse.
# Analogue triggers rest between 0 and -1, so a fraction of full travel is plenty.
const TRIGGER_PRESS := 0.55
# Tab strips are about 11 px tall here; clamped against the panel so an odd theme cannot put the
# cursor down in the page body.
const TAB_STRIP_HEIGHT := 12.0
const PAD_GRACE_MS := 500

const MODE_MOUSE := "mouse"
const MODE_GAMEPAD := "gamepad"


# Overlays that take over the screen; the topmost visible one owns navigation.
const OVERLAYS := [
	"OldVersionConfirmDialog",
	"MissingCharConfirmDialog",
	"ModWarningWindow",
	"NagWindow",
	"ReplayWindow",
	"Credits",
	"OptionsContainer",
	"PostGameButtons",
	"PausePanel",
	"MainMenu",
]

const GAME_OVERLAYS := ["PausePanel", "OptionsContainer", "ReplayWindow", "Credits", "PostGameButtons"]

# Overlays that live inside GameUI rather than directly under UILayer. The pause panel is one:
# it is a child of GameUI, which is why every lookup that only walked UILayer missed it.
const GAME_UI_OVERLAYS := ["PausePanel"]

var _trigger_axis_held := -1
# Which menu tab the pad has actually committed to. -1 until A is pressed on a tab name.
var _tab_focus = -1
var _tab_panel = null
var _tab_trigger_ms := 0
var mode := MODE_MOUSE
var active_device := 0

var _dir_lock := Vector2.ZERO
var _dir_time := 0.0
var _next_repeat := 0.0
var _last_pad_ms := 0

var _cursor := Vector2(320, 180)
var _cursor_dirty := true
var _overlay: Control = null
var _over_hot := false

# Where the d-pad stands in the move bar: "category" (the row of categories), "move" (the
# moves of the open category) or "turn" (the lock-in / free / flip / undo column).
var _focus := "move"
var _focus_cat := ""
var _turn_slot := 0
var _turn_live := false
var _turn_key := ""
var _pad_cancel_ms := 0

# The widget the right stick is aiming at, and the game entity that asked for it.
var _parked_for = null
var _aim_target = null
var _aim_owner = null
var _stick_was_idle := true


func _ready():
	pause_mode = Node.PAUSE_MODE_PROCESS
	_make_cursor_overlay()


# ------------------------------------------------------------------ device tracking

func _input(event):
	if event is InputEventJoypadButton:
		if event.pressed:
			_last_pad_ms = OS.get_ticks_msec()
			_pad_cancel_ms = OS.get_ticks_msec() if event.button_index == JOY_XBOX_B else _pad_cancel_ms
			if event.device != active_device:
				active_device = event.device
			_set_mode(MODE_GAMEPAD)
			if _game_button(event.button_index):
				get_tree().set_input_as_handled()
			elif _menu_bumper(event.button_index):
				get_tree().set_input_as_handled()
			elif event.button_index == JOY_XBOX_A and _menu_confirm():
				# A on a tab name commits to that tab. Checked before the global button
				# handler below, which in a menu only feeds ui_accept to whatever has focus.
				get_tree().set_input_as_handled()
			elif event.button_index == JOY_XBOX_B and _handle_cancel():
				# B backs out of character select and of any open panel. Handled here rather
				# than by polling ui_cancel, which does not fire reliably for every pad.
				get_tree().set_input_as_handled()
		return
	if event is InputEventJoypadMotion:
		if abs(event.axis_value) >= DEADZONE:
			_last_pad_ms = OS.get_ticks_msec()
			if event.device != active_device:
				active_device = event.device
			_set_mode(MODE_GAMEPAD)
		# Most pads report the triggers as axes, not buttons, so the tab triggers are read
		# here as well. Without this, RT / LT would do nothing on anything but a pad that
		# exposes them as JOY_L2 / JOY_R2.
		var tab_btn = _axis_trigger(event.axis, event.axis_value)
		if tab_btn >= 0:
			# In a match the triggers walk the bar (and reach the Lock In column from either
			# side); in a menu they change tab. One press, one meaning, per context.
			if is_game_context() and _game_button(tab_btn):
				get_tree().set_input_as_handled()
			elif _menu_bumper(tab_btn):
				get_tree().set_input_as_handled()
		return

	if event is InputEventMouseMotion:
		# Our own warps and our own synthetic clicks both generate motion events. Only a real
		# reach for the mouse should hand control back: the pad must have been quiet for a while,
		# and the pointer must have actually moved somewhere we did not put it.
		if mode == MODE_GAMEPAD and OS.get_ticks_msec() - _last_pad_ms > PAD_GRACE_MS:
			if event.relative.length() > 3.0 and not (event.position - _cursor).length() < 6.0:
				_set_mode(MODE_MOUSE)
		return
	if event is InputEventMouseButton and event.pressed:
		_set_mode(MODE_MOUSE)
		return
	if event is InputEventKey and event.pressed and not event.echo:
		_set_mode(MODE_MOUSE)
		return
	if event is InputEventScreenTouch and event.pressed:
		_set_mode(MODE_MOUSE)


func _set_mode(new_mode):
	if mode == new_mode:
		return
	mode = new_mode
	_dir_lock = Vector2.ZERO
	_dir_time = 0.0
	_aim_target = null
	if mode == MODE_GAMEPAD:
		Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)
		_set_cursor_visible(true)
		_snap_cursor()
		focus_first()
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		_set_cursor_visible(false)
		# leave the pointer where the pad left it
		warp_mouse(_clamp_cursor(_cursor))
	_refresh_help()


func _process(delta):
	if mode != MODE_GAMEPAD:
		return
	# Opening a tabbed panel puts the pad on its tab row rather than inside a page: the tab is
	# a decision, so nothing on a page can be reached until A has picked one.
	_arm_tab_row()
	# Godot 3 never releases focus when a panel is hidden, so focus can be sitting on a
	# button behind the one on screen. Checked here rather than only in the navigation
	# branch, so it also happens while the player is not touching the d-pad.
	var owner = focus_owner()
	if owner != null and is_instance_valid(owner) and not _in_scope(owner):
		focus_first()
	_update_cursor(delta)
	if is_game_context() and not _menu_blocking():
		_game_process(delta)
	else:
		_menu_process(delta)
	# Redraw last, so the highlight and the cursor reflect wherever focus ended up this frame
	# even when the player is not touching anything. In a menu the cursor is re-parked on the
	# focused control each frame: panels move as they lay themselves out, and a crosshair left
	# where a button used to be reads as broken.
	if not is_game_context():
		_snap_cursor()
	elif _overlay.visible:
		_overlay.update()


# ------------------------------------------------------------------ contexts

func _scene():
	var scene = get_tree().current_scene
	return scene if is_instance_valid(scene) else null


func _ui():
	var scene = _scene()
	if scene == null:
		return null
	return scene.get_node_or_null("UILayer")


# A match is on screen when the in-game UI layer is visible. The action bar exists in the scene
# at all times, so its presence must not be used as the test.
func is_game_context():
	var ui = _ui()
	if not is_instance_valid(ui):
		return false
	if is_charselect_open():
		return false
	var game_ui = ui.get_node_or_null("GameUI")
	if not is_instance_valid(game_ui):
		return false
	return game_ui.visible


func is_charselect_open():
	var ui = _ui()
	if not is_instance_valid(ui):
		return false
	var cs = ui.get_node_or_null("CharacterSelect")
	if not is_instance_valid(cs):
		return false
	return cs.visible


func _action_buttons():
	var scene = _scene()
	if scene == null:
		return null
	var p1 = scene.get_node_or_null("UILayer/GameUI/BottomBar/ActionButtons/VBoxContainer/P1ActionButtons")
	var p2 = scene.get_node_or_null("UILayer/GameUI/BottomBar/ActionButtons/VBoxContainer2/P2ActionButtons")
	# Two players on one machine: the acting panel is the visible one. In a normal singleplayer
	# match P2's panel is never shown, so this collapses to P1.
	if is_instance_valid(p2) and is_instance_valid(p1):
		if p2.visible and not p1.visible:
			return p2
	return p1


# Topmost visible overlay = the last matching child of UILayer, because later siblings draw on
# top. MainMenu stays visible behind Options/Credits, so list order would pick the wrong one.
func visible_overlay():
	var ui = _ui()
	if not is_instance_valid(ui):
		return null
	var found = null
	# Walk in draw order, so the thing drawn last (on top) wins. GameUI is walked in place
	# because the pause panel sits inside it.
	for child in ui.get_children():
		if child is Control and child.visible and str(child.name) in OVERLAYS:
			found = child
		elif is_instance_valid(child) and str(child.name) == "GameUI" and child.visible:
			for inner in child.get_children():
				if inner is Control and inner.visible and str(inner.name) in GAME_UI_OVERLAYS:
					found = inner
	return found


func _menu_blocking():
	if is_charselect_open():
		return false
	var overlay = visible_overlay()
	if overlay == null:
		return false
	return str(overlay.name) in GAME_OVERLAYS


# ------------------------------------------------------------------ menus

func focus_scope():
	var overlay = visible_overlay()
	if overlay != null:
		return overlay
	var ui = _ui()
	if not is_instance_valid(ui):
		return null
	if is_charselect_open():
		return ui.get_node_or_null("CharacterSelect")
	if is_game_context():
		var game_ui = ui.get_node_or_null("GameUI")
		if is_instance_valid(game_ui):
			return game_ui
	return ui.get_node_or_null("MainMenu")


func first_focusable():
	if _on_tab_row(_open_tabs()):
		# The panel is waiting for a tab to be picked: there is nothing to focus yet.
		return null
	var candidates = _nav_candidates()
	if candidates.size() > 0:
		return candidates[0]
	var scope = focus_scope()
	if not is_instance_valid(scope):
		return null
	return _first_button(scope)


func _first_button(node):
	if node is CanvasItem and not node.is_visible_in_tree():
		return null
	if node is BaseButton:
		return node
	for child in node.get_children():
		var found = _first_button(child)
		if found != null:
			return found
	return null


func focus_owner():
	var scope = focus_scope()
	if not is_instance_valid(scope):
		return null
	return scope.get_focus_owner()


func _in_scope(control):
	var scope = focus_scope()
	if not is_instance_valid(scope):
		return false
	var n = control
	while is_instance_valid(n):
		if n == scope:
			# Inside the panel is not enough when the panel is tabbed: focus on a hidden page,
			# or on the buttons under the tabs, would both pass that test and then the d-pad
			# would walk things the player cannot see.
			var tabs = _find_tabs(scope)
			if tabs == null:
				return true
			if _on_tab_row(tabs):
				# The panel is waiting for a tab to be picked: nothing behind the tab row is
				# in scope, including the page that happens to be showing.
				return false
			if _page_of(tabs, control) == null:
				return _first_page_has_no_controls(tabs)
			return _in_page(tabs, control)
		n = n.get_parent()
	return false


# A page with nothing to walk (the Pad page is plain text) leaves focus stuck on whatever the
# player was on before the tab change; that is fine, and the d-pad scrolls instead.
func _first_page_has_no_controls(tabs):
	var page = _tab_page(tabs)
	if not is_instance_valid(page):
		return false
	return _all_buttons(page, []).size() == 0


# ------------------------------------------------------------------ menu tab selection
#
# A tabbed panel opens with the tabs themselves as the only thing the pad can reach. A picks
# one, and only then does the d-pad move into the page. Changing tab (triggers or left / right)
# drops back to the tab row, so a page is never live while you are looking at another one.

# Is the pad standing on a tab name rather than on a page control?
func _on_tab_row(tabs):
	if not is_instance_valid(tabs):
		return false
	if str(tabs.get_meta("pad_tab_open", "")) != "row":
		return false
	return _tab_panel == tabs


func _open_tab_row(tabs):
	if not is_instance_valid(tabs):
		return false
	tabs.set_meta("pad_tab_open", "row")
	_tab_panel = tabs
	_tab_focus = tabs.current_tab
	_release_focus()
	_cursor_to_tab(tabs, _tab_focus)
	return true


# Called every frame in a menu: if the panel on screen is tabbed and the pad is not yet on its
# tab row, put it there once, and only once per panel.
func _arm_tab_row():
	var tabs = _open_tabs()
	if tabs == null:
		_tab_panel = null
		_tab_focus = -1
		return
	if _tab_panel == tabs and str(tabs.get_meta("pad_tab_open", "")) in ["row", "page"]:
		# Already decided for this panel: either waiting on a tab, or inside one.
		return
	_open_tab_row(tabs)


func _close_tab_row(tabs):
	if not is_instance_valid(tabs):
		return false
	tabs.set_meta("pad_tab_open", "page")
	return true


# Move the drawn cursor onto a tab name. Godot 3 does not expose per-tab rects, so the strip is
# measured from the container and the tabs are taken to share its width, which is how this
# project's theme draws them.
func _tab_rect(tabs, index):
	if not is_instance_valid(tabs):
		return Rect2()
	var count = tabs.get_tab_count()
	if count <= 0:
		return Rect2()
	var body = tabs.get_rect()
	var strip = min(body.size.y, TAB_STRIP_HEIGHT)
	if strip <= 1.0:
		return Rect2()
	var left = 0.0
	if tabs.has_method("has_constant") and tabs.has_constant("side_margin"):
		left = float(tabs.get_constant("side_margin"))
	var width = (body.size.x - left * 2.0) / float(count)
	if width <= 0:
		return Rect2()
	return Rect2(body.position.x + left + width * index, body.position.y, width, strip)


func _cursor_to_tab(tabs, index):
	var r = _tab_rect(tabs, index)
	if r.size.x <= 0:
		return
	_cursor = _clamp_cursor(r.position + r.size * 0.5)
	_cursor_dirty = true
	_sync_mouse()
	_render_cursor()


func _step_tab(tabs, step):
	var count = tabs.get_tab_count()
	if count <= 0:
		return false
	_tab_focus = int((_tab_focus + step + count) % count)
	if tabs.current_tab != _tab_focus:
		# The page follows the highlight, the same as clicking a tab name does.
		tabs.current_tab = _tab_focus
	_release_focus()
	_cursor_to_tab(tabs, _tab_focus)
	return true


# A on a tab name: that page becomes the live one and focus goes to its first control.
func _select_tab(tabs):
	if not is_instance_valid(tabs):
		return false
	var page = tabs.get_child(_tab_focus)
	if not is_instance_valid(page):
		return false
	# The Pad page is plain text: there is nothing to enter, so stay on the tab row rather
	# than implying a page is live when nothing on it can be reached.
	var first = _first_button(page)
	if not is_instance_valid(first):
		_cursor_to_tab(tabs, _tab_focus)
		return true
	_close_tab_row(tabs)
	_focus_into(tabs, _tab_focus)
	_focus_control(first)
	return true


# Back out of the page and stand on the tab row again.
func _leave_tab_page(tabs):
	if not is_instance_valid(tabs):
		return false
	if _tab_focus < 0 or _tab_panel != tabs:
		_tab_focus = tabs.current_tab
	_tab_panel = tabs
	tabs.set_meta("pad_tab_open", "row")
	_release_focus()
	_cursor_to_tab(tabs, _tab_focus)
	return true


# Focus has to be dropped, not merely moved, or `_active_control()` keeps handing the page's
# old control back to the d-pad and the tab row is never reachable.
func _release_focus():
	var owner = focus_owner()
	if owner != null and is_instance_valid(owner) and owner is Control:
		owner.release_focus()


func focus_first():
	var btn = first_focusable()
	if is_instance_valid(btn):
		btn.grab_focus()
		# Park the crosshair on what now has focus, so the pad's cursor is never left behind in
		# the middle of the screen while a panel is open.
		_snap_cursor()


func _menu_process(delta):
	# B backs out of character select and of any overlay that has a way out. The keyboard's
	# escape key goes through here; the pad's own button is handled where it arrives.
	if OS.get_ticks_msec() - _pad_cancel_ms > 200 \
			and Input.is_action_just_pressed("ui_cancel") and _handle_cancel():
		return

	var tabs_row = _open_tabs()
	if tabs_row != null and _on_tab_row(tabs_row):
		# Waiting on a tab: the d-pad drives the tab row and focus stays off the page.
		var tab_dir = _read_dir()
		if tab_dir != Vector2.ZERO and _dir_lock == Vector2.ZERO:
			_menu_step(null, tab_dir)
			_dir_lock = tab_dir
			_dir_time = 0.0
			_next_repeat = REPEAT_DELAY
			return
		if tab_dir == Vector2.ZERO:
			_dir_lock = Vector2.ZERO
		return

	var owner = _active_control()
	if owner == null:
		# Control.get_focus_owner() is viewport-wide, so opening Options from the main menu
		# leaves focus on a button behind the panel. Pull it into whatever is on top.
		focus_first()
		owner = _active_control()
	if owner == null:
		# Nothing focusable on this page (the pad / help pages are plain text): let the
		# d-pad scroll it instead.
		var scroll_dir = _read_dir()
		if scroll_dir != Vector2.ZERO and _scroll_scope(scroll_dir):
			pass
		_release_dir()
		return

	var dir = _read_dir()
	if dir == Vector2.ZERO:
		_release_dir()
		return
	if _dir_lock == Vector2.ZERO:
		_menu_step(owner, dir)
		_dir_lock = dir
		_dir_time = 0.0
		_next_repeat = REPEAT_DELAY
		return
	_dir_time += delta
	if _dir_time > 1.0:
		if dir != _dir_lock:
			_menu_step(owner, dir)
			_dir_lock = dir
			_next_repeat = REPEAT_DELAY
			return
		_next_repeat -= delta
		while _next_repeat <= 0.0:
			owner = focus_owner()
			if owner == null:
				return
			_menu_step(owner, _dir_lock)
			_next_repeat += REPEAT_INTERVAL


func _release_dir():
	_dir_lock = Vector2.ZERO
	_dir_time = 0.0


# Directional navigation done geometrically instead of trusting the focus chain. Godot's
# built-in chain follows tree order, which on a screen like character select jumps from the
# character wall straight into the rules toggles and back. Picking the nearest control in the
# direction the player pressed is what a console UI does.
# Scroll the panel under the focus. Used when a page has no controls to walk, and as a
# fallback when the d-pad is pushed past the last control in that direction.
func _scroll_scope(dir):
	var scope = focus_scope()
	if not is_instance_valid(scope):
		return false
	var scroll = _find_scroll(scope)
	if not is_instance_valid(scroll):
		return false
	var before = scroll.scroll_vertical
	scroll.scroll_vertical = int(before + (dir.y * 40))
	if scroll.scroll_vertical != before:
		return true
	var hbefore = scroll.scroll_horizontal
	scroll.scroll_horizontal = int(hbefore + (dir.x * 40))
	return scroll.scroll_horizontal != hbefore


func _find_scroll(node):
	if node is ScrollContainer:
		return node
	for child in node.get_children():
		if child is CanvasItem and not child.is_visible_in_tree():
			continue
		var found = _find_scroll(child)
		if found != null:
			return found
	return null


func _menu_step(from, dir):
	var tabs = _open_tabs()
	if tabs != null and _on_tab_row(tabs):
		# On the tab row left / right move between tab names and down is the same as A. There
		# is nothing above the tabs, so up keeps you on them.
		if abs(dir.x) > 0.5:
			_step_tab(tabs, 1 if dir.x > 0 else -1)
		elif dir.y > 0:
			_select_tab(tabs)
		return
	if _adjust_slider(from, dir):
		return
	_menu_focus_nearest(from, dir)


# The tab container of the panel on screen, if it has one.
func _open_tabs():
	var scope = focus_scope()
	if not is_instance_valid(scope):
		return null
	return _find_tabs(scope)


func _menu_focus_nearest(from, dir):
	var candidates = _nav_candidates()
	# `from` can be a control that was freed between the frame that chose it and this one - a
	# panel closing mid-repeat is enough. Reading a rect off a dead instance is the crash that
	# `best.grab_focus()` used to be, one line earlier.
	var origin = _rect_center(from)
	if origin == null:
		origin = _scope_origin()
	var best = null
	var best_score = INF
	for b in candidates:
		if b == from:
			continue
		if not _can_focus(b):
			continue
		var r = b.get_global_rect()
		if r.size.x <= 0 or r.size.y <= 0:
			continue
		var p = r.position + r.size * 0.5
		var d = p - origin
		var along = d.dot(dir)
		if along <= 4.0:
			continue
		var across = abs(d.x * - dir.y + d.y * dir.x)
		# prefer what is straight ahead; punish sideways drift hard
		var score = along + across * 2.4
		if score < best_score:
			best_score = score
			best = b
	if best == null:
		# Nothing further that way: scroll rather than ignore the press - but never scroll a
		# panel with no controls on it, because that is how you get stuck.
		_scroll_scope(dir)
		return
	if not _focus_control(best):
		return


# Is this safe to grab focus on right now? A control that has been freed, hidden or switched
# to FOCUS_NONE between two frames must never reach grab_focus().
func _can_focus(control):
	if control == null or not is_instance_valid(control):
		return false
	if not (control is Control):
		return false
	var c = control as Control
	if c.focus_mode == Control.FOCUS_NONE:
		return false
	if not c.is_visible_in_tree():
		return false
	return true


# Focus + move the drawn cursor in one place, so every caller gets the same guards.
func _focus_control(control):
	if not _can_focus(control):
		return false
	control.grab_focus()
	var r = control.get_global_rect()
	if r.size.x > 0:
		_cursor = _clamp_cursor(r.position + r.size * 0.5)
		_cursor_dirty = true
		_sync_mouse()
		_render_cursor()
	return true


func _rect_center(control):
	if not (control is Control) or not is_instance_valid(control):
		return null
	var r = control.get_global_rect()
	if r.size.x <= 0 or r.size.y <= 0:
		return null
	return r.position + r.size * 0.5


# Where to measure "which way is that" from when there is nothing focused yet.
func _scope_origin():
	var scope = focus_scope()
	if scope is Control and is_instance_valid(scope):
		var r = scope.get_global_rect()
		return r.position + r.size * 0.5
	return Vector2.ZERO


# Sliders and spin rows take the direction as "change the value" rather than "move away".
func _adjust_slider(control, dir):
	if not (control is Range):
		return false
	if abs(dir.x) < 0.5:
		return false
	var rng = control
	var step = (rng.max_value - rng.min_value) / 20.0
	if rng.step > 0:
		step = max(step, rng.step)
	rng.value = clamp(rng.value + step * (1 if dir.x > 0 else - 1), rng.min_value, rng.max_value)
	if rng.has_signal("value_changed"):
		rng.emit_signal("value_changed", rng.value)
	return true


# LB / RB change tab when the focused control lives in a TabContainer; that is the standard
# bumper behaviour in a tabbed options screen.
# Focus owner, but only if it is inside the panel that is actually on screen.
func _active_control():
	var owner = focus_owner()
	if owner == null or not is_instance_valid(owner):
		return null
	if not _in_scope(owner):
		return null
	return owner


# A trigger that arrives as an axis, converted to the button code the rest of the pad code
# speaks. Returns -1 when the axis is not a trigger or the trigger is still held.
func _axis_trigger(axis, value):
	if axis != JOY_ANALOG_L2 and axis != JOY_ANALOG_R2:
		return -1
	var down = value >= TRIGGER_PRESS
	var now = OS.get_ticks_msec()
	if not down:
		if axis == _trigger_axis_held:
			_trigger_axis_held = -1
		return -1
	if axis == _trigger_axis_held and now - _tab_trigger_ms < 180:
		return -1
	_trigger_axis_held = axis
	_tab_trigger_ms = now
	return JOY_L2 if axis == JOY_ANALOG_L2 else JOY_R2


# Tabs are the trigger buttons. LB / RB stay on "previous / next move category" in a match and
# are not used for tabs at all, so there is never a press that means two things.
func _menu_bumper(btn):
	if is_game_context():
		return false
	if btn != JOY_L2 and btn != JOY_R2:
		# A gamepad whose shoulder buttons report as 4/5 sent them as L2/R2 constants on some
		# drivers; accept both rather than leaving those pads unable to change tabs.
		if btn != JOY_L and btn != JOY_R:
			return false
	var tabs = _find_tabs(focus_scope())
	if tabs == null:
		return false
	return _switch_tab(tabs, btn)


# The page a control belongs to, or null if it is not inside any tab page.
func _page_of(tabs, control):
	if not (is_instance_valid(tabs) and is_instance_valid(control)):
		return null
	for i in range(tabs.get_tab_count()):
		var page = tabs.get_child(i)
		var n = control
		while is_instance_valid(n):
			if n == page:
				return page
			if n == tabs:
				break
			n = n.get_parent()
	return null


# The page the pad is currently allowed to walk. Anything outside it (the done / cache / mods
# buttons at the foot of the panel) is not a navigation target while a tab is open.
func _tab_page(tabs):
	if not is_instance_valid(tabs):
		return null
	return tabs.get_child(tabs.current_tab)


func _in_page(tabs, control):
	var page = _page_of(tabs, control)
	return page != null and page == _tab_page(tabs)


func _find_tabs(node):
	if node is TabContainer:
		return node
	for child in node.get_children():
		if child is CanvasItem and not child.is_visible_in_tree():
			continue
		var found = _find_tabs(child)
		if found != null:
			return found
	return null


func _switch_tab(tabs, btn):
	var forward = (btn == JOY_R or btn == JOY_R2)
	if forward:
		tabs.current_tab = (tabs.current_tab + 1) % tabs.get_tab_count()
	else:
		tabs.current_tab = (tabs.current_tab - 1 + tabs.get_tab_count()) % tabs.get_tab_count()
	# A different tab is a new choice: drop back to the tab row so A has to be pressed again.
	_tab_panel = tabs
	_tab_focus = tabs.current_tab
	_on_tab_row_force(tabs)
	_focus_into(tabs, tabs.current_tab)
	return true


func _on_tab_row_force(tabs):
	if is_instance_valid(tabs):
		tabs.set_meta("pad_tab_open", "row")


# After a tab change, move focus onto the new page, otherwise the next d-pad press would
# step relative to a control that is no longer on screen. A page with no controls of its own
# (the Pad page is plain text) leaves focus where it is and the d-pad scrolls instead.
func _focus_into(tabs, index):
	var page = tabs.get_child(index)
	if not is_instance_valid(page):
		return
	var btn = _first_button(page)
	if is_instance_valid(btn):
		btn.grab_focus()
		_cursor_to_control(btn)


func _cursor_to_control(btn):
	if not is_instance_valid(btn):
		return
	var r = btn.get_global_rect()
	if r.size.x > 0:
		_cursor = _clamp_cursor(r.position + r.size * 0.5)
		_cursor_dirty = true
		_sync_mouse()
		_render_cursor()


# A while the pad is standing on a menu's tab row. Returns true when it consumed the press.
func _menu_confirm():
	var tabs = _open_tabs()
	if tabs == null or not _on_tab_row(tabs):
		return false
	return _select_tab(tabs)


func _handle_cancel():
	if is_charselect_open():
		# Back to the menu, not out of the game: quitting here reloads the scene and lands on a
		# title screen that is already hidden.
		var cs = _ui().get_node_or_null("CharacterSelect")
		if is_instance_valid(cs) and cs.has_method("quit"):
			var ui = _ui()
			if is_instance_valid(ui) and ui.has_method("return_to_main_menu"):
				ui.return_to_main_menu()
			else:
				cs.quit()
			return true
		return false
	var overlay = visible_overlay()
	if overlay == null:
		return false
	if str(overlay.name) == "PausePanel":
		_ui().pause()
		return true
	# The options / credits / replay panels are all dismissed by hiding them, which is what
	# their own back buttons do.
	if str(overlay.name) in ["OptionsContainer", "Credits", "ReplayWindow", "PostGameButtons"]:
		# B steps out of a page to its tab row first, the same way B steps back a level in a
		# match. Only a second B closes the panel.
		var tabs = _open_tabs()
		if tabs != null and not _on_tab_row(tabs):
			return _leave_tab_page(tabs)
		overlay.hide()
		return true
	# Anything else: press the control that says back / close / resume.
	for btn in _all_buttons(overlay):
		var label = _button_label(btn).to_lower()
		if label.find("back") >= 0 or label.find("close") >= 0 or label.find("resume") >= 0:
			btn.emit_signal("pressed")
			return true
	return false


# What the d-pad is allowed to walk on this screen. Character select is the one screen where
# tree order and geometry both lie: the rules toggles sit above the character wall and the GO
# button far below it, so it gets an explicit order of character cards then GO.
func _nav_candidates():
	if is_charselect_open():
		var out = []
		var cs = _ui().get_node_or_null("CharacterSelect")
		if not is_instance_valid(cs):
			return out
		var container = cs.get_node_or_null("%CharacterButtonContainer")
		if is_instance_valid(container):
			for b in container.get_children():
				if b is BaseButton and b.is_visible_in_tree():
					out.append(b)
		var go = cs.get_node_or_null("%GoButton")
		if is_instance_valid(go) and go.is_visible_in_tree():
			out.append(go)
		return out
	var scope = focus_scope()
	if not is_instance_valid(scope):
		return []
	var out = _all_buttons(scope, [])
	# The Play panel is built in code and sits on top of the main menu, so the menu's own
	# buttons must drop out while it is open, or the pad walks things that are underneath it.
	# The play panel, and the multiplayer screen it opens, are their own scopes: the menu's own
	# buttons must drop out while either is up.
	for panel_name in ["MultiplayerPanel", "PlayPanel"]:
		var panel = _ui().get_node_or_null("MainMenu/" + panel_name) if is_instance_valid(_ui()) else null
		if is_instance_valid(panel) and panel.visible:
			return _all_buttons(panel, [])
	# A tabbed panel: the d-pad belongs to the page that is showing. Controls on other pages
	# are off limits, which is the whole point of having tabs.
	var tabs = _find_tabs(scope)
	if tabs != null:
		# Standing on the tab row: the tabs are the only targets, which is what makes the tab
		# a choice rather than something you can walk past.
		if _on_tab_row(tabs):
			return []
		var page = _tab_page(tabs)
		if is_instance_valid(page):
			var in_page = _all_buttons(page, [])
			# The done / delete cache / mods buttons live under the tabs, outside every page.
			# They stay reachable from the last page and from a page with no controls, so the
			# player can always get out, but they are not part of walking a normal page.
			for b in out:
				if not (b in in_page):
					in_page.append(b)
			if in_page.size() > 0:
				return in_page
	return out


func _play_panel():
	var ui = _ui()
	if not is_instance_valid(ui):
		return null
	return ui.get_node_or_null("MainMenu/PlayPanel")


func _multiplayer_panel():
	var ui = _ui()
	if not is_instance_valid(ui):
		return null
	return ui.get_node_or_null("MainMenu/MultiplayerPanel")


func _all_buttons(node, out = []):
	if node is CanvasItem and not node.is_visible_in_tree():
		return out
	# Disabled controls are still navigation targets: character select's GO button stays
	# disabled until a character is chosen, and the pad must be able to reach it and press it.
	if node is BaseButton:
		out.append(node)
	for child in node.get_children():
		_all_buttons(child, out)
	return out


func _button_label(btn):
	if btn is Button or btn is LinkButton:
		return str(btn.text)
	if btn.has_meta("label"):
		return str(btn.get_meta("label"))
	return ""


# ------------------------------------------------------------------ the game

func _game_process(delta):
	var ab = _action_buttons()
	if not is_instance_valid(ab):
		return

	# A turn the player can act on always starts on the category row: that is the first line of
	# the bar and the first decision, whether to pick a category or go straight to lock in.
	if _can_play(ab) and not _turn_live:
		_turn_live = true
		# A new turn is a new choice of tab, exactly like opening a menu panel.
		_start_turn_focus(ab)
		_bar_open_tab_row(ab)
	elif not _can_play(ab):
		_turn_live = false
		_turn_key = ""

	if _menu_blocking():
		_dir_lock = Vector2.ZERO
		_aim_target = null
		return

	# Keep the cursor parked on whatever the game is currently asking about.
	_auto_target(ab)

	if not _can_play(ab):
		_dir_lock = Vector2.ZERO
		return

	var dir = _read_dir()
	if dir == Vector2.ZERO:
		_dir_lock = Vector2.ZERO
		return

	# While the cursor is in an aim widget the d-pad should not also move the selection:
	# the player is aiming, not browsing.
	if is_instance_valid(_aim_target):
		return

	if _dir_lock == Vector2.ZERO:
		_grid_step(ab, dir)
		_dir_lock = dir
		_dir_time = 0.0
		_next_repeat = REPEAT_DELAY
		return

	_dir_time += delta
	if _dir_time > 1.2:
		if dir != _dir_lock:
			_grid_step(ab, dir)
			_dir_lock = dir
			_next_repeat = REPEAT_DELAY
			return
		_next_repeat -= delta
		while _next_repeat <= 0.0:
			_grid_step(ab, _dir_lock)
			_next_repeat += REPEAT_INTERVAL


func _can_play(ab):
	if not bool(ab.get("active")):
		return false
	if not ab.visible:
		return false
	var n = ab.get_parent()
	while is_instance_valid(n) and n.name != "GameUI":
		n = n.get_parent()
	if is_instance_valid(n) and not n.visible:
		return false
	return true


func _read_dir():
	var x = 0.0
	var y = 0.0
	if Input.is_joy_button_pressed(active_device, JOY_DPAD_LEFT) \
			or Input.get_joy_axis(active_device, JOY_AXIS_0) < - DEADZONE:
		x = - 1.0
	elif Input.is_joy_button_pressed(active_device, JOY_DPAD_RIGHT) \
			or Input.get_joy_axis(active_device, JOY_AXIS_0) > DEADZONE:
		x = 1.0
	if Input.is_joy_button_pressed(active_device, JOY_DPAD_UP) \
			or Input.get_joy_axis(active_device, JOY_AXIS_1) < - DEADZONE:
		y = - 1.0
	elif Input.is_joy_button_pressed(active_device, JOY_DPAD_DOWN) \
			or Input.get_joy_axis(active_device, JOY_AXIS_1) > DEADZONE:
		y = 1.0
	return Vector2(x, y)


func _right_stick():
	var v = Vector2(
		Input.get_joy_axis(active_device, JOY_AXIS_2),
		Input.get_joy_axis(active_device, JOY_AXIS_3))
	if v.length() < DEADZONE:
		return Vector2.ZERO
	v = v.normalized() * ((v.length() - DEADZONE) / (1.0 - DEADZONE))
	return v


func _grid_step(ab, dir):
	# Standing on the tab row: left / right and LB / RB change tab, down (or A) commits to the
	# tab that is showing. Nothing in a page is reachable until that happens.
	if _on_bar_tab_row():
		if abs(dir.x) > 0.5:
			_bar_step_tab(ab, 1 if dir.x > 0 else - 1)
		elif dir.y > 0:
			_bar_select_tab(ab)
		return
	var zone = _focus_zone(ab)
	if zone == "turn":
		if dir.y > 0:
			_step_turn_column(ab, 1)
		elif dir.y < 0:
			# Already on the first slot: up leaves the column, the same way left does.
			if _turn_slot <= 0:
				_focus_category(ab, _category_of(ab, ab.get("current_button")))
			else:
				_step_turn_column(ab, - 1)
		elif dir.x == - _turn_dir(ab):
			# Back from the column is the tab row: the moves of MOVEMENT are behind it.
			_focus_category(ab, _category_of(ab, ab.get("current_button")))
		return
	if zone == "category":
		if dir.x != 0:
			_cycle_category(ab, 1 if dir.x > 0 else - 1, false)
		elif dir.y < 0:
			# The moves stack above the category labels.
			_enter_first_move(ab)
		return
	# zone == "move"
	var current = ab.get("current_button")
	if not is_instance_valid(current) or not current.visible:
		_enter_first_move(ab)
		return
	if not _move_within_category(ab, current, dir):
		if dir.x == _turn_dir(ab) and _is_turn_category(ab) and _enter_turn_column(ab, 0):
			# Off the far end of MOVEMENT's moves is the turn column: Lock In and the rest are
			# the last cells of this tab, not cells of a tab of their own.
			return
		if dir.x != 0 or dir.y > 0:
			# Off any other edge of the grid: back to the tab row.
			_focus_category(ab, _category_of(ab, current))
		# Up off the top row has nothing above it, so it stays put.


func _is_turn_category(ab):
	var cat = _find_category_by_label(ab, _focus_cat)
	return is_instance_valid(cat) and _category_label_of(cat).to_lower() == TURN_CATEGORY


func _enter_last_move(ab):
	var cat = _find_category_by_label(ab, _focus_cat)
	if not is_instance_valid(cat):
		cat = _category_of(ab, ab.get("current_button"))
	var list = _category_button_list(cat)
	if list.size() == 0:
		_focus_category(ab, cat)
		return
	var btn = list[list.size() - 1]
	_focus = "move"
	ab.on_action_selected(btn.action_name, btn)
	_cursor_to_button(ab, btn)


func _select_first(ab):
	var cat = _first_category(ab)
	if cat == null:
		return
	var btn = _first_button_of(cat)
	if is_instance_valid(btn):
		ab.on_action_selected(btn.action_name, btn)


func _first_category(ab):
	var visible = _visible_categories(ab)
	return visible[0] if visible.size() > 0 else null


func _first_button_of(cat):
	var buttons = cat.get("category_buttons")
	if buttons == null:
		return null
	var live = cat.get_node_or_null("%ButtonContainer")
	for b in buttons:
		if is_instance_valid(b) and b.visible and b.get_parent() == live:
			return b
	for b in buttons:
		if is_instance_valid(b) and b.visible:
			return b
	return null


func _category_of(ab, button):
	var containers = ab.get("button_category_containers")
	if containers == null or not is_instance_valid(button):
		return null
	for key in containers:
		var c = containers[key]
		if not is_instance_valid(c):
			continue
		for b in c.category_buttons:
			if b == button:
				return c
	return null


# The moves of a category are laid out in a grid (three columns), so the d-pad follows the
# grid the player can see rather than the order the game happens to have stored them in.
func _category_button_list(cat):
	var list = []
	if not is_instance_valid(cat):
		return list
	var live = cat.get_node_or_null("%ButtonContainer")
	var all = cat.get("category_buttons")
	if all == null:
		return list
	for b in all:
		if is_instance_valid(b) and b.visible and b.get_parent() == live:
			list.append(b)
	if list.size() == 0:
		for b in all:
			if is_instance_valid(b) and b.visible:
				list.append(b)
	return list


# Is this button one of the moves drawn in the category's grid? The game also lists the turn
# column's buttons under a category (Continue is filed under Movement), and those must never be
# treated as a move.
func _is_grid_move(cat, btn):
	if not is_instance_valid(cat) or not is_instance_valid(btn) or not btn.visible:
		return false
	var live = cat.get_node_or_null("%ButtonContainer")
	return is_instance_valid(live) and btn.get_parent() == live


func _category_columns(cat, list):
	var cols = 3
	var bc = cat.get_node_or_null("%ButtonContainer") if is_instance_valid(cat) else null
	if is_instance_valid(bc) and bc.columns > 0:
		cols = bc.columns
	return max(1, min(cols, max(1, list.size())))


func _move_within_category(ab, current, dir):
	var cat = _category_of(ab, current)
	if not is_instance_valid(cat):
		return false
	var list = _category_button_list(cat)
	if list.size() == 0:
		return false
	var cols = _category_columns(cat, list)
	var idx = list.find(current)
	if idx < 0:
		idx = 0
	var col = idx % cols
	var target = idx
	if dir.y != 0:
		# Up and down move a whole row.
		target = idx + (cols * (1 if dir.y > 0 else - 1))
		# Down off the last row and up off the top row both stay put: moving between categories
		# is what the category row and LB / RB are for, and a surprise jump to another category
		# is exactly the kind of thing that makes a bar feel unpredictable.
		if target >= list.size():
			return false
		if target < 0:
			# Top row: there is nothing above this zone, the caller goes to the category row.
			return false
	elif dir.x != 0:
		# Left and right walk the row; at either end they leave the zone.
		if dir.x < 0 and col == 0:
			return false
		if dir.x > 0 and (col == cols - 1 or idx + 1 >= list.size()):
			return false
		target = idx + (1 if dir.x > 0 else - 1)
	if target == idx or target < 0 or target >= list.size():
		return false
	var nxt = list[target]
	if nxt != current:
		ab.on_action_selected(nxt.action_name, nxt)
		_focus = "move"
		_cursor_to_button(ab, nxt)
	return true


# ---------------------------------------------------------------- move bar tabs
#
# There is one row of tabs and it is the game's own category row: DEFENSE, SUPER, SPECIAL,
# ATTACK, MOVEMENT. The turn column (Lock In, Hold, Free, Flip, Undo) is not a second tab - it
# lives at the end of MOVEMENT, so there is exactly one bar and one way round it. LB / RB (and
# L2 / R2, and left / right on the tab row) change tab; A picks one; B steps back out to the tab
# row; another B is what deselects a move.

const TURN_CATEGORY := "movement"


func _on_bar_tab_row():
	return _focus == "tab"


func _bar_categories(ab):
	return _visible_categories(ab)


func _bar_tab_index(ab):
	var cats = _bar_categories(ab)
	var cat = _find_category_by_label(ab, _focus_cat)
	var idx = cats.find(cat) if is_instance_valid(cat) else -1
	return int(max(0, idx))


func _tab_rect_of(ab, cat):
	if not is_instance_valid(cat):
		return Rect2()
	var label = cat.get_node_or_null("%Label")
	var r = label.get_global_rect() if is_instance_valid(label) else cat.get_global_rect()
	return r


func _bar_cursor_to_tab(ab, cat):
	var r = _tab_rect_of(ab, cat)
	if r.size.x <= 0:
		return
	_cursor = _clamp_cursor(r.position + r.size * 0.5)
	_cursor_dirty = true
	_sync_mouse()
	_render_cursor()


# Stand on the tab row, with the highlight on the current tab.
# Triggers on the move bar. Right always moves towards the turn column, left away from it, so the
# column is reachable without leaving the tab you are on: right off the last category lands on
# Lock In, left off the last category steps back to the previous one. The tabs still change, they
# just do not change at the end of the bar any more.
func _trigger_bar(ab, step):
	if _on_bar_tab_row():
		var cats = _bar_categories(ab)
		if cats.size() == 0:
			return false
		var idx = _bar_tab_index(ab)
		var want = idx + step
		if want >= cats.size():
			return _enter_turn_column(ab, 0)
		if want < 0:
			return false
		return _bar_step_tab(ab, step)
	if _focus == "turn":
		# Walking the column, not jumping out of it: down one slot at a time, and up one slot
		# until there is nowhere left to go, at which point the trigger leaves the column the
		# way it came in.
		if step < 0 and _turn_slot <= 0:
			return _enter_last_move(ab)
		return _step_turn_column(ab, step)
	# Anywhere in a category's moves: right heads for the column, left goes to the tab row.
	if step > 0:
		if _is_turn_category(ab):
			return _enter_turn_column(ab, 0)
		return _bar_step_tab(ab, 1)
	_focus_category(ab, _category_of(ab, ab.get("current_button")))
	return true


func _bar_open_tab_row(ab):
	_focus = "tab"
	_turn_slot = 0
	var cat = _find_category_by_label(ab, _focus_cat)
	if not is_instance_valid(cat):
		cat = _first_category(ab)
		_focus_cat = _category_label_of(cat)
	_bar_cursor_to_tab(ab, cat)


func _bar_step_tab(ab, step):
	var cats = _bar_categories(ab)
	if cats.size() == 0:
		return false
	var idx = _bar_tab_index(ab)
	idx = int((idx + step + cats.size()) % cats.size())
	var cat = cats[idx]
	# Changing tab always lands on the tab row, whatever was focused before: the moves of the
	# tab that was open are not the moves of this one, and a pad left "in the grid" of a tab it
	# is no longer looking at is a pad that cannot move.
	_focus = "tab"
	_turn_slot = 0
	_focus_cat = _category_label_of(cat)
	_bar_cursor_to_tab(ab, cat)
	return true


# A on a tab: that category becomes the live one and the pad moves into its moves. MOVEMENT has
# the turn column immediately after its moves, so Lock In is one tab away, not one tab of its own.
func _bar_select_tab(ab):
	var cat = _find_category_by_label(ab, _focus_cat)
	if not is_instance_valid(cat):
		return false
	var current = ab.get("current_button")
	var keep = null
	if _is_grid_move(cat, current):
		keep = current
	var btn = keep if is_instance_valid(keep) else _first_button_of(cat)
	if not is_instance_valid(btn):
		return false
	_focus = "move"
	ab.on_action_selected(btn.action_name, btn)
	_cursor_to_button(ab, btn)
	return true


# ---------------------------------------------------------------- move bar zones

func _start_turn_focus(ab):
	_focus = "tab"
	_turn_slot = 0
	# Always the left edge of the bar. The game auto-picks a move of its own when a turn
	# begins, so following that would put the highlight in a different place every turn.
	var cat = _first_category(ab)
	_focus_cat = _category_label_of(cat)
	if is_instance_valid(cat):
		_cursor_to_button(ab, cat)

# Which of the three zones the pad is standing on: the category row, the moves of an open
# category, or the lock-in / free / flip / undo column.
func _focus_zone(ab):
	if _focus == "category" or _focus == "turn" or _focus == "move":
		return _focus
	return "move"


func _category_label_of(cat):
	if not is_instance_valid(cat):
		return ""
	return str(cat.label_text)


func _visible_categories(ab):
	var containers = ab.get("button_category_containers")
	var out = []
	if containers == null:
		return out
	for key in containers:
		var c = containers[key]
		if is_instance_valid(c) and c.visible and c.any_buttons_visible():
			out.append(c)
	# Left to right on screen, not dictionary order.
	out.sort_custom(self, "_cat_before")
	return out


func _cat_before(a, b):
	return a.get_global_rect().position.x < b.get_global_rect().position.x


func _focus_category(ab, cat):
	# The category labels are the tab row, so standing on one is standing on the tab row.
	_focus = "tab"
	_turn_slot = 0
	_focus_cat = _category_label_of(cat)
	_bar_cursor_to_tab(ab, cat)
	# current_button is left alone: it is what the game submits if the player locks in from
	# here, and the pressed move is what colours its category label.


# A on the category row opens the highlighted category and hands the stick to its moves.
func _open_category(ab):
	var cat = _find_category_by_label(ab, _focus_cat)
	if not is_instance_valid(cat):
		cat = _first_category(ab)
	if not is_instance_valid(cat):
		return
	var current = ab.get("current_button")
	var keep = null
	if _is_grid_move(cat, current):
		keep = current
	var btn = keep if is_instance_valid(keep) else _first_button_of(cat)
	if not is_instance_valid(btn):
		return
	_focus = "move"
	_focus_cat = _category_label_of(cat)
	ab.on_action_selected(btn.action_name, btn)
	_cursor_to_button(ab, btn)


# The turn column is drawn beside MOVEMENT - to its right for player 1, to its left for
# player 2, because that panel is mirrored. Work out which side rather than assuming.
func _turn_dir(ab):
	var tb = ab.get_node_or_null("%TurnButtons")
	var cat = _find_category_by_label(ab, _focus_cat)
	if not is_instance_valid(tb) or not is_instance_valid(cat):
		return 1
	return 1 if tb.get_global_rect().position.x >= cat.get_global_rect().position.x else - 1


func _find_category_by_label(ab, label):
	for c in _visible_categories(ab):
		if _category_label_of(c) == label:
			return c
	return null


func _enter_first_move(ab):
	var cat = _find_category_by_label(ab, _focus_cat)
	if not is_instance_valid(cat):
		cat = _first_category(ab)
	if not is_instance_valid(cat):
		return
	var current = ab.get("current_button")
	var btn = _first_button_of(cat)
	if _is_grid_move(cat, current):
		btn = current
	if not is_instance_valid(btn):
		return
	_focus = "move"
	ab.on_action_selected(btn.action_name, btn)
	_cursor_to_button(ab, btn)


func _cursor_to_button(ab, btn):
	if not is_instance_valid(btn):
		return
	var r = btn.get_global_rect()
	if r.size.x > 0:
		_cursor = _clamp_cursor(r.position + r.size * 0.5)
		_sync_mouse()
		_render_cursor()


# The lock-in column is part of the bar: down from a category lands on Lock In, and the rest of
# that column is reachable from there.
func _turn_column(ab):
	var out = []
	var tb = ab.get_node_or_null("%TurnButtons")
	if not is_instance_valid(tb):
		return out
	for key in ["%SelectButton", "%ContinueButton", "%FeintButton", "%ReverseButton", "%UndoButton", "%AutoButton"]:
		var b = ab.get_node_or_null(key)
		if is_instance_valid(b) and b.visible and b.is_visible_in_tree():
			out.append(b)
	return out


func _turn_index(ab):
	var column = _turn_column(ab)
	if column.size() == 0:
		return - 1
	return _turn_slot


func _focus_turn_column(ab):
	var column = _turn_column(ab)
	if column.size() == 0:
		return false
	_focus = "turn"
	_turn_slot = int(clamp(_turn_slot, 0, column.size() - 1))
	_cursor_to_button(ab, column[_turn_slot])
	return true


func _enter_turn_column(ab, slot):
	var old_slot = _turn_slot
	_turn_slot = slot
	if _focus_turn_column(ab):
		return true
	_turn_slot = old_slot
	return false


func _step_turn_column(ab, step):
	var column = _turn_column(ab)
	if column.size() == 0:
		return false
	_turn_slot = int(clamp(_turn_slot + step, 0, column.size() - 1))
	return _focus_turn_column(ab)


func _cycle_category(ab, step, select_move = true):
	var visible = _visible_categories(ab)
	if visible.size() == 0:
		return
	# Stepping follows the highlighted category, not the game's pressed move: browsing
	# categories must not be dragged back to whatever was last selected.
	var cat = _find_category_by_label(ab, _focus_cat)
	if not is_instance_valid(cat):
		cat = _category_of(ab, ab.get("current_button"))
	var idx = 0
	if cat != null:
		idx = visible.find(cat)
		if idx < 0:
			idx = 0
	idx = int(stepify(idx + step, 1))
	if idx >= visible.size():
		idx = 0
	if idx < 0:
		idx = visible.size() - 1
	var target_cat = visible[idx]
	_focus_cat = _category_label_of(target_cat)
	if not select_move:
		# Walking the category row only moves the highlight. A is what opens a category, so
		# nothing is selected and nothing is submitted while browsing.
		_cursor_to_button(ab, target_cat)
		return
	var btn = _first_button_of(target_cat)
	if is_instance_valid(btn):
		ab.on_action_selected(btn.action_name, btn)
		_cursor_to_button(ab, btn)


# ------------------------------------------------------------------ game buttons

func _game_button(btn):
	if not is_game_context():
		return false

	if _menu_blocking():
		# A panel is up. The menu button still has to close it, and B has to back out, or the
		# pad opens a menu it cannot leave.
		var panel = visible_overlay()
		match btn:
			JOY_START, JOY_SELECT:
				if is_instance_valid(panel) and str(panel.name) == "PausePanel":
					_ui().pause()
					return true
			JOY_XBOX_B:
				if _handle_cancel():
					return true
		return false

	var ab = _action_buttons()
	if not is_instance_valid(ab):
		return false

	if not _can_play(ab):
		match btn:
			JOY_START, JOY_SELECT:
				_ui().pause()
				return true
		return false

	match btn:
		JOY_XBOX_A:
			_confirm(ab)
			return true
		JOY_XBOX_B:
			_cancel(ab)
			return true
		JOY_XBOX_X:
			# X is the replay button: it does what R does from the keyboard, from inside a match.
			# Feint and Reverse were on X / Y, and feint moves to R3 so the pair the game's own
			# help text advertises (X faint, Y reverse) keeps working.
			_watch_replay()
			return true
		JOY_XBOX_Y:
			_toggle(ab, "%ReverseButton")
			return true
		JOY_L:
			if _on_bar_tab_row():
				_bar_step_tab(ab, - 1)
			else:
				_cycle_category(ab, - 1, false)
				_bar_open_tab_row(ab)
			return true
		JOY_R:
			if _on_bar_tab_row():
				_bar_step_tab(ab, 1)
			else:
				_cycle_category(ab, 1, false)
				_bar_open_tab_row(ab)
			return true
		JOY_L2:
			_trigger_bar(ab, - 1)
			return true
		JOY_R2:
			_trigger_bar(ab, 1)
			return true
		JOY_START, JOY_SELECT:
			# Both the start and the select button open the menu: which of them is the "three
			# lines" button differs between pads, and being able to reach the menu matters more
			# than the help overlay that select used to toggle.
			_ui().pause()
			return true
		JOY_R3:
			_toggle(ab, "%FeintButton")
			return true
		JOY_L3:
			# Zoom was on the stick clicks; feint takes one of them, so zoom-in moves to L2 with
			# compass-style camera control and zoom-out stays on L3.
			_zoom(- 1)
			return true
	return false


# Watch replay, the same thing R does: game.gd buffers a playback on the "playback" action. Sent
# as an action event rather than read directly so it goes through the game's own path, including
# its "not while resimulating, not on tick 0" guards.
func _watch_replay():
	var game = Global.current_game
	if not is_instance_valid(game):
		return
	var ev = InputEventAction.new()
	ev.action = "playback"
	ev.pressed = true
	Input.parse_input_event(ev)


# Camera zoom was mouse-wheel only. Clicking the sticks is the usual console mapping for it.
func _zoom(direction):
	var game = Global.current_game
	if not is_instance_valid(game):
		return
	if direction > 0:
		game.zoom_in()
	else:
		game.zoom_out()


# A does the obvious thing for where the cursor is: click there if there is a live control
# under it, otherwise lock in.
func _confirm(ab):
	if is_instance_valid(_aim_target):
		return
	if _on_bar_tab_row():
		_bar_select_tab(ab)
		return
	if _focus == "category":
		_open_category(ab)
		return
	if _cursor_over_control():
		_click_complete(BUTTON_LEFT)
		return
	ab._on_submit_pressed()


func _cancel(ab):
	if is_instance_valid(_aim_target):
		_aim_target = null
		_aim_owner = null
		_snap_cursor()
		return
	var current = ab.get("current_button")
	if not is_instance_valid(current):
		return
	if current.data_node and current.data_node.visible:
		current.data_node.hide()
		if current.container:
			current.container.hide_data_container()
		_snap_cursor()
		return
	# B steps back a level: moves or the turn column go to that category's tab, the tab row goes
	# to nothing selected. It never means "go to another tab" - that is what left / right and
	# LB / RB are for.
	if _focus == "move":
		_focus_category(ab, _category_of(ab, current))
		return
	if _focus == "turn":
		_bar_open_tab_row(ab)
		return
	if _focus != "tab":
		_bar_open_tab_row(ab)
		return
	current.set_pressed_no_signal(false)
	ab.set("current_button", null)
	ab.set("current_action", null)
	ab.send_ui_action()
	_snap_cursor()


func _toggle(ab, path):
	var btn = ab.get_node_or_null(path)
	if is_instance_valid(btn) and not btn.disabled:
		btn.pressed = not btn.pressed


func _toggle_prediction(ab):
	var cat = _category_of(ab, ab.get("current_button"))
	if cat == null:
		cat = _first_category(ab)
	if cat == null:
		return
	var btn = cat.get_node_or_null("VBoxContainer/CenterContainer/PredictButton")
	if is_instance_valid(btn) and btn.visible:
		btn.pressed = not btn.pressed


# ------------------------------------------------------------------ virtual cursor

func _make_cursor_overlay():
	var layer = CanvasLayer.new()
	layer.name = "GamepadCursor"
	layer.layer = 100
	layer.pause_mode = Node.PAUSE_MODE_PROCESS
	add_child(layer)
	_overlay = Control.new()
	_overlay.name = "Cursor"
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.set_anchors_preset(Control.PRESET_WIDE)
	_overlay.visible = false
	layer.add_child(_overlay)
	_overlay.connect("draw", self, "_draw_cursor")


func _set_cursor_visible(on):
	_overlay.visible = on
	_cursor_dirty = true


func _view_size():
	var scene = _scene()
	if scene == null:
		return Vector2(640, 360)
	return scene.get_viewport().get_visible_rect().size


func _clamp_cursor(pos):
	var size = _view_size()
	return Vector2(clamp(pos.x, 2, size.x - 2), clamp(pos.y, 2, size.y - 2))


func _update_cursor(delta):
	# Right stick drives the cursor, unless a widget has grabbed it as an aim stick.
	var stick = _right_stick()

	if stick == Vector2.ZERO:
		_stick_was_idle = true
	elif _stick_was_idle:
		_stick_was_idle = false
		if not is_instance_valid(_aim_target):
			_acquire_aim_target()

	var slow = Input.is_joy_button_pressed(active_device, JOY_XBOX_Y)
	if is_instance_valid(_aim_target):
		_aim_with(stick, delta, slow)
		return

	if stick != Vector2.ZERO:
		if _cursor_needs_aim_acquire():
			_acquire_aim_target()
			if is_instance_valid(_aim_target):
				_aim_with(stick, delta, slow)
				return
		var speed = CURSOR_SPEED_SLOW if slow else CURSOR_SPEED
		var mag = stick.length()
		var scaled = pow(mag, STICK_CURVE) * speed * delta
		_cursor = _clamp_cursor(_cursor + stick.normalized() * scaled)
		_cursor_dirty = true
		_sync_mouse()

	# Redraw every frame while the pad is in charge: the player is looking at this cursor, and
	# it sits over UI that can change under it.
	_render_cursor()


func _sync_mouse():
	warp_mouse(_cursor)


# The game renders 640x360 and is stretched to the window, so viewport coordinates and window
# coordinates are not the same. Everything here works in viewport space; the two conversions
# below are the only places that touch window space.
func _window_scale():
	var vp = _scene().get_viewport()
	var vp_size = Vector2(vp.size)
	if vp_size.x <= 0 or vp_size.y <= 0:
		return Vector2.ONE
	return Vector2(OS.window_size) / vp_size


func _to_window(pos):
	return pos * _window_scale()


# Godot 3 has no Input.warp_mouse; the viewport does it.
# Warping generates a mouse-motion event, which would otherwise look like the player
# reaching for the mouse and drop us straight back into mouse mode. Treat our own warp as
# pad activity so the grace window covers it.
func warp_mouse(pos):
	var scene = _scene()
	if is_instance_valid(scene):
		_last_pad_ms = OS.get_ticks_msec()
		scene.get_viewport().warp_mouse(pos)


func _render_cursor():
	_cursor_dirty = false
	_over_hot = _cursor_over_control()
	if _overlay.visible:
		_overlay.update()


# The bar needs to show what the d-pad has hold of, not just where the cursor is. The game only
# colours a category label once one of its moves is selected, so browsing would otherwise be
# invisible.
func _focus_rect():
	# A tabbed panel waiting on a tab: the highlight is the tab name, not the page under it.
	var tabs = _open_tabs()
	if tabs != null and _on_tab_row(tabs):
		var r = _tab_rect(tabs, _tab_focus if _tab_focus >= 0 else tabs.current_tab)
		if r.size.x > 0:
			return r
	# While a panel is up, the thing to highlight is the control that has focus.
	if _menu_blocking() or not is_game_context():
		var focused = _active_control()
		if is_instance_valid(focused):
			var fr = focused.get_global_rect()
			if fr.size.x > 0:
				return fr.grow(1.0)
		return null
	var ab = _action_buttons()
	if not is_instance_valid(ab) or not _can_play(ab):
		return null
	if _on_bar_tab_row():
		var cat = _find_category_by_label(ab, _focus_cat)
		if is_instance_valid(cat):
			var tr = _tab_rect_of(ab, cat)
			if tr.size.x > 0:
				return tr.grow(1.0)
		return null
	match _focus:
		"category":
			var cat = _find_category_by_label(ab, _focus_cat)
			if is_instance_valid(cat) and cat.visible:
				# The word itself, not the whole column: framing the moves too would say the
				# whole category is selected, which is exactly what browsing is not.
				var label = cat.get_node_or_null("%Label")
				var r = (label.get_global_rect() if is_instance_valid(label) else cat.get_global_rect())
				if r.size.x > 0 and r.size.y > 0:
					return r.grow(1.0)
			return null
		"turn":
			var column = _turn_column(ab)
			if _turn_slot >= 0 and _turn_slot < column.size():
				return column[_turn_slot].get_global_rect()
			return null
	var cur = ab.get("current_button")
	if is_instance_valid(cur) and cur.visible:
		return cur.get_global_rect()
	return null


func _draw_cursor():
	if _overlay == null:
		return
	# In a menu the focus box is the pointer: a crosshair drawn over a button label just makes
	# the label harder to read. The free cursor belongs to the match, where there is a stage to
	# aim at and no focus list.
	if not is_game_context():
		return
	# Highlight box for whatever the d-pad is on.
	var fr = _focus_rect()
	if fr != null and fr.size.x > 0:
		var pad = 2.0
		var box = Rect2(fr.position - Vector2(pad, pad), fr.size + Vector2(pad * 2, pad * 2))
		# The game draws at 640x360 and is upscaled, so a 1px outline turns into a hairline.
		# Fill plus a 2px border reads clearly at both scales.
		_overlay.draw_rect(box, Color(0.49, 0.83, 1.0, 0.20), true)
		_overlay.draw_rect(box, Color(0.49, 0.83, 1.0, 1.0), false, 2.0)

	var c = _cursor
	var col = Color(1, 1, 1, 0.95)
	var accent = Color("ffd34d") if _over_hot else Color("7fd3ff")
	# soft ring, crosshair and centre dot: readable over both dark panels and bright stages
	_overlay.draw_circle(c, 7.0, Color(0, 0, 0, 0.45))
	_overlay.draw_arc(c, 7.0, 0, TAU, 24, col, 1.5, true)
	_overlay.draw_line(c + Vector2( - 12, 0), c + Vector2( - 4, 0), col, 1.0)
	_overlay.draw_line(c + Vector2(4, 0), c + Vector2(12, 0), col, 1.0)
	_overlay.draw_line(c + Vector2(0, - 12), c + Vector2(0, - 4), col, 1.0)
	_overlay.draw_line(c + Vector2(0, 4), c + Vector2(0, 12), col, 1.0)
	_overlay.draw_circle(c, 1.8, accent)


# Is there a real control under the cursor that would take a click?
func _cursor_over_control():
	var scope = _control_scope()
	if not is_instance_valid(scope):
		return false
	return _hit_test(scope, _cursor)


func _control_scope():
	var overlay = visible_overlay()
	if overlay != null:
		return overlay
	var ui = _ui()
	if not is_instance_valid(ui):
		return null
	if is_charselect_open():
		return ui.get_node_or_null("CharacterSelect")
	var game_ui = ui.get_node_or_null("GameUI")
	if is_instance_valid(game_ui) and game_ui.visible:
		return game_ui
	return ui.get_node_or_null("MainMenu")


func _hit_test(node, point):
	if node is CanvasItem and not node.is_visible_in_tree():
		return false
	if node is Control and node.rect_clip_content and not node.get_global_rect().has_point(point):
		return false
	if node is BaseButton and not node.disabled:
		if node.get_global_rect().has_point(point):
			return true
	for child in node.get_children():
		if _hit_test(child, point):
			return true
	return false


# Click where the cursor is, through the normal input path. The event has to be in window
# coordinates: Godot rescales window input back into the stretched viewport, so sending the
# viewport position directly lands at half the distance on a 2x window.
func _click(button = BUTTON_LEFT, pressed = true):
	_last_pad_ms = OS.get_ticks_msec()
	var pos = _to_window(_cursor)
	var ev = InputEventMouseButton.new()
	ev.position = pos
	ev.global_position = pos
	ev.button_index = button
	ev.pressed = pressed
	if pressed:
		ev.button_mask = int(pow(2, button - 1))
	else:
		ev.button_mask = 0
	Input.parse_input_event(ev)


# Press and release, so anything listening for a completed click sees one.
func _click_complete(button = BUTTON_LEFT):
	_click(button, true)
	_click(button, false)


func _snap_cursor():
	var pos = _wanted_cursor_position()
	_cursor = _clamp_cursor(pos)
	_cursor_dirty = true
	if mode == MODE_GAMEPAD:
		_sync_mouse()
		_render_cursor()


# Where the cursor should sit when the player has not moved it: over the thing the game is
# currently asking about.
func _wanted_cursor_position():
	if not is_game_context():
		if is_charselect_open():
			var cont = _ui().get_node_or_null("CharacterSelect/%CharacterButtonContainer")
			if is_instance_valid(cont) and cont is Control:
				var cr = cont.get_global_rect()
				if cr.size.x > 0:
					return cr.position + cr.size * 0.5
		# In a menu the cursor sits on the control that has focus, not in the middle of the
		# screen: a crosshair parked on the logo says nothing about what A would press.
		var focused = _active_control()
		if is_instance_valid(focused) and focused is Control:
			var fr = focused.get_global_rect()
			if fr.size.x > 0:
				return fr.position + fr.size * 0.5
		var scope = _control_scope()
		if is_instance_valid(scope) and scope is Control:
			var r = scope.get_global_rect()
			if r.size.x > 0:
				return r.position + r.size * 0.5
		return _view_size() * 0.5

	var ab = _action_buttons()
	if is_instance_valid(ab):
		var current = ab.get("current_button")
		if is_instance_valid(current) and current.data_node and current.data_node.visible:
			var dn = current.data_node
			if dn is Control:
				return dn.get_global_rect().position + dn.get_global_rect().size * 0.5
	var aim = _find_aim_widget()
	if is_instance_valid(aim):
		var a = aim.get_global_rect()
		return a.position + a.size * 0.5
	return _view_size() * 0.5


# When the game opens a move-data panel, park the cursor on it once. Doing this every frame
# would drag the cursor back while the player is using it, so it only fires on a new panel.
func _auto_target(ab):
	var current = ab.get("current_button")
	if not is_instance_valid(current):
		_parked_for = null
		# The turn was submitted or reset: start the next turn on the category row, the way
		# the bar reads top to bottom.
		_focus = "category"
		_focus_cat = _category_label_of(_first_category(ab))
		_turn_slot = 0
		return
	# Only the moves zone follows the game's selection. On the category row the highlight is
	# the player's, and the game auto-picking a move each turn would otherwise yank it away.
	var cat = _category_of(ab, current)
	if cat != null and _focus == "move":
		_focus_cat = _category_label_of(cat)
	if current != _parked_for and current.data_node and current.data_node.visible and current.data_node is Control:
		_parked_for = current
		var dn = current.data_node.get_global_rect()
		_cursor = _clamp_cursor(dn.position + dn.size * 0.5)
		_cursor_dirty = true
		_sync_mouse()
		_render_cursor()


# ------------------------------------------------------------------ aiming / DI

# While a player is being hit, DI is the only decision that matters, so the stick goes straight
# to the DI wheel instead of acting as a cursor.
func _cursor_needs_aim_acquire():
	var game = Global.current_game if is_instance_valid(Global.current_game) else null
	if not is_instance_valid(game):
		return false
	var ab = _action_buttons()
	if not is_instance_valid(ab):
		return false
	var fighter = ab.get("fighter")
	if not is_instance_valid(fighter):
		return false
	if not fighter.is_in_hurt_state():
		return false
	var di = _find_di_widget()
	return is_instance_valid(di)


func _find_di_widget():
	var ab = _action_buttons()
	if not is_instance_valid(ab):
		return null
	return ab.get_node_or_null("%DI")


func _find_aim_widget():
	var ab = _action_buttons()
	if not is_instance_valid(ab):
		return null
	var current = ab.get("current_button")
	if not is_instance_valid(current):
		return null
	var node = current.data_node
	if not is_instance_valid(node):
		return null
	# Any XYPlot-style widget inside the move data panel is an aim control.
	return _find_xyplot(node)


func _find_xyplot(node):
	if node is Control and node.has_method("update_value") and node.get("panel") != null:
		return node
	for child in node.get_children():
		var found = _find_xyplot(child)
		if found != null:
			return found
	return null


func _acquire_aim_target():
	var ab = _action_buttons()
	if not is_instance_valid(ab):
		return
	var current = ab.get("current_button")
	var fighter = ab.get("fighter")

	# 1. being hit: DI
	if is_instance_valid(fighter) and fighter.is_in_hurt_state():
		var di = _find_di_widget()
		if is_instance_valid(di):
			_set_aim(di, null)
			return

	# 2. a move with an aim widget is selected: grab it
	if is_instance_valid(current):
		var aim = _find_aim_widget()
		if is_instance_valid(aim) and aim.visible:
			_set_aim(aim, current.data_node)
			return


func _set_aim(widget, owner):
	_aim_target = widget
	_aim_owner = owner
	_mark_aim(widget)


# Tell the player, on the widget itself, what the stick is doing. Some moves only allow a
# narrow arc, and without this the stick feels broken when the widget refuses to move.
func _mark_aim(widget):
	var label = widget.get_node_or_null("Label")
	if not is_instance_valid(label):
		return
	if label.text.ends_with(" (stick)"):
		return
	label.text = label.text + " (stick)"

	if widget is Control:
		_cursor = _clamp_cursor(widget.get_global_rect().position + widget.get_global_rect().size * 0.5)
		_cursor_dirty = true
		_sync_mouse()
		_render_cursor()


func _aim_with(stick, delta, slow):
	if not is_instance_valid(_aim_target):
		return
	if stick == Vector2.ZERO:
		return
	var plot = _aim_target
	var reach = float(plot.get("panel_radius")) if plot.get("panel_radius") != null else 24.0
	var seconds = AIM_SECONDS_SLOW if slow else AIM_SECONDS_FULL
	var current = _current_aim_offset(plot)
	var next = (current + stick * (reach / seconds) * delta).limit_length(reach)
	plot.update_value(next)
	# keep the drawn cursor on the aim nub
	if plot is Control:
		var mid = plot.midpoint() if plot.has_method("midpoint") else plot.panel_radius * Vector2.ONE
		var panel = plot.get_node_or_null("PlotPanel")
		if is_instance_valid(panel):
			_cursor = _clamp_cursor(panel.get_global_rect().position + mid + next)
			_cursor_dirty = true
			_sync_mouse()
			_render_cursor()


func _current_aim_offset(plot):
	if plot.has_method("get_value_float"):
		var v = plot.get_value_float()
		if v is Vector2:
			return v
	return Vector2.ZERO


# ------------------------------------------------------------------ engine setup

func _refresh_help():
	var ui = _ui()
	if is_instance_valid(ui) and ui.has_method("update_help_text"):
		ui.update_help_text()
