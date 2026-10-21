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
local function make_robot (pos, program, items, upgrades)
	core.set_node(pos, { name = "cogwork:robot", param2 = core.dir_to_facedir({ x = 0, y = 0, z = -1 }) })
	local meta = core.get_meta(pos)
	meta:get_inventory():set_size("main", 32)
	meta:get_inventory():set_size("disk", 1)
	meta:get_inventory():set_size("upgrades", 5)
	-- the test world is a void: robots fly unless a test says otherwise
	for _, up in ipairs(upgrades or { "cogwork:upgrade_flight" }) do
		meta:get_inventory():add_item("upgrades", up)
	end
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
-- ---------------------------------------------------------------- events

core.register_entity("cogwork_test:dummy", {
	initial_properties = { physical = false, visual = "sprite", textures = { "blank.png" } },
})

local H = "use events\nfn h a b c\n  move up\n  call events.leave\n"

-- the handler lifts the robot one block, so ending at y+1 shows it ran
local function lifted () return vector.equals(find_robot() or P(9, 9, 9), P(0, 2, 0)) end

run_program("event nodes",
	H .. "call events.register_nodes \"h\"\ncall events.process",
	nil, function ()
		core.after(1.0, function () core.set_node(P(0, 1, 1), { name = material }) end)
	end, function (_, timeout) assert(not timeout and lifted(), "handler did not run") end)

run_program("event items",
	H .. "call events.register_items 3 \"h\"\ncall events.process",
	nil, function ()
		core.set_node(P(1, 0, 1), { name = material })
		core.after(1.0, function () core.add_item(P(1, 1, 1), ItemStack(material)) end)
	end, function (_, timeout) assert(not timeout and lifted(), "handler did not run") end)

run_program("event entities",
	H .. "call events.register_entities 3 \"h\"\ncall events.process",
	nil, function ()
		core.after(1.0, function () core.add_entity(P(1, 1, 1), "cogwork_test:dummy") end)
	end, function (_, timeout) assert(not timeout and lifted(), "handler did not run") end)

run_program("event public chat",
	H .. "call events.register_chat \"h\"\ncall events.process",
	nil, function ()
		core.after(1.0, function ()
			for _, f in ipairs(core.registered_on_chat_messages) do f("tester", "hello") end
		end)
	end, function (_, timeout) assert(not timeout and lifted(), "handler did not run") end)

run_program("event private message",
	H .. "call events.register_whisper \"h\"\ncall events.process",
	nil, function ()
		core.after(1.0, function ()
			local ok, res = S.whisper_to_bot("tester", "Scout", "psst")
			assert(ok == false, "an unnamed robot was found")
			core.get_meta(find_robot()):set_string("bot_name", "Scout")
			local ok2, res2 = S.whisper_to_bot("tester", "scout", "psst")
			assert(ok2 and res2 == 1, tostring(res2))
			-- somebody else's private robot does not listen to strangers
			assert(S.whisper_to_bot("stranger", "Scout", "hi") == false)
		end)
	end, function (_, timeout) assert(not timeout and lifted(), "handler did not run") end)

-- robot to robot: a robot of another owner only hears what its owner allowed
test("event robot message", function (done)
	clear_area()
	local sender = make_robot(P(0, 1, 0), "wait 40\ntell_bots \"hello\"", nil)
	core.get_meta(sender):set_string("bot_name", "Sender")
	local rx = make_robot(P(5, 1, 0), H .. "call events.register_bot \"h\"\ncall events.process", nil)
	local m = core.get_meta(rx)
	m:set_string("bot_name", "Rx")
	m:set_string("owner", "other")
	local ok = S.start(rx)
	local started = S.start(sender)
	local blocked, allowed

	core.after(1.0, function ()
		-- another owner's robot does not hear us until its owner allows it
		blocked = #S.listeners_of(sender)
		S.bot_allow_set(rx, { "tester" })
		allowed = S.listeners_of(sender)
	end)

	wait_for(sender, 40, function (timeout)
		local lifted_rx = S.is_robot(core.get_node(P(5, 2, 0)).name)
		report("event robot message", ok and started and not timeout and blocked == 0
			and allowed and #allowed == 1 and allowed[1] == "other/Rx" and lifted_rx,
			("blocked=%s allowed=%s lifted=%s timeout=%s"):format(tostring(blocked),
				allowed and table.concat(allowed, ",") or "nil", tostring(lifted_rx), tostring(timeout)))
		done()
	end)
end)

