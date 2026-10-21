-- Runs every check below on a flat area, prints "SBT ..." lines, then
-- "SBT DONE" and shuts the server down.

local S = cogwork

-- Mineclonia protects chunks its own level generator has not made, which the
-- singlenode test world never has
if core.get_modpath("mcl_levelgen") then
	core.register_on_mods_loaded(function ()
		core.is_protected = function () return false end
	end)
end
local results = {}
local fails = 0

local function report (name, ok, extra)
	if not ok then fails = fails + 1 end
	print(("SBT %s %s%s"):format(ok and "PASS" or "FAIL", name, extra and (" -- " .. tostring(extra)) or ""))
end

local ORIGIN = { x = 0, y = 40, z = 0 }
local function P (x, y, z) return vector.add(ORIGIN, { x = x, y = y, z = z }) end

local function emerge (cb)
	core.emerge_area(P(-20, -5, -20), P(40, 15, 40), function (_, _, remaining)
		if remaining == 0 then
			-- keep the area loaded: nobody is online to do it
			for x = -16, 32, 16 do for y = -8, 16, 16 do for z = -16, 32, 16 do
				core.forceload_block(P(x, y, z), true)
			end end end
			cb()
		end
	end)
end

local function clear_area ()
	for x = -12, 30 do for y = -3, 12 do for z = -12, 30 do
		core.set_node(P(x, y, z), { name = "air" })
	end end end
	core.set_node(P(0, 0, 0), { name = "air" })
end

local material = S.compat.item("stone") or S.compat.item("matter")
local dirt = S.compat.item("dirt") or material
local chest = S.compat.item("chest")

-- place a robot at pos facing +z (front = +z), give it items and a program
local function make_robot (pos, program, items)
	core.set_node(pos, { name = "cogwork:robot", param2 = core.dir_to_facedir({ x = 0, y = 0, z = -1 }) })
	local meta = core.get_meta(pos)
	meta:get_inventory():set_size("main", 32)
	meta:get_inventory():set_size("disk", 1)
	meta:set_string("owner", "tester")
	meta:set_string("program", program)
	for _, it in ipairs(items or {}) do
		meta:get_inventory():add_item("main", it)
	end
	return pos
end

local find_robot
local function wait_for (pos, timeout, cb)
	local t = 0
	local function poll ()
		t = t + 0.5
		if os.getenv("SBT_TRACE") then
			local rp = find_robot()
			local r = select(2, next(S.running))
			print("SBT trace", rp and core.pos_to_string(vector.subtract(rp, ORIGIN)), next(S.running) ~= nil,
				r and core.pos_to_string(vector.subtract(r.bot.pos, ORIGIN)), r and core.get_node(r.bot.pos).name, r and r.ctx.line, r and coroutine.status(r.co))
		end
		if next(S.running) == nil or t > timeout then return cb(t > timeout) end
		core.after(0.5, poll)
	end
	poll()
end

