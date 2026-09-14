class_name Game
extends RefCounted

## Оркестратор партии: ход, фазы, кабинет, кризисы, концовки.
## Ничего не знает про UI — вся презентация получает данные через словари.

var db: ContentDB
var state: GameState
var director: Director

var current_event: Dictionary = {}
var current_scale: float = 1.0
var current_source: String = ""

## Автосохранение включает интерфейс. Симулятор и тесты играют без него:
## иначе на каждую партию приходились бы десятки записей на диск.
var autosave: bool = false


func _init(content_db: ContentDB) -> void:
	db = content_db
	director = Director.new(content_db)


func start(seed_value: int = 0) -> void:
	state = GameState.new()
	state.setup(db.config, seed_value)
	state.phase = GameState.Phase.READY


# --- фаза 1: начало хода -----------------------------------------------------

## Начинает ход и возвращает событие для показа.
func begin_turn() -> Dictionary:
	if state.phase == GameState.Phase.OVER:
		return {}
	state.turn += 1
	state.acted_this_turn = false

	if state.get_stat("stability") < 30:
		state.low_stability_streak += 1
	else:
		state.low_stability_streak = 0

	director.tick_patrons(state)
	director.apply_turn_pressure(state)

	var selection := director.select_event(state)
	if selection.is_empty():
		# Пул исчерпан — ход проходит без события, но кабинет доступен.
		current_event = {}
		state.phase = GameState.Phase.CABINET
		return {}

	current_event = selection["event"]
	current_scale = float(selection["scale"])
	current_source = String(selection["source"])
	state.phase = GameState.Phase.CHOICE

	if current_source in ["scheduled", "threshold", "patron"]:
		state.consecutive_triggers += 1
	else:
		state.consecutive_triggers = 0

	_autosave()
	return describe_current()


func describe_current() -> Dictionary:
	if current_event.is_empty():
		return {}
	var choices: Array = []
	for choice in current_event["choices"]:
		choices.append({
			"index": int(choice["index"]),
			"text": String(choice["text"]),
			"available": Effects.check(state, choice.get("condition")),
		})
	return {
		"code": String(current_event.get("code", current_event.get("id", ""))),
		"title": String(current_event["title"]),
		"description": String(current_event["description"]),
		"kind": String(current_event.get("kind", "")),
		"source": current_source,
		"turn": state.turn,
		"choices": choices,
	}


# --- фаза 2: выбор -----------------------------------------------------------

## Применяет выбор. Возвращает {outcome, applied} либо {error}.
func choose(index: int) -> Dictionary:
	if state.phase != GameState.Phase.CHOICE:
		return {"error": "сейчас не фаза выбора"}

	var choice: Dictionary = {}
	for candidate in current_event["choices"]:
		if int(candidate["index"]) == index:
			choice = candidate
			break
	if choice.is_empty():
		return {"error": "нет такого варианта"}
	if not Effects.check(state, choice.get("condition")):
		return {"error": "вариант недоступен"}

	var code := String(current_event.get("code", current_event.get("id", "")))
	var applied := Effects.apply(state, choice, current_scale)
	director.apply_hooks(state, choice)

	state.mark_seen(code)
	state.trigger_last_turn[code] = state.turn
	state.history.append({
		"turn": state.turn,
		"event": code,
		"title": String(current_event["title"]),
		"choice": index,
		"choice_text": String(choice["text"]),
	})
	if code == "С-7":
		state.final_choice = index

	state.phase = GameState.Phase.CABINET
	_autosave()
	return {"outcome": String(choice["outcome"]), "applied": applied}


# --- фаза 3: кабинет ---------------------------------------------------------

## Действия конвертации, доступные в этом ходу.
func available_actions() -> Array:
	var out: Array = []
	for action in db.actions:
		out.append({
			"id": String(action["id"]),
			"title": String(action["title"]),
			"description": String(action["description"]),
			"cost": action["cost"],
			"gain": action["gain"],
			"available": _action_available(action),
			"cooldown_until": int(state.action_cooldowns.get(action["id"], 0)),
		})
	return out


func _action_available(action: Dictionary) -> bool:
	if state.acted_this_turn or state.phase != GameState.Phase.CABINET:
		return false
	if state.turn < int(state.action_cooldowns.get(action["id"], 0)):
		return false
	for key in action.get("requires", {}):
		if state.get_stat(String(key)) < int(action["requires"][key]):
			return false
	return true


