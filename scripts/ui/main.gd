extends Control

## Интерфейс партии. Строится кодом — так его проще перекрашивать и
## не нужно синхронизировать .tscn с логикой. Ядро (Game) про UI не знает.

enum Mode { TITLE, EVENT, OUTCOME, ENDING }

var db: ContentDB
var game: Game
var mode: Mode = Mode.EVENT

var _turn_label: Label
var _source_label: Label
var _stats_box: VBoxContainer
var _title_label: Label
var _body: RichTextLabel
var _choice_box: VBoxContainer
var _cabinet_box: VBoxContainer
var _footer: HBoxContainer
var _journal_button: Button
var _saved_body := ""
var _journal_open := false


func _ready() -> void:
	db = ContentDB.new()
	var err := db.load_all()
	if not err.is_empty():
		push_error(err)
		return
	game = Game.new(db)
	game.autosave = true
	_build_layout()
	if SaveGame.has_save():
		_show_title()
	else:
		_new_game()


func _new_game() -> void:
	SaveGame.clear()
	game.start(0)
	_close_journal()
	_advance_turn()


## Экран выбора: продолжить прерванный мандат или начать заново.
func _show_title() -> void:
	mode = Mode.TITLE
	_clear(_choice_box)
	_clear(_cabinet_box)
	_clear(_footer)
	_journal_button.visible = false
	_turn_label.text = "Балканский протекторат"
	_source_label.text = "Мандат прерван на середине"
	_title_label.text = "Незаконченный мандат"
	_body.text = "В резиденции остались бумаги предыдущей сессии. Мандат не дослушан до конца — можно вернуться к нему или начать всё заново.\n\n[color=#%s]Новый мандат стирает сохранение без возможности вернуться.[/color]" % Palette.TEXT_DIM.to_html(false)
	_refresh_stats()

	var resume := _make_wide_button("Продолжить мандат", true)
	resume.pressed.connect(_on_resume)
	_choice_box.add_child(resume)
	var fresh := _make_wide_button("Новый мандат", false)
	fresh.pressed.connect(_new_game)
	_choice_box.add_child(fresh)


func _on_resume() -> void:
	var err := SaveGame.load_into(game)
	if not err.is_empty():
		push_warning(err)
		_new_game()
		return
	game.autosave = true
	_close_journal()
	if game.state.phase == GameState.Phase.CHOICE and not game.current_event.is_empty():
		mode = Mode.EVENT
		_render_event(game.describe_current())
	else:
		_show_cabinet("Вы возвращаетесь к делам. Ход не закрыт.")


func _make_wide_button(text: String, accent: bool) -> Button:
	var button := Button.new()
	button.text = text
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.add_theme_font_size_override("font_size", 15)
	button.add_theme_color_override("font_color", Palette.TEXT)
	var edge := Palette.ACCENT if accent else Palette.PANEL_EDGE
	button.add_theme_stylebox_override("normal", Palette.button_style(Palette.PANEL, edge))
	button.add_theme_stylebox_override("hover", Palette.button_style(Palette.PANEL_EDGE, Palette.ACCENT))
	button.add_theme_stylebox_override("pressed", Palette.button_style(Palette.PANEL_EDGE, Palette.ACCENT))
	return button


# --- построение интерфейса ---------------------------------------------------

func _build_layout() -> void:
	var bg := ColorRect.new()
	bg.color = Palette.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 28)
	margin.add_theme_constant_override("margin_right", 28)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_bottom", 20)
	add_child(margin)

	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 22)
	margin.add_child(columns)

	columns.add_child(_build_sidebar())
	columns.add_child(_build_main_column())


func _build_sidebar() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Palette.panel_style())
	panel.custom_minimum_size = Vector2(316, 0)
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 4)
	panel.add_child(column)

	_turn_label = _make_label("", 20, Palette.TEXT)
	column.add_child(_turn_label)
	_source_label = _make_label("", 11, Palette.TEXT_DIM)
	column.add_child(_source_label)
	column.add_child(_spacer(10))

	_stats_box = VBoxContainer.new()
	_stats_box.add_theme_constant_override("separation", 3)
	column.add_child(_stats_box)

	var filler := Control.new()
	filler.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(filler)

	_journal_button = Button.new()
	_journal_button.text = "Журнал решений"
	_journal_button.add_theme_font_size_override("font_size", 12)
	_journal_button.add_theme_color_override("font_color", Palette.TEXT_DIM)
	_journal_button.add_theme_stylebox_override("normal", Palette.button_style(Palette.PANEL, Palette.PANEL_EDGE))
	_journal_button.add_theme_stylebox_override("hover", Palette.button_style(Palette.PANEL_EDGE, Palette.ACCENT))
	_journal_button.pressed.connect(_toggle_journal)
	column.add_child(_journal_button)
	return panel


