class_name ContentDB
extends RefCounted

## Загружает и хранит весь контент игры из content/*.json.
## Художественный текст порождается из исходного .docx (tools/parse_docx.py),
## руками events.json не правится.

var config: Dictionary = {}
var events: Array = []          ## 47 событий из .docx: random / trigger / story
var crises: Array = []          ## кризисные события механики хода отсрочки
var patron_events: Array = []   ## события патронов
var actions: Array = []         ## действия кабинета
var endings: Array = []

var _by_code: Dictionary = {}
var _chain_starters: Dictionary = {}

const CONTENT_DIR := "res://content/"


func load_all() -> String:
	var cfg = _read_json(CONTENT_DIR + "config.json")
	if cfg is String:
		return cfg
	config = cfg

	var ev = _read_json(CONTENT_DIR + "events.json")
	if ev is String:
		return ev
	events = ev["events"]

	# Дополнительный пул: пишется в том же авторском формате (events_extra.txt)
	# и подмешивается к основному. Файла может не быть — это не ошибка.
	if FileAccess.file_exists(CONTENT_DIR + "events_extra.json"):
		var extra = _read_json(CONTENT_DIR + "events_extra.json")
		if extra is String:
			return extra
		events.append_array(extra["events"])

	var cr = _read_json(CONTENT_DIR + "crises.json")
	if cr is String:
		return cr
	crises = cr["crises"]

	var pt = _read_json(CONTENT_DIR + "patrons.json")
	if pt is String:
		return pt
	patron_events = pt["events"]

	var ac = _read_json(CONTENT_DIR + "actions.json")
	if ac is String:
		return ac
	actions = ac["actions"]

	var en = _read_json(CONTENT_DIR + "endings.json")
	if en is String:
		return en
	endings = en["endings"]

	for e in events:
		_by_code[e["code"]] = e
		# Стартовое событие цепочки — обычное случайное, чья заметка ведёт
		# на шаг цепочки. Отдельно помечать его в тексте не нужно.
		if e["kind"] == "random":
			for choice in e["choices"]:
				for hook in choice.get("hooks", []):
					if String(hook.get("type", "")) == "schedule":
						for target in hook.get("targets", []):
							if String(target).begins_with("Ц-"):
								_chain_starters[e["code"]] = true
	for e in patron_events:
		_by_code[e["id"]] = e
	for c in crises:
		_by_code[c["id"]] = c
	return ""


## Событие по коду («I», «Т-5», «С-3», «P-BEL-HIGH», «CR-STAB»).
func get_event(code: String) -> Dictionary:
	return _by_code.get(code, {})


func is_chain_starter(code: String) -> bool:
	return _chain_starters.get(code, false)


func chain_starter_count() -> int:
	return _chain_starters.size()


func events_of_kind(kind: String) -> Array:
	var out: Array = []
	for e in events:
		if e["kind"] == kind:
			out.append(e)
	return out


func get_action(id: String) -> Dictionary:
	for a in actions:
		if a["id"] == id:
			return a
	return {}


func stat_keys() -> Array:
	return config["stats"].keys()


func fatal_stats() -> Array:
	var out: Array = []
	for key in config["stats"]:
		if config["stats"][key].get("fatal", false):
			out.append(key)
	return out


func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return "не найден файл: " + path
	var text := FileAccess.get_file_as_string(path)
	var parsed = JSON.parse_string(text)
	if parsed == null:
		return "не разобран JSON: " + path
	return parsed