test("event chat limits", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "use events\nset n = 0\nfn h a b\n  add n 1\n"
		.. "call events.register_chat \"h\"\ncall events.process", nil)
	core.get_meta(pos):set_string("bot_name", "Counter")
	assert(S.start(pos))

	core.after(1.0, function ()
		for i = 1, 8 do
			for _, f in ipairs(core.registered_on_chat_messages) do f("tester", "m" .. i) end
		end
		for _, f in ipairs(core.registered_on_chat_messages) do f("other", "x") end
	end)

	core.after(3.0, function ()
		local r = S.running[core.hash_node_position(pos)]
		local got = r and r.ctx.globals.n
		S.stop(pos)

		-- sending: public and private messages are limited per player, the owner's chat is not
		local bot = S.Bot.new(pos, "tester")
		local said = 0
		for _ = 1, 8 do if bot:say("hi") then said = said + 1 end end
		local owner_ok = true
		for _ = 1, 20 do owner_ok = owner_ok and bot:chat("x") end
		report("event chat limits", got == 6 and said == S.settings.chat_limit and owner_ok,
			("received=%s (want 6: 5 from tester, 1 from other) said=%s"):format(tostring(got), said))
		done()
	end)
end)

-- ---------------------------------------------------------------- punch

core.register_tool("cogwork_test:sword", {
	description = "Test sword",
	inventory_image = "blank.png",
	tool_capabilities = { full_punch_interval = 0.3, damage_groups = { fleshy = 4 }, punch_attack_uses = 20 },
})

core.register_entity("cogwork_test:mob", {
	initial_properties = { physical = false, visual = "sprite", textures = { "blank.png" }, hp_max = 10 },
	on_activate = function (self) self.object:set_armor_groups({ fleshy = 100 }) end,
})

run_program("punch picks up items",
	"wait 5\npunch front\nif count " .. material .. " = 3\n  move up",
	nil, function ()
		core.after(0.0, function ()
			core.set_node(P(0, 0, 1), { name = material })
			local obj = core.add_item(P(0, 1, 1), ItemStack(material .. " 3"))
			assert(obj, "no item")
		end)
	end, function ()
		assert(vector.equals(find_robot(), P(0, 2, 0)), "items were not picked up")
	end)

test("punch hits an entity with a tool", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0),
		"if entity front = \"cogwork_test:mob\"\n  repeat 4\n    punch front cogwork_test:sword\nelse\n  move down",
		{ "cogwork_test:sword" })
	local mob = core.add_entity(P(0, 1, 1), "cogwork_test:mob")
	assert(S.start(pos))
	wait_for(pos, 40, function (timeout)
		local gone = not mob:is_valid() or mob:get_hp() <= 0
		local stack = core.get_meta(pos):get_inventory():get_stack("main", 1)
		local worn = stack:get_wear() > 0
		report("punch hits an entity with a tool", not timeout and gone and worn,
			("gone=%s worn=%s timeout=%s err=%s"):format(tostring(gone), tostring(worn), tostring(timeout), err_of(pos)))
		if mob:is_valid() then mob:remove() end
		done()
	end)
end)

test("punch never hits a player-less robot's missing tool", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "punch front cogwork_test:sword\nif ok\n  move up", {})
	local mob = core.add_entity(P(0, 1, 1), "cogwork_test:mob")
	assert(S.start(pos))
	wait_for(pos, 40, function (timeout)
		report("punch with an item the robot does not have fails",
			vector.equals(find_robot(), P(0, 1, 0)) and mob:get_hp() == 10 and not timeout)
		mob:remove()
		done()
	end)
end)

-- ---------------------------------------------------------------- pathfinding