local tests = {}
local function test (name, fn) tests[#tests + 1] = { name = name, fn = fn } end

local function run_program (name, program, items, setup, check, start)
	test(name, function (done)
		clear_area()
		if setup then setup() end
		local pos = make_robot(start or P(0, 1, 0), program, items)
		local ok, err = S.start(pos)
		if not ok then report(name, false, "start: " .. tostring(err)) return done() end
		wait_for(pos, 40, function (timeout)
			local node = core.get_node(pos)
			local meta
			-- the robot may have moved: find it by scanning
			local ok2, why = pcall(check, pos, timeout)
			if not ok2 then report(name, false, why) else report(name, why ~= false, timeout and "timeout" or (type(why) == "string" and why or nil)) end
			done()
		end)
	end)
end

function find_robot ()
	for x = -12, 30 do for y = -3, 12 do for z = -12, 30 do
		local p = P(x, y, z)
		local n = core.get_node(p).name
		if S.is_robot(n) then return p end
	end end end
end

local function err_of (p) return core.get_meta(p):get_string("error") end

-- ---------------------------------------------------------------- tests

run_program("move and turn",
	"move forward\nmove forward\nturn right\nmove forward\nmove up",
	nil, nil, function ()
		local p = find_robot()
		-- start (0,1,0) facing +z: +2z, then right = -x... facing +z, right is +x
		assert(p, "robot lost")
		assert(vector.equals(p, P(1, 2, 2)), "ended at " .. core.pos_to_string(vector.subtract(p, ORIGIN)) .. " " .. err_of(p))
	end)

run_program("dig and collect",
	"dig front\nmove forward\ndig down\ndig up",
	nil, function ()
		core.set_node(P(0, 1, 1), { name = material })
		core.set_node(P(0, 0, 1), { name = material })
		core.set_node(P(0, 2, 1), { name = material })
	end, function ()
		local p = find_robot()
		assert(p, "robot lost")
		local inv = core.get_meta(p):get_inventory()
		assert(not inv:is_empty("main"), "nothing collected: " .. err_of(p))
		assert(core.get_node(P(0, 0, 1)).name == "air" and core.get_node(P(0, 2, 1)).name == "air", "not dug")
	end)

run_program("place and detect",
	("repeat 3\n  place front %s\n  turn left\nif detect front %s\n  chat \"yes\""):format(material, material),
	{ material .. " 10" }, nil, function ()
		local p = find_robot()
		assert(core.get_node(P(0, 1, 1)).name == material, "no block in front: " .. err_of(p))
		assert(core.get_node(P(-1, 1, 0)).name ~= "air", "no block left")
	end)

run_program("alias placing",
	"place front @stone\nplace down @dirt",
	{ material .. " 5", dirt .. " 5" }, nil, function ()
		local p = find_robot()
		assert(err_of(p) == "", err_of(p))
		assert(core.get_node(P(0, 1, 1)).name == material, "stone alias")
	end)

run_program("functions and variables",
	"fn row n\n  repeat n\n    place down " .. material .. "\n    move forward\nset total = 0\nrepeat 2\n  call row 3\n  add total 1\n  turn right\n  turn right\n  move forward\nif total = 2\n  place front " .. material,
	{ material .. " 20" }, function ()
		core.set_node(P(0, 0, 0), { name = dirt })
	end, function ()
		local p = find_robot()
		assert(err_of(p) == "", err_of(p))
		for z = 0, 2 do
			assert(core.get_node(P(0, 0, z)).name == material or z == 0, "no floor at z=" .. z)
		end
	end)

run_program("package use",
	"use movement\ncall walk 3\ncall rise 2",
	nil, nil, function ()
		local p = find_robot()
		assert(err_of(p) == "", err_of(p))
		assert(vector.equals(p, P(0, 3, 3)), "ended " .. core.pos_to_string(vector.subtract(p, ORIGIN)))
	end)

run_program("mining package tunnel",
	"use mining\ncall tunnel 4",
	nil, function ()
		for z = 1, 5 do for y = 1, 3 do core.set_node(P(0, y, z), { name = material }) end end
	end, function ()
		local p = find_robot()
		assert(err_of(p) == "", err_of(p))
		assert(vector.equals(p, P(0, 1, 4)), "ended " .. core.pos_to_string(vector.subtract(p, ORIGIN)))
		assert(core.get_node(P(0, 2, 3)).name == "air", "ceiling not dug")
		assert(core.get_node(P(0, 1, 5)).name == material, "dug too far")
	end)

run_program("mining package layer",
	"use mining\ncall layer 3 3",
	nil, function ()
		for x = 0, 2 do for z = 0, 2 do core.set_node(P(x, 1, z), { name = material }) end end
		core.set_node(P(0, 1, 0), { name = "air" })
	end, function ()
		local p = find_robot()
		assert(err_of(p) == "", err_of(p))
		assert(vector.equals(p, P(0, 1, 0)), "did not come back: " .. core.pos_to_string(vector.subtract(p, ORIGIN)))
		for x = 0, 2 do for z = 0, 2 do
			-- start facing +z; "right" of heading is +x
			local n = core.get_node(P(x, 1, z)).name
			assert(n == "air" or (x == 0 and z == 0), "left a block at " .. x .. "," .. z .. ": " .. n)
		end end
	end, P(0, 1, 0))

run_program("building package floor",
	"use building\ncall pave 3 2 " .. material,
	{ material .. " 30" }, function ()
		for x = -1, 4 do for z = -1, 4 do core.set_node(P(x, 0, z), { name = "air" }) end end
	end, function ()
		local p = find_robot()
		assert(err_of(p) == "", err_of(p))
		for x = 0, 1 do for z = 0, 2 do
			-- the floor is under the path: rows go forward (+z) and shift right (-x)
		end end
		local n = 0
		for x = -1, 2 do for z = 0, 3 do
			if core.get_node(P(x, 0, z)).name == material then n = n + 1 end
		end end
		assert(n == 6, "placed " .. n .. " blocks")
	end)

run_program("function return value",
	"use math\nset r = call max 3 9\nrepeat r\n  move up",
	nil, nil, function ()
		local p = find_robot()
		assert(err_of(p) == "", err_of(p))
		assert(vector.equals(p, P(0, 10, 0)), "ended " .. core.pos_to_string(vector.subtract(p, ORIGIN)))
	end)

run_program("runtime error reported",
	"set x = 1 / 0",
	nil, nil, function ()
		local p = find_robot()
		assert(err_of(p):find("divide by zero"), "error is: '" .. err_of(p) .. "'")
	end)

run_program("blocked move is not an error",
	"move forward\nif ok\n  chat \"moved\"\nelse\n  move up",
	nil, function ()
		core.set_node(P(0, 1, 1), { name = material })
	end, function ()
		local p = find_robot()
		assert(vector.equals(p, P(0, 2, 0)), "ended " .. core.pos_to_string(vector.subtract(p, ORIGIN)))
	end)

run_program("craft",
	"craft " .. (S.compat.item("stick") or "default:stick"),
	nil, nil, function () return true end)

if chest then
	run_program("pull and put with a chest",
		"pull\nturn around\nplace front " .. material .. "\nturn around\nput " .. material,
		{ material .. " 2" }, function ()
			core.set_node(P(0, 1, 1), { name = chest, param2 = 0 })
			local inv = core.get_meta(P(0, 1, 1)):get_inventory()
			inv:add_item("main", "air")
			inv:add_item("main", (S.compat.item("coal") or material) .. " 3")
		end, function ()
			local p = find_robot()
			assert(p, "robot lost")
			assert(err_of(p) == "", err_of(p))
			local rinv = core.get_meta(p):get_inventory()
			local coal = S.compat.item("coal")
			if coal then assert(rinv:contains_item("main", coal .. " 3"), "pull failed") end
		end)
end

-- the editor builds without errors for every tab
test("editor formspec", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "use mining\ncall tunnel 3\nif detect front\n  dig front", { material .. " 4" })
	local fake = { get_player_name = function () return "tester" end,
		get_inventory = function () return nil end, is_player = function () return true end }
	local s = { tab = "program", line = 2, tok = 2, scroll = 0, cat = "fn", msg = "", player = fake, pos = pos }
	local ok, err = true, nil
	for _, tab in ipairs({ "program", "text", "storage", "packages", "settings", "help" }) do
		s.tab = tab
		local good, res = pcall(S.formspec, pos, s)
		if not good or type(res) ~= "string" or #res < 50 then ok, err = false, tab .. ": " .. tostring(res) end
	end
	for _, cat in ipairs({ "flow", "move", "world", "inventory", "var", "check", "fn" }) do
		s.tab, s.cat = "program", cat
		local good, res = pcall(S.formspec, pos, s)
		if not good then ok, err = false, cat .. ": " .. tostring(res) end
	end
	report("editor formspec", ok, err)
	done()
end)