## Журнал открывается поверх текста события: выборы и кабинет прячутся,
## но не пересобираются — вернуться нужно ровно туда, где был игрок.
func _toggle_journal() -> void:
	if _journal_open:
		_close_journal()
		return
	_journal_open = true
	_saved_body = _body.text
	_journal_button.text = "← Вернуться"
	_choice_box.visible = false
	_cabinet_box.visible = false
	_footer.visible = false
	_body.text = _journal_text()


func _close_journal() -> void:
	if not _journal_open:
		return
	_journal_open = false
	_journal_button.text = "Журнал решений"
	_choice_box.visible = true
	_cabinet_box.visible = true
	_footer.visible = true
	_body.text = _saved_body


func _journal_text() -> String:
	if game.state.history.is_empty():
		return "[color=#%s]Решений пока не принято.[/color]" % Palette.TEXT_DIM.to_html(false)
	var dim := Palette.TEXT_DIM.to_html(false)
	var lines: Array = ["[font_size=13]"]
	for entry in game.state.history:
		var code := String(entry["event"])
		var mark := ""
		if code.begins_with("С-"):
			mark = " [color=#%s]· главная линия[/color]" % Palette.ACCENT.to_html(false)
		elif code.begins_with("Т-") or code.begins_with("CR-") or code.begins_with("P-"):
			mark = " [color=#%s]· последствие[/color]" % dim
		lines.append("[color=%s]Ход %d.[/color]  [b]%s[/b]%s\n%s\n" % [
			"#" + dim, int(entry["turn"]), String(entry["title"]), mark, String(entry["choice_text"])])
	lines.append("[/font_size]")
	return "\n".join(lines)


func _build_main_column() -> Control:
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 12)

	_title_label = _make_label("", 26, Palette.TEXT)
	_title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_title_label)

	var text_panel := PanelContainer.new()
	text_panel.add_theme_stylebox_override("panel", Palette.panel_style())
	text_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(text_panel)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	text_panel.add_child(scroll)

	_body = RichTextLabel.new()
	_body.bbcode_enabled = true
	_body.fit_content = true
	_body.scroll_active = false
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_font_size_override("normal_font_size", 16)
	_body.add_theme_color_override("default_color", Palette.TEXT)
	scroll.add_child(_body)

	_choice_box = VBoxContainer.new()
	_choice_box.add_theme_constant_override("separation", 7)
	column.add_child(_choice_box)

	_cabinet_box = VBoxContainer.new()
	_cabinet_box.add_theme_constant_override("separation", 6)
	column.add_child(_cabinet_box)

	_footer = HBoxContainer.new()
	_footer.alignment = BoxContainer.ALIGNMENT_END
	column.add_child(_footer)
	return column


# --- отрисовка состояния -----------------------------------------------------

func _refresh_stats() -> void:
	if game.state == null:
		_clear(_stats_box)
		return
	# queue_free() отложен до конца кадра — без remove_child строки
	# накладываются друг на друга при нескольких обновлениях за кадр
	_clear(_stats_box)

	_add_stat_group("Ресурсы", ["stability", "un", "security", "support"], true)
	_add_stat_group("Комиссар", ["influence", "personal"], false)
	_add_stat_group("Лояльность общин", ["loyalty_serb", "loyalty_alb", "loyalty_greek"], false)
	_add_stat_group("Влияние соседей", ["patron_belgrade", "patron_tirana", "patron_athens"], false)


func _add_stat_group(caption: String, keys: Array, fatal: bool) -> void:
	_stats_box.add_child(_spacer(8))
	var header := _make_label(caption.to_upper(), 10, Palette.TEXT_DIM)
	_stats_box.add_child(header)

	for key in keys:
		var value: int = game.state.get_stat(String(key))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)

		var name_label := _make_label(String(db.config["stats"][key]["label"]), 13, Palette.TEXT)
		name_label.custom_minimum_size = Vector2(142, 0)
		row.add_child(name_label)

		var bar := ProgressBar.new()
		bar.min_value = 0
		bar.max_value = 100
		bar.value = value
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(78, 11)
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var fill := StyleBoxFlat.new()
		fill.bg_color = Palette.gauge_color(value) if fatal else _tint_for(String(key))
		fill.set_corner_radius_all(2)
		var track := StyleBoxFlat.new()
		track.bg_color = Palette.PANEL_EDGE
		track.set_corner_radius_all(2)
		bar.add_theme_stylebox_override("fill", fill)
		bar.add_theme_stylebox_override("background", track)
		row.add_child(bar)

		var value_label := _make_label(str(value), 13, Palette.TEXT_DIM)
		value_label.custom_minimum_size = Vector2(28, 0)
		value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(value_label)

		_stats_box.add_child(row)