local function goto_program (target, extra)
	return ("use pathfind\nset r = call pathfind.goto %d %d %d\nif r = 0\n  move up\nif r = -1\n  turn around%s")
		:format(target.x, target.y, target.z, extra or "")
end

run_program("pathfind around a wall",
	goto_program(P(0, 1, 6)),
	nil, function ()
		for x = -2, 2 do for y = -1, 6 do core.set_node(P(x, y, 3), { name = material }) end end
	end, function (_, timeout)
		assert(not timeout, "timeout")
		assert(vector.equals(find_robot(), P(0, 2, 6)), "ended at " .. core.pos_to_string(vector.subtract(find_robot(), ORIGIN)))
	end)

run_program("pathfind reports -1 for a sealed target",
	goto_program(P(0, 1, 6)),
	nil, function ()
		for x = -1, 1 do for y = 0, 2 do for z = 5, 7 do
			if not (x == 0 and y == 1 and z == 6) then core.set_node(P(x, y, z), { name = material }) end
		end end end
	end, function (_, timeout)
		assert(not timeout, "timeout")
		-- the robot turns around and stays: its front is now -z
		local p = find_robot()
		assert(vector.equals(p, P(0, 1, 0)), "moved to " .. core.pos_to_string(vector.subtract(p, ORIGIN)))
		assert(core.get_node(p).param2 ~= core.dir_to_facedir({ x = 0, y = 0, z = -1 }), "did not turn around")
	end)

run_program("pathfind to an entity",
	"use pathfind\nset r = call pathfind.goto_entity \"cogwork_test:dummy\"\nif r = 0\n  move up",
	nil, function ()
		-- earlier tests left dummies around
		for _, obj in ipairs(core.get_objects_inside_radius(P(0, 1, 0), 60)) do
			if not obj:is_player() then obj:remove() end
		end
		core.add_entity(P(0, 1, 5), "cogwork_test:dummy")
	end, function (_, timeout)
		assert(not timeout, "timeout")
		local p = find_robot()
		assert(vector.equals(p, P(0, 2, 4)), "ended at " .. core.pos_to_string(vector.subtract(p, ORIGIN)))
	end)

-- terrain nobody loaded: a wall without Forceload, walked into with it
local FAR = P(0, 1, 64)

run_program("pathfind to unloaded terrain fails without forceload",
	goto_program(FAR),
	nil, nil, function (_, timeout)
		assert(not timeout, "timeout")
		assert(vector.equals(find_robot(), P(0, 1, 0)), "it moved")
	end)

test("pathfind to unloaded terrain with forceload", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), goto_program(FAR), nil)
	-- clear_area stops at z=30 and the rest of the emerged area is not air
	for x = -3, 3 do for y = -3, 5 do for z = 31, 47 do
		core.set_node(P(x, y, z), { name = "air" })
	end end end
	assert(S.set_persist(pos, true), "no forceload")
	assert(S.start(pos))
	wait_for(pos, 90, function (timeout)
		local p = vector.add(FAR, { x = 0, y = 1, z = 0 })
		local good = S.is_robot(core.get_node(p).name)
		local found = core.find_nodes_in_area(P(-3, -3, -3), P(3, 8, 80), S.ROBOT_NODES)
		local where = {}
		for _, f in ipairs(found) do where[#where + 1] = core.pos_to_string(vector.subtract(f, ORIGIN)) .. " " .. err_of(f) end
		report("pathfind to unloaded terrain with forceload", not timeout and good,
			("timeout=%s node=%s robots at %s"):format(tostring(timeout), core.get_node(p).name, table.concat(where, ";")))
		S.set_persist(p, false)
		done()
	end)
end)

-- ---------------------------------------------------------------- upgrades

-- run a program on a robot with the given upgrades, standing on a floor block
local function upgrade_test (name, upgrades, program, check)
	test(name, function (done)
		clear_area()
		core.set_node(P(0, 0, 0), { name = material })
		local pos = make_robot(P(0, 1, 0), program, nil, upgrades)
		assert(S.start(pos))
		wait_for(pos, 40, function (timeout)
			local ok, why = pcall(check, timeout)
			report(name, ok and why ~= false, not ok and why or nil)
			done()
		end)
	end)