func do_action(id: String) -> Dictionary:
	var action := db.get_action(id)
	if action.is_empty():
		return {"error": "нет такого действия"}
	if not _action_available(action):
		return {"error": "действие недоступно"}

	# Действия кабинета написаны в той же авторской амплитуде, что и события,
	# поэтому проходят через тот же множитель.
	var mult := state.effect_multiplier
	var applied: Dictionary = {}
	for key in action["cost"]:
		applied[key] = state.add_stat(String(key), int(round(float(action["cost"][key]) * mult)))
	for key in action["gain"]:
		applied[key] = int(applied.get(key, 0)) + state.add_stat(String(key), int(round(float(action["gain"][key]) * mult)))
	for dyn in action.get("dynamic_gain", []):
		var key := Effects.resolve(state, String(dyn["resolver"]))
		if not key.is_empty():
			applied[key] = int(applied.get(key, 0)) + state.add_stat(key, int(round(float(dyn["delta"]) * mult)))

	state.acted_this_turn = true
	state.action_cooldowns[id] = state.turn + int(action["cooldown"])
	_autosave()
	return {"applied": applied, "title": String(action["title"])}


# --- фаза 4: конец хода ------------------------------------------------------

## Закрывает ход: разрешает кризис, проверяет поражение и конец мандата.
## Возвращает {} если игра продолжается, иначе описание концовки.
func end_turn() -> Dictionary:
	if state.phase == GameState.Phase.OVER:
		return get_ending()
	# Ход нельзя закрыть, пока событие не разрешено: иначе то же событие
	# выпадет снова и партия зациклится.
	if state.phase == GameState.Phase.CHOICE:
		return {"error": "событие текущего хода не разрешено"}

	if not state.crisis_stat.is_empty():
		if state.get_stat(state.crisis_stat) > 0:
			state.crisis_resolved_turn = state.turn
			state.crisis_stat = ""
		else:
			state.defeat_reason = state.crisis_stat
			state.phase = GameState.Phase.OVER
			_autosave()
			return get_ending()
	else:
		for key in db.fatal_stats():
			if state.get_stat(key) <= 0:
				state.crisis_stat = key
				break

	if state.turn >= int(db.config["mandate_turns"]) and state.is_seen("С-7"):
		state.phase = GameState.Phase.OVER
		_autosave()
		return get_ending()

	state.phase = GameState.Phase.READY
	_autosave()
	return {}


func _autosave() -> void:
	if not autosave:
		return
	if state.phase == GameState.Phase.OVER:
		# Законченную партию продолжать нечего — иначе «Продолжить»
		# воскрешало бы уже отыгранный мандат.
		SaveGame.clear()
		return
	var err := SaveGame.save(self)
	if not err.is_empty():
		push_warning("автосохранение не удалось: " + err)


# --- концовки ----------------------------------------------------------------

func get_ending() -> Dictionary:
	for ending in db.endings:
		if Effects.check(state, ending["condition"]):
			var result := {
				"id": String(ending["id"]),
				"kind": String(ending["kind"]),
				"title": String(ending["title"]),
				"text": String(ending["text"]),
				"turn": state.turn,
				"stats": state.stats.duplicate(),
				"key_moments": key_moments(),
			}
			if not state.defeat_reason.is_empty():
				result["defeat_reason"] = defeat_text(state.defeat_reason)
			return result
	return {}


func defeat_text(stat_key: String) -> String:
	match stat_key:
		"un":
			return "Совбез не стал дожидаться конца мандата. Вас отозвали, преемник назначен в тот же день, и в резолюции о вашей работе сказано ровно одно предложение."
		"security":
			return "Контроль над территорией потерян окончательно. Решение о вашей замене приняли не в Нью-Йорке, а в штабе МСС, и оформили его задним числом."
		"support":
			return "Страна перестала признавать вашу администрацию. Формально вы оставались в должности до конца недели, фактически — до того дня, когда охрана перестала пускать людей к резиденции."
		"stability":
			return "Государство остановилось. Ведомства не работают, бюджет не исполняется, и международное присутствие теперь обсуждают в терминах эвакуации, а не мандата."
		_:
			return "Мандат прерван досрочно."


## Ключевые решения партии — то, чем игрока помянут в финале.
func key_moments() -> Array:
	var out: Array = []
	for entry in state.history:
		var code := String(entry["event"])
		if code.begins_with("С-") or code.begins_with("Т-") or code.begins_with("CR-"):
			out.append(entry)
	return out