func _tint_for(key: String) -> Color:
	var group := String(db.config["stats"][key].get("group", ""))
	if group == "loyalty":
		return Palette.LOYALTY
	if group == "patron":
		return Palette.PATRON
	return Palette.FATAL


# --- ход ---------------------------------------------------------------------

func _advance_turn() -> void:
	var presented := game.begin_turn()
	if game.state.phase == GameState.Phase.OVER:
		_show_ending(game.get_ending())
		return
	if presented.is_empty():
		_show_cabinet("Тихий ход. Событий нет — есть только текущие дела.")
		return

	_render_event(presented)


func _render_event(presented: Dictionary) -> void:
	mode = Mode.EVENT
	_journal_button.visible = true
	_turn_label.text = "Ход %d / %d" % [game.state.turn, int(db.config["mandate_turns"])]
	_source_label.text = _source_caption(String(presented["source"]))
	_title_label.text = String(presented["title"])
	_body.text = String(presented["description"])
	_refresh_stats()
	_clear(_cabinet_box)
	_clear(_footer)
	_clear(_choice_box)

	for choice in presented["choices"]:
		var button := _make_choice_button(choice)
		_choice_box.add_child(button)


func _source_caption(source: String) -> String:
	match source:
		"story":    return "Главная линия мандата"
		"crisis":   return "Кризис — шкала на нуле"
		"scheduled": return "Последствие вашего прошлого решения"
		"threshold": return "Обстановка вышла из-под контроля"
		"patron":   return "Вмешательство соседей"
		_:          return "Текущие дела"


func _make_choice_button(choice: Dictionary) -> Button:
	var button := Button.new()
	var index := int(choice["index"])
	button.text = "%s.  %s" % [_roman(index), String(choice["text"])]
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.add_theme_font_size_override("font_size", 15)
	button.add_theme_color_override("font_color", Palette.TEXT)
	button.add_theme_stylebox_override("normal", Palette.button_style(Palette.PANEL, Palette.PANEL_EDGE))
	button.add_theme_stylebox_override("hover", Palette.button_style(Palette.PANEL_EDGE, Palette.ACCENT))
	button.add_theme_stylebox_override("pressed", Palette.button_style(Palette.PANEL_EDGE, Palette.ACCENT))

	if not choice["available"]:
		button.disabled = true
		button.tooltip_text = "Недоступно при нынешних показателях"
		button.add_theme_color_override("font_disabled_color", Palette.TEXT_DIM)
	else:
		button.pressed.connect(_on_choice.bind(index))
	return button


func _on_choice(index: int) -> void:
	var result := game.choose(index)
	if result.has("error"):
		return
	mode = Mode.OUTCOME
	_clear(_choice_box)

	var text := String(result["outcome"])
	var deltas := _format_deltas(result["applied"])
	if not deltas.is_empty():
		text += "\n\n" + deltas
	_show_cabinet(text)


## Изменения шкал — строкой, чтобы игрок видел цену решения сразу.
func _format_deltas(applied: Dictionary) -> String:
	var parts: Array = []
	for key in applied:
		var delta := int(applied[key])
		if delta == 0:
			continue
		var color := Palette.GOOD if delta > 0 else Palette.BAD
		parts.append("[color=#%s]%s %+d[/color]" % [
			color.to_html(false), String(db.config["stats"][key]["short"]), delta])
	if parts.is_empty():
		return ""
	return "[font_size=13]" + "   ".join(parts) + "[/font_size]"


# --- кабинет -----------------------------------------------------------------