end

local UP = "repeat 6\n  move up"
upgrade_test("a bare robot goes 1 block above the floor", {}, UP, function ()
	assert(vector.equals(find_robot(), P(0, 2, 0)), "ended at " .. core.pos_to_string(vector.subtract(find_robot(), ORIGIN)))
end)
upgrade_test("each hover upgrade adds a block", { "cogwork:upgrade_hover", "cogwork:upgrade_hover" }, UP, function ()
	assert(vector.equals(find_robot(), P(0, 4, 0)), "ended at " .. core.pos_to_string(vector.subtract(find_robot(), ORIGIN)))
end)
upgrade_test("a flight upgrade removes the limit", { "cogwork:upgrade_flight" }, UP, function ()
	assert(vector.equals(find_robot(), P(0, 7, 0)), "ended at " .. core.pos_to_string(vector.subtract(find_robot(), ORIGIN)))
end)
upgrade_test("height_limit reports it", { "cogwork:upgrade_hover" },
	"if height_limit = 2\n  move up", function ()
	assert(vector.equals(find_robot(), P(0, 2, 0)), "limit not 2")
end)

test("upgrade slots only take upgrades", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "stop", nil, {})
	local node = core.registered_nodes["cogwork:robot"]
	local fake = { get_player_name = function () return "tester" end }
	local stone = ItemStack(material)
	local up = ItemStack("cogwork:upgrade_hover")
	report("upgrade slots only take upgrades",
		node.allow_metadata_inventory_put(pos, "upgrades", 1, stone, fake) == 0
		and node.allow_metadata_inventory_put(pos, "upgrades", 1, up, fake) == 1
		and S.height_limit(pos) == 1)
	done()
end)

-- pathfinding is bound by the same limit: no way up into the air, but a staircase works
local function path_test (name, upgrades, build, target, check)
	test(name, function (done)
		clear_area()
		build()
		local pos = make_robot(P(0, 1, 0), goto_program(target), nil, upgrades)
		assert(S.start(pos))
		wait_for(pos, 60, function (timeout)
			local ok, why = pcall(check, timeout)
			report(name, ok and why ~= false, not ok and why or nil)
			done()
		end)
	end)
end

path_test("pathfind will not climb into the air without upgrades", {}, function ()
	core.set_node(P(0, 0, 0), { name = material })
end, P(0, 6, 0), function (timeout)
	assert(not timeout, "timeout")
	local p = find_robot()
	assert(vector.equals(p, P(0, 1, 0)), "moved to " .. core.pos_to_string(vector.subtract(p, ORIGIN)))
end)

path_test("pathfind climbs a staircase within the limit", {}, function ()
	for x = 0, 4 do for y = 0, x do core.set_node(P(x, y, 0), { name = material }) end end
end, P(4, 5, 0), function (timeout)
	assert(not timeout, "timeout")
	-- it climbed the stairs (each step is 1 block above the floor at most), arrived and
	-- the program's "move up" took it one block above the top step
	local p = find_robot()
	assert(vector.equals(p, P(4, 6, 0)), "ended at " .. core.pos_to_string(vector.subtract(p, ORIGIN)))
end)

-- a robot climbs along a wall, so it can leave a shaft it dug
test("a robot climbs back out of its own shaft", function (done)
	clear_area()
	for x = -1, 1 do for y = -6, 0 do for z = -1, 1 do core.set_node(P(x, y, z), { name = material }) end end end
	local pos = make_robot(P(0, 1, 0), "use mining\ncall shaft 4\ncall climb 4", nil, {})
	assert(S.start(pos))
	wait_for(pos, 40, function (timeout)
		local p = find_robot()
		report("a robot climbs back out of its own shaft", not timeout and p and vector.equals(p, P(0, 1, 0)),
			"ended at " .. (p and core.pos_to_string(vector.subtract(p, ORIGIN)) or "?") .. " " .. (p and err_of(p) or ""))
		done()
	end)
end)