test("robot can be dug by hand", function (done)
	for _, name in ipairs({ "cogwork:robot", "cogwork:robot_on" }) do
		local def = core.registered_nodes[name]
		local ok, info
		if core.get_modpath("mcl_core") then
			-- Mineclonia/VoxeLibre dig with their own tables: the hand-dig
			-- group their autogroup mod derives from "handy"
			ok = (def.groups.handy_dig or 0) > 0
			info = "handy_dig=" .. tostring(def.groups.handy_dig)
		else
			local params = core.get_dig_params(def.groups, ItemStack(""):get_tool_capabilities())
			ok, info = params.diggable, params.time
		end
		report("hand digs " .. name, ok, info)
	end
	done()
end)

test("editor events and check", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "# a note\nchat \"x\"\nmove up", nil)
	local fake = { get_player_name = function () return "tester" end,
		get_inventory = function () return nil end, is_player = function () return true end,
		get_player_control = function () return {} end }
	local function send (fields)
		S.on_editor_fields(fake, "cogwork:ed", fields)
	end
	local function lines () return core.get_meta(pos):get_string("program") end
	local s = S.editor_session(fake)
	s.pos, s.player, s.tab = pos, fake, "program"

	s.line, s.tok = 1, 2
	send({ val = "hello big world", val_set = "Set" })
	report("note keeps all words", lines():find("^# hello big world\n"), lines())

	s.line, s.tok = 2, 2
	send({ val = "hello world", val_text = "As text" })
	report("as text quotes it", lines():find('chat "hello world"', 1, true), lines())

	local ok, msg, line = S.check_program(pos, "move up\nmove sideways")
	report("check finds bad direction", ok == false and line == 2, tostring(msg))
	ok, msg = S.check_program(pos, "place front nomod:nothing")
	report("check finds unknown item", ok == true and msg:find("unknown item"), tostring(msg))
	ok, msg, line = S.check_program(pos, "move up")
	report("check passes", ok and line == nil, tostring(msg))

	core.get_meta(pos):set_string("program", "move up\nmove up")
	s.tab = "program"
	send({ quit = "true", op_runclose = "Run and close" })
	report("run and close starts", S.is_running(pos))
	report("run and close forgets the form", s.pos == nil)
	S.stop(pos, "")
	-- a form closed with Esc must not come back
	s.pos = pos
	send({ quit = "true" })
	report("quit forgets the form", s.pos == nil)
	done()