func _show_cabinet(body_text: String) -> void:
	_journal_button.visible = true
	_body.text = body_text
	_refresh_stats()
	_clear(_cabinet_box)
	_clear(_footer)

	var header := _make_label("КАБИНЕТ — одно решение за ход", 10, Palette.TEXT_DIM)
	_cabinet_box.add_child(header)

	var grid := HFlowContainer.new()
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	_cabinet_box.add_child(grid)

	for action in game.available_actions():
		grid.add_child(_make_action_button(action))

	var next_button := Button.new()
	next_button.text = "Завершить ход  →"
	next_button.add_theme_font_size_override("font_size", 15)
	next_button.add_theme_color_override("font_color", Palette.BG)
	next_button.add_theme_stylebox_override("normal", Palette.button_style(Palette.TEXT_DIM, Palette.TEXT_DIM))
	next_button.add_theme_stylebox_override("hover", Palette.button_style(Palette.TEXT, Palette.TEXT))
	next_button.add_theme_stylebox_override("pressed", Palette.button_style(Palette.TEXT, Palette.TEXT))
	next_button.pressed.connect(_on_end_turn)
	_footer.add_child(next_button)


func _make_action_button(action: Dictionary) -> Button:
	var button := Button.new()
	button.text = String(action["title"])
	button.add_theme_font_size_override("font_size", 12)
	button.tooltip_text = "%s\n\n%s" % [String(action["description"]), _action_price(action)]
	button.add_theme_color_override("font_color", Palette.TEXT)
	button.add_theme_stylebox_override("normal", Palette.button_style(Palette.PANEL, Palette.PANEL_EDGE))
	button.add_theme_stylebox_override("hover", Palette.button_style(Palette.PANEL_EDGE, Palette.ACCENT))
	button.add_theme_stylebox_override("pressed", Palette.button_style(Palette.PANEL_EDGE, Palette.ACCENT))
	if action["available"]:
		button.pressed.connect(_on_action.bind(String(action["id"])))
	else:
		button.disabled = true
		button.add_theme_color_override("font_disabled_color", Palette.PANEL_EDGE)
	return button


func _action_price(action: Dictionary) -> String:
	var parts: Array = []
	var multiplier := game.state.effect_multiplier
	for source in [action["cost"], action["gain"]]:
		for key in source:
			var delta := int(round(float(source[key]) * multiplier))
			parts.append("%s %+d" % [String(db.config["stats"][key]["short"]), delta])
	return "   ".join(parts)


func _on_action(id: String) -> void:
	var result := game.do_action(id)
	if result.has("error"):
		return
	var text := _body.text
	var deltas := _format_deltas(result["applied"])
	_show_cabinet(text + "\n\n[color=#%s]%s.[/color] %s" % [
		Palette.ACCENT.to_html(false), String(result["title"]), deltas])


func _on_end_turn() -> void:
	var ending := game.end_turn()
	if ending.has("error"):
		return
	if not ending.is_empty():
		_show_ending(ending)
		return
	_advance_turn()


# --- финал -------------------------------------------------------------------

func _show_ending(ending: Dictionary) -> void:
	mode = Mode.ENDING
	_close_journal()
	_clear(_choice_box)
	_clear(_cabinet_box)
	_clear(_footer)
	_refresh_stats()

	_turn_label.text = "Мандат завершён"
	_source_label.text = "Ход %d из %d" % [int(ending.get("turn", 0)), int(db.config["mandate_turns"])]
	_title_label.text = String(ending.get("title", "—"))

	var text := ""
	if ending.has("defeat_reason"):
		text += "[color=#%s]%s[/color]\n\n" % [Palette.BAD.to_html(false), String(ending["defeat_reason"])]
	text += String(ending.get("text", ""))

	var moments: Array = ending.get("key_moments", [])
	if not moments.is_empty():
		text += "\n\n[font_size=13][color=#%s]ЧТО ОПРЕДЕЛИЛО ЭТОТ ИСХОД[/color]\n" % Palette.TEXT_DIM.to_html(false)
		for moment in moments:
			text += "\n[color=#%s]Ход %d.[/color] %s — %s" % [
				Palette.TEXT_DIM.to_html(false), int(moment["turn"]),
				String(moment["title"]), String(moment["choice_text"])]
		text += "[/font_size]"
	_body.text = text

	var again := Button.new()
	again.text = "Новый мандат"
	again.add_theme_font_size_override("font_size", 15)
	again.add_theme_color_override("font_color", Palette.BG)
	again.add_theme_stylebox_override("normal", Palette.button_style(Palette.TEXT_DIM, Palette.TEXT_DIM))
	again.add_theme_stylebox_override("hover", Palette.button_style(Palette.TEXT, Palette.TEXT))
	again.pressed.connect(_new_game)
	_footer.add_child(again)


# --- мелочи ------------------------------------------------------------------

func _make_label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	return label


func _spacer(height: int) -> Control:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, height)
	return spacer


func _clear(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()


func _roman(index: int) -> String:
	match index:
		1: return "I"
		2: return "II"
		3: return "III"
		_: return str(index)