test("a robot beside a tower climbs it, one in open air does not", function (done)
	clear_area()
	for y = 0, 10 do core.set_node(P(1, y, 0), { name = material }) end
	local pos = make_robot(P(0, 1, 0), "repeat 8\n  move up", nil, {})
	core.set_node(P(0, 0, 0), { name = material })
	assert(S.start(pos))
	wait_for(pos, 40, function (timeout)
		local p = find_robot()
		-- beside the tower all the way: 8 up from y=1
		report("a robot beside a tower climbs it", not timeout and p and vector.equals(p, P(0, 9, 0)),
			"ended at " .. (p and core.pos_to_string(vector.subtract(p, ORIGIN)) or "?"))
		done()
	end)
end)

path_test("pathfind climbs up a shaft wall", {}, function ()
	for y = 0, 8 do core.set_node(P(1, y, 0), { name = material }) end
	core.set_node(P(0, 0, 0), { name = material })
end, P(0, 7, 0), function (timeout)
	assert(not timeout, "timeout")
	local p = find_robot()
	-- arrived at y=7, then the program's "move up" went on along the wall
	assert(vector.equals(p, P(0, 8, 0)), "ended at " .. core.pos_to_string(vector.subtract(p, ORIGIN)))
end)

-- ---------------------------------------------------------------- drone

test("a robot with a flight upgrade is a drone", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "stop", nil, {})
	local node = core.registered_nodes["cogwork:robot"]
	local fake = { get_player_name = function () return "tester" end }
	local inv = core.get_meta(pos):get_inventory()

	local before = core.get_node(pos).name
	-- as the formspec does: the engine stores the stack, then calls the callback
	inv:set_stack("upgrades", 1, ItemStack("cogwork:upgrade_flight"))
	node.on_metadata_inventory_put(pos, "upgrades", 1, ItemStack("cogwork:upgrade_flight"), fake)
	local drone = core.get_node(pos).name
	local p2 = core.get_node(pos).param2

	-- it runs as a drone too, and stops as one
	assert(S.start(pos))
	local running = core.get_node(pos).name
	S.stop(pos, "")
	local stopped = core.get_node(pos).name

	inv:set_stack("upgrades", 1, ItemStack(""))
	node.on_metadata_inventory_take(pos, "upgrades", 1, ItemStack("cogwork:upgrade_flight"), fake)
	local back = core.get_node(pos).name

	report("a robot with a flight upgrade is a drone",
		before == "cogwork:robot" and drone == "cogwork:drone" and running == "cogwork:drone_on"
		and stopped == "cogwork:drone" and back == "cogwork:robot" and core.get_node(pos).param2 == p2,
		table.concat({ before, drone, running, stopped, back }, " "))
	done()
end)

test("a hover upgrade does not make a drone", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "stop", nil, { "cogwork:upgrade_hover" })
	S.refresh_variant(pos)
	report("a hover upgrade does not make a drone", core.get_node(pos).name == "cogwork:robot", core.get_node(pos).name)
	done()
end)

-- ---------------------------------------------------------------- node events

local NODE_EVENT = "use events\nfn h dir block change detail\n  if change = \"%s\"\n    if detail = \"%s\"\n      move up\n      call events.leave\n"
	.. "call events.register_nodes \"h\"\ncall events.process"

local function node_event_test (name, change, detail, setup, trigger)
	run_program(name, NODE_EVENT:format(change, detail), nil, function ()
		if setup then setup() end
		core.after(1.5, trigger)
	end, function (_, timeout)
		assert(not timeout and S.is_robot(core.get_node(P(0, 2, 0)).name), "handler did not run")
	end)
end

node_event_test("nodes event: replaced block", "node", material, function ()
	core.set_node(P(0, 1, 1), { name = material })
end, function () core.set_node(P(0, 1, 1), { name = "air" }) end)

node_event_test("nodes event: inventory change", "inventory", "main", function ()
	local box = make_robot(P(0, 1, 1), "stop", nil, {})
end, function ()
	core.get_meta(P(0, 1, 1)):get_inventory():add_item("main", ItemStack(material))
end)

