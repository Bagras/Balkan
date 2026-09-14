class_name Effects
extends RefCounted

## Применение эффектов выбора и вычисление условий.
## Часть эффектов в исходнике адресует шкалу словами («Л-(их община)») —
## такие разрешаются резолверами из текущего состояния партии.


## Применяет числовые и динамические эффекты. scale — множитель силы
## (используется патронскими событиями: чем выше влияние, тем сильнее эффект).
## Возвращает словарь фактических изменений для показа игроку.
static func apply(state: GameState, choice: Dictionary, scale: float = 1.0) -> Dictionary:
	var applied: Dictionary = {}
	scale *= state.effect_multiplier

	for key in choice.get("effects", {}):
		var delta: int = _scaled(int(choice["effects"][key]), scale)
		var real := state.add_stat(key, delta)
		if real != 0:
			applied[key] = int(applied.get(key, 0)) + real

	for dyn in choice.get("dynamic_effects", []):
		var key: String = resolve(state, String(dyn["resolver"]))
		if key.is_empty():
			continue
		var delta: int = _scaled(int(dyn["delta"]), scale)
		var real := state.add_stat(key, delta)
		if real != 0:
			applied[key] = int(applied.get(key, 0)) + real

	return applied


static func _scaled(delta: int, scale: float) -> int:
	if is_equal_approx(scale, 1.0):
		return delta
	# округляем от нуля, чтобы масштабирование не съедало эффект ±1
	var scaled_value: float = float(delta) * scale
	return int(ceil(scaled_value)) if delta > 0 else int(floor(scaled_value))


## Резолверы динамических целей. Логика: радикализация и вооружённое подполье
## рождаются в самой обделённой общине, а премьерский пост занимает та,
## что сейчас наверху.
static func resolve(state: GameState, resolver: String) -> String:
	var loyalties := state.loyalties_sorted()
	if loyalties.is_empty():
		return ""

	match resolver:
		"loyalty_lowest":
			return String(loyalties[0][0])
		"loyalty_highest":
			return String(loyalties[-1][0])
		"loyalty_highest_excluding_lowest":
			return String(loyalties[-1][0])
		"donor_community":
			# донор — тот патрон, чьё влияние сейчас больше
			return "loyalty_serb" if state.get_stat("patron_belgrade") >= state.get_stat("patron_athens") else "loyalty_greek"
		"branch_stat":
			return branch_stat(state)
		_:
			push_warning("неизвестный резолвер: " + resolver)
			return ""


## Профильная шкала ветки С-6: ветка определяется тем, что именно просело.
static func branch_stat(state: GameState) -> String:
	var candidates := [
		["security", state.get_stat("security")],
		["un", state.get_stat("un")],
		["support", state.get_stat("support")],
	]
	candidates.sort_custom(func(a, b): return a[1] < b[1])
	if int(candidates[0][1]) < 45:
		return String(candidates[0][0])
	return "influence"  # всё в порядке — ветка «торг о наследстве»


## Вычисляет условие доступности выбора / срабатывания триггера / концовки.
static func check(state: GameState, condition, ctx: Dictionary = {}) -> bool:
	if condition == null or (condition is Dictionary and condition.is_empty()):
		return true

	match String(condition.get("type", "")):
		"always":
			return true
		"stat_above":
			return state.get_stat(String(condition["stat"])) >= int(condition["value"])
		"stat_below":
			return state.get_stat(String(condition["stat"])) <= int(condition["value"])
		"stat_below_streak":
			return state.low_stability_streak >= int(condition["turns"])
		"all_loyalty_above":
			for pair in state.loyalties_sorted():
				if int(pair[1]) < int(condition["value"]):
					return false
			return true
		"loyalty_gap_above":
			return state.loyalty_gap() >= int(condition["value"])
		"lowest_loyalty_below":
			var loyalties := state.loyalties_sorted()
			return not loyalties.is_empty() and int(loyalties[0][1]) <= int(condition["value"])
		"choice_taken":
			for entry in state.history:
				if String(entry["event"]) == String(condition["event"]) \
						and int(entry["choice"]) == int(condition["index"]):
					return true
			return false
		"final_choice":
			return state.final_choice == int(condition["value"])
		"final_choice_in":
			# JSON-числа приходят как float — сравниваем явно приведёнными int
			for value in condition["values"]:
				if state.final_choice == int(value):
					return true
			return false
		"defeat":
			return not state.defeat_reason.is_empty()
		"best_ending":
			return _best_ending_available(state)
		"mid_ending":
			return not _best_ending_available(state)
		"all":
			for sub in condition["of"]:
				if not check(state, sub, ctx):
					return false
			return true
		"any":
			for sub in condition["of"]:
				if check(state, sub, ctx):
					return true
			return false
		_:
			push_warning("неизвестное условие: " + String(condition.get("type", "?")))
			return true


## Доступность варианта С-7.I: «завершить международное управление».
## Требует и цифр, и выбранного курса на передачу полномочий (С-4.II или С-6.II).
static func _best_ending_available(state: GameState) -> bool:
	if state.has_flag("best_ending_blocked"):
		return false
	if not state.has_flag("best_ending_enabled"):
		return false
	for key in ["stability", "security", "support", "un"]:
		if state.get_stat(key) < 60:
			return false
	return true
