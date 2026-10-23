-- The robot's form: the program sheet (blocks), a text view, storage,
-- packages, settings and help.

local cogwork = ...
local lang = cogwork.lang
local S = cogwork.S
local esc = core.formspec_escape

local FORMNAME = "cogwork:ed"
local ICONS, FN_ICONS, PKG_ICONS = assert(loadfile(cogwork.modpath .. "/src/icons.lua"))()

local ROWS = 11          -- program lines visible
local CELL = 0.8
local STEP = 0.85
local SHEET_W = 10.3
local MAX_LINES = 200
local MAX_TEXT = 20000

local TABS = { "program", "text", "storage", "structure", "packages", "settings", "help" }
local TAB_LABELS = { S("Program"), S("Text"), S("Storage"), S("Structure"), S("Packages"), S("Settings"), S("Help") }

local sessions = {}

-- Mineclonia and VoxeLibre hide the plain slot squares (their formspec prepend
-- makes lists transparent) and draw their own slot picture behind each slot
local function slot_bg (x, y, w, h)
	if core.global_exists("mcl_formspec") and mcl_formspec.get_itemslot_bg_v4 then
		return mcl_formspec.get_itemslot_bg_v4(x, y, w, h)
	end
	return ""
end

local function session (player)
	local name = player:get_player_name()
	sessions[name] = sessions[name] or { tab = "program", line = 1, tok = 0,
		scroll = 0, cat = "flow", pkg = nil, msg = "" }
	return sessions[name]
end

cogwork.editor_session = session

core.register_on_leaveplayer(function (player)
	sessions[player:get_player_name()] = nil
end)

--------------------------------------------------------------------------
-- program access

local function get_lines (pos)
	local lines = lang.parse_text(core.get_meta(pos):get_string("program"))
	if #lines == 0 then lines[1] = { indent = 0, tokens = {} } end
	return lines
end

local function put_lines (pos, lines)
	local text = lang.to_text(lines)
	if #text > MAX_TEXT or #lines > MAX_LINES then return false end
	core.get_meta(pos):set_string("program", text)
	return true
end

--------------------------------------------------------------------------
-- token classes

local STATEMENT = {}
for w in ("if else loop repeat forever break continue fn return call use"):gmatch("%S+") do
	STATEMENT[w] = true
end
local VARIABLE_OPS = {}
for w in ("set add sub mul div mod join"):gmatch("%S+") do VARIABLE_OPS[w] = true end

local BLOCK_OPENERS = { ["if"] = true, ["else"] = true, loop = true, ["repeat"] = true,
	forever = true, fn = true }

local function token_class (tok)
	if STATEMENT[tok] then return "flow" end
	if VARIABLE_OPS[tok] then return "var" end
	local def = lang.commands[tok]
	if def then return def.kind == "query" and "check" or def.category end
	if tok == "#" then return "note" end
	if ICONS[tok] then return "op" end
	if tok:sub(1, 1) == '"' then return "text" end
	if lang.is_number_token(tok) then return "number" end
	if tok:find(":", 1, true) or tok:sub(1, 1) == "@" then return "item" end
	return "name"
end

local CLASS_COLOR = {
	text = "#3d7a3d", number = "#3d7a3d", name = "#8a7a1d", note = "#666666",
	item = "#444444", op = "#555577",
}

--------------------------------------------------------------------------
-- palette

local PALETTE_CATS = { "flow", "chat", "move", "world", "inventory", "var", "check", "machine", "fn" }
local CAT_ICON = { flow = "if", chat = "say", move = "move", world = "dig", inventory = "pull",
	var = "set", check = "detect", machine = "machine_power", fn = "call" }
local CAT_TIP = { flow = S("Flow"), chat = S("Chat and messages"), move = S("Move"), world = S("World"),
	inventory = S("Items and parts"), var = S("Variables and values"), check = S("Conditions and checks"),
	machine = S("Machines and structure"), fn = S("Functions and packages") }