end)

test("packages compile", function (done)
	local ok = true
	for _, name in ipairs(S.list_packages()) do
		local good, err = S.check_package(name)
		if not good then ok = false report("package " .. name, false, err) end
	end
	report("packages compile", ok)
	done()
end)

test("recipes registered", function (done)
	for _, item in ipairs({ "cogwork:robot", "cogwork:cassette", "cogwork:disk" }) do
		local r = core.get_all_craft_recipes(item)
		report("recipe " .. item, r ~= nil and #r > 0)
	end
	done()
end)

test("package disk round trip", function (done)
	local lib = S.extract_functions("move up\nfn go n\n  repeat n\n    move forward\nuse movement\ncall go 2")
	local ok, err = S.validate_library(lib or "")
	report("extract functions", lib ~= nil and ok, err or lib)
	local bad = S.validate_library("move up")
	report("library rejects statements", bad == nil)
	done()
end)

local function run_all ()
	local i = 0
	local function nextt ()
		i = i + 1
		local t = tests[i]
		if not t then
			print("SBT DONE fails=" .. fails)
			core.request_shutdown("test done", false, 0)
			return
		end
		local called = false
		local ok, err = pcall(t.fn, function ()
			if called then return end
			called = true
			core.after(0.1, nextt)
		end)
		if not ok then report(t.name, false, err) core.after(0.1, nextt) end
	end
	nextt()
end

core.register_on_mods_loaded(function ()
	-- Mineclonia's level generator keeps working on the area for a while
	core.after(core.get_modpath("mcl_levelgen") and 15 or 1, function () emerge(function () core.after(core.get_modpath("mcl_levelgen") and 10 or 0, run_all) end) end)
end)
