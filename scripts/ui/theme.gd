class_name Palette
extends RefCounted

## Оформление: бумага служебной папки, а не интерфейс космического корабля.

const BG          := Color("#14161a")
const PANEL       := Color("#1c1f26")
const PANEL_EDGE  := Color("#2c313c")
const TEXT        := Color("#d8d4cc")
const TEXT_DIM    := Color("#8b8780")
const ACCENT      := Color("#c8a45c")

const GOOD        := Color("#7ea172")
const BAD         := Color("#b5665c")
const NEUTRAL     := Color("#8b8780")
const WARN        := Color("#c2a25a")

const FATAL       := Color("#c9c2b4")
const LOYALTY     := Color("#8fa5b8")
const PATRON      := Color("#9c8aa8")


static func panel_style(edge: Color = PANEL_EDGE) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL
	style.border_color = edge
	style.set_border_width_all(1)
	style.set_corner_radius_all(3)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	return style


static func button_style(bg: Color, edge: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = edge
	style.set_border_width_all(1)
	style.set_corner_radius_all(2)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	return style


## Цвет шкалы по её доле: красный у нуля, спокойный в середине.
static func gauge_color(value: int) -> Color:
	if value <= 20:
		return BAD
	if value <= 40:
		return WARN
	return GOOD