-- entries: { label, tokens, mode = "line" | "token", tip }
local function palette_entries (cat, lines, view)
	local list = {}
	local function add (tokens, mode, tip, label)
		local e = { tokens = tokens, mode = mode or "line", tip = tip, label = label }
		list[#list + 1] = e
		return e
	end

	if cat == "flow" then
		add({ "if", "detect", "front" }, "line", S("If a condition is true, run the lines below"))
		add({ "else" }, "line", S("Otherwise"))
		add({ "loop", "detect", "front" }, "line", S("Repeat while a condition is true"))
		add({ "repeat", "4" }, "line", S("Repeat a number of times"))
		add({ "forever" }, "line", S("Repeat until break or stop"))
		add({ "break" }, "line", S("Leave the loop"))
		add({ "continue" }, "line", S("Next loop turn"))
		add({ "wait", "5" }, "line", S("Wait, in tenths of a second"))
		add({ "stop" }, "line", S("Stop the program"))
		add({ "#", "note" }, "line", S("A note, ignored by the robot"))
	elseif cat == "chat" then
		add({ "chat", '"hello"' }, "line", S("Chat message to the owner"))
		add({ "say", '"hello"' }, "line", S("Public chat message (limited per player)"))
		add({ "whisper", '"name"', '"hello"' }, "line", S("Private chat message to a player (limited per player)"))
		add({ "tell_bot", '"name"', '"hello"' }, "line", S("Message a robot that allows this one"))
		add({ "tell_bots", '"hello"' }, "line", S("Message every robot that allows this one"))
	elseif cat == "move" then
		add({ "move", "forward" }, "line", S("Move one block"))
		add({ "turn", "left" }, "line", S("Turn the robot"))
		add({ "interact", "front" }, "line", S("Use (right-click) the block"))
	elseif cat == "world" then
		add({ "dig", "front" }, "line", S("Dig a block"))
		add({ "place", "front" }, "line", S("Place an item from storage"))
		add({ "interact", "front" }, "line", S("Use (right-click) the block"))
		add({ "punch", "front" }, "line", S("Pick up dropped items, or hit an entity (name a tool from storage to hit with it)"))
		add({ "machine_switch", "front", '"off"' }, "line", S("Turn the machine in the block on or off"))
		add({ "craft" }, "line", S("Craft an item from storage"))
	elseif cat == "inventory" then
		for _, v in ipairs({ "pull", "pull_stack", "put", "put_stack", "drop", "drop_stack",
			"trash", "trash_stack" }) do
			add({ v }, "line", S("@1 (an item name after it limits it)", v))
		end
		add({ "install", '"cell"' }, "line", S("Put a part from storage into the robot: cell, armor_mod or augment"))
		add({ "uninstall", '"armor_mod"' }, "line", S("Take a part out into storage (a cell only while another stays)"))
	elseif cat == "var" then
		add({ "set", "x", "=", "0" }, "line", S("Set a variable"))
		add({ "add", "x", "1" }, "line", S("Add to a variable"))
		add({ "sub", "x", "1" }, "line", S("Subtract from a variable"))
		add({ "mul", "x", "2" }, "line", S("Multiply a variable"))
		add({ "div", "x", "2" }, "line", S("Divide a variable"))
		add({ "mod", "x", "2" }, "line", S("Remainder of a variable"))
		add({ "join", "s", '"text"' }, "line", S("Append text to a variable"))
		-- the values and the arithmetic that go with variables
		for _, v in ipairs({ "counter", "ok", "random", "floor", "length", "true", "false",
			"+", "-", "*", "/", "%", "(", ")" }) do
			add({ v }, "token", v)
		end
	elseif cat == "check" then
		for _, v in ipairs({ "detect", "node", "entity", "contains", "fits", "count", "even", "odd",
			"pos_x", "pos_y", "pos_z", "facing" }) do
			add({ v }, "token", S("@1", v))
		end
		for _, v in ipairs({ "not", "and", "or", "matches", "=", "!=", "<", ">", "<=", ">=" }) do
			add({ v }, "token", v)
		end
	elseif cat == "machine" then
		for _, v in ipairs({ "machine_state", "machine_power", "machine_capacity", "machine_level",
			"machine_supply", "machine_demand", "network_level", "node_timer", "node_stock",
			"height_limit", "battery_level", "armor_level", "cell_count", "structure_item",
			"listeners", "listener" }) do
			add({ v }, "token", S("@1", v))
		end
		add({ "machine_switch", "front", '"off"' }, "line", S("Turn the machine in the block on or off"))
	elseif cat == "fn" then
		for _, line in ipairs(lines) do
			if line.indent == 0 and line.tokens[1] == "fn" and line.tokens[2] then
				local name = line.tokens[2]
				local call = { "call", name }
				for k = 3, #line.tokens do call[#call + 1] = "0" end
				add(call, "line", S("Call @1", name), name).icon = ICONS.call
			end
		end
		add({ "fn", "name" }, "line", S("Define a function"))
		add({ "return" }, "line", S("Give back a value and leave the function"))

		-- packages: pick one, then its functions
		local view = view or cogwork.list_packages()[1]
		for _, pname in ipairs(cogwork.list_packages()) do
			list[#list + 1] = { mode = "view", view = pname, tokens = { pname }, label = pname,
				tip = S("Show the functions of @1", pname), selected = pname == view,
				icon = PKG_ICONS[pname] or PKG_ICONS.default }
		end
		if view and lang.packages[view] then
			add({ "use", view }, "line", S("Use package @1: @2", view, lang.packages[view].meta.title or "")).icon = ICONS.use
			local ok, unit = pcall(lang.get_package, view, 0)
			if ok and unit then
				local names = {}
				for fname in pairs(unit.fns) do names[#names + 1] = fname end
				table.sort(names)
				for _, fname in ipairs(names) do
					local fn = unit.fns[fname]
					local call = { "call", view .. "." .. fname }
					for _ = 1, #fn.params do call[#call + 1] = "1" end
					add(call, "line", S("Call @1.@2 @3", view, fname, table.concat(fn.params, " ")), fname)
						.icon = FN_ICONS[view .. "." .. fname]
				end
			end
		end
	end

	return list
end

-- options that fit the selected token
local DIR8_LIST = { "front", "front_up", "front_down", "up", "down", "back", "back_up", "back_down" }

local function options_for (line, tok_index)
	local toks = line and line.tokens or {}
	local tok = toks[tok_index]
	if not tok then return {} end

	local def = lang.commands[toks[1]]
	if tok_index == 2 and def and def.args[1] then
		local kind = def.args[1].type
		if kind == "dir8" then return DIR8_LIST
		elseif kind == "dir4" then return { "forward", "back", "up", "down" }
		elseif kind == "turn" then return { "left", "right", "around" } end
	end

	-- a direction after detect or node inside an expression
	local prev = toks[tok_index - 1]
	if (prev == "detect" or prev == "node") and (lang.DIR8[tok] or lang.DIR4[tok]) then
		return DIR8_LIST
	end

	return {}
end

--------------------------------------------------------------------------
-- editing operations on the line list

local function line_is_blank (line) return #line.tokens == 0 end

local function new_indent (lines, at)
	local line = lines[at]
	if not line then return 0 end
	local opener = line.tokens[1]
	if BLOCK_OPENERS[opener] and opener ~= "else" then return line.indent + 1 end
	if opener == "else" then return line.indent + 1 end
	return line.indent
end

local function clamp_cursor (s, lines)
	if s.line < 1 then s.line = 1 end
	if s.line > #lines then s.line = #lines end
	local n = #lines[s.line].tokens
	if s.tok > n then s.tok = n end
	if s.tok < 0 then s.tok = 0 end
	if s.line <= s.scroll then s.scroll = s.line - 1 end
	if s.line > s.scroll + ROWS then s.scroll = s.line - ROWS end
	if s.scroll < 0 then s.scroll = 0 end
end

local function copy_tokens (t)
	local out = {}
	for i, v in ipairs(t) do out[i] = v end
	return out
end

local function insert_entry (s, lines, entry)
	if entry.mode == "token" then
		local line = lines[s.line]
		local at = s.tok == 0 and #line.tokens or s.tok
		for i, t in ipairs(entry.tokens) do
			table.insert(line.tokens, at + i, t)
		end
		s.tok = at + #entry.tokens
		return
	end

	local cur = lines[s.line]
	local tokens = copy_tokens(entry.tokens)
	if line_is_blank(cur) then
		cur.tokens = tokens
		s.tok = math.min(2, #tokens)
		return
	end

	local indent = new_indent(lines, s.line)
	if tokens[1] == "else" then indent = math.max(0, cur.indent - 1) end
	if tokens[1] == "fn" then indent = 0 end
	table.insert(lines, s.line + 1, { indent = indent, tokens = tokens })
	s.line = s.line + 1
	s.tok = math.min(2, #tokens)
end

local function replace_or_insert (s, lines, new_tokens)
	local line = lines[s.line]
	if s.tok >= 1 then
		local cls = token_class(line.tokens[s.tok])
		local valuelike = cls == "text" or cls == "number" or cls == "item" or cls == "name"
		if valuelike then
			table.remove(line.tokens, s.tok)
			for i, t in ipairs(new_tokens) do table.insert(line.tokens, s.tok + i - 1, t) end
			s.tok = s.tok + #new_tokens - 1
			return
		end
	end

	local at = s.tok == 0 and #line.tokens or s.tok
	for i, t in ipairs(new_tokens) do table.insert(line.tokens, at + i, t) end
	s.tok = at + #new_tokens
end

local function insert_after (s, lines, new_tokens)
	local line = lines[s.line]
	local at = s.tok == 0 and #line.tokens or s.tok
	for i, t in ipairs(new_tokens) do table.insert(line.tokens, at + i, t) end
	s.tok = at + #new_tokens
end

-- value typed into the field: numbers, quoted text, names and items as given
local function field_tokens (text)
	text = text:gsub("^%s+", ""):gsub("%s+$", "")
	if text == "" then return nil end
	return lang.tokenize(text)
end

local OPS = {}

cogwork.check_program = nil -- set below

-- Compile the program and look for item names that do not exist here.
-- Returns ok, message, line.
local function check_program (pos, lines)
	local unit, err, line = cogwork.compile_for(pos, lang.to_text(lines))
	if not unit then return false, err, line end

	for i, l in ipairs(lines) do
		if l.tokens[1] ~= "#" then
			for _, tok in ipairs(l.tokens) do
				if tok:sub(1, 1) == "@" then
					if not cogwork.compat.alias(tok) then
						return true, S("line @1: '@2' does not exist in this game", i, tok), i
					end
				elseif tok:find(":", 1, true) and tok:sub(1, 1) ~= '"' and not tok:find("^group:")
					and not core.registered_items[tok] then
					return true, S("line @1: unknown item '@2'", i, tok), i
				end
			end
		end
	end

	return true, S("Program is fine"), nil
end
cogwork.check_program = function (pos, text) return check_program(pos, lang.parse_text(text)) end

function OPS.op_insert (s, lines)
	table.insert(lines, s.line + 1, { indent = lines[s.line].indent, tokens = {} })
	s.line = s.line + 1
	s.tok = 0
end

function OPS.op_delete (s, lines)
	if #lines == 1 then lines[1] = { indent = 0, tokens = {} } return end
	table.remove(lines, s.line)
	s.tok = 0
end

function OPS.op_dup (s, lines)
	local line = lines[s.line]
	table.insert(lines, s.line + 1, { indent = line.indent, tokens = copy_tokens(line.tokens) })
	s.line = s.line + 1
end

function OPS.op_indent (s, lines)
	local line = lines[s.line]
	if line.indent < 8 then line.indent = line.indent + 1 end
end

function OPS.op_unindent (s, lines)
	local line = lines[s.line]
	if line.indent > 0 then line.indent = line.indent - 1 end
end

function OPS.op_up (s, lines)
	if s.line > 1 then
		lines[s.line], lines[s.line - 1] = lines[s.line - 1], lines[s.line]
		s.line = s.line - 1
	end
end

function OPS.op_down (s, lines)
	if s.line < #lines then
		lines[s.line], lines[s.line + 1] = lines[s.line + 1], lines[s.line]
		s.line = s.line + 1
	end
end

function OPS.op_delcell (s, lines)
	local line = lines[s.line]
	if s.tok >= 1 and line.tokens[s.tok] then
		table.remove(line.tokens, s.tok)
		if s.tok > #line.tokens then s.tok = #line.tokens end
	end
end

function OPS.op_clear (s, lines)
	for i = #lines, 2, -1 do lines[i] = nil end
	lines[1] = { indent = 0, tokens = {} }
	s.line, s.tok, s.scroll = 1, 0, 0
end

function OPS.op_left (s, lines)
	if s.tok > 1 then
		local t = lines[s.line].tokens
		t[s.tok], t[s.tok - 1] = t[s.tok - 1], t[s.tok]
		s.tok = s.tok - 1
	end
end

function OPS.op_right (s, lines)
	local t = lines[s.line].tokens
	if s.tok >= 1 and s.tok < #t then
		t[s.tok], t[s.tok + 1] = t[s.tok + 1], t[s.tok]
		s.tok = s.tok + 1
	end
end

--------------------------------------------------------------------------
-- formspec

local function tooltip_for (tok)
	local def = lang.commands[tok]
	if def then return tok .. (def.args[1] and " ..." or "") end
	return tok
end

local function cell (fs, x, y, name, tok, prev)
	local icon = ICONS[tok] or FN_ICONS[tok]
	if not icon and prev == "use" then icon = PKG_ICONS[tok] or PKG_ICONS.default end
	local cls = token_class(tok)

	if icon then
		fs[#fs + 1] = ("image_button[%g,%g;%g,%g;%s;%s;]"):format(x, y, CELL, CELL, icon, name)
	elseif cls == "item" and tok:sub(1, 1) ~= "@" and core.registered_items[tok] then
		fs[#fs + 1] = ("item_image_button[%g,%g;%g,%g;%s;%s;]"):format(x, y, CELL, CELL, esc(tok), name)
	else
		local label = tok
		if tok:sub(1, 1) == '"' then label = tok:sub(2, -2) end
		if cls == "item" then label = tok:gsub("^[^:]+:", "") end
		if #label > 9 then label = label:sub(1, 8) .. "…" end
		fs[#fs + 1] = ("style[%s;bgcolor=%s;textcolor=#ffffff]"):format(name, CLASS_COLOR[cls] or "#444444")
		fs[#fs + 1] = ("button[%g,%g;%g,%g;%s;%s]"):format(x, y, CELL, CELL, name, esc(label))
	end
	fs[#fs + 1] = ("tooltip[%s;%s]"):format(name, esc(tooltip_for(tok)))
end

local function program_tab (fs, pos, s, lines)
	local meta = core.get_meta(pos)
	local y0 = 0.9

	-- sheet
	fs[#fs + 1] = ("box[0.2,%g;%g,%g;#00000040]"):format(y0 - 0.1, SHEET_W, ROWS * STEP + 0.1)
	for row = 1, ROWS do
		local i = s.scroll + row
		local line = lines[i]
		if not line then break end
		local y = y0 + (row - 1) * STEP

		if i == s.line then
			fs[#fs + 1] = ("box[0.25,%g;%g,%g;#ffff0030]"):format(y - 0.03, SHEET_W - 0.1, CELL + 0.06)
		end

		fs[#fs + 1] = ("style[l_%d;bgcolor=%s;textcolor=#cccccc]"):format(i, i == s.line and "#665500" or "#333333")
		fs[#fs + 1] = ("button[0.3,%g;0.6,%g;l_%d;%d]"):format(y, CELL, i, i)

		local x = 1.0 + math.min(line.indent, 6) * 0.3
		local maxcells = math.floor((SHEET_W + 0.2 - x) / STEP)

		if line.tokens[1] == "#" then
			fs[#fs + 1] = ("style[c_%d_1;bgcolor=#3a3a3a;textcolor=#aaaaaa;font=italic]"):format(i)
			fs[#fs + 1] = ("button[%g,%g;%g,%g;c_%d_1;# %s]"):format(x, y, SHEET_W - x - 0.1, CELL, i,
				esc((line.tokens[2] or ""):sub(1, 70)))
		else
			for k, tok in ipairs(line.tokens) do
				if k > maxcells then
					fs[#fs + 1] = ("label[%g,%g;…]"):format(x, y + 0.4)
					break
				end
				if i == s.line and k == s.tok then
					fs[#fs + 1] = ("box[%g,%g;%g,%g;#ffff00]"):format(x - 0.05, y - 0.05, CELL + 0.1, CELL + 0.1)
				end
				cell(fs, x, y, ("c_%d_%d"):format(i, k), tok, line.tokens[k - 1])
				x = x + STEP
			end
		end
	end

	-- scrolling
	fs[#fs + 1] = ("button[%g,%g;0.6,0.6;scroll_up;▲]"):format(SHEET_W - 0.3, 0.2)
	fs[#fs + 1] = ("button[%g,%g;0.6,0.6;scroll_down;▼]"):format(SHEET_W + 0.35, 0.2)

	-- sheet tools
	local ty = y0 + ROWS * STEP + 0.1
	local tools = { { "op_insert", "insert", S("Insert line") }, { "op_delete", "delete", S("Delete line") },
		{ "op_dup", "duplicate", S("Duplicate line") }, { "op_indent", "indent", S("Indent") },
		{ "op_unindent", "unindent", S("Unindent") }, { "op_up", "line_up", S("Move line up") },
		{ "op_down", "line_down", S("Move line down") }, { "op_left", "cell_left", S("Move block left") },
		{ "op_right", "cell_right", S("Move block right") }, { "op_delcell", "cell_delete", S("Remove block") },
		{ "op_clear", "clear", S("Clear the whole program") },
		{ "op_check", "check", S("Check the program") } }
	for k, t in ipairs(tools) do
		local x = 0.3 + (k - 1) * 0.85
		fs[#fs + 1] = ("image_button[%g,%g;0.78,0.78;cogwork_ui_%s.png;%s;]"):format(x, ty, t[2], t[1])
		fs[#fs + 1] = ("tooltip[%s;%s]"):format(t[1], esc(t[3]))
	end

	-- status line under the sheet
	local unit, err = cogwork.compile_for(pos, lang.to_text(lines))
	local status
	if cogwork.is_running(pos) then
		fs[#fs + 1] = ("label[0.3,%g;%s]"):format(ty + 1.2, esc(core.colorize("#7fdf7f", S("Running (line @1)", cogwork.running_line(pos) or 0))))
	elseif meta:get_string("error") ~= "" then
		fs[#fs + 1] = ("label[0.3,%g;%s]"):format(ty + 1.2, esc(core.colorize("#ff6060", meta:get_string("error"))))
	elseif s.check then
		fs[#fs + 1] = ("label[0.3,%g;%s]"):format(ty + 1.2, esc(core.colorize(
			s.check.ok and (s.check.line and "#ffd060" or "#7fdf7f") or "#ff6060", s.check.msg)))
	elseif not unit then
		fs[#fs + 1] = ("label[0.3,%g;%s]"):format(ty + 1.2, esc(core.colorize("#ffb060", err)))
	else
		fs[#fs + 1] = ("label[0.3,%g;%s]"):format(ty + 1.2, esc(core.colorize("#7fdf7f", S("Program is fine"))))
	end

	-- right panel
	local rx = SHEET_W + 0.8
	local rw = 19.4 - rx

	local running = cogwork.is_running(pos)
	fs[#fs + 1] = ("image_button[%g,0.8;1.1,1.1;cogwork_ui_power_%s.png;op_power;]"):format(rx, running and "on" or "off")
	fs[#fs + 1] = ("tooltip[op_power;%s]"):format(esc(running and S("Stop the program") or S("Run the program")))
	if not running then
		fs[#fs + 1] = ("image_button_exit[%g,0.8;1.1,1.1;cogwork_ui_run_bg.png;op_runclose;]"):format(rx + 1.3)
		fs[#fs + 1] = ("tooltip[op_runclose;%s]"):format(esc(S("Run in Background: start the program and close this window; the robot keeps working")))
	end
	local persist = meta:get_int("persist") == 1
	fs[#fs + 1] = ("image_button[%g,0.8;1.1,1.1;cogwork_ui_persist_%s.png;op_persist;]"):format(rx + 2.6, persist and "on" or "off")
	fs[#fs + 1] = ("tooltip[op_persist;%s]"):format(esc(S("Forceload: keep the area loaded while the robot works: @1", persist and S("on") or S("off"))))

	local name = meta:get_string("bot_name")
	fs[#fs + 1] = ("label[%g,1.2;%s]"):format(rx + 3.9, esc(name ~= "" and name or S("(no name)")))
	local owner = meta:get_string("owner")
	fs[#fs + 1] = ("label[%g,1.6;%s]"):format(rx + 3.9, esc(owner ~= "" and S("Owner: @1", owner) or ""))

	-- palette categories: a row that scrolls sideways when there are more than fit
	local cat_w = 1.2
	local content_w = #PALETTE_CATS * cat_w
	fs[#fs + 1] = ("scroll_container[%g,2.1;%g,1.4;catscroll;horizontal;0.1]"):format(rx, rw)
	for k, cat in ipairs(PALETTE_CATS) do
		local x = (k - 1) * cat_w + 0.1
		local name_ = "cat_" .. cat
		if cat == s.cat then
			fs[#fs + 1] = ("box[%g,0.05;1.2,1.2;#ffff00]"):format(x - 0.1)
		end
		fs[#fs + 1] = ("image_button[%g,0.15;1.0,1.0;%s;%s;]"):format(x, ICONS[CAT_ICON[cat]], name_)
		fs[#fs + 1] = ("tooltip[%s;%s]"):format(name_, esc(CAT_TIP[cat]))
	end
	fs[#fs + 1] = "scroll_container_end[]"
	if content_w > rw then
		fs[#fs + 1] = ("scrollbaroptions[min=0;max=%d;smallstep=6;largestep=24]"):format(math.ceil((content_w - rw + 0.2) * 10))
		fs[#fs + 1] = ("scrollbar[%g,3.5;%g,0.25;horizontal;catscroll;%d]"):format(rx, rw, s.cat_scroll or 0)
	end

	local entries = palette_entries(s.cat, lines, s.pkg_view)
	s.entries = entries
	local per_row = 7
	local pw, ph = 1.05, 0.88
	local max_palette = 42
	local palette_y = 3.8
	for k, e in ipairs(entries) do
		if k > max_palette then break end
		local col, row = (k - 1) % per_row, math.floor((k - 1) / per_row)
		local x, y = rx + col * (pw + 0.1), palette_y + row * (ph + 0.1)
		local name_ = "p_" .. k
		local icon = ICONS[e.tokens[1]]
		if e.mode == "view" and e.selected then
			fs[#fs + 1] = ("box[%g,%g;%g,%g;#ffff00]"):format(x - 0.05, y - 0.05, pw + 0.1, ph + 0.1)
		end
		if e.icon then
			fs[#fs + 1] = ("image_button[%g,%g;%g,%g;%s;%s;]"):format(x, y, pw, ph, e.icon, name_)
		elseif e.label then
			fs[#fs + 1] = ("style[%s;bgcolor=%s;textcolor=#ffffff;font_size=-3]"):format(name_,
				e.selected and "#7a5aa8" or "#335577")
			fs[#fs + 1] = ("button[%g,%g;%g,%g;%s;%s]"):format(x, y, pw, ph, name_, esc(e.label))
		elseif e.mode == "token" and not (icon and ICONS[e.tokens[1]]) then
			fs[#fs + 1] = ("button[%g,%g;%g,%g;%s;%s]"):format(x, y, pw, ph, name_, esc(e.tokens[1]))
		else
			fs[#fs + 1] = ("image_button[%g,%g;%g,%g;%s;%s;]"):format(x, y, pw, ph, icon or "", name_)
		end
		fs[#fs + 1] = ("tooltip[%s;%s]"):format(name_, esc(e.tip or e.tokens[1]))
	end

	-- options for the selected token
	local opts = options_for(lines[s.line], s.tok)
	s.options = opts
	local oy = 8.0
	if #opts > 0 then
		fs[#fs + 1] = ("label[%g,%g;%s]"):format(rx, oy - 0.2, esc(S("Change the selected block")))
		for k, o in ipairs(opts) do
			local name_ = "o_" .. k
			fs[#fs + 1] = ("image_button[%g,%g;0.8,0.8;%s;%s;]"):format(rx + (k - 1) * 0.85, oy, ICONS[o] or "", name_)
			fs[#fs + 1] = ("tooltip[%s;%s]"):format(name_, esc(o))
		end
	end

	-- value field
	local vy = 9.1
	fs[#fs + 1] = ("field[%g,%g;3.2,0.8;val;%s;]"):format(rx, vy + 0.2, esc(S("Value")))
	fs[#fs + 1] = "field_close_on_enter[val;false]"
	fs[#fs + 1] = ("button[%g,%g;1.0,0.8;val_set;%s]"):format(rx + 3.3, vy + 0.2, esc(S("Set")))
	fs[#fs + 1] = ("button[%g,%g;1.7,0.8;val_ins;%s]"):format(rx + 4.4, vy + 0.2, esc(S("Add after")))
	fs[#fs + 1] = ("button[%g,%g;1.4,0.8;val_text;%s]"):format(rx + 6.2, vy + 0.2, esc(S("As text")))
	fs[#fs + 1] = ("tooltip[val_text;%s]"):format(esc(S("Set the selected block to the whole text, spaces included")))
	fs[#fs + 1] = ("tooltip[val_set;%s]"):format(esc(S("Replace the selected block")))
	fs[#fs + 1] = ("tooltip[val_ins;%s]"):format(esc(S("Insert after the selected block")))

	-- items: one button opens the picker with everything the robot and the player carry
	fs[#fs + 1] = ("button[%g,%g;%g,0.8;pick_item;%s]"):format(rx, vy + 1.3, rw - 0.4, esc(S("Pick an item...")))
	fs[#fs + 1] = ("tooltip[pick_item;%s]"):format(esc(S("Choose an item from the robot's storage or your inventory")))
end

local function text_tab (fs, pos, s, lines)
	local text = lang.to_text(lines)
	fs[#fs + 1] = ("textarea[0.3,0.9;13.2,9.6;text;%s;%s]"):format(esc(S("Program text (two spaces per level)")), esc(text))
	fs[#fs + 1] = ("button[0.3,10.9;3,0.9;text_apply;%s]"):format(esc(S("Apply")))
	fs[#fs + 1] = ("button[3.4,10.9;3,0.9;text_check;%s]"):format(esc(S("Check program")))
	local unit, err = cogwork.compile_for(pos, text)
	fs[#fs + 1] = ("label[6.7,11.35;%s]"):format(esc(s.check and core.colorize(s.check.ok and "#7fdf7f" or "#ff6060", s.check.msg) or unit and core.colorize("#7fdf7f", S("Program is fine")) or core.colorize("#ffb060", err)))
	local names = {}
	for _, n in ipairs(cogwork.list_packages()) do names[#names + 1] = n end
	fs[#fs + 1] = ("textarea[13.8,0.9;5.6,9.6;;%s;%s]"):format(esc(S("Packages")),
		esc(table.concat(names, "\n") .. "\n\n" .. S("Items: default:stone, or @stone for the game's own.\nAliases: @1", table.concat(cogwork.compat.alias_names(), " @"))))
end

-- Returns the height the window needs: the storage grows with Storage Upgrades.
local function storage_tab (fs, pos, s)
	local spos = pos.x .. "," .. pos.y .. "," .. pos.z
	cogwork.sync_storage(pos)
	local size = core.get_meta(pos):get_inventory():get_size("main")
	local rows = math.max(1, math.ceil(size / 8))

	fs[#fs + 1] = ("label[0.4,1.0;%s]"):format(esc(S("Robot storage: @1 slots (a Storage Upgrade adds @2)", size, cogwork.STORAGE_PER_UPGRADE)))
	fs[#fs + 1] = slot_bg(0.4, 1.3, 8, rows)
	fs[#fs + 1] = ("list[nodemeta:%s;main;0.4,1.3;8,%d;]"):format(spos, rows)

	local inv_y = 1.3 + rows * 1.25 + 0.5
	fs[#fs + 1] = ("label[0.4,%g;%s]"):format(inv_y, esc(S("Inventory")))
	fs[#fs + 1] = slot_bg(0.4, inv_y + 0.3, 8, 4)
	fs[#fs + 1] = ("list[current_player;main;0.4,%g;8,4;]"):format(inv_y + 0.3)
	fs[#fs + 1] = ("listring[nodemeta:%s;main]listring[current_player;main]"):format(spos)
	return math.max(12.2, inv_y + 0.3 + 5.0 + 0.4)
end

-- what the structure slots hold, in words
local function structure_lines (pos)
	local inv = core.get_meta(pos):get_inventory()
	local armor = inv:get_stack("armor", 1)
	local lines = {}

	local durability, max = cogwork.armor_info(armor)
	lines.armor = durability
		and S("@1: @2 / @3 durability", armor:get_definition().short_description or armor:get_name(), math.floor(durability), max)
		or S("No armor: the robot will not run")
	lines.armor_worn = durability and durability <= 0 and S("Worn out: protects nothing") or ""

	local mod = inv:get_stack("armor_mod", 1)
	lines.mod = mod:is_empty() and S("(none)") or (mod:get_definition().short_description or mod:get_name())

	lines.cells = {}
	for i = 1, 2 do
		local charge, capacity = cogwork.cell_info(inv:get_stack("cells", i))
		lines.cells[i] = charge and S("Cell @1: @2 / @3", i, math.floor(charge), capacity) or S("Cell @1: empty slot", i)
	end

	local aug = inv:get_stack("augment", 1)
	lines.augment = aug:is_empty() and S("(none)") or (aug:get_definition().short_description or aug:get_name())
	lines.why = cogwork.cannot_run(pos)
	return lines
end

-- what the side text of the Structure tab says, in one string (to see it changed)
function cogwork.structure_signature (pos)
	local lines = structure_lines(pos)
	return table.concat({ lines.armor, lines.armor_worn, lines.mod, lines.cells[1], lines.cells[2], lines.augment,
		lines.why or "", cogwork.height_text(pos), tostring(cogwork.active_cell(pos)) }, "|")
end

local function structure_tab (fs, pos, s)
	cogwork.ensure_structure(pos)
	local spos = pos.x .. "," .. pos.y .. "," .. pos.z
	local lines = structure_lines(pos)
	s.signature = cogwork.structure_signature(pos)
	local active = cogwork.active_cell(pos)

	fs[#fs + 1] = ("label[0.6,1.0;%s]"):format(esc(S("Armor")))
	fs[#fs + 1] = slot_bg(0.6, 1.3, 1, 1)
	fs[#fs + 1] = ("list[nodemeta:%s;armor;0.6,1.3;1,1;]"):format(spos)
	fs[#fs + 1] = ("label[2.2,1.6;%s]"):format(esc(lines.armor))
	fs[#fs + 1] = ("label[2.2,2.1;%s]"):format(esc(lines.armor_worn))

	fs[#fs + 1] = ("label[0.6,3.0;%s]"):format(esc(S("Armor modification")))
	fs[#fs + 1] = slot_bg(0.6, 3.3, 1, 1)
	fs[#fs + 1] = ("list[nodemeta:%s;armor_mod;0.6,3.3;1,1;]"):format(spos)
	fs[#fs + 1] = ("label[2.2,3.8;%s]"):format(esc(lines.mod))

	fs[#fs + 1] = ("label[0.6,5.0;%s]"):format(esc(S("Power cells")))
	fs[#fs + 1] = slot_bg(0.6, 5.3, 2, 1)
	fs[#fs + 1] = ("list[nodemeta:%s;cells;0.6,5.3;2,1;]"):format(spos)
	-- the cell the robot draws its power from first (the other one when it is empty)
	for i = 1, 2 do
		fs[#fs + 1] = ("label[3.4,%g;%s]"):format(5.45 + (i - 1) * 0.65, esc(lines.cells[i]))
		fs[#fs + 1] = ("button[6.4,%g;2.8,0.55;cell_use_%d;%s]"):format(5.2 + (i - 1) * 0.65, i,
			esc(active == i and S("Drawing from it") or S("Draw from it")))
	end

	fs[#fs + 1] = ("label[0.6,7.0;%s]"):format(esc(S("Power augmentation")))
	fs[#fs + 1] = slot_bg(0.6, 7.3, 1, 1)
	fs[#fs + 1] = ("list[nodemeta:%s;augment;0.6,7.3;1,1;]"):format(spos)
	fs[#fs + 1] = ("label[2.2,7.8;%s]"):format(esc(lines.augment))

	local status = lines.why and core.colorize("#ff9060", lines.why) or core.colorize("#7fdf7f", S("Ready to run"))
	fs[#fs + 1] = ("label[0.6,9.3;%s]"):format(esc(status))
	fs[#fs + 1] = ("label[0.6,10.0;%s]"):format(esc(S("Runs only with armor and a charged cell.\nA Small cell lasts about 450 moves.")))

	fs[#fs + 1] = ("label[9.6,1.0;%s]"):format(esc(S("Inventory")))
	fs[#fs + 1] = slot_bg(9.6, 1.3, 8, 4)
	fs[#fs + 1] = "list[current_player;main;9.6,1.3;8,4;]"
	-- the upgrades: under the inventory, nothing else on this side below it
	cogwork.ensure_upgrade_slots(pos)
	fs[#fs + 1] = ("label[9.6,6.9;%s]"):format(esc(S("Upgrades")))
	fs[#fs + 1] = slot_bg(9.6, 7.2, cogwork.UPGRADE_SLOTS, 1)
	fs[#fs + 1] = ("list[nodemeta:%s;upgrades;9.6,7.2;%d,1;]"):format(spos, cogwork.UPGRADE_SLOTS)
	fs[#fs + 1] = ("label[9.6,8.8;%s]"):format(esc(cogwork.height_text(pos)))
	fs[#fs + 1] = ("label[9.6,9.3;%s]"):format(esc(S("Hover Upgrade: one more block above the floor.")))
	fs[#fs + 1] = ("label[9.6,9.7;%s]"):format(esc(S("Flight Upgrade: no limit above the floor, a drone.")))
	fs[#fs + 1] = ("label[9.6,10.1;%s]"):format(esc(S("Combat Upgrade: the punch can hit players.")))
	fs[#fs + 1] = ("label[9.6,10.5;%s]"):format(esc(S("Storage Upgrade: 4 more storage slots.")))
	fs[#fs + 1] = ("label[9.6,10.9;%s]"):format(esc(S("Without upgrades: 1 block above the floor.")))

	for _, list in ipairs({ "armor", "armor_mod", "cells", "augment", "upgrades" }) do
		fs[#fs + 1] = ("listring[current_player;main]listring[nodemeta:%s;%s]"):format(spos, list)
	end
end

local function package_source (pos, name)
	local mine = cogwork.robot_packages(pos)[name]
	if mine then return mine, true end
	local pkg = lang.packages[name]
	return pkg and pkg.source, false
end

local function packages_tab (fs, pos, s)
	local names, seen = {}, {}
	for n in pairs(cogwork.robot_packages(pos)) do names[#names + 1] = n seen[n] = true end
	for _, n in ipairs(cogwork.list_packages()) do
		if not seen[n] then names[#names + 1] = n end
	end
	table.sort(names)
	s.pkg_names = names

	local selected = 1
	for k, n in ipairs(names) do if n == s.pkg then selected = k end end
	if names[selected] then s.pkg = names[selected] end

	local rows = {}
	for k, n in ipairs(names) do
		local _, mine = package_source(pos, n)
		local pkg = lang.packages[n]
		local title = mine and S("@1 (installed in this robot)", n) or (n .. "  " .. ((pkg and pkg.meta.title) or ""))
		rows[k] = esc(title)
	end

	fs[#fs + 1] = ("label[0.4,1.0;%s]"):format(esc(S("Packages you can use with 'use name'")))
	fs[#fs + 1] = ("textlist[0.4,1.3;6.4,4.0;pkg_list;%s;%d;false]"):format(table.concat(rows, ","), selected)

	local src, mine = "", false
	if s.pkg then src, mine = package_source(pos, s.pkg) end
	fs[#fs + 1] = ("textarea[7.2,1.3;12.2,4.0;;%s;%s]"):format(esc(s.pkg and (lang.packages[s.pkg] and lang.packages[s.pkg].meta.description or "") or ""), esc(src or ""))

	fs[#fs + 1] = ("button[7.2,5.5;3.6,0.8;pkg_disk;%s]"):format(esc(S("Write to the disk")))
	fs[#fs + 1] = ("field[11.0,5.7;3.8,0.7;pkg_name;%s;%s]"):format(esc(S("Name for the disk")), esc(s.pkg_new or ""))
	fs[#fs + 1] = ("button[15.0,5.5;4.4,0.8;pkg_mine;%s]"):format(esc(S("My functions to disk")))
	if s.msg ~= "" then
		fs[#fs + 1] = ("label[0.4,6.55;%s]"):format(esc(s.msg))
	end

	fs[#fs + 1] = ("label[0.4,6.9;%s]"):format(esc(S("Inventory")))
	fs[#fs + 1] = slot_bg(0.4, 7.1, 8, 4)
	fs[#fs + 1] = "list[current_player;main;0.4,7.1;8,4;]"

	local spos = ("%d,%d,%d"):format(pos.x, pos.y, pos.z)
	fs[#fs + 1] = ("label[10.8,7.1;%s]"):format(esc(S("Disk slot:")))
	fs[#fs + 1] = slot_bg(10.8, 7.4, 1, 1)
	fs[#fs + 1] = ("list[nodemeta:%s;disk;10.8,7.4;1,1;]"):format(spos)
	fs[#fs + 1] = ("button[12.2,7.5;3.6,0.8;pkg_install;%s]"):format(esc(S("Install it")))
	if mine then
		fs[#fs + 1] = ("button[12.2,8.5;3.6,0.8;pkg_remove;%s]"):format(esc(S("Remove from robot")))
	end
	fs[#fs + 1] = ("label[10.8,9.7;%s]"):format(esc(S("Shift-click moves a disk between\nyour inventory and the slot.")))
	fs[#fs + 1] = ("listring[nodemeta:%s;disk]listring[current_player;main]"):format(spos)
end

local function settings_tab (fs, pos, s)
	local meta = core.get_meta(pos)
	fs[#fs + 1] = ("field[0.5,1.5;6,0.8;bot_name;%s;%s]"):format(esc(S("Robot name")), esc(meta:get_string("bot_name")))
	fs[#fs + 1] = ("button[6.7,1.5;2,0.8;name_set;%s]"):format(esc(S("Set")))
	fs[#fs + 1] = ("checkbox[0.5,3;public;%s;%s]"):format(esc(S("Public: anyone can use this robot")), meta:get_int("public") == 1 and "true" or "false")
	fs[#fs + 1] = ("label[0.5,4.2;%s]"):format(esc(S("Owner: @1", meta:get_string("owner"))))
	fs[#fs + 1] = ("label[0.5,5;%s]"):format(esc(S("Position: @1", core.pos_to_string(pos))))

	-- who may go into the robot's room (sneak + right-click)
	local lock = cogwork.room_lock(pos)
	local at = 1
	for i, mode in ipairs(cogwork.ROOM_LOCKS) do if mode == lock then at = i end end
	fs[#fs + 1] = ("label[0.5,6.3;%s]"):format(esc(S("Entrance of the room (sneak + right-click)")))
	fs[#fs + 1] = ("dropdown[0.5,6.6;6,0.8;room_lock;%s,%s,%s;%d;true]"):format(
		esc(S("Anyone who can use the robot")), esc(S("Owner and the players allowed here")), esc(S("Owner only")), at)

	-- robot to robot messages
	local x = 10.0
	fs[#fs + 1] = ("label[%g,1.1;%s]"):format(x, esc(S("Robots allowed to message this one")))
	fs[#fs + 1] = ("label[%g,1.5;%s]"):format(x, esc(S("Your own robots always are. A player name allows all their robots, Player/RobotName just one.")))
	fs[#fs + 1] = ("field[%g,2.2;5.4,0.8;allow_name;;]"):format(x)
	fs[#fs + 1] = "field_close_on_enter[allow_name;false]"
	fs[#fs + 1] = ("button[%g,2.2;1.8,0.8;allow_add;%s]"):format(x + 5.6, esc(S("Allow")))
	local allow = {}
	for _, e in ipairs(cogwork.bot_allow_list(pos)) do allow[#allow + 1] = esc(e) end
	fs[#fs + 1] = ("textlist[%g,3.2;7.4,2.4;allow_sel;%s;%d]"):format(x, table.concat(allow, ","), s.allow_sel or 0)
	fs[#fs + 1] = ("button[%g,5.7;3.4,0.8;allow_remove;%s]"):format(x, esc(S("Remove selected")))

	local heard = {}
	for _, e in ipairs(cogwork.listeners_of(pos)) do heard[#heard + 1] = esc(e) end
	fs[#fs + 1] = ("label[%g,7.0;%s]"):format(x, esc(S("Listening to this robot now (running, and registered for robot messages)")))
	fs[#fs + 1] = ("textlist[%g,7.3;7.4,2.6;;%s]"):format(x, #heard > 0 and table.concat(heard, ",") or esc(S("(nobody)")))
end

local function hx (text)
	return (text:gsub("[\\<>]", "\\%0"))
end

local function help_text ()
	local esc = hx
	local out = {}
	local function p (s) out[#out + 1] = s end

	p("<big>" .. esc(S("Cogwork")) .. "</big>")
	p(esc(S("A program is a list of lines. Each line is a command followed by what it works on. Lines indented further belong to the line above (if, loop, repeat, fn).")))
	p("")
	p("<b>" .. esc(S("Actions")) .. "</b>")
	local names = {}
	for n, d in pairs(lang.commands) do
		if d.kind == "action" then names[#names + 1] = n end
	end
	table.sort(names)
	p(esc(table.concat(names, ", ")))
	p("")
	p("<b>" .. esc(S("Values and conditions")) .. "</b>")
	names = {}
	for n, d in pairs(lang.commands) do
		if d.kind == "query" then names[#names + 1] = n end
	end
	table.sort(names)
	p(esc(table.concat(names, ", ") .. ", + - * / % = != < > <= >= and or not matches"))
	p("")
	p("<b>" .. esc(S("Directions")) .. "</b>")
	p("front, front_up, front_down, back, back_up, back_down, up, down; move: forward back up down; turn: left right around")
	p("")
	p("<b>" .. esc(S("Functions")) .. "</b>")
	p(esc(S("fn name a b  defines a function. 'call name 1 2' runs it, 'return value' gives a value back: set r = call name 1 2. Put arguments that are sums in brackets: call walk (n - 1).")))
	p("")
	p("<b>" .. esc(S("Packages")) .. "</b>")
	p(esc(S("'use mining' makes a package's functions available. Names can also be written package.function. Packages are made of functions only; copy yours to a disk and install it in another robot.")))
	p("")
	p("<b>" .. esc(S("Events")) .. "</b>")
	p(esc(S("use events, then call events.register_nodes / register_entities r / register_items r / register_chat / register_whisper / register_bot with the name of one of your functions in quotes, then call events.process. It handles events until a handler calls events.leave. Messages: chat (owner, no limit), say (everyone) and whisper (one player) are limited per player; tell_bot and tell_bots reach robots that allow this one in their Settings tab.")))
	p("")
	p("<b>" .. esc(S("Inside the robot")) .. "</b>")
	p(esc(S("Sneak and right-click a robot to go into it: a room with a viewscreen showing what the robot sees, a chest (its storage), a bay (armor, cells, upgrades), a terminal (the program), a settings panel (name, access and the lock on the entrance) and a controller (move and turn it). The door, or /leave_robot, takes you out.")))
	p("")
	p("<b>" .. esc(S("Structure and power")) .. "</b>")
	p(esc(S("A robot runs only with armor and a power cell that has charge (Structure tab); without them it stays off, and it stops when they go. Every action costs power, a Small cell lasts about 450 moves. Armor never breaks, at no durability it protects nothing and damage goes to the cells. install \"cell\" / \"armor_mod\" / \"augment\" and uninstall put parts from and to storage (a cell only while another stays; the armor is for players). battery_level and armor_level are percent, cell_count, structure_item \"cell1\".")))
	p("")
	p("<b>" .. esc(S("Machines, upgrades")) .. "</b>")
	p(esc(S("The nodes event hands the handler: dir node change detail, where change is node, inventory, timer, state or power. machine_state/_power/_level/_capacity front, network_level front, node_timer front, node_stock front item read the block next to the robot (-1 when unknown); machine_switch front \"off\" turns a Skyblock: Zero, Technic or Techage machine on or off. A robot can be 1 block above the floor; each Hover Upgrade adds a block, a Flight Upgrade removes the limit (six upgrade slots in the Structure tab). height_limit is the limit, -1 flying.")))
	p("")
	p("<b>" .. esc(S("Punch and pathfinding")) .. "</b>")
	p(esc(S("punch front: pick up dropped items there, else hit the entity there; punch front default:sword_steel hits with that tool from storage. Players are never hit. 'entity front' is the name of the entity there. use pathfind, then call pathfind.goto x y z or call pathfind.goto_entity name: they walk there and give 0 when arrived, -1 when there is no way. pathfind.start/start_entity plan only (steps, or -1), pathfind.step moves one step (steps left). Routes are re-planned while walking. Unloaded terrain is a wall unless Forceload is on.")))
	p("")
	p("<b>" .. esc(S("Items")) .. "</b>")
	p(esc(S("Write item names in full (default:stone) or as @stone, @cobble, @dirt, @planks, @torch, @chest ... which pick the matching item of the game being played.")))
	p("")
	p("<b>" .. esc(S("Running")) .. "</b>")
	p(esc(S("Press the power button. Sneak + punch a running robot to stop it. Punch a robot with a cassette to copy its program; sneak + right-click with a cassette to load one (without one, sneak + right-click goes into the robot).")))
	return table.concat(out, "\n")
end

local function help_tab (fs)
	fs[#fs + 1] = ("hypertext[0.4,0.9;19,10.8;help;%s]"):format(core.formspec_escape(help_text()))
end

function cogwork.formspec (pos, s)
	local lines = get_lines(pos)
	clamp_cursor(s, lines)

	local fs = { "formspec_version[6]", "size[19.8,12.2]", "bgcolor[#1c1c24f0;true]" }
	local height = 12.2
	local idx = 1
	for k, t in ipairs(TABS) do if t == s.tab then idx = k end end
	fs[#fs + 1] = ("tabheader[0,0;ed_tab;%s;%d;false;true]"):format(table.concat(TAB_LABELS, ","), idx)

	if s.tab == "program" then program_tab(fs, pos, s, lines)
	elseif s.tab == "text" then text_tab(fs, pos, s, lines)
	elseif s.tab == "storage" then height = storage_tab(fs, pos, s)
	elseif s.tab == "structure" then structure_tab(fs, pos, s)
	elseif s.tab == "packages" then packages_tab(fs, pos, s)
	elseif s.tab == "settings" then settings_tab(fs, pos, s)
	else help_tab(fs) end

	fs[2] = ("size[19.8,%g]"):format(height)
	return table.concat(fs)
end

function cogwork.show_editor (pos, player)
	local s = session(player)
	s.pos = vector.new(pos)
	s.player = player
	s.shown = FORMNAME
	core.show_formspec(player:get_player_name(), FORMNAME, cogwork.formspec(pos, s))
end

-- Parts went in or out of the robot, or its power changed: the Storage and Structure tabs
-- open on it are drawn again (the side text shows what is in the slots).
local function redraw_later (name, s, delay)
	s.redraw = (s.redraw or 0) + 1
	local token = s.redraw
	core.after(delay, function ()
		local player = core.get_player_by_name(name)
		if not player or s.redraw ~= token or not s.pos or s.shown ~= FORMNAME then return end
		cogwork.show_editor(s.pos, player)
	end)
end

function cogwork.editor_refresh (pos)
	for name, s in pairs(sessions) do
		if s.pos and vector.equals(s.pos, pos) and s.shown == FORMNAME and (s.tab == "structure" or s.tab == "storage") then
			redraw_later(name, s, 0.05)
		end
	end
end

-- a charge that changed while the Structure tab is open (the generator, the repair module)
local refresh_clock = 0
core.register_globalstep(function (dt)
	refresh_clock = refresh_clock + dt
	if refresh_clock < 2 then return end
	refresh_clock = 0
	for name, s in pairs(sessions) do
		if s.pos and s.shown == FORMNAME and s.tab == "structure" and s.signature then
			local node = core.get_node_or_nil(s.pos)
			if node and cogwork.is_robot(node.name) and cogwork.structure_signature(s.pos) ~= s.signature then
				redraw_later(name, s, 0)
			end
		end
	end
end)

-- The robot moved: the windows open on it follow it. The slots in the window are
-- tied to the place, so an editor left where it was would show empty lists. A program
-- moves the robot often: the window is drawn again once it has stopped for a moment.
function cogwork.editor_robot_moved (from, to)
	for name, s in pairs(sessions) do
		if s.pos and vector.equals(s.pos, from) then
			s.pos = vector.new(to)
			if s.shown == FORMNAME then
				s.redraw = (s.redraw or 0) + 1
				local token = s.redraw
				core.after(0.3, function ()
					local player = core.get_player_by_name(name)
					if not player or s.redraw ~= token or not s.pos or s.shown ~= FORMNAME then return end
					cogwork.show_editor(s.pos, player)
				end)
			end
		end
	end
end

--------------------------------------------------------------------------
-- events

cogwork.on_editor_fields = function (player, formname, fields)
	if formname ~= FORMNAME then return end

	local s = session(player)
	local pos = s.pos
	if not pos then return end

	local node = core.get_node_or_nil(pos)
	if not node or not cogwork.is_robot(node.name) or not cogwork.can_access(pos, player) then
		core.close_formspec(player:get_player_name(), FORMNAME)
		return true
	end

	s.player = player
	local pname = player:get_player_name()
	local meta = core.get_meta(pos)

	if fields.quit then
		-- closed by the player: nothing reopens it
		s.shown = nil
		if not fields.op_runclose then s.pos = nil end
		if not fields.op_runclose then return true end
	end

	if fields.ed_tab then
		s.tab = TABS[tonumber(fields.ed_tab)] or "program"
		s.msg = ""
		cogwork.show_editor(pos, player)
		return true
	end

	if s.tab == "program" or s.tab == "text" then
		local lines = get_lines(pos)
		local changed = false
		local closing = false

		for name in pairs(fields) do
			local ln, tk = name:match("^c_(%d+)_(%d+)$")
			if ln then
				s.line, s.tok = tonumber(ln), tonumber(tk)
			elseif name:match("^l_%d+$") then
				s.line, s.tok = tonumber(name:sub(3)), 0
			elseif name:match("^cat_") then
				s.cat = name:sub(5)
			elseif name == "catscroll" then
				s.cat_scroll = tonumber(tostring(fields.catscroll):match(":(%d+)")) or s.cat_scroll
			elseif name == "scroll_up" then
				s.scroll = math.max(0, s.scroll - ROWS + 1)
			elseif name == "scroll_down" then
				s.scroll = math.min(math.max(0, #lines - ROWS), s.scroll + ROWS - 1)
			elseif name == "op_check" then
				local ok, msg, line = check_program(pos, lines)
				s.check = { ok = ok, msg = msg, line = line }
				if line then s.line, s.tok = line, 0 end
			elseif name == "op_runclose" then
				local ok, err = cogwork.start(pos)
				if not ok then
					core.chat_send_player(pname, err or "")
					s.check = { ok = false, msg = err or "" }
					closing = false
				else
					closing = true
				end
			elseif name == "op_power" then
				if cogwork.is_running(pos) then
					cogwork.stop(pos, "")
				else
					local ok, err = cogwork.start(pos)
					if not ok then core.chat_send_player(pname, err or "") end
				end
			elseif name == "pick_item" then
				cogwork.show_item_picker(pos, player)
				return true
			elseif name == "op_persist" then
				local on = meta:get_int("persist") ~= 1
				local ok, why = cogwork.set_persist(pos, on)
				if not ok then core.chat_send_player(pname, why or "") end
			elseif OPS[name] then
				clamp_cursor(s, lines)
				OPS[name](s, lines)
				changed = true
			else
				local k = name:match("^p_(%d+)$")
				local entry = k and s.entries and s.entries[tonumber(k)]
				if entry and entry.mode == "view" then
					s.pkg_view = entry.view
				elseif entry then
					clamp_cursor(s, lines)
					insert_entry(s, lines, entry)
					changed = true
				end
				k = name:match("^o_(%d+)$")
				if k and s.options and s.options[tonumber(k)] then
					lines[s.line].tokens[s.tok] = s.options[tonumber(k)]
					changed = true
				end
			end
		end

		if fields.val_set or fields.val_ins or fields.val_text then
			local raw = (fields.val or ""):gsub("^%s+", ""):gsub("%s+$", "")
			clamp_cursor(s, lines)
			local toks = field_tokens(raw)

			if raw == "" then
				toks = nil
			elseif lines[s.line].tokens[1] == "#" then
				-- a note keeps its whole text as one block
				lines[s.line].tokens = { "#", raw }
				s.tok = 2
				toks = nil
				changed = true
			elseif fields.val_text then
				toks = { '"' .. raw:gsub('"', "'") .. '"' }
			end

			if toks then
				if fields.val_set or fields.val_text then replace_or_insert(s, lines, toks)
				else insert_after(s, lines, toks) end
				changed = true
			end
		end

		if fields.text_check and fields.text then
			local tl = lang.parse_text((fields.text:gsub("\r", "")))
			local ok, msg, line = check_program(pos, tl)
			s.check = { ok = ok, msg = msg, line = line }
		end

		if fields.text_apply and fields.text then
			local text = fields.text:gsub("\r", "")
			if #text <= MAX_TEXT then
				meta:set_string("program", text)
				meta:set_string("error", "")
			end
		elseif changed then
			s.check = nil
			if not put_lines(pos, lines) then
				core.chat_send_player(pname, S("The program is too long."))
			else
				meta:set_string("error", "")
			end
		end

		if closing then
			core.close_formspec(pname, FORMNAME)
			s.pos = nil
			return true
		end
		cogwork.show_editor(pos, player)
		return true
	end

	if s.tab == "packages" then
		if fields.pkg_list then
			local ev = core.explode_textlist_event(fields.pkg_list)
			if ev.type == "CHG" or ev.type == "DCL" then
				s.pkg = s.pkg_names and s.pkg_names[ev.index]
			end
		end
		s.pkg_new = fields.pkg_name or s.pkg_new
		s.msg = ""

		if fields.pkg_disk and s.pkg then
			local src = package_source(pos, s.pkg)
			if src then
				if cogwork.write_disk(meta:get_inventory(), s.pkg, src) then
					s.msg = S("Wrote '@1' to the disk in the slot.", s.pkg)
				else
					s.msg = S("Put a package disk in the slot first.")
				end
			end
		elseif fields.pkg_mine then
			local name = (fields.pkg_name or ""):gsub("%s", "")
			local lib = cogwork.extract_functions(meta:get_string("program"))
			if not name:match("^[%a_][%w_]*$") then
				s.msg = S("Give the package a name (letters, digits, _).")
			elseif not lib then
				s.msg = S("The program has no functions to put on a disk.")
			else
				local ok, err = cogwork.validate_library(lib)
				if not ok then
					s.msg = err
				elseif cogwork.write_disk(meta:get_inventory(), name, lib) then
					s.msg = S("Wrote '@1' to the disk in the slot.", name)
				else
					s.msg = S("Put a package disk in the slot first.")
				end
			end
		elseif fields.pkg_install then
			local inv = meta:get_inventory()
			local stack = inv:get_stack("disk", 1)
			local name, src = cogwork.read_disk(stack)
			if not name then
				s.msg = S("Put a package disk in the slot first.")
			else
				local ok, err = cogwork.validate_library(src)
				if ok then
					cogwork.install_package(pos, name, src)
					s.pkg = name
					s.msg = S("Installed '@1'.", name)
				else
					s.msg = err
				end
			end
		elseif fields.pkg_remove and s.pkg then
			cogwork.remove_package(pos, s.pkg)
			s.msg = S("Removed '@1'.", s.pkg)
		end

		cogwork.show_editor(pos, player)
		return true
	end

	if s.tab == "structure" then
		for i = 1, 2 do
			if fields["cell_use_" .. i] then
				core.get_meta(pos):set_int("cell_active", i)
			end
		end
		cogwork.show_editor(pos, player)
		return true
	end

	if s.tab == "settings" then
		if fields.name_set or (fields.key_enter_field == "bot_name") then
			local n = (fields.bot_name or ""):sub(1, 40)
			meta:set_string("bot_name", n)
			meta:set_string("infotext", n ~= "" and S("Robot: @1", n) or S("Robot"))
		end
		if fields.public ~= nil then
			meta:set_int("public", fields.public == "true" and 1 or 0)
		end

		local mode = fields.room_lock and cogwork.ROOM_LOCKS[tonumber(fields.room_lock)]
		if mode ~= nil then
			meta:set_string("room_lock", mode)
			cogwork.room_recheck(pos)
		end

		local list = cogwork.bot_allow_list(pos)
		local sel = fields.allow_sel and tonumber(fields.allow_sel:match("^%a+:(%d+)$"))
		if sel then s.allow_sel = sel end

		if fields.allow_add or fields.key_enter_field == "allow_name" then
			local entry = (fields.allow_name or ""):gsub("^%s+", ""):gsub("%s+$", "")
			if entry ~= "" and #entry <= 80 and not entry:find("[\n,;%[%]]") and #list < 32 then
				local dup = false
				for _, e in ipairs(list) do if e:lower() == entry:lower() then dup = true end end
				if not dup then
					list[#list + 1] = entry
					cogwork.bot_allow_set(pos, list)
				end
			end
		elseif fields.allow_remove and s.allow_sel and list[s.allow_sel] then
			table.remove(list, s.allow_sel)
			cogwork.bot_allow_set(pos, list)
			s.allow_sel = nil
		end
		cogwork.show_editor(pos, player)
		return true
	end

	return true
end

--------------------------------------------------------------------------
-- item picker: a second window listing every item to choose from

local PICKFORM = "cogwork:items"
local PICK_COLS = 8

local function unique_items (inv, list, seen, out)
	if not inv then return end
	for _, st in ipairs(inv:get_list(list) or {}) do
		local n = st:get_name()
		if n ~= "" and not seen[n] then
			seen[n] = true
			out[#out + 1] = n
		end
	end
end

function cogwork.show_item_picker (pos, player)
	local s = session(player)
	s.pos = vector.new(pos)
	s.player = player
	s.shown = PICKFORM

	local seen = {}
	local robot, mine = {}, {}
	unique_items(core.get_meta(pos):get_inventory(), "main", seen, robot)
	unique_items(player:get_inventory(), "main", seen, mine)
	s.pick_items = {}

	local fs = { "formspec_version[6]", "size[10,9.5]", "bgcolor[#1c1c24f0;true]" }
	fs[#fs + 1] = ("label[0.4,0.5;%s]"):format(esc(S("Pick an item")))
	fs[#fs + 1] = "scroll_container[0.4,1;8.7,7;pick_scroll;vertical;0.1]"
	local y = 0
	local function section (title, list)
		fs[#fs + 1] = ("label[0,%g;%s]"):format(y + 0.3, esc(title))
		y = y + 0.6
		if #list == 0 then
			fs[#fs + 1] = ("label[0,%g;%s]"):format(y + 0.3, esc(S("(nothing)")))
			y = y + 0.8
			return
		end
		for i, n in ipairs(list) do
			local col, row = (i - 1) % PICK_COLS, math.floor((i - 1) / PICK_COLS)
			s.pick_items[#s.pick_items + 1] = n
			local name_ = "pi_" .. #s.pick_items
			fs[#fs + 1] = ("item_image_button[%g,%g;1,1;%s;%s;]"):format(col * 1.08, y + row * 1.08, esc(n), name_)
			fs[#fs + 1] = ("tooltip[%s;%s]"):format(name_, esc(n))
		end
		y = y + math.ceil(#list / PICK_COLS) * 1.08 + 0.3
	end
	section(S("In the robot"), robot)
	section(S("In your inventory"), mine)
	fs[#fs + 1] = "scroll_container_end[]"
	local total = math.max(0, y - 7)
	fs[#fs + 1] = ("scrollbaroptions[max=%d]"):format(math.ceil(total * 10 + 5))
	fs[#fs + 1] = "scrollbar[9.2,1;0.4,7;vertical;pick_scroll;0]"
	fs[#fs + 1] = ("button[0.4,8.4;3,0.8;pick_back;%s]"):format(esc(S("Back")))
	core.show_formspec(player:get_player_name(), PICKFORM, table.concat(fs))
end

core.register_on_player_receive_fields(function (player, formname, fields)
	if formname ~= PICKFORM then return end
	local s = session(player)
	local pos = s.pos
	if not pos then return true end
	local node = core.get_node_or_nil(pos)
	if not node or not cogwork.is_robot(node.name) or not cogwork.can_access(pos, player) then
		s.pos = nil
		return true
	end

	for name in pairs(fields) do
		local k = name:match("^pi_(%d+)$")
		local item = k and s.pick_items and s.pick_items[tonumber(k)]
		if item then
			local lines = get_lines(pos)
			clamp_cursor(s, lines)
			replace_or_insert(s, lines, { item })
			s.check = nil
			if put_lines(pos, lines) then
				core.get_meta(pos):set_string("error", "")
			else
				core.chat_send_player(player:get_player_name(), S("The program is too long."))
			end
			cogwork.show_editor(pos, player)
			return true
		end
	end

	-- Back, or the window was closed: return to the editor
	if fields.pick_back or fields.quit then
		cogwork.show_editor(pos, player)
	end
	return true
end)

core.register_on_player_receive_fields(cogwork.on_editor_fields)