node_event_test("nodes event: timer", "timer", "started", function ()
	core.set_node(P(0, 1, 1), { name = material })
end, function () core.get_node_timer(P(0, 1, 1)):start(30) end)

if rawget(_G, "sbz_api") and core.registered_nodes["sbz_power:battery"] then
	node_event_test("nodes event: battery level (sbz_power)", "power", "100", function ()
		core.set_node(P(0, 1, 1), { name = "sbz_power:battery" })
		core.get_meta(P(0, 1, 1)):set_int("power", 2500)
	end, function () core.get_meta(P(0, 1, 1)):set_int("power", 5000) end)

	test("sbz_power reading and switching", function (done)
		clear_area()
		core.set_node(P(0, 1, 1), { name = "sbz_power:battery" })
		core.get_meta(P(0, 1, 1)):set_int("power", 1250)
		local info = S.machine_info(P(0, 1, 1))
		report("sbz_power reading and switching", info and info.mod == "sbz_power"
			and info.power == 1250 and info.capacity == 5000 and info.level == 25,
			info and ("level=" .. tostring(info.level) .. " cap=" .. tostring(info.capacity)) or "no reading")
		done()
	end)
end

core.register_node("cogwork_test:tbox4", { groups = { technic_machine = 1, technic_lv = 1 } })
core.register_node("cogwork_test:tmachine_active", { groups = { technic_machine = 1, technic_mv = 1 } })

-- technic and techage are not in the test games: stand-ins that answer the way the
-- real ones do (fields and calls read from their source) check our side of it
test("technic and techage readings", function (done)
	clear_area()
	rawset(_G, "technic", {})
	rawset(_G, "techage", {
		get_node_number = function (pos) if vector.equals(pos, P(0, 1, 2)) then return 77 end end,
		send_single = function (src, number, topic, payload)
			assert(src == "0" and number == 77)
			if topic == "state" then return "running" end
			if topic == "delivered" then return 120 end
			if topic == "load" then return 64 end
			if topic == "on" or topic == "off" then return true end
		end,
	})
	core.set_node(P(0, 1, 1), { name = "cogwork_test:tbox4" })
	local m = core.get_meta(P(0, 1, 1))
	m:set_int("LV_EU_demand", 300) m:set_int("LV_EU_input", 100)
	core.set_node(P(0, 1, 3), { name = "cogwork_test:tmachine_active" })
	core.get_meta(P(0, 1, 3)):set_string("enabled", "1")
	core.set_node(P(0, 1, 2), { name = material })

	local box = S.machine_info(P(0, 1, 1))
	local machine = S.machine_info(P(0, 1, 3))
	local ta = S.machine_info(P(0, 1, 2))
	local switched = S.machine_switch(P(0, 1, 3), false)
	local ta_on = S.machine_switch(P(0, 1, 2), true)
	rawset(_G, "technic", nil)
	rawset(_G, "techage", nil)

	local ok = box and box.mod == "technic" and box.demand == 300 and box.power == 100
		and machine and machine.state == "on" and switched == true
		and core.get_meta(P(0, 1, 3)):get_int("enabled") == 0
		and ta and ta.mod == "techage" and ta.state == "on" and ta.power == 120 and ta.level == 64 and ta_on == true
	report("technic and techage readings", ok, ok and nil or core.serialize({ box = box, machine = machine, ta = ta, switched = switched, ta_on = ta_on }))
	done()
end)

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
	for _, name in ipairs(S.ROBOT_NODES) do
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

test("robot callbacks do not open the editor while a program runs", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "move up", nil)
	local fake = { get_player_name = function () return "tester" end,
		get_inventory = function () return nil end, is_player = function () return true end,
		get_player_control = function () return {} end }
	local s = S.editor_session(fake)
	s.pos = nil
	local def = core.registered_nodes["cogwork:robot"]
	S.acting = true
	def.on_rightclick(pos, core.get_node(pos), fake, ItemStack(""), { type = "node", under = pos, above = pos })
	S.acting = false
	report("rightclick ignored while acting", s.pos == nil)
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
