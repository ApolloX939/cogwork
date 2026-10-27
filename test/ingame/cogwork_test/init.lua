-- Runs every check below on a flat area, prints "SBT ..." lines, then
-- "SBT DONE" and shuts the server down.


-- stopped robots fall to the floor; most checks below leave them where the program ends
cogwork.settings.gravity = false

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

local material = cogwork.compat.item("stone") or cogwork.compat.item("matter")
local dirt = cogwork.compat.item("dirt") or material
local chest = cogwork.compat.item("chest")

-- place a robot at pos facing +z (front = +z), give it items and a program
local function make_robot (pos, program, items, upgrades, bare)
	core.set_node(pos, { name = "cogwork:robot", param2 = core.dir_to_facedir({ x = 0, y = 0, z = -1 }) })
	local meta = core.get_meta(pos)
	meta:get_inventory():set_size("main", 16)
	meta:get_inventory():set_size("disk", 1)
	meta:get_inventory():set_size("upgrades", 6)
	-- the test world is a void: robots fly unless a test says otherwise
	for _, up in ipairs(upgrades or { "cogwork:upgrade_flight" }) do
		meta:get_inventory():add_item("upgrades", up)
	end
	cogwork.sync_storage(pos)
	-- armor and a power cell, or the robot does not run
	if not bare then
		meta:get_inventory():set_stack("armor", 1, ItemStack("cogwork:armor_basic"))
		meta:get_inventory():set_stack("cells", 1, ItemStack("cogwork:cell_small"))
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
			local r = select(2, next(cogwork.running))
			print("SBT trace", rp and core.pos_to_string(vector.subtract(rp, ORIGIN)), next(cogwork.running) ~= nil,
				r and core.pos_to_string(vector.subtract(r.bot.pos, ORIGIN)), r and core.get_node(r.bot.pos).name, r and r.ctx.line, r and coroutine.status(r.co))
		end
		if next(cogwork.running) == nil or t > timeout then return cb(t > timeout) end
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
		local ok, err = cogwork.start(pos)
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
		if cogwork.is_robot(n) then return p end
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
	"craft " .. (cogwork.compat.item("stick") or "default:stick"),
	nil, nil, function () return true end)

if chest then
	run_program("pull and put with a chest",
		"pull\nturn around\nplace front " .. material .. "\nturn around\nput " .. material,
		{ material .. " 2" }, function ()
			core.set_node(P(0, 1, 1), { name = chest, param2 = 0 })
			local inv = core.get_meta(P(0, 1, 1)):get_inventory()
			inv:add_item("main", "air")
			inv:add_item("main", (cogwork.compat.item("coal") or material) .. " 3")
		end, function ()
			local p = find_robot()
			assert(p, "robot lost")
			assert(err_of(p) == "", err_of(p))
			local rinv = core.get_meta(p):get_inventory()
			local coal = cogwork.compat.item("coal")
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
			local ok, res = cogwork.whisper_to_bot("tester", "Scout", "psst")
			assert(ok == false, "an unnamed robot was found")
			core.get_meta(find_robot()):set_string("bot_name", "Scout")
			local ok2, res2 = cogwork.whisper_to_bot("tester", "scout", "psst")
			assert(ok2 and res2 == 1, tostring(res2))
			-- somebody else's private robot does not listen to strangers
			assert(cogwork.whisper_to_bot("stranger", "Scout", "hi") == false)
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
	local ok = cogwork.start(rx)
	local started = cogwork.start(sender)
	local blocked, allowed

	core.after(1.0, function ()
		-- another owner's robot does not hear us until its owner allows it
		blocked = #cogwork.listeners_of(sender)
		cogwork.bot_allow_set(rx, { "tester" })
		allowed = cogwork.listeners_of(sender)
	end)

	wait_for(sender, 40, function (timeout)
		local lifted_rx = cogwork.is_robot(core.get_node(P(5, 2, 0)).name)
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
	assert(cogwork.start(pos))

	core.after(1.0, function ()
		for i = 1, 8 do
			for _, f in ipairs(core.registered_on_chat_messages) do f("tester", "m" .. i) end
		end
		for _, f in ipairs(core.registered_on_chat_messages) do f("other", "x") end
	end)

	core.after(3.0, function ()
		local r = cogwork.running[core.hash_node_position(pos)]
		local got = r and r.ctx.globals.n
		cogwork.stop(pos)

		-- sending: public and private messages are limited per player, the owner's chat is not
		local bot = cogwork.Bot.new(pos, "tester")
		local said = 0
		for _ = 1, 8 do if bot:say("hi") then said = said + 1 end end
		local owner_ok = true
		for _ = 1, 20 do owner_ok = owner_ok and bot:chat("x") end
		report("event chat limits", got == 6 and said == cogwork.settings.chat_limit and owner_ok,
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
	assert(cogwork.start(pos))
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
	assert(cogwork.start(pos))
	wait_for(pos, 40, function (timeout)
		report("punch with an item the robot does not have fails",
			vector.equals(find_robot(), P(0, 1, 0)) and mob:get_hp() == 10 and not timeout)
		mob:remove()
		done()
	end)
end)

local function reach_test (name, upgrades, distance, hit, blocked)
	test(name, function (done)
		clear_area()
		for _, obj in ipairs(core.get_objects_inside_radius(P(0, 1, 2), 10)) do
			if not obj:is_player() and not cogwork.is_visual(obj) then obj:remove() end
		end
		if blocked then core.set_node(P(0, 1, 2), { name = material }) end
		local pos = make_robot(P(0, 1, 0), "punch front cogwork_test:sword", { "cogwork_test:sword" }, upgrades)
		local mob = core.add_entity(P(0, 1, distance), "cogwork_test:mob")
		assert(cogwork.start(pos))
		core.after(3, function ()
			local gone = not mob:is_valid() or mob:get_hp() < 10
			report(name, gone == hit, ("gone=%s expected=%s hp=%s err=%s count=%s"):format(tostring(gone), tostring(hit), tostring(mob:is_valid() and mob:get_hp()), err_of(pos), cogwork.combat_count(pos)))
			if mob:is_valid() then mob:remove() end
			cogwork.stop(pos, "")
			done()
		end)
	end)
end

reach_test("one Combat Upgrade punches one block", { "cogwork:upgrade_combat" }, 3, false)
reach_test("three Combat Upgrades punch three blocks", { "cogwork:upgrade_combat", "cogwork:upgrade_combat", "cogwork:upgrade_combat" }, 3, true)
reach_test("a block in the way stops the extended punch", { "cogwork:upgrade_combat", "cogwork:upgrade_combat", "cogwork:upgrade_combat" }, 3, false, true)

test("the entrance lock lets in the owner, the allowed players or nobody else", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "stop", nil, {})
	local meta = core.get_meta(pos)
	meta:set_string("owner", "alice")
	meta:set_int("public", 1)
	local function who (name) return { get_player_name = function () return name end } end
	local open = cogwork.can_enter(pos, who("bob"))
	meta:set_string("room_lock", "allow")
	cogwork.bot_allow_set(pos, { "carol", "dave/Rover" })
	local allowed = cogwork.can_enter(pos, who("carol")) and cogwork.can_enter(pos, who("dave")) and cogwork.can_enter(pos, who("alice"))
	local denied = not cogwork.can_enter(pos, who("bob"))
	meta:set_string("room_lock", "owner")
	local only = cogwork.can_enter(pos, who("alice")) and not cogwork.can_enter(pos, who("carol"))
	report("the entrance lock lets in the owner, the allowed players or nobody else",
		open and allowed and denied and only,
		("open=%s allowed=%s denied=%s only=%s"):format(tostring(open), tostring(allowed), tostring(denied), tostring(only)))
	done()
end)

test("the viewscreen draws an entity in front of the terrain", function (done)
	clear_area()
	for _, obj in ipairs(core.get_objects_inside_radius(P(0, 1, 5), 20)) do
		if not obj:is_player() then obj:remove() end
	end
	local front = { x = 0, y = 0, z = 1 }
	local empty = cogwork.view_job(P(0, 1, 0), front)
	while not cogwork.view_step(empty, 10) do end
	local mob = core.add_entity(P(0, 1, 5), "cogwork_test:mob")
	local job = cogwork.view_job(P(0, 1, 0), front)
	while not cogwork.view_step(job, 10) do end
	local centre = (job.H / 2) * job.W + job.W / 2 + 1
	local orange = job.pixels[centre] ~= empty.pixels[centre] and job.pixels[centre] % 256 < 128
	mob:remove()
	report("the viewscreen draws an entity in front of the terrain", #job.marks == 1 and orange,
		("marks=%d centre=%x was %x"):format(#job.marks, job.pixels[centre], empty.pixels[centre]))
	done()
end)

test("the viewscreen shows a block dug since the last picture, at once", function (done)
	clear_area()
	for _, obj in ipairs(core.get_objects_inside_radius(P(0, 1, 5), 30)) do
		if not obj:is_player() and not cogwork.is_visual(obj) then obj:remove() end
	end
	for x = -8, 8 do for y = -2, 4 do core.set_node(P(x, y, 7), { name = material }) end end
	local mem = {}
	local front = { x = 0, y = 0, z = 1 }
	local first = cogwork.view_job(P(0, 1, 0), front, mem)
	while not cogwork.view_step(first, 10) do end
	for x = -8, 8 do for y = -2, 4 do core.set_node(P(x, y, 7), { name = "air" }) end end
	local t0 = os.clock()
	local second = cogwork.view_job(P(0, 1, 0), front, mem)
	while not cogwork.view_step(second, 10) do end
	local ms = (os.clock() - t0) * 1000
	local centre = (second.H / 2) * second.W + second.W / 2 + 1
	report("the viewscreen shows a block dug since the last picture, at once",
		first.pixels[centre] ~= second.pixels[centre], ("%.0f ms"):format(ms))
	done()
end)

test("Skyblock: Zero's fall-off teleport leaves players inside a room alone", function (done)
	local api = rawget(_G, "sbz_api")
	if not (api and api.activate_safetynet) then
		report("Skyblock: Zero's fall-off teleport leaves players inside a room alone", true, "not Skyblock: Zero")
		return done()
	end
	local o = cogwork.room_origin(1)
	local inside = api.activate_safetynet("tester", { x = o.x + 7, y = o.y + 1, z = o.z + 7 })
	local outside = api.activate_safetynet("tester", { x = 0, y = -500, z = 0 })
	report("Skyblock: Zero's fall-off teleport leaves players inside a room alone",
		inside == false and outside == true, ("inside=%s outside=%s"):format(tostring(inside), tostring(outside)))
	done()
end)

test("the robot you point at is its entity, with a hitbox the shape of the model", function (done)
	clear_area()
	local ok, detail = true, {}
	for i, kind in ipairs({ "robot", "hover", "drone" }) do
		local pos = make_robot(P(3 * i, 1, 0), "stop", nil, {})
		core.swap_node(pos, { name = "cogwork:" .. kind })
		cogwork.ensure_visual(pos)
		local found
		for _, obj in ipairs(core.get_objects_inside_radius(pos, 0.45)) do
			local le = obj:get_luaentity()
			if le and le.name == "cogwork:visual" then found = obj end
		end
		local props = found and found:get_properties()
		local want = cogwork.MODEL_SELECTION[kind]
		local good = props and props.pointable and math.abs(props.selectionbox[3] - want[3]) < 0.001 and math.abs(props.selectionbox[5] - want[5]) < 0.001 and props.selectionbox.rotate == true
		local node_def = core.registered_nodes["cogwork:" .. kind]
		good = good and node_def.collision_box.fixed[4] >= want[4] and node_def.selection_box.fixed[4] < 0.1
		ok = ok and good
		detail[#detail + 1] = kind .. "=" .. tostring(good and true or false)
	end
	report("the robot you point at is its entity, with a hitbox the shape of the model", ok, table.concat(detail, " "))
	done()
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
	-- Mineclonia generates real terrain in the blocks nobody emerged, so "nothing below"
	-- (void) and "nothing loaded ahead" do not hold there
	if core.get_modpath("mcl_levelgen") then
		report("pathfind to unloaded terrain with forceload", true, "skipped: Mineclonia generates terrain around the test area")
		return done()
	end
	clear_area()
	local pos = make_robot(P(0, 1, 0), goto_program(FAR), nil)
	-- clear_area stops at z=30 and the rest of the emerged area is not air
	for x = -3, 3 do for y = -3, 5 do for z = 31, 47 do
		core.set_node(P(x, y, z), { name = "air" })
	end end end
	assert(cogwork.set_persist(pos, true), "no forceload")
	assert(cogwork.start(pos))
	wait_for(pos, 90, function (timeout)
		local p = vector.add(FAR, { x = 0, y = 1, z = 0 })
		local good = cogwork.is_robot(core.get_node(p).name)
		local found = core.find_nodes_in_area(P(-3, -3, -3), P(3, 8, 80), cogwork.ROBOT_NODES)
		local where = {}
		for _, f in ipairs(found) do where[#where + 1] = core.pos_to_string(vector.subtract(f, ORIGIN)) .. " " .. err_of(f) end
		report("pathfind to unloaded terrain with forceload", not timeout and good,
			("timeout=%s node=%s robots at %s"):format(tostring(timeout), core.get_node(p).name, table.concat(where, ";")))
		cogwork.set_persist(p, false)
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
		assert(cogwork.start(pos))
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

-- moving (and falling) must carry every list along
test("a moving robot keeps its inventory and upgrades", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "repeat 4\n  move forward", { material .. " 7", dirt .. " 3" },
		{ "cogwork:upgrade_flight", "cogwork:upgrade_storage", "cogwork:upgrade_combat" })
	local inv = core.get_meta(pos):get_inventory()
	local before = { main = inv:get_size("main"), upgrades = inv:get_size("upgrades"), armor = inv:get_size("armor"), cells = inv:get_size("cells") }
	assert(cogwork.start(pos))
	wait_for(pos, 40, function (timeout)
		local ok, why = pcall(function ()
			local at = find_robot()
			assert(vector.equals(at, P(0, 1, 4)), "ended at " .. core.pos_to_string(vector.subtract(at, ORIGIN)))
			local i2 = core.get_meta(at):get_inventory()
			for list, size in pairs(before) do
				assert(i2:get_size(list) == size, list .. " size " .. i2:get_size(list) .. " not " .. size)
			end
			assert(i2:contains_item("main", ItemStack(material .. " 7")), "stone lost")
			assert(i2:contains_item("main", ItemStack(dirt .. " 3")), "dirt lost")
			assert(cogwork.has_upgrade(at, "cogwork:upgrade_storage") and cogwork.has_upgrade(at, "cogwork:upgrade_combat"), "upgrades lost")
			assert(i2:contains_item("armor", ItemStack("cogwork:armor_basic")), "armor lost")
		end)
		report("a moving robot keeps its inventory and upgrades", ok, not ok and why or nil)
		done()
	end)
end)

-- the room controller drives a forceloaded robot that has a room, then it falls
test("a driven robot with a room keeps its lists, also when it falls", function (done)
	clear_area()
	core.set_node(P(0, 0, 0), { name = material })
	local pos = make_robot(P(0, 1, 0), "stop", { material .. " 5" }, { "cogwork:upgrade_flight", "cogwork:upgrade_storage" })
	local fake = { get_player_name = function () return "tester" end, is_player = function () return true end,
		get_meta = function () return { get_string = function () return "" end, set_string = function () end } end }
	cogwork.set_persist(pos, true)
	cogwork.room_enter(pos, fake)
	local id = core.get_meta(pos):get_int("room_id")
	local sizes = {}
	for _, l in ipairs({ "main", "upgrades", "armor", "cells", "augment", "armor_mod", "disk" }) do
		sizes[l] = core.get_meta(pos):get_inventory():get_size(l)
	end
	local bot = cogwork.Bot.new(pos, "tester")
	for _, m in ipairs({ { "move", "up" }, { "move", "up" }, { "move", "forward" }, { "turn", "left" }, { "move", "forward" }, { "move", "back" } }) do
		local ok = bot[m[1]](bot, m[2])
		assert(ok ~= nil)
	end
	local at = bot.pos
	-- take the flight upgrade out so it falls to the floor
	core.get_meta(at):get_inventory():set_stack("upgrades", 1, ItemStack(""))
	cogwork.refresh_variant(at)
	cogwork.settle_later(at)
	core.after(3, function ()
		local ok, why = pcall(function ()
			local now = find_robot()
			assert(now and cogwork.room_robot(id) and vector.equals(cogwork.room_robot(id), now), "room lost the robot")
			local inv = core.get_meta(now):get_inventory()
			for l, n in pairs(sizes) do assert(inv:get_size(l) == n, l .. " size " .. inv:get_size(l) .. " not " .. n) end
			assert(inv:contains_item("main", ItemStack(material .. " 5")), "items lost")
			assert(cogwork.has_upgrade(now, "cogwork:upgrade_storage"), "storage upgrade lost")
			assert(inv:contains_item("armor", ItemStack("cogwork:armor_basic")), "armor lost")
			assert(core.get_meta(now):get_int("room_id") == id, "room id lost")
		end)
		report("a driven robot with a room keeps its lists, also when it falls", ok, not ok and why or nil)
		-- freeing the robot's forceload also freed the block the harness keeps loaded
		for x = -16, 32, 16 do for y = -8, 16, 16 do for z = -16, 32, 16 do
			core.forceload_block(P(x, y, z), true)
		end end end
		done()
	end)
end)

-- the editor open on a robot goes with it, or its slots would show nothing
test("an open editor follows the robot when it moves", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "stop", nil, { "cogwork:upgrade_flight" })
	local fake = { get_player_name = function () return "editor_follower" end, is_player = function () return true end }
	cogwork.show_editor(pos, fake)
	local bot = cogwork.Bot.new(pos, "tester")
	bot:move("forward")
	bot:move("up")
	local s = cogwork.editor_session(fake)
	local followed = s.pos and vector.equals(s.pos, bot.pos)
	report("an open editor follows the robot when it moves", followed,
		"stayed at " .. tostring(s.pos and core.pos_to_string(s.pos)))
	done()
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
		and cogwork.height_limit(pos) == 1)
	done()
end)

-- pathfinding is bound by the same limit: no way up into the air, but a staircase works
local function path_test (name, upgrades, build, target, check)
	test(name, function (done)
		clear_area()
		build()
		local pos = make_robot(P(0, 1, 0), goto_program(target), nil, upgrades)
		assert(cogwork.start(pos))
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
	assert(cogwork.start(pos))
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
	assert(cogwork.start(pos))
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
	core.set_node(P(0, 0, 0), { name = material })
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
	assert(cogwork.start(pos))
	local running = core.get_node(pos).name
	cogwork.stop(pos, "")
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
	core.set_node(P(0, 0, 0), { name = material })
	local pos = make_robot(P(0, 1, 0), "stop", nil, { "cogwork:upgrade_hover" })
	cogwork.refresh_variant(pos)
	report("a hover upgrade does not make a drone", core.get_node(pos).name == "cogwork:robot", core.get_node(pos).name)
	done()
end)

-- ---------------------------------------------------------------- hover model, gravity, water

-- a test water, and a bucket for it, so this runs in every game
core.register_node("cogwork_test:water_source", {
	description = "Test water", drawtype = "liquid", tiles = { "blank.png" },
	paramtype = "light", walkable = false, pointable = false, diggable = false, buildable_to = true,
	liquidtype = "source", liquid_alternative_flowing = "cogwork_test:water_flowing",
	liquid_alternative_source = "cogwork_test:water_source", liquid_viscosity = 1,
	groups = { water = 3, liquid = 3 },
})
core.register_node("cogwork_test:water_flowing", {
	description = "Test water", drawtype = "flowingliquid", tiles = { "blank.png" },
	special_tiles = { { name = "blank.png" }, { name = "blank.png" } },
	paramtype = "light", paramtype2 = "flowingliquid", walkable = false, pointable = false,
	diggable = false, buildable_to = true, liquidtype = "flowing",
	liquid_alternative_flowing = "cogwork_test:water_flowing",
	liquid_alternative_source = "cogwork_test:water_source", liquid_viscosity = 1,
	groups = { water = 3, liquid = 3, not_in_creative_inventory = 1 },
})
core.register_craftitem("cogwork_test:bucket_empty", { description = "Test bucket", inventory_image = "blank.png", stack_max = 99 })
core.register_craftitem("cogwork_test:bucket_water", { description = "Test bucket of water", inventory_image = "blank.png", stack_max = 1 })
cogwork.register_bucket({
	empty = "cogwork_test:bucket_empty",
	filled = function (source) return source == "cogwork_test:water_source" and "cogwork_test:bucket_water" or nil end,
})
local WATER = "cogwork_test:water_source"

local function name_at (p) return core.get_node(p).name end

test("a robot with nothing under it hovers, with something under it it rolls", function (done)
	clear_area()
	core.set_node(P(0, -1, 0), { name = material })
	local pos = make_robot(P(0, 1, 0), "stop", nil, {})
	cogwork.refresh_variant(pos)
	local hover = name_at(pos)
	core.set_node(P(0, 0, 0), { name = material })
	cogwork.refresh_variant(pos)
	local rolls = name_at(pos)
	core.remove_node(P(0, 0, 0))
	cogwork.start(pos)
	local running = name_at(pos)
	cogwork.stop(pos, "")
	local stopped = name_at(pos)

	-- a drone stays a drone
	local up = make_robot(P(3, 1, 0), "stop", nil, { "cogwork:upgrade_flight" })
	cogwork.refresh_variant(up)
	report("a robot with nothing under it hovers, with something under it it rolls",
		hover == "cogwork:hover" and rolls == "cogwork:robot" and running == "cogwork:hover_on"
		and stopped == "cogwork:hover" and name_at(up) == "cogwork:drone",
		table.concat({ hover, rolls, running, stopped, name_at(up) }, " "))
	done()
end)

test("a stopped robot falls to the floor, a running one does not", function (done)
	-- Mineclonia generates real terrain in the blocks nobody emerged, so "nothing below"
	-- (void) and "nothing loaded ahead" do not hold there
	if core.get_modpath("mcl_levelgen") then
		report("a stopped robot falls to the floor, a running one does not", true, "skipped: Mineclonia generates terrain around the test area")
		return done()
	end
	clear_area()
	cogwork.settings.gravity = true
	core.set_node(P(0, 0, 0), { name = material })
	local lost = make_robot(P(0, 5, 0), "stop", nil, {})
	local floating = make_robot(P(2, 5, 0), "wait 100", nil, {})
	assert(cogwork.start(floating))
	cogwork.settle_later(lost)
	cogwork.settle_later(floating)
	-- a robot with no floor in range stays
	local nofloor = make_robot(P(6, 5, 0), "stop", nil, {})
	cogwork.settle_later(nofloor)

	core.after(3, function ()
		cogwork.settings.gravity = false
		local landed = cogwork.is_robot(name_at(P(0, 1, 0))) and core.get_meta(P(0, 1, 0)):get_string("owner") == "tester"
		local stayed = cogwork.is_robot(name_at(P(2, 5, 0)))
		local void = cogwork.is_robot(name_at(P(6, 5, 0)))
		cogwork.stop(P(2, 5, 0), "")
		report("a stopped robot falls to the floor, a running one does not", landed and stayed and void,
			("landed=%s running stayed=%s no floor stayed=%s"):format(tostring(landed), tostring(stayed), tostring(void)))
		done()
	end)
end)

test("a robot keeps its program, storage and forceload when it falls", function (done)
	clear_area()
	cogwork.settings.gravity = true
	core.set_node(P(0, 0, 0), { name = material })
	local pos = make_robot(P(0, 4, 0), "move up", { material .. " 5" }, {})
	core.get_meta(pos):set_string("bot_name", "Faller")
	cogwork.settle_later(pos)
	core.after(2.5, function ()
		cogwork.settings.gravity = false
		local p = P(0, 1, 0)
		local meta = core.get_meta(p)
		report("a robot keeps its program, storage and forceload when it falls",
			cogwork.is_robot(name_at(p)) and meta:get_string("program") == "move up"
			and meta:get_string("bot_name") == "Faller"
			and meta:get_inventory():contains_item("main", ItemStack(material .. " 5"))
			and meta:get_string("owner") == "tester",
			name_at(p))
		done()
	end)
end)

-- water: a robot may be in it ("flooded"), floats or sinks, gives its water to a bucket

test("a robot moves through water and leaves the water behind", function (done)
	clear_area()
	core.set_node(P(0, 1, 1), { name = WATER })
	local pos = make_robot(P(0, 1, 0), "move forward", nil)
	assert(cogwork.start(pos))
	wait_for(pos, 20, function (timeout)
		local in_water = core.get_meta(P(0, 1, 1)):get_string("flooded") == WATER and cogwork.is_robot(name_at(P(0, 1, 1)))
		local behind = name_at(P(0, 1, 0))
		-- go back: the water of that block was never there; leaving the water block restores it
		local back = make_robot(P(0, 1, 1), "move back", nil)
		core.get_meta(P(0, 1, 1)):set_string("flooded", WATER)
		assert(cogwork.start(P(0, 1, 1)))
		wait_for(P(0, 1, 1), 20, function (timeout2)
			report("a robot moves through water and leaves the water behind",
				not timeout and not timeout2 and in_water and behind == "air"
				and name_at(P(0, 1, 1)) == WATER and cogwork.is_robot(name_at(P(0, 1, 0)))
				and core.get_meta(P(0, 1, 0)):get_string("flooded") == "",
				("in_water=%s behind=%s water_back=%s"):format(tostring(in_water), behind, name_at(P(0, 1, 1))))
			done()
		end)
	end)
end)

local function water_column ()
	clear_area()
	core.set_node(P(0, -4, 0), { name = material })
	for y = -3, 2 do core.set_node(P(0, y, 0), { name = WATER }) end
end

local function float_test (name, can_float, want_y)
	test(name, function (done)
		water_column()
		cogwork.settings.gravity, cogwork.settings.can_float = true, can_float
		local pos = make_robot(P(0, 5, 0), "stop", nil, {})
		cogwork.settle_later(pos)
		core.after(3.5, function ()
			cogwork.settings.gravity, cogwork.settings.can_float = false, true
			local p = P(0, want_y, 0)
			report(name, cogwork.is_robot(name_at(p)) and core.get_meta(p):get_string("flooded") == WATER,
				"at " .. (function ()
					for y = -4, 6 do if cogwork.is_robot(name_at(P(0, y, 0))) then return y end end
					return "?"
				end)() .. " wanted " .. want_y)
			done()
		end)
	end)
end
float_test("a robot floats in the water when robots can float", true, 2)
float_test("a robot sinks to the bottom when robots cannot float", false, -3)

test("an empty bucket takes the water of a flooded robot instead of opening it", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "stop", nil, {})
	core.get_meta(pos):set_string("flooded", WATER)
	local node = core.registered_nodes[name_at(pos)]
	local inv = core.create_detached_inventory("cogwork_test_bucket", {})
	inv:set_size("main", 8)
	local fake = { get_player_name = function () return "tester" end, get_inventory = function () return inv end,
		is_player = function () return true end, get_player_control = function () return {} end,
		get_pos = function () return pos end }
	local s = cogwork.editor_session(fake)
	s.pos = nil

	local empty = ItemStack("cogwork_test:bucket_empty")
	local res = node.on_rightclick(pos, core.get_node(pos), fake, empty, { type = "node", under = pos, above = pos })
	local filled = res:get_name() == "cogwork_test:bucket_water"
	local cleared = core.get_meta(pos):get_string("flooded") == ""
	local no_ui = s.pos == nil

	-- not flooded any more: the bucket is just a held item, the editor opens
	local res2 = node.on_rightclick(pos, core.get_node(pos), fake, ItemStack("cogwork_test:bucket_empty"), { type = "node", under = pos, above = pos })
	local ui = s.pos ~= nil
	s.pos = nil

	-- a stack of buckets: one is filled, the rest stay
	core.get_meta(pos):set_string("flooded", WATER)
	local stack = ItemStack("cogwork_test:bucket_empty 3")
	local res3 = node.on_rightclick(pos, core.get_node(pos), fake, stack, { type = "node", under = pos, above = pos })
	local rest = res3:get_name() == "cogwork_test:bucket_empty" and res3:get_count() == 2
		and inv:contains_item("main", ItemStack("cogwork_test:bucket_water"))

	-- something that is not a bucket opens the editor even when flooded
	core.get_meta(pos):set_string("flooded", WATER)
	node.on_rightclick(pos, core.get_node(pos), fake, ItemStack(material), { type = "node", under = pos, above = pos })
	local other = s.pos ~= nil
	s.pos = nil

	report("an empty bucket takes the water of a flooded robot instead of opening it",
		filled and cleared and no_ui and ui and rest and other,
		table.concat({ tostring(filled), tostring(cleared), tostring(no_ui), tostring(ui), tostring(rest), tostring(other) }, " "))
	done()
end)

-- the game's own bucket mod
do
	local pairs_by_game = {
		{ global = "bucket", empty = "bucket:bucket_empty", source = "default:water_source", full = "bucket:bucket_water" },
		{ global = "mcl_buckets", empty = "mcl_buckets:bucket_empty", source = "mcl_core:water_source", full = "mcl_buckets:bucket_water" },
	}
	for _, g in ipairs(pairs_by_game) do
		if rawget(_G, g.global) and core.registered_items[g.empty] and core.registered_nodes[g.source] then
			test("the " .. g.global .. " mod's bucket takes the water of a flooded robot", function (done)
				clear_area()
				local pos = make_robot(P(0, 1, 0), "stop", nil, {})
				core.get_meta(pos):set_string("flooded", g.source)
				local inv = core.create_detached_inventory("cogwork_test_bucket2", {})
				inv:set_size("main", 8)
				local fake = { get_player_name = function () return "tester" end, get_inventory = function () return inv end,
					is_player = function () return true end, get_player_control = function () return {} end,
					get_pos = function () return pos end }
				local res = core.registered_nodes[name_at(pos)].on_rightclick(pos, core.get_node(pos), fake,
					ItemStack(g.empty), { type = "node", under = pos, above = pos })
				report("the " .. g.global .. " mod's bucket takes the water of a flooded robot",
					res:get_name() == g.full and core.get_meta(pos):get_string("flooded") == "", res:get_name())
				done()
			end)
		end
	end
end

test("water is put back when a flooded robot is dug, and a robot placed in water is flooded", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "stop", nil, {})
	core.get_meta(pos):set_string("flooded", WATER)
	core.remove_node(pos)
	core.registered_nodes["cogwork:robot"].after_dig_node(pos, { name = "cogwork:robot" },
		{ fields = { flooded = WATER }, inventory = {} }, nil)
	local restored = name_at(pos) == WATER

	-- placed: the callbacks every placed node goes through, the old node was water
	core.set_node(pos, { name = "cogwork:robot" })
	for _, f in ipairs(core.registered_on_placenodes) do
		pcall(f, pos, { name = "cogwork:robot" }, nil, { name = WATER }, ItemStack("cogwork:robot"), { type = "node" })
	end
	local flooded = core.get_meta(pos):get_string("flooded") == WATER
	report("water is put back when a flooded robot is dug, and a robot placed in water is flooded",
		restored and flooded, tostring(restored) .. " " .. tostring(flooded))
	done()
end)

-- ---------------------------------------------------------------- structure

local function inv_of (p) return core.get_meta(p):get_inventory() end
local function cell_charge (p, i) return (cogwork.cell_info(inv_of(p):get_stack("cells", i or 1))) end

test("actions cost power", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "repeat 5\n  move forward\ndig front\nturn left", nil, nil)
	assert(cogwork.start(pos))
	wait_for(pos, 20, function (timeout)
		local p = find_robot()
		-- 5 moves (5) + dig (2, nothing there but it still costs) + turn (0.5)
		local charge = cell_charge(p)
		report("actions cost power", not timeout and math.abs(charge - (450 - 7.5)) < 0.01,
			"charge " .. tostring(charge))
		done()
	end)
end)

test("a robot stops when its cells run dry and stays off", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "repeat 10\n  move forward", nil, nil)
	local stack = inv_of(pos):get_stack("cells", 1)
	cogwork.set_cell_charge(stack, 3)
	inv_of(pos):set_stack("cells", 1, stack)
	assert(cogwork.start(pos))
	wait_for(pos, 20, function (timeout)
		local p = find_robot()
		local err = err_of(p)
		local again, why = cogwork.start(p)
		report("a robot stops when its cells run dry and stays off",
			not timeout and vector.equals(p, P(0, 1, 3)) and err:lower():find("out of power") and cell_charge(p) == 0
			and again == false and why and why:find("empty") and not cogwork.is_running(p),
			("at %s err=%s again=%s"):format(core.pos_to_string(vector.subtract(p, ORIGIN)), err, tostring(again)))
		done()
	end)
end)

test("a robot without armor or without a cell stays off", function (done)
	clear_area()
	local no_armor = make_robot(P(0, 1, 0), "move up", nil, nil, true)
	inv_of(no_armor):set_stack("cells", 1, ItemStack("cogwork:cell_small"))
	local a_ok, a_why = cogwork.start(no_armor)

	local no_cell = make_robot(P(3, 1, 0), "move up", nil, nil, true)
	inv_of(no_cell):set_stack("armor", 1, ItemStack("cogwork:armor_basic"))
	local c_ok, c_why = cogwork.start(no_cell)

	local bare = make_robot(P(6, 1, 0), "move up", nil, nil, true)
	local b_ok = cogwork.start(bare)
	report("a robot without armor or without a cell stays off",
		a_ok == false and a_why:find("armor") and c_ok == false and c_why:find("cell") and b_ok == false
		and not cogwork.is_running(no_armor) and not cogwork.is_running(no_cell),
		tostring(a_why) .. " | " .. tostring(c_why))
	done()
end)

test("taking out the armor or the cells stops a running robot", function (done)
	clear_area()
	local node = core.registered_nodes["cogwork:robot"]
	local fake = { get_player_name = function () return "tester" end }
	local armored = make_robot(P(0, 1, 0), "wait 100", nil, nil)
	assert(cogwork.start(armored))
	inv_of(armored):set_stack("armor", 1, ItemStack())
	node.on_metadata_inventory_take(armored, "armor", 1, ItemStack("cogwork:armor_basic"), fake)
	local a_stopped = not cogwork.is_running(armored) and err_of(armored):find("armor") ~= nil
	local a_restart = cogwork.start(armored)

	local celled = make_robot(P(4, 1, 0), "wait 100", nil, nil)
	assert(cogwork.start(celled))
	inv_of(celled):set_stack("cells", 1, ItemStack())
	node.on_metadata_inventory_take(celled, "cells", 1, ItemStack("cogwork:cell_small"), fake)
	local c_stopped = not cogwork.is_running(celled) and err_of(celled):find("cell") ~= nil
	report("taking out the armor or the cells stops a running robot",
		a_stopped and a_restart == false and c_stopped, tostring(a_stopped) .. " " .. tostring(c_stopped))
	done()
end)

test("armor wears but never breaks, then the cells take the damage", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "wait 100", nil, nil)
	cogwork.damage(pos, 10)
	local armor = inv_of(pos):get_stack("armor", 1)
	local first = cogwork.armor_info(armor)
	cogwork.damage(pos, 40)           -- 14 left in the armor, the other 26 go to the cells
	armor = inv_of(pos):get_stack("armor", 1)
	local worn = cogwork.armor_info(armor)
	local charge = cell_charge(pos)
	-- worn out, still there, the robot still starts
	local starts = cogwork.start(pos)
	report("armor wears but never breaks, then the cells take the damage",
		first == 14 and worn == 0 and armor:get_name() == "cogwork:armor_basic"
		and math.abs(charge - 424) < 0.01 and starts == true and cogwork.has_armor(pos),
		("first=%s worn=%s charge=%s"):format(tostring(first), tostring(worn), tostring(charge)))
	cogwork.stop(pos, "")
	done()
end)

test("the Self-Repair Module mends armor for power", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "stop", nil, nil)
	inv_of(pos):set_stack("armor_mod", 1, ItemStack(cogwork.ITEM_REPAIR))
	cogwork.damage(pos, 10)    -- 10 durability of the 24
	local before = cogwork.armor_info(inv_of(pos):get_stack("armor", 1))
	local charge_before = cell_charge(pos)
	cogwork.structure_tick(pos)
	local after = cogwork.armor_info(inv_of(pos):get_stack("armor", 1))
	report("the Self-Repair Module mends armor for power",
		before == 14 and after == 15 and math.abs(cell_charge(pos) - (charge_before - 1)) < 0.01,
		("%s -> %s"):format(tostring(before), tostring(after)))
	done()
end)

test("the Self-Generator charges one cell at a time", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "stop", nil, nil)
	local inv = inv_of(pos)
	local a = ItemStack("cogwork:cell_small"); cogwork.set_cell_charge(a, 100); inv:set_stack("cells", 1, a)
	local b = ItemStack("cogwork:cell_medium"); cogwork.set_cell_charge(b, 0); inv:set_stack("cells", 2, b)
	inv:set_stack("augment", 1, ItemStack(cogwork.ITEM_GENERATOR))
	cogwork.structure_changed(pos, "augment")
	local timer_started = core.get_node_timer(pos):is_started()
	cogwork.structure_tick(pos)
	cogwork.structure_tick(pos)
	-- the first cell not full gets all of it: 100 + 2 x 10; the other stays empty
	report("the Self-Generator charges one cell at a time",
		timer_started and cell_charge(pos, 1) == 120 and cell_charge(pos, 2) == 0,
		("%s %s timer=%s"):format(tostring(cell_charge(pos, 1)), tostring(cell_charge(pos, 2)), tostring(timer_started)))
	done()
end)

test("a Creative Capacitor fills the cells at once and keeps them full", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "repeat 20\n  move forward", nil, nil)
	local inv = inv_of(pos)
	local a = ItemStack("cogwork:cell_small"); cogwork.set_cell_charge(a, 10); inv:set_stack("cells", 1, a)
	local b = ItemStack("cogwork:cell_large"); cogwork.set_cell_charge(b, 0); inv:set_stack("cells", 2, b)
	inv:set_stack("augment", 1, ItemStack(cogwork.ITEM_CAPACITOR))
	core.registered_nodes["cogwork:robot"].on_metadata_inventory_put(pos, "augment", 1, ItemStack(cogwork.ITEM_CAPACITOR),
		{ get_player_name = function () return "tester" end })
	local filled = cell_charge(pos, 1) == 450 and cell_charge(pos, 2) == 1400
	assert(cogwork.start(pos))
	wait_for(pos, 20, function (timeout)
		report("a Creative Capacitor fills the cells at once and keeps them full",
			filled and not timeout and cell_charge(find_robot(), 1) == 450 and err_of(find_robot()) == "",
			("filled=%s now %s"):format(tostring(filled), tostring(cell_charge(find_robot(), 1))))
		done()
	end)
end)

test("the structure slots take only their own parts", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "stop", nil, nil)
	local node = core.registered_nodes["cogwork:robot"]
	local fake = { get_player_name = function () return "tester" end }
	local function put (list, name) return node.allow_metadata_inventory_put(pos, list, 1, ItemStack(name), fake) end
	report("the structure slots take only their own parts",
		put("armor", "cogwork:armor_heavy") == 1 and put("armor", "cogwork:cell_small") == 0
		and put("cells", "cogwork:cell_colossal") == 1 and put("cells", "cogwork:armor_basic") == 0
		and put("armor_mod", cogwork.ITEM_REPAIR) == 1 and put("armor_mod", cogwork.ITEM_GENERATOR) == 0
		and put("augment", cogwork.ITEM_CAPACITOR) == 1 and put("augment", cogwork.ITEM_REPAIR) == 0
		and put("upgrades", "cogwork:upgrade_combat") == 1 and put("upgrades", "cogwork:cell_small") == 0)
	done()
end)

test("a robot installs and uninstalls its own parts, but keeps one cell", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0),
		"install \"armor_mod\"\ninstall \"augment\"\ninstall \"cell\"\nuninstall \"cell\"\nuninstall \"cell\"\nif ok\n  move up\n"
		.. "uninstall \"armor\"\nif ok\n  turn around",
		{ cogwork.ITEM_REPAIR, cogwork.ITEM_GENERATOR, "cogwork:cell_medium" }, nil)
	assert(cogwork.start(pos))
	wait_for(pos, 20, function (timeout)
		local p = find_robot()
		local inv = inv_of(p)
		local cells = cogwork.cells_of(p)
		report("a robot installs and uninstalls its own parts, but keeps one cell",
			not timeout and vector.equals(p, P(0, 1, 0))                       -- the second uninstall failed: no move up
			and inv:get_stack("armor_mod", 1):get_name() == cogwork.ITEM_REPAIR
			and inv:get_stack("augment", 1):get_name() == cogwork.ITEM_GENERATOR
			and #cells == 1 and cells[1].stack:get_name() == "cogwork:cell_medium"   -- the emptier Small went back to storage
			and inv:contains_item("main", ItemStack("cogwork:cell_small"))
			and cogwork.has_armor(p) and core.get_node(p).param2 == core.dir_to_facedir({ x = 0, y = 0, z = -1 }),
			("cells=%d err=%s"):format(#cells, err_of(p)))
		done()
	end)
end)

test("structure queries and old robots", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0),
		"if battery_level = 100 and armor_level = 100 and cell_count = 1 and structure_item \"armor\" = \"cogwork:armor_basic\"\n  move up",
		nil, nil)
	assert(cogwork.start(pos))
	wait_for(pos, 20, function (timeout)
		local queried = vector.equals(find_robot(), P(0, 2, 0))

		-- a robot from before the structure: no flag, empty slots: starter armor and cell, once
		local old = make_robot(P(4, 1, 0), "stop", nil, nil, true)
		core.get_meta(old):set_string("structure_v", "")
		local started = cogwork.start(old)
		local starter = cogwork.has_armor(old) and #cogwork.cells_of(old) == 1 and core.get_meta(old):get_int("structure_v") == 1
		cogwork.stop(old, "")
		inv_of(old):set_stack("armor", 1, ItemStack())
		cogwork.ensure_structure(old)
		local once = not cogwork.has_armor(old)
		report("structure queries and old robots", not timeout and queried and started and starter and once,
			("queried=%s started=%s starter=%s once=%s"):format(tostring(queried), tostring(started), tostring(starter), tostring(once)))
		done()
	end)
end)

test("the Combat Upgrade is an upgrade, and robots only hit players when it is in", function (done)
	clear_area()
	local with = make_robot(P(0, 1, 0), "stop", nil, { "cogwork:upgrade_combat" })
	local without = make_robot(P(3, 1, 0), "stop", nil, {})
	report("the Combat Upgrade is an upgrade, and robots only hit players when it is in",
		cogwork.has_upgrade(with, "cogwork:upgrade_combat") and not cogwork.has_upgrade(without, "cogwork:upgrade_combat")
		and cogwork.UPGRADE_ITEMS["cogwork:upgrade_combat"])
	done()
end)

-- all liquids: any liquid floods (none hurts) and fills a bucket, Skyblock: Zero's fluid cells too
core.register_node("cogwork_test:lava_source", {
	description = "Test lava", drawtype = "liquid", tiles = { "blank.png" },
	paramtype = "light", walkable = false, pointable = false, diggable = false, buildable_to = true,
	liquidtype = "source", liquid_alternative_flowing = "cogwork_test:lava_flowing",
	liquid_alternative_source = "cogwork_test:lava_source", liquid_viscosity = 7,
	damage_per_second = 4, groups = { lava = 3, liquid = 2 },
})
core.register_node("cogwork_test:lava_flowing", {
	description = "Test lava", drawtype = "flowingliquid", tiles = { "blank.png" },
	special_tiles = { { name = "blank.png" }, { name = "blank.png" } },
	paramtype = "light", paramtype2 = "flowingliquid", walkable = false, pointable = false,
	diggable = false, buildable_to = true, liquidtype = "flowing",
	liquid_alternative_flowing = "cogwork_test:lava_flowing",
	liquid_alternative_source = "cogwork_test:lava_source", liquid_viscosity = 7,
	damage_per_second = 4, groups = { lava = 3, liquid = 2, not_in_creative_inventory = 1 },
})
core.register_craftitem("cogwork_test:bucket_lava", { description = "Test bucket of lava", inventory_image = "blank.png", stack_max = 1 })
cogwork.register_bucket({
	empty = "cogwork_test:bucket_empty",
	filled = function (source) return source == "cogwork_test:lava_source" and "cogwork_test:bucket_lava" or nil end,
})

test("a robot goes into any liquid, lava does not hurt it, a bucket takes the lava", function (done)
	clear_area()
	core.set_node(P(0, 1, 1), { name = "cogwork_test:lava_source" })
	local pos = make_robot(P(0, 1, 0), "move forward\nwait 80", nil, nil)
	assert(cogwork.start(pos))
	core.after(5, function ()
		local in_lava = core.get_meta(P(0, 1, 1)):get_string("flooded") == "cogwork_test:lava_source"
		local armor = cogwork.armor_info(inv_of(P(0, 1, 1)):get_stack("armor", 1))
		cogwork.stop(P(0, 1, 1), "")

		-- the bucket
		local inv = core.create_detached_inventory("cogwork_test_lava", {})
		inv:set_size("main", 4)
		local fake = { get_player_name = function () return "tester" end, get_inventory = function () return inv end,
			is_player = function () return true end, get_player_control = function () return {} end,
			get_pos = function () return P(0, 1, 1) end }
		local res = cogwork.fill_bucket(P(0, 1, 1), fake, ItemStack("cogwork_test:bucket_empty"))
		report("a robot goes into any liquid, lava does not hurt it, a bucket takes the lava",
			in_lava and armor == 24 and cell_charge(P(0, 1, 1)) > 440 and res and res:get_name() == "cogwork_test:bucket_lava",
			("in_lava=%s armor=%s bucket=%s"):format(tostring(in_lava), tostring(armor), res and res:get_name() or "nil"))
		done()
	end)
end)

if rawget(_G, "sbz_api") and sbz_api.sources2fluid_cells and core.registered_items["sbz_chem:empty_fluid_cell"] then
	test("Skyblock: Zero's empty Fluid Cell takes the liquid of a flooded robot", function (done)
		clear_area()
		local source, full = next(sbz_api.sources2fluid_cells)
		local pos = make_robot(P(0, 1, 0), "stop", nil, nil)
		core.get_meta(pos):set_string("flooded", source)
		local inv = core.create_detached_inventory("cogwork_test_fluid", {})
		inv:set_size("main", 4)
		local fake = { get_player_name = function () return "tester" end, get_inventory = function () return inv end,
			is_player = function () return true end, get_player_control = function () return {} end,
			get_pos = function () return pos end }
		local res = core.registered_nodes[core.get_node(pos).name].on_rightclick(pos, core.get_node(pos), fake,
			ItemStack("sbz_chem:empty_fluid_cell"), { type = "node", under = pos, above = pos })
		report("Skyblock: Zero's empty Fluid Cell takes the liquid of a flooded robot",
			res:get_name() == full and core.get_meta(pos):get_string("flooded") == "", source .. " -> " .. res:get_name())
		done()
	end)
end

test("every structure item has a recipe except the Creative Capacitor", function (done)
	local missing = {}
	for _, item in ipairs({ "cogwork:cell_small", "cogwork:cell_medium", "cogwork:cell_large", "cogwork:cell_huge",
		"cogwork:cell_colossal", "cogwork:armor_basic", "cogwork:armor_reinforced", "cogwork:armor_heavy",
		"cogwork:armor_mod_repair", "cogwork:augment_generator", "cogwork:upgrade_combat", "cogwork:upgrade_storage",
		"cogwork:upgrade_hover", "cogwork:upgrade_flight" }) do
		if not core.get_all_craft_recipes(item) then missing[#missing + 1] = item end
	end
	local capacitor = core.get_all_craft_recipes(cogwork.ITEM_CAPACITOR)
	report("every structure item has a recipe except the Creative Capacitor",
		#missing == 0 and capacitor == nil, table.concat(missing, ","))
	done()
end)

-- ---------------------------------------------------------------- chargers

core.register_tool("cogwork_test:tbattery", { description = "Test technic battery", inventory_image = "blank.png" })

-- a charger with a robot on it that has two cells (the charges given)
local function charger_setup (c1, c2, slot_kind)
	clear_area()
	local cpos = P(0, 0, 0)
	core.set_node(cpos, { name = "cogwork:charger" })
	local robot = make_robot(P(0, 1, 0), "stop", nil, nil)
	local inv = inv_of(robot)
	local a = ItemStack("cogwork:cell_small"); cogwork.set_cell_charge(a, c1); inv:set_stack("cells", 1, a)
	local b = ItemStack("cogwork:cell_medium"); cogwork.set_cell_charge(b, c2); inv:set_stack("cells", 2, b)
	return cpos, robot
end

test("a charger charges both cells of the robot on it from a spare cell", function (done)
	local cpos, robot = charger_setup(100, 0)
	local sinv = core.get_meta(cpos):get_inventory()
	local spare = ItemStack("cogwork:cell_large")
	sinv:set_stack("source", 1, spare)
	cogwork.charger_base_tick(cpos)
	local c1, c2 = cell_charge(robot, 1), cell_charge(robot, 2)
	local left = cogwork.cell_info(sinv:get_stack("source", 1))
	-- two cells charge at 25 a second each, so the source gives 50 (and loses a tenth doing it)
	local two_ok = c1 == 125 and c2 == 25 and math.abs(left - (1400 - 50 / 0.9)) < 0.1

	-- one cell full: only the other is charged, and the source gives half as much
	local fresh = ItemStack("cogwork:cell_small"); inv_of(robot):set_stack("cells", 1, fresh)
	sinv:set_stack("source", 1, ItemStack("cogwork:cell_large"))
	cogwork.charger_base_tick(cpos)
	local one_left = cogwork.cell_info(sinv:get_stack("source", 1))
	local one_ok = cell_charge(robot, 1) == 450 and cell_charge(robot, 2) == 50 and math.abs(one_left - (1400 - 25 / 0.9)) < 0.1

	-- an empty source charges nothing; all cells full takes nothing from it
	local empty = ItemStack("cogwork:cell_large"); cogwork.set_cell_charge(empty, 0)
	sinv:set_stack("source", 1, empty)
	cogwork.charger_base_tick(cpos)
	local none_ok = cell_charge(robot, 2) == 50

	report("a charger charges both cells of the robot on it from a spare cell", two_ok and one_ok and none_ok,
		("%s %s left=%s | %s %s | %s"):format(tostring(c1), tostring(c2), tostring(left), tostring(cell_charge(robot, 1)), tostring(cell_charge(robot, 2)), tostring(none_ok)))
	done()
end)

test("a Technic battery item charges the cells, and the source slot takes only sources", function (done)
	local cpos, robot = charger_setup(0, 0)
	-- stands in for Technic: power tools with a charge in the stack meta, as technic.get_charge/set_charge do
	rawset(_G, "technic", {
		power_tools = { ["cogwork_test:tbattery"] = 10000 },
		get_charge = function (stack)
			local max = technic.power_tools[stack:get_name()]
			if not max then return 0, 0 end
			return stack:get_meta():get_int("technic:charge"), max
		end,
		set_charge = function (stack, charge) stack:get_meta():set_int("technic:charge", charge) end,
	})
	local battery = ItemStack("cogwork_test:tbattery")
	technic.set_charge(battery, 10000)
	local node = core.registered_nodes["cogwork:charger"]
	local fake = { get_player_name = function () return "tester" end, is_player = function () return true end }
	local accepts = node.allow_metadata_inventory_put(cpos, "source", 1, battery, fake) == 1
		and node.allow_metadata_inventory_put(cpos, "source", 1, ItemStack(material), fake) == 0
		and node.allow_metadata_inventory_put(cpos, "source", 1, ItemStack("cogwork:cell_small"), fake) == 1

	local sinv = core.get_meta(cpos):get_inventory()
	sinv:set_stack("source", 1, battery)
	cogwork.charger_base_tick(cpos)
	-- 10 000 EU are 1000 units; two cells take 25 each, 500 EU
	local left = technic.get_charge(sinv:get_stack("source", 1))
	rawset(_G, "technic", nil)
	report("a Technic battery item charges the cells, and the source slot takes only sources",
		accepts and cell_charge(robot, 1) == 25 and cell_charge(robot, 2) == 25 and left == 9500,
		("%s %s left=%s accepts=%s"):format(tostring(cell_charge(robot, 1)), tostring(cell_charge(robot, 2)), tostring(left), tostring(accepts)))
	done()
end)

test("Technic LV and MV chargers demand more for more cells, MV less than LV", function (done)
	local cpos, robot = charger_setup(0, 0)
	local meta = core.get_meta(cpos)
	local lv, mv = cogwork.charger_technic_run("LV", 150), cogwork.charger_technic_run("MV", 100)

	lv(cpos)
	local demand_lv = meta:get_int("LV_EU_demand")      -- two cells: 300
	meta:set_int("LV_EU_input", 100)
	lv(cpos)
	local starved = cell_charge(robot, 1) == 0           -- not enough power: nothing
	meta:set_int("LV_EU_input", 300)
	lv(cpos)
	local lv_ok = cell_charge(robot, 1) == 25 and cell_charge(robot, 2) == 25

	mv(cpos)
	local demand_mv = meta:get_int("MV_EU_demand")      -- two cells: 200, less than LV
	meta:set_int("MV_EU_input", 200)
	mv(cpos)
	local mv_ok = cell_charge(robot, 1) == 50

	-- one cell needs only half
	local full = ItemStack("cogwork:cell_small"); inv_of(robot):set_stack("cells", 1, full)
	lv(cpos)
	local one = meta:get_int("LV_EU_demand")
	-- nothing on top: no demand
	core.remove_node(robot)
	lv(cpos)
	report("Technic LV and MV chargers demand more for more cells, MV less than LV",
		demand_lv == 300 and starved and lv_ok and demand_mv == 200 and mv_ok and one == 150 and meta:get_int("LV_EU_demand") == 0,
		("%d %s %s %d %s %d"):format(demand_lv, tostring(starved), tostring(lv_ok), demand_mv, tostring(mv_ok), one))
	done()
end)

test("a Techage charger takes from the network's pool in proportion to what it gets", function (done)
	local cpos, robot = charger_setup(0, 0)
	local asked
	rawset(_G, "techage", { ElectricCable = {} })
	rawset(_G, "networks", { power = { consume_power = function (pos, cable, outdir, amount)
		asked = amount
		return amount / 2        -- the network has half of it
	end } })
	cogwork.charger_techage_tick(cpos)
	rawset(_G, "techage", nil)
	rawset(_G, "networks", nil)
	-- two cells ask 8 per cycle; half of it charges each cell for half of 2 s x 25 units
	report("a Techage charger takes from the network's pool in proportion to what it gets",
		asked == 8 and cell_charge(robot, 1) == 25 and cell_charge(robot, 2) == 25,
		("asked=%s %s %s"):format(tostring(asked), tostring(cell_charge(robot, 1)), tostring(cell_charge(robot, 2))))
	done()
end)

if rawget(_G, "sbz_api") and core.registered_nodes["cogwork:charger_sbz"] then
	test("a Skyblock: Zero charger reports what it draws and charges what the network can spare", function (done)
		local cpos, robot = charger_setup(0, 0)
		core.set_node(cpos, { name = "cogwork:charger_sbz" })
		local node = core.registered_nodes["cogwork:charger_sbz"]
		local meta = core.get_meta(cpos)
		local drawn_both = node.action(cpos, core.get_node(cpos), meta, 100, 0)
		local both = cell_charge(robot, 1) == 25 and cell_charge(robot, 2) == 25
		-- the network has power for one cell only
		local drawn_one = node.action(cpos, core.get_node(cpos), meta, 20, 0)
		local one = cell_charge(robot, 1) == 50 and cell_charge(robot, 2) == 25
		report("a Skyblock: Zero charger reports what it draws and charges what the network can spare",
			drawn_both == 24 and both and drawn_one == 12 and one and core.get_item_group("cogwork:charger_sbz", "sbz_machine") == 1,
			("%s %s %s %s"):format(tostring(drawn_both), tostring(both), tostring(drawn_one), tostring(one)))
		done()
	end)
end

test("the charger recipes exist", function (done)
	local base = core.get_all_craft_recipes("cogwork:charger")
	local sbz = rawget(_G, "sbz_api") ~= nil
	report("the charger recipes exist", base ~= nil and (not sbz or core.get_all_craft_recipes("cogwork:charger_sbz") ~= nil))
	done()
end)

-- storage: 8 x 2, a Storage Upgrade adds 4 slots
test("storage is 16 slots and every Storage Upgrade adds 4", function (done)
	clear_area()
	local plain = make_robot(P(0, 1, 0), "stop", nil, {})
	local two = make_robot(P(3, 1, 0), "stop", nil, { "cogwork:upgrade_storage", "cogwork:upgrade_storage" })
	local all = make_robot(P(6, 1, 0), "stop", nil, { "cogwork:upgrade_storage", "cogwork:upgrade_storage",
		"cogwork:upgrade_storage", "cogwork:upgrade_storage", "cogwork:upgrade_storage", "cogwork:upgrade_storage" })

	-- a fresh robot node, and the callback that puts an upgrade in
	core.set_node(P(9, 1, 0), { name = "cogwork:robot" })
	local fresh = inv_of(P(9, 1, 0)):get_size("main")
	inv_of(P(9, 1, 0)):set_stack("upgrades", 1, ItemStack("cogwork:upgrade_storage"))
	core.registered_nodes["cogwork:robot"].on_metadata_inventory_put(P(9, 1, 0), "upgrades", 1,
		ItemStack("cogwork:upgrade_storage"), { get_player_name = function () return "tester" end })
	report("storage is 16 slots and every Storage Upgrade adds 4",
		inv_of(plain):get_size("main") == 16 and inv_of(two):get_size("main") == 24
		and inv_of(all):get_size("main") == 40 and fresh == 16 and inv_of(P(9, 1, 0)):get_size("main") == 20,
		("%d %d %d fresh=%d put=%d"):format(inv_of(plain):get_size("main"), inv_of(two):get_size("main"), inv_of(all):get_size("main"), fresh, inv_of(P(9, 1, 0)):get_size("main")))
	done()
end)

test("a Storage Upgrade stays while its slots hold items, and the storage shrinks when it goes", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "stop", nil, { "cogwork:upgrade_storage" })
	local node = core.registered_nodes["cogwork:robot"]
	local fake = { get_player_name = function () return "tester" end }
	local up = ItemStack("cogwork:upgrade_storage")
	local inv = inv_of(pos)

	inv:set_stack("main", 18, ItemStack(material))       -- in the slots the upgrade gives (17..20)
	local blocked = node.allow_metadata_inventory_take(pos, "upgrades", 1, up, fake) == 0
		and node.allow_metadata_inventory_move(pos, "upgrades", 1, "main", 1, 1, fake) == 0
	-- but another upgrade slot can be rearranged
	local shuffle = node.allow_metadata_inventory_move(pos, "upgrades", 1, "upgrades", 2, 1, fake) == 1

	inv:set_stack("main", 18, ItemStack())
	local free = node.allow_metadata_inventory_take(pos, "upgrades", 1, up, fake) == 1
	inv:set_stack("upgrades", 1, ItemStack())
	node.on_metadata_inventory_take(pos, "upgrades", 1, up, fake)
	report("a Storage Upgrade stays while its slots hold items, and the storage shrinks when it goes",
		blocked and shuffle and free and inv:get_size("main") == 16,
		("blocked=%s shuffle=%s free=%s size=%d"):format(tostring(blocked), tostring(shuffle), tostring(free), inv:get_size("main")))
	done()
end)

test("an older robot with 32 slots keeps its items and shrinks once they are gone", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "stop", nil, {})
	local inv = inv_of(pos)
	inv:set_size("main", 32)
	inv:set_stack("main", 30, ItemStack(material))
	inv:set_stack("main", 5, ItemStack(material))
	cogwork.ensure_structure(pos)
	local kept = inv:get_size("main") == 30 and inv:get_stack("main", 30):get_name() == material
	inv:set_stack("main", 30, ItemStack())
	cogwork.sync_storage(pos)
	report("an older robot with 32 slots keeps its items and shrinks once they are gone",
		kept and inv:get_size("main") == 16 and inv:get_stack("main", 5):get_name() == material)
	done()
end)

test("the Storage tab with all upgrades fits its window and overlaps nothing", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "stop", nil, { "cogwork:upgrade_storage", "cogwork:upgrade_storage",
		"cogwork:upgrade_storage", "cogwork:upgrade_storage", "cogwork:upgrade_storage", "cogwork:upgrade_storage" })
	local fake = { get_player_name = function () return "tester" end, get_inventory = function () return nil end, is_player = function () return true end }
	local fs = cogwork.formspec(pos, { tab = "storage", line = 1, tok = 0, scroll = 0, cat = "flow", msg = "", player = fake, pos = pos })
	local height = tonumber(fs:match("size%[19%.8,([%d%.]+)%]"))
	local lists = {}
	local bottom = 0
	for x, y, w, h in fs:gmatch("list%[[^;]*;[^;]*;([%d%.%-]+),([%d%.%-]+);([%d%.]+),([%d%.]+);") do
		x, y, w, h = tonumber(x), tonumber(y), tonumber(w), tonumber(h)
		lists[#lists + 1] = { y = y, y2 = y + h * 1.25 - 0.25, h = h }
		bottom = math.max(bottom, y + h * 1.25 - 0.25)
	end
	-- 40 slots in 5 rows, the inventory below them, all inside the window
	report("the Storage tab with all upgrades fits its window and overlaps nothing",
		#lists == 2 and lists[1].h == 5 and lists[1].y2 <= lists[2].y and bottom <= height,
		("lists=%d rows=%s bottom=%s height=%s"):format(#lists, tostring(lists[1] and lists[1].h), tostring(bottom), tostring(height)))
	done()
end)

-- ---------------------------------------------------------------- the robot you see

-- the visual entities standing on the robot node at pos
local function visuals_at (p)
	local out = {}
	for _, obj in ipairs(core.get_objects_inside_radius(p, 0.45)) do
		local le = obj:get_luaentity()
		if le and le.name == "cogwork:visual" then out[#out + 1] = obj end
	end
	return out
end

test("a robot is drawn by one entity with the right model and face", function (done)
	clear_area()
	core.set_node(P(0, 0, 0), { name = material })
	local pos = make_robot(P(0, 1, 0), "wait 100", nil, {})
	cogwork.ensure_visual(pos)
	cogwork.ensure_visual(pos)                      -- twice: still one
	local one = visuals_at(pos)
	local mesh = one[1] and one[1]:get_properties().mesh
	local off_face = one[1] and one[1]:get_properties().textures[2]

	assert(cogwork.start(pos))
	local lit = visuals_at(pos)[1]:get_properties().textures[2]
	cogwork.stop(pos, "")
	local dark = visuals_at(pos)[1]:get_properties().textures[2]

	-- nothing under it: the hover model
	local up = make_robot(P(4, 1, 0), "stop", nil, {})
	cogwork.refresh_variant(up)
	local hover = visuals_at(up)[1] and visuals_at(up)[1]:get_properties().mesh
	report("a robot is drawn by one entity with the right model and face",
		#one == 1 and mesh == "cogwork_robot.obj" and off_face == "cogwork_face.png"
		and lit == "cogwork_face_on.png" and dark == "cogwork_face.png" and hover == "cogwork_hover.obj",
		("n=%d %s %s %s %s %s"):format(#one, tostring(mesh), tostring(off_face), tostring(lit), tostring(dark), tostring(hover)))
	done()
end)

test("a drone has four rotors that spin while it runs, and thrusters give particles in the air", function (done)
	clear_area()
	core.set_node(P(0, 0, 0), { name = material })
	-- a drone on the floor: rotors, no particles
	local grounded = make_robot(P(0, 1, 0), "wait 100", nil, { "cogwork:upgrade_flight" })
	cogwork.refresh_variant(grounded)
	local le = visuals_at(grounded)[1]:get_luaentity()
	local rotors = #(le.rotors or {})
	local still = le.rotors[1]:get_properties().automatic_rotate == 0
	local no_particles = le.spawner == nil

	assert(cogwork.start(grounded))
	le = visuals_at(P(0, 1, 0))[1]:get_luaentity()
	local spins = le.rotors[1]:get_properties().automatic_rotate > 0 and le.rotors[4]:get_properties().automatic_rotate > 0
	cogwork.stop(grounded, "")
	le = visuals_at(P(0, 1, 0))[1]:get_luaentity()
	local stops = le.rotors[1]:get_properties().automatic_rotate == 0

	-- the same in the air, and a hover robot: thruster particles
	local flying = make_robot(P(5, 3, 0), "stop", nil, { "cogwork:upgrade_flight" })
	cogwork.refresh_variant(flying)
	local fle = visuals_at(flying)[1]:get_luaentity()
	local hovering = make_robot(P(8, 3, 0), "stop", nil, {})
	cogwork.refresh_variant(hovering)
	local hle = visuals_at(hovering)[1]:get_luaentity()
	report("a drone has four rotors that spin while it runs, and thrusters give particles in the air",
		rotors == 4 and still and no_particles and spins and stops and fle.spawner ~= nil and hle.spawner ~= nil,
		("rotors=%d still=%s nopart=%s spins=%s stops=%s fly=%s hover=%s"):format(rotors, tostring(still), tostring(no_particles),
			tostring(spins), tostring(stops), tostring(fle.spawner), tostring(hle.spawner)))
	done()
end)

test("the visual goes along when the robot moves and is gone when it is dug", function (done)
	clear_area()
	core.set_node(P(0, 0, 0), { name = material })
	core.set_node(P(0, 0, 1), { name = material })
	core.set_node(P(0, 0, 2), { name = material })
	local pos = make_robot(P(0, 1, 0), "move forward\nmove forward", nil, {})
	cogwork.ensure_visual(pos)
	assert(cogwork.start(pos))
	wait_for(pos, 20, function (timeout)
		local at_new = #visuals_at(P(0, 1, 2))
		local at_old = #visuals_at(P(0, 1, 0)) + #visuals_at(P(0, 1, 1))
		-- dug: the node's destructor takes the visual with it
		core.remove_node(P(0, 1, 2))     -- calls the node's on_destruct
		-- an entity is removed at the end of the server step
		core.after(0.5, function ()
			local after_dig = #visuals_at(P(0, 1, 2))
			report("the visual goes along when the robot moves and is gone when it is dug",
				not timeout and at_new == 1 and at_old == 0 and after_dig == 0,
				("new=%d old=%d dug=%d"):format(at_new, at_old, after_dig))
			done()
		end)
	end)
end)

test("a robot's body is not an entity to the robots around it", function (done)
	clear_area()
	core.set_node(P(0, 0, 0), { name = material })
	local pos = make_robot(P(0, 1, 0), "if entity front = \"\"\n  move up", nil, {})
	local other = make_robot(P(0, 1, 1), "stop", nil, {})
	cogwork.ensure_visual(other)
	cogwork.ensure_visual(pos)
	assert(cogwork.start(pos))
	wait_for(pos, 20, function (timeout)
		report("a robot's body is not an entity to the robots around it",
			not timeout and cogwork.is_robot(name_at(P(0, 2, 0))), "no move")
		done()
	end)
end)

-- ---------------------------------------------------------------- inside a robot

-- the pixel (x, y) of a finished picture, as r, g, b
local function pixel (job, x, y)
	local c = job.pixels[y * job.W + x + 1]
	return math.floor(c / 65536) % 256, math.floor(c / 256) % 256, c % 256
end

test("the viewscreen draws what the robot sees, with the nodes' own colours", function (done)
	clear_area()
	for _, obj in ipairs(core.get_objects_inside_radius(P(0, 1, 5), 30)) do
		if not obj:is_player() and not cogwork.is_visual(obj) then obj:remove() end
	end
	-- a wall of a block with a known colour 6 blocks ahead of a robot facing +z
	for x = -8, 8 do for y = -2, 2 do core.set_node(P(x, y, 7), { name = material }) end end
	local want = cogwork.view_node_color(material, "side")
	local job = cogwork.view_job(P(0, 1, 0), { x = 0, y = 0, z = 1 })
	local t0 = os.clock()
	while not cogwork.view_step(job, 10) do end
	local ms = (os.clock() - t0) * 1000

	local cr, cg, cb = pixel(job, job.W / 2, job.H / 2)             -- straight ahead: the wall
	local sr, sg, sb = pixel(job, job.W / 2, 1)                      -- up in the picture: the sky above it
	local looks_like_wall = want and math.abs(cr - want[1] * 0.9) < want[1] * 0.35 + 25
	local sky_is_blue = sb > sr and sb > 180
	report("the viewscreen draws what the robot sees, with the nodes' own colours",
		want ~= nil and looks_like_wall and sky_is_blue and ms < 4000 and #job.pixels == job.W * job.H,
		("wall %d,%d,%d want ~%s sky %d,%d,%d %.0f ms"):format(cr, cg, cb, want and ("%d,%d,%d"):format(want[1], want[2], want[3]) or "?", sr, sg, sb, ms))
	done()
end)

test("the viewscreen sees far, and unloaded terrain is haze, not an error", function (done)
	clear_area()
	-- a column 29 blocks ahead (3 wide: a pixel is about half a block there) is seen as a column
	for x = -1, 1 do for y = -3, 6 do core.set_node(P(x, y, 29), { name = material }) end end
	local job = cogwork.view_job(P(0, 1, 0), { x = 0, y = 0, z = 1 })
	while not cogwork.view_step(job, 10) do end
	-- the far column is within the loaded area: not the sky colour
	local r, g, b = pixel(job, job.W / 2, job.H / 2)
	-- look into terrain beyond what is loaded: no error, a picture
	local far = cogwork.view_job(P(0, 1, 0), { x = 1, y = 0, z = 0 })
	far.ox = far.ox + 200
	while not cogwork.view_step(far, 10) do end
	report("the viewscreen sees far, and unloaded terrain is haze, not an error",
		#job.pixels == job.W * job.H and #far.pixels == far.W * far.H and not (b > r + 40),
		("%d,%d,%d"):format(r, g, b))
	done()
end)

test("a room is out of the way of the room container mods and nobody builds in it", function (done)
	local o = cogwork.room_origin(1)
	local inside = { x = o.x + 5, y = o.y + 3, z = o.z + 5 }
	local between = { x = o.x + 20, y = o.y + 3, z = o.z + 5 }       -- the gap between two rooms
	local clear_of_sbz = not (o.y + 10 >= -28000 - 64 and o.y <= -15000 + 64)
	local level = 16 * (tonumber(core.settings:get("area_containers_y_level_blocks")) or 1931)
	local clear_of_area = not (o.y <= level + 16 and o.y + 10 >= level)
	report("a room is out of the way of the room container mods and nobody builds in it",
		cogwork.room_at(inside) == 1 and cogwork.room_at(between) == nil
		-- the harness replaces core.is_protected on Mineclonia (see the top), which drops our hook
		and (core.get_modpath("mcl_levelgen") or core.is_protected(inside, "tester"))
		and clear_of_sbz and clear_of_area and cogwork.room_origin(2).x ~= o.x,
		("y=%d"):format(o.y))
	done()
end)

test("the first room slot that clashes with Skyblock: Zero's rooms is skipped", function (done)
	local blocked = cogwork.room_next()
	local o = cogwork.room_origin(blocked)
	local old = rawget(_G, "sbz_room_containers")
	local store = AreaStore()
	store:insert_area(o, vector.add(o, 15), "someone's room")
	rawset(_G, "sbz_room_containers", { room_areastore = store })

	clear_area()
	core.set_node(P(0, 0, 0), { name = material })
	local pos = make_robot(P(0, 1, 0), "stop", nil, {})
	local fake = { get_player_name = function () return "tester" end, is_player = function () return true end,
		get_meta = function () return { get_string = function () return "" end, set_string = function () end } end }
	cogwork.room_enter(pos, fake)
	local id = core.get_meta(pos):get_int("room_id")
	rawset(_G, "sbz_room_containers", old)
	report("the first room slot that clashes with Skyblock: Zero's rooms is skipped",
		id > blocked, ("blocked %d got %d"):format(blocked, id))
	done()
end)

test("a room is built with a door, a chest, a bay, a terminal, a controller and a screen", function (done)
	clear_area()
	core.set_node(P(0, 0, 0), { name = material })
	local pos = make_robot(P(0, 1, 0), "stop", nil, {})
	local fake = { get_player_name = function () return "tester" end, is_player = function () return true end,
		get_meta = function () return { get_string = function () return "" end, set_string = function () end } end }
	cogwork.room_enter(pos, fake)
	local id = core.get_meta(pos):get_int("room_id")
	cogwork.room_prepare(id, function ()
		local o = cogwork.room_origin(id)
		local function at (x, y, z) return core.get_node({ x = o.x + x, y = o.y + y, z = o.z + z }).name end
		local ok = at(0, 5, 5) == "cogwork:room_wall" and at(7, 0, 7) == "cogwork:room_floor"
			and at(7, 1, 0) == "cogwork:room_exit" and at(2, 1, 7) == "cogwork:room_chest"
			and at(2, 1, 9) == "cogwork:room_bay" and at(13, 1, 7) == "cogwork:room_terminal"
			and at(7, 1, 11) == "cogwork:room_controller" and at(7, 5, 15) == "cogwork:room_screen"
			and at(3, 5, 15) == "cogwork:room_frame" and at(4, 9, 4) == "cogwork:room_light"
			and at(7, 2, 2) == "air" and at(7, 1, 2) == "air"
		report("a room is built with a door, a chest, a bay, a terminal, a controller and a screen",
			ok, ("%s %s %s %s"):format(at(7, 1, 0), at(2, 1, 7), at(7, 5, 15), at(7, 1, 2)))
		done()
	end)
end)

test("the screen of a room shows pictures", function (done)
	clear_area()
	core.set_node(P(0, 0, 0), { name = material })
	local pos = make_robot(P(0, 1, 0), "stop", nil, {})
	local fake = { get_player_name = function () return "tester" end, is_player = function () return true end,
		get_meta = function () return { get_string = function () return "" end, set_string = function () end } end }
	cogwork.room_enter(pos, fake)
	local id = core.get_meta(pos):get_int("room_id")
	cogwork.room_prepare(id, function ()
		-- with a player in the room its block is active; here the test keeps it so
		local origin = cogwork.room_origin(id)
		core.forceload_block(origin, true)
		cogwork.room_guard_off = true
		cogwork.room_open_view(id)
		-- a busy server draws slowly (4 ms of every step): wait for the first picture
		local waited = 0
		local function look ()
			local o = cogwork.room_origin(id)
			local sc = cogwork.ROOM_SCREEN
			local found
			for _, obj in ipairs(core.get_objects_inside_radius({ x = o.x + sc.x, y = o.y + sc.y, z = o.z + sc.z }, 0.6)) do
				local le = obj:get_luaentity()
				if le and le.name == "cogwork:screen" then found = obj end
			end
			local tex = found and found:get_properties().textures[1] or ""
			if (tex:sub(1, 5) == "[png:" and #tex > 200) or waited >= 25 then
				local state = cogwork.view_state(id)
				cogwork.view_unwatch(id)
				cogwork.room_guard_off = nil
				core.forceload_free_block(origin, true)
				report("the screen of a room shows pictures", found ~= nil and tex:sub(1, 5) == "[png:" and #tex > 200,
					found and ("texture " .. #tex .. " chars after " .. waited .. " s, " .. state) or "no screen")
				return done()
			end
			waited = waited + 0.5
			core.after(0.5, look)
		end
		look()
	end)
end)

test("the controller drives the robot, and costs power", function (done)
	clear_area()
	core.set_node(P(0, 0, 0), { name = material })
	core.set_node(P(0, 0, 1), { name = material })
	core.set_node(P(0, 0, 2), { name = material })
	local pos = make_robot(P(0, 1, 0), "wait 100", nil, {})
	-- a real room id: entering allocates it (the fake player never arrives)
	local blank = { get_player_name = function () return "tester" end, is_player = function () return true end,
		get_meta = function () return { get_string = function () return "" end, set_string = function () end } end }
	cogwork.room_enter(pos, blank)
	local id = core.get_meta(pos):get_int("room_id")
	local fake = { get_player_name = function () return "tester" end, is_player = function () return true end,
		get_meta = function () return { get_string = function () return tostring(id) end, set_string = function () end } end }

	local function press (button)
		for _, f in ipairs(core.registered_on_player_receive_fields) do
			pcall(f, fake, "cogwork:room_ctl", { [button] = "x" })
		end
	end
	local start = cell_charge(pos)
	press("ctl_fwd")
	local moved = cogwork.is_robot(name_at(P(0, 1, 1))) and not cogwork.is_robot(name_at(P(0, 1, 0)))
	local paid = math.abs(cell_charge(P(0, 1, 1)) - (start - 1)) < 0.01
	local registry = cogwork.room_robot(id) ~= nil and vector.equals(cogwork.room_robot(id), P(0, 1, 1))

	core.after(0.5, function ()
		local before = core.get_node(P(0, 1, 1)).param2
		press("ctl_left")
		local turned = core.get_node(P(0, 1, 1)).param2 ~= before

		-- while a program runs it will not be driven
		assert(cogwork.start(P(0, 1, 1)))
		core.after(0.5, function ()
			press("ctl_fwd")
			local refused = cogwork.is_robot(name_at(P(0, 1, 1))) and not cogwork.is_robot(name_at(P(0, 1, 2)))
			cogwork.stop(P(0, 1, 1), "")
			report("the controller drives the robot, and costs power", moved and paid and registry and turned and refused,
				("moved=%s paid=%s registry=%s turned=%s refused=%s"):format(tostring(moved), tostring(paid), tostring(registry), tostring(turned), tostring(refused)))
			done()
		end)
	end)
end)

test("the chest, the bay and the terminal open the robot at their own tab", function (done)
	clear_area()
	core.set_node(P(0, 0, 0), { name = material })
	local pos = make_robot(P(0, 1, 0), "stop", nil, {})
	local fake = { get_player_name = function () return "tester" end, is_player = function () return true end,
		get_inventory = function () return nil end, get_player_control = function () return {} end,
		get_meta = function () return { get_string = function () return "" end, set_string = function () end } end }
	cogwork.room_enter(pos, fake)
	local id = core.get_meta(pos):get_int("room_id")
	cogwork.room_prepare(id, function ()
		local o = cogwork.room_origin(id)
		local sess = cogwork.editor_session(fake)
		local result = {}
		for kind, tab in pairs({ chest = "storage", bay = "structure", terminal = "program" }) do
			local p = ({ chest = { 2, 1, 7 }, bay = { 2, 1, 9 }, terminal = { 13, 1, 7 } })[kind]
			local np = { x = o.x + p[1], y = o.y + p[2], z = o.z + p[3] }
			sess.tab, sess.pos = nil, nil
			core.registered_nodes["cogwork:room_" .. kind].on_rightclick(np, core.get_node(np), fake)
			result[#result + 1] = (sess.tab == tab and sess.pos and vector.equals(sess.pos, pos)) and "ok" or (kind .. ":" .. tostring(sess.tab))
		end
		table.sort(result)
		report("the chest, the bay and the terminal open the robot at their own tab",
			#result == 3 and result[1] == "ok" and result[2] == "ok" and result[3] == "ok", table.concat(result, " "))
		done()
	end)
end)

test("a robot keeps its room when dug and placed again, and digging it ejects nobody into the void", function (done)
	clear_area()
	local node = core.registered_nodes["cogwork:robot"]
	local pos = P(0, 1, 0)
	core.set_node(pos, { name = "cogwork:robot" })
	core.get_meta(pos):set_int("room_id", 7)
	local drop = ItemStack("cogwork:robot")
	node.preserve_metadata(pos, { name = "cogwork:robot" }, { fields = { room_id = "7", no_emc = "true" }, inventory = {} }, { drop })
	local carried = drop:get_meta():get_int("room_id") == 7

	local pos2 = P(4, 1, 0)
	core.set_node(pos2, { name = "cogwork:robot" })
	node.after_place_node(pos2, nil, drop)
	local again = core.get_meta(pos2):get_int("room_id") == 7 and cogwork.room_robot_at ~= nil
	-- no one inside: digging does nothing odd
	local ok = pcall(cogwork.room_robot_gone, pos2)
	report("a robot keeps its room when dug and placed again, and digging it ejects nobody into the void",
		carried and again and ok)
	done()
end)

-- armor numbers: the lightest 24, 7 more every tier
test("armor takes 24, 31 and 38", function (done)
	local function max_of (name) return select(2, cogwork.armor_info(ItemStack(name))) end
	report("armor takes 24, 31 and 38",
		max_of("cogwork:armor_basic") == 24 and max_of("cogwork:armor_reinforced") == 31 and max_of("cogwork:armor_heavy") == 38)
	done()
end)

-- a robot item that was never placed comes with armor and a cell, then is no_emc for good
test("a new robot comes with armor and a cell, and is marked no_emc", function (done)
	clear_area()
	local node = core.registered_nodes["cogwork:robot"]
	local pos = P(0, 1, 0)
	core.set_node(pos, { name = "cogwork:robot" })
	node.after_place_node(pos, nil, ItemStack("cogwork:robot"))
	local fresh = cogwork.has_armor(pos) and #cogwork.cells_of(pos) == 1 and core.get_meta(pos):get_string("no_emc") == "true"

	-- dug: the item carries no_emc
	local drop = ItemStack("cogwork:robot")
	node.preserve_metadata(pos, { name = "cogwork:robot" }, { fields = { no_emc = "true" }, inventory = {} }, { drop })
	local marked = drop:get_meta():get_string("no_emc") == "true"

	-- placed again: what it carried is back, and nothing new is given (one armor, one cell)
	local pos2 = P(3, 1, 0)
	core.set_node(pos2, { name = "cogwork:robot" })
	node.on_construct(pos2)
	node.after_place_node(pos2, nil, drop)
	local again = cogwork.has_armor(pos2) and #cogwork.cells_of(pos2) == 1 and core.get_meta(pos2):get_string("no_emc") == "true"
	report("a new robot comes with armor and a cell, and is marked no_emc", fresh and marked and again,
		tostring(fresh) .. " " .. tostring(marked) .. " " .. tostring(again))
	done()
end)

-- no slot is drawn over another one on any tab, no text runs into a slot
test("no inventory slot or text overlaps another on any tab", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "stop", nil, nil)
	local fake = { get_player_name = function () return "tester" end,
		get_inventory = function () return nil end, is_player = function () return true end }
	local problems = {}
	for _, tab in ipairs({ "storage", "structure", "packages", "settings", "program" }) do
		local sess = { tab = tab, line = 1, tok = 0, scroll = 0, cat = "check", msg = "", player = fake, pos = pos }
		local fs = cogwork.formspec(pos, sess)
		local lists, labels = {}, {}
		for x, y, w, h in fs:gmatch("list%[[^;]*;[^;]*;([%d%.%-]+),([%d%.%-]+);([%d%.]+),([%d%.]+);") do
			x, y, w, h = tonumber(x), tonumber(y), tonumber(w), tonumber(h)
			lists[#lists + 1] = { x = x, y = y, x2 = x + w * 1.25 - 0.25, y2 = y + h * 1.25 - 0.25 }
		end
		for x, y, text in fs:gmatch("label%[([%d%.%-]+),([%d%.%-]+);([^%]]*)%]") do
			-- the client strips translation markers, they take no room
			text = text:gsub("\27%b()", ""):gsub("\27[FE]", "")
			local longest, n = 0, 0
			for line in (text .. "\n"):gmatch("([^\n]*)\n") do longest = math.max(longest, #line) n = n + 1 end
			x, y = tonumber(x), tonumber(y)
			-- about 0.17 per character; a label is drawn centred on its y, a line is 0.3 high
			labels[#labels + 1] = { x = x, y = y - 0.15, x2 = x + longest * 0.17, y2 = y + 0.15 + 0.3 * (n - 1), text = text }
		end
		-- touching is fine, over each other (by more than a hair) is not
		local function overlap (a, b)
			local e = 0.08
			return a.x + e < b.x2 and b.x + e < a.x2 and a.y + e < b.y2 and b.y + e < a.y2
		end
		for i = 1, #lists do
			for j = i + 1, #lists do
				if overlap(lists[i], lists[j]) then problems[#problems + 1] = tab .. ": slots " .. i .. " and " .. j end
			end
			for _, lab in ipairs(labels) do
				if overlap(lists[i], lab) then problems[#problems + 1] = tab .. ": text '" .. lab.text:sub(1, 24) .. "' over slots " .. i end
			end
		end
		if #lists == 0 and tab ~= "program" and tab ~= "settings" then problems[#problems + 1] = tab .. ": no slots found" end
	end
	report("no inventory slot or text overlaps another on any tab", #problems == 0, table.concat(problems, "; "))
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
		assert(not timeout and cogwork.is_robot(core.get_node(P(0, 2, 0)).name), "handler did not run")
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
		local info = cogwork.machine_info(P(0, 1, 1))
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

	local box = cogwork.machine_info(P(0, 1, 1))
	local machine = cogwork.machine_info(P(0, 1, 3))
	local ta = cogwork.machine_info(P(0, 1, 2))
	local switched = cogwork.machine_switch(P(0, 1, 3), false)
	local ta_on = cogwork.machine_switch(P(0, 1, 2), true)
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
	for _, tab in ipairs({ "program", "text", "storage", "structure", "packages", "settings", "help" }) do
		s.tab = tab
		local good, res = pcall(cogwork.formspec, pos, s)
		if not good or type(res) ~= "string" or #res < 50 then ok, err = false, tab .. ": " .. tostring(res) end
	end
	for _, cat in ipairs({ "flow", "move", "world", "inventory", "var", "check", "fn" }) do
		s.tab, s.cat = "program", cat
		local good, res = pcall(cogwork.formspec, pos, s)
		if not good then ok, err = false, cat .. ": " .. tostring(res) end
	end
	report("editor formspec", ok, err)
	done()
end)

test("robot can be dug by hand", function (done)
	for _, name in ipairs(cogwork.ROBOT_NODES) do
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
		cogwork.on_editor_fields(fake, "cogwork:ed", fields)
	end
	local function lines () return core.get_meta(pos):get_string("program") end
	local s = cogwork.editor_session(fake)
	s.pos, s.player, s.tab = pos, fake, "program"

	s.line, s.tok = 1, 2
	send({ val = "hello big world", val_set = "Set" })
	report("note keeps all words", lines():find("^# hello big world\n"), lines())

	s.line, s.tok = 2, 2
	send({ val = "hello world", val_text = "As text" })
	report("as text quotes it", lines():find('chat "hello world"', 1, true), lines())

	local ok, msg, line = cogwork.check_program(pos, "move up\nmove sideways")
	report("check finds bad direction", ok == false and line == 2, tostring(msg))
	ok, msg = cogwork.check_program(pos, "place front nomod:nothing")
	report("check finds unknown item", ok == true and msg:find("unknown item"), tostring(msg))
	ok, msg, line = cogwork.check_program(pos, "move up")
	report("check passes", ok and line == nil, tostring(msg))

	core.get_meta(pos):set_string("program", "move up\nmove up")
	s.tab = "program"
	send({ quit = "true", op_runclose = "Run and close" })
	report("run and close starts", cogwork.is_running(pos))
	report("run and close forgets the form", s.pos == nil)
	cogwork.stop(pos, "")
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
	local s = cogwork.editor_session(fake)
	s.pos = nil
	local def = core.registered_nodes["cogwork:robot"]
	cogwork.acting = true
	def.on_rightclick(pos, core.get_node(pos), fake, ItemStack(""), { type = "node", under = pos, above = pos })
	cogwork.acting = false
	report("rightclick ignored while acting", s.pos == nil)
	done()
end)

test("packages compile", function (done)
	local ok = true
	for _, name in ipairs(cogwork.list_packages()) do
		local good, err = cogwork.check_package(name)
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
	local lib = cogwork.extract_functions("move up\nfn go n\n  repeat n\n    move forward\nuse movement\ncall go 2")
	local ok, err = cogwork.validate_library(lib or "")
	report("extract functions", lib ~= nil and ok, err or lib)
	local bad = cogwork.validate_library("move up")
	report("library rejects statements", bad == nil)
	done()
end)

test("a robot above the floor uses power for hovering and flying", function (done)
	clear_area()
	local old_hover, old_flight = cogwork.settings.hover_drain, cogwork.settings.flight_drain
	cogwork.settings.hover_drain, cogwork.settings.flight_drain = 0.3, 1
	core.set_node(P(0, 0, 0), { name = material })
	local grounded = make_robot(P(0, 1, 0), "stop", nil, { "cogwork:upgrade_flight" })
	local high = make_robot(P(3, 5, 0), "stop", nil, { "cogwork:upgrade_hover", "cogwork:upgrade_hover" })
	local flying = make_robot(P(6, 5, 0), "stop", nil, { "cogwork:upgrade_flight" })
	local bare = make_robot(P(9, 5, 0), "stop", nil, {})
	local ok = cogwork.lift_drain(grounded) == 0 and math.abs(cogwork.lift_drain(high) - 0.6) < 1e-6
		and cogwork.lift_drain(flying) == 1 and cogwork.lift_drain(bare) == 0
	cogwork.settings.hover_drain, cogwork.settings.flight_drain = old_hover, old_flight
	report("a robot above the floor uses power for hovering and flying", ok)
	done()
end)

test("a robot draws power from the chosen cell first", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "stop", nil, {})
	local inv = inv_of(pos)
	local a = ItemStack("cogwork:cell_small"); cogwork.set_cell_charge(a, 100); inv:set_stack("cells", 1, a)
	local b = ItemStack("cogwork:cell_small"); cogwork.set_cell_charge(b, 100); inv:set_stack("cells", 2, b)
	cogwork.spend(pos, 10)
	local first = cell_charge(pos, 1) == 90 and cell_charge(pos, 2) == 100
	core.get_meta(pos):set_int("cell_active", 2)
	cogwork.spend(pos, 10)
	local second = cell_charge(pos, 1) == 90 and cell_charge(pos, 2) == 90
	report("a robot draws power from the chosen cell first", first and second,
		("%s %s"):format(cell_charge(pos, 1), cell_charge(pos, 2)))
	done()
end)

test("a player can keep only a limited number of robots forceloading", function (done)
	clear_area()
	local first = make_robot(P(0, 1, 0), "stop", nil, {})
	local second = make_robot(P(3, 1, 0), "stop", nil, {})
	local other = make_robot(P(6, 1, 0), "stop", nil, {})
	core.get_meta(first):set_string("owner", "tester_a")
	core.get_meta(second):set_string("owner", "tester_a")
	core.get_meta(other):set_string("owner", "tester_b")
	local old = cogwork.settings.max_persist
	cogwork.settings.max_persist = 1
	local ok1 = cogwork.set_persist(first, true)
	local ok2, why = cogwork.set_persist(second, true)
	local ok3 = cogwork.set_persist(other, true)             -- somebody else's robot
	cogwork.set_persist(first, false)
	local ok4 = cogwork.set_persist(second, true)            -- a place is free again
	core.remove_node(second)                                  -- dug: the place is free
	core.get_meta(first):set_string("owner", "tester_a")
	local ok5 = cogwork.set_persist(first, true)
	cogwork.set_persist(first, false)
	cogwork.set_persist(other, false)
	cogwork.settings.max_persist = old
	report("a player can keep only a limited number of robots forceloading",
		ok1 and not ok2 and why and ok3 and ok4 and ok5,
		("%s %s %s %s %s"):format(tostring(ok1), tostring(ok2), tostring(ok3), tostring(ok4), tostring(ok5)))
	done()
end)

test("forceloading stops when the owner has been offline for a while", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "stop", nil, {})
	core.get_meta(pos):set_string("owner", "ghost_owner")
	local old_offline, old_max = cogwork.settings.persist_offline, cogwork.settings.max_persist
	cogwork.settings.persist_offline, cogwork.settings.max_persist = 1, 5
	local on = cogwork.set_persist(pos, true) and cogwork.persist_active(pos)
	core.after(12, function ()
		local suspended = core.get_meta(pos):get_int("persist") == 1 and not cogwork.persist_active(pos)
		cogwork.set_persist(pos, false)
		cogwork.settings.persist_offline, cogwork.settings.max_persist = old_offline, old_max
		report("forceloading stops when the owner has been offline for a while", on and suspended,
			("on=%s suspended=%s"):format(tostring(on), tostring(suspended)))
		done()
	end)
end)

test("punching the robot's entity with a bare hand picks it up after a while", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "stop", nil, {})
	core.get_meta(pos):set_string("owner", "tester")
	local fake = { get_player_name = function () return "tester" end, is_player = function () return true end,
		get_wielded_item = function () return ItemStack("") end, set_wielded_item = function () end,
		get_player_control = function () return {} end }
	local dug
	local real = core.node_dig
	core.node_dig = function (p) dug = p end
	for _ = 1, 12 do cogwork.robot_punch(pos, fake, true, 0.2) end
	core.node_dig = real
	report("punching the robot's entity with a bare hand picks it up after a while", dug ~= nil and vector.equals(dug, pos),
		tostring(dug and core.pos_to_string(dug)))
	done()
end)

-- ---------------------------------------------------------------- waypoints and examples

local function example_source (name)
	for _, example in ipairs(cogwork.list_examples()) do
		if example.name == name then return example.source end
	end
	error("no example " .. name)
end

local FACING_NORTH = core.dir_to_facedir({ x = 0, y = 0, z = -1 })      -- the robots of these tests face +z

run_program("waypoints: save, walk away, turn, and walk back facing the same way",
	"use waypoint\ncall waypoint.save \"a\"\nrepeat 3\n  move forward\nturn right\nset r = call waypoint.go_face \"a\"\nif r = 0\n  move up",
	nil, nil, function (_, timeout)
		assert(not timeout, "timeout")
		local p = find_robot()
		assert(vector.equals(p, P(0, 2, 0)), "ended at " .. core.pos_to_string(vector.subtract(p, ORIGIN)) .. " " .. err_of(p))
		assert(core.get_node(p).param2 == FACING_NORTH, "does not face the saved way")
	end)

test("waypoints are kept in the robot, with names checked", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "stop", nil, {})
	local ok1 = cogwork.waypoint_here(pos, "base")
	local ok2 = cogwork.waypoint_here(pos, "bad,name")
	local ok3 = cogwork.waypoint_here(pos, "")
	local names = cogwork.waypoint_names(pos)
	local wp = cogwork.waypoints_of(pos).base
	local removed = cogwork.waypoint_remove(pos, "base")
	report("waypoints are kept in the robot, with names checked",
		ok1 and not ok2 and not ok3 and #names == 1 and wp.facing == "north" and wp.y == pos.y and removed
		and #cogwork.waypoint_names(pos) == 0)
	done()
end)

test("the examples and the waypoint package compile", function (done)
	local bad = {}
	local list = cogwork.list_examples()
	for _, example in ipairs(list) do
		local ok, err = cogwork.check_example(example)
		if not ok then bad[#bad + 1] = example.name .. ": " .. tostring(err) end
	end
	local pkg_ok, pkg_err = cogwork.check_package("waypoint")
	if not pkg_ok then bad[#bad + 1] = "waypoint: " .. tostring(pkg_err) end
	report("the examples and the waypoint package compile", #bad == 0 and #list >= 5, table.concat(bad, "; "))
	done()
end)

run_program("the miner example comes home when it has dug as far as it was told",
	(example_source("3_miner_home"):gsub("set longest = 200", "set longest = 5")),
	nil, nil, function (_, timeout)
		assert(not timeout, "timeout")
		local p = find_robot()
		assert(vector.equals(p, P(0, 1, 0)), "ended at " .. core.pos_to_string(vector.subtract(p, ORIGIN)) .. " " .. err_of(p))
		assert(core.get_node(p).param2 == FACING_NORTH, "does not face the way it started")
	end)

run_program("the recharging worker example goes to the charger and comes back to carry on",
	(example_source("4_worker_recharge"):gsub("set goal = 120", "set goal = 5"):gsub("set low_power = 25", "set low_power = 101")
		:gsub("set full_power = 95", "set full_power = 0")),
	nil, nil, function (_, timeout)
		assert(not timeout, "timeout")
		local p = find_robot()
		assert(vector.equals(p, P(0, 1, 0)), "ended at " .. core.pos_to_string(vector.subtract(p, ORIGIN)) .. " " .. err_of(p))
	end)

run_program("the strings package: part, find, case, trim, replace, split and the rest",
	"use strings\n"
	.. "set n = 0\n"
	.. "if (call strings.upper \"abc\") = \"ABC\"\n  move up\n"
	.. "if (call strings.lower \"AbC\") = \"abc\"\n  move up\n"
	.. "if (call strings.title \"hello big WORLD\") = \"Hello Big World\"\n  move up\n"
	.. "if (call strings.trim \"  hi there \") = \"hi there\"\n  move up\n"
	.. "if (call strings.part \"hello\" 2 4) = \"ell\"\n  move up\n"
	.. "if (call strings.find \"hello\" \"ll\") = 3\n  move up\n"
	.. "if (call strings.parts \"a,b,c\" \",\") = 3\n  move up\n"
	.. "if (call strings.split \"a,bb,c\" \",\" 2) = \"bb\"\n  move up\n"
	.. "if (call strings.split \"a,bb,c\" \",\" 4) = \"\"\n  move up\n"
	.. "if (call strings.has_part \"x,y,z\" \",\" \"y\")\n  move up\n"
	.. "if (call strings.replace \"a-b-c\" \"-\" \"+\") = \"a+b+c\"\n  move up\n"
	.. "if (call strings.starts_with \"hello\" \"he\")\n  move up\n"
	.. "if (call strings.ends_with \"hello\" \"llo\")\n  move up\n"
	.. "if (call strings.reverse \"abc\") = \"cba\"\n  move up\n"
	.. "if (call strings.times \"ab\" 3) = \"ababab\"\n  move up",
	nil, nil, function (_, timeout)
		assert(not timeout, "timeout")
		local p = find_robot()
		-- one block up for each of the 15 checks that held
		assert(p.y - (ORIGIN.y + 1) == 15, "checks that held: " .. (p.y - (ORIGIN.y + 1)) .. " " .. err_of(p))
	end)

test("the Combat Upgrade count can be asked", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "stop", nil, { "cogwork:upgrade_combat", "cogwork:upgrade_combat", "cogwork:upgrade_hover" })
	report("the Combat Upgrade count can be asked",
		cogwork.upgrade_count(pos, "combat") == 2 and cogwork.upgrade_count(pos, "hover") == 1
		and cogwork.upgrade_count(pos, "flight") == 0 and cogwork.upgrade_count(pos, "nonsense") == 0)
	done()
end)

test("the combat guard example hunts a mob and fights it with a sword", function (done)
	clear_area()
	for _, obj in ipairs(core.get_objects_inside_radius(P(0, 1, 3), 30)) do
		if not obj:is_player() and not cogwork.is_visual(obj) then obj:remove() end
	end
	local source = example_source("6_combat_guard")
		:gsub('set route = "[^"]*"', 'set route = "post"')
		:gsub('set monsters = "[^"]*"', 'set monsters = "cogwork_test:mob"')
		:gsub('set weapon = "group:sword"', 'set weapon = "cogwork_test:sword"')
		:gsub('set armory = "armory"', 'set armory = ""')
	local pos = make_robot(P(0, 1, 0), source, { "cogwork_test:sword" })
	cogwork.waypoint_here(pos, "post")
	cogwork.waypoint_here(pos, "charger")
	local mob = core.add_entity(P(0, 1, 5), "cogwork_test:mob")
	assert(cogwork.start(pos))
	core.after(25, function ()
		local dead = not mob:is_valid() or mob:get_hp() <= 0
		local robot = find_robot()
		local err = robot and err_of(robot) or "no robot"
		if mob:is_valid() then mob:remove() end
		if robot then cogwork.stop(robot, "") end
		report("the combat guard example hunts a mob and fights it with a sword", dead and err == "", ("dead=%s err=%s"):format(tostring(dead), err))
		done()
	end)
end)

test("the Waypoints and Examples tabs are drawn", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "stop", nil, {})
	cogwork.waypoint_here(pos, "base")
	local fake = { get_player_name = function () return "tester" end, is_player = function () return true end }
	local fs1 = cogwork.formspec(pos, { tab = "waypoints", line = 1, tok = 0, scroll = 0, cat = "flow", msg = "", player = fake, pos = pos })
	local fs2 = cogwork.formspec(pos, { tab = "examples", line = 1, tok = 0, scroll = 0, cat = "flow", msg = "", player = fake, pos = pos, ex_sel = 2 })
	report("the Waypoints and Examples tabs are drawn",
		fs1:find("base", 1, true) and fs1:find("wp_save", 1, true) and fs2:find("ex_replace", 1, true)
		and fs2:find("Crafter bot", 1, true))
	done()
end)


-- ---------------------------------------------------------------- controls

test("the line under the viewscreen gives the position and the looking direction", function (done)
	local function has (front, text) return cogwork.direction_text(front):find(text, 1, true) ~= nil end
	local ok = has({ x = 0, y = 0, z = 1 }, "N (+Z)") and has({ x = 1, y = 0, z = 0 }, "E (+X)")
		and has({ x = 0, y = 0, z = -1 }, "S (-Z)") and has({ x = -1, y = 0, z = 0 }, "W (-X)")
		and has({ x = 0.7, y = 0, z = 0.7 }, "NE") and has({ x = 0, y = 0.5, z = 0.87 }, "up 30")
	local text = cogwork.view_info_text({ x = 3, y = 40, z = -5 }, { x = 0, y = 0, z = 1 })
	local screen = { x = 0, y = 41, z = 0 }
	cogwork.view_info(screen, text)
	local shown
	for _, obj in ipairs(core.get_objects_inside_radius({ x = 0, y = 41 - 4.05, z = -0.06 }, 0.5)) do
		local le = obj:get_luaentity()
		if le and le.name == "cogwork:screen_text" then shown = obj:get_properties().nametag end
	end
	report("the line under the viewscreen gives the position and the looking direction",
		ok and shown == text and text:find("3, 40, -5", 1, true), tostring(shown))
	done()
end)


test("a robot takes its inventory along in its item and puts it back when placed", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "stop", nil, { "cogwork:upgrade_storage", "cogwork:upgrade_hover" })
	local meta = core.get_meta(pos)
	meta:set_string("no_emc", "true")
	local inv = inv_of(pos)
	local cell = ItemStack("cogwork:cell_small"); cogwork.set_cell_charge(cell, 123); inv:set_stack("cells", 1, cell)
	inv:set_stack("armor_mod", 1, ItemStack("cogwork:armor_mod_repair"))
	inv:set_stack("main", 20, ItemStack(material .. " 7"))
	local armor_before = inv:get_stack("armor", 1):to_string()
	local def = core.registered_nodes[core.get_node(pos).name]
	local drops = { ItemStack("cogwork:robot") }
	def.preserve_metadata(pos, core.get_node(pos), meta:to_table(), drops)
	local carried = drops[1]:get_meta():get_string("inventory") ~= ""

	local placed = P(5, 1, 0)
	core.set_node(placed, { name = "cogwork:robot" })
	def.on_construct(placed)
	def.after_place_node(placed, nil, drops[1])
	local back = inv_of(placed)
	local ok = cogwork.cell_info(back:get_stack("cells", 1)) == 123
		and back:get_stack("armor_mod", 1):get_name() == "cogwork:armor_mod_repair"
		and back:get_stack("main", 20):get_count() == 7
		and back:get_stack("upgrades", 1):get_name() == "cogwork:upgrade_storage"
		and back:get_size("main") == 20
		and back:get_stack("armor", 1):to_string() == armor_before      -- no new starter armor
		and back:get_stack("cells", 2):is_empty()
	report("a robot takes its inventory along in its item and puts it back when placed", carried and ok,
		("carried=%s cell=%s size=%d armor=%s"):format(tostring(carried), tostring(cogwork.cell_info(back:get_stack("cells", 1))), back:get_size("main"), back:get_stack("armor", 1):get_name()))
	done()
end)


test("a player inside a room sees the robot's slots through a copy of its inventory", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "stop", nil, {})
	inv_of(pos):set_stack("main", 1, ItemStack(material .. " 5"))
	local fake = { get_player_name = function () return "tester" end, is_player = function () return true end,
		get_meta = function () return { get_string = function () return "" end, set_string = function () end } end }
	local outside = cogwork.inventory_location(pos, fake)
	cogwork.room_enter(pos, fake)
	-- the room-of-player check reads the player's meta: stand in for a player inside
	fake.get_meta = function () return { get_string = function () return tostring(core.get_meta(pos):get_int("room_id")) end, set_string = function () end } end
	local inside = cogwork.inventory_location(pos, fake)
	local det = core.get_inventory({ type = "detached", name = "cogwork_ed_tester" })
	local copy_ok = det and det:get_stack("main", 1):get_name() == material and det:get_size("upgrades") == cogwork.UPGRADE_SLOTS
	inv_of(pos):set_stack("main", 2, ItemStack(material))
	local changed = cogwork.proxy_changed(fake)
	local same = det:get_stack("main", 2):get_name() == material
	report("a player inside a room sees the robot's slots through a copy of its inventory",
		outside:find("^nodemeta:") and inside == "detached:cogwork_ed_tester" and copy_ok and changed and same,
		("%s %s %s %s %s"):format(outside, inside, tostring(copy_ok), tostring(changed), tostring(same)))
	done()
end)


test("the Settings tab picks the robot up", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "stop", nil, {})
	core.get_meta(pos):set_string("owner", "tester")
	local fake = { get_player_name = function () return "tester" end, is_player = function () return true end }
	local real = core.node_dig
	local dug
	core.node_dig = function (p) dug = p return true end
	local ok = cogwork.pick_up(pos, fake)
	core.node_dig = real
	report("the Settings tab picks the robot up", ok and dug ~= nil and vector.equals(dug, pos))
	done()
end)


-- a player that is in a room, as far as the controls care
local function control_player (pos)
	local fake = { get_player_name = function () return "tester" end, is_player = function () return true end,
		get_meta = function () return { get_string = function () return "" end, set_string = function () end } end,
		hud_add = function () return 1 end, hud_change = function () end, hud_remove = function () end,
		set_physics_override = function () end, get_physics_override = function () return { speed = 1, jump = 1 } end,
		get_pos = function () return { x = 0, y = 0, z = 0 } end, set_pos = function () end,
		get_velocity = function () return { x = 0, y = 0, z = 0 } end, add_velocity = function () end }
	cogwork.room_enter(pos, fake)
	return fake, core.get_meta(pos):get_int("room_id")
end

test("the camera controller turns and tilts the camera with the keys", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "stop", nil, {})
	local fake, id = control_player(pos)
	local st = { kind = "camera", id = id, hold = 0, hud_time = 0, saved = {} }
	cogwork.control_step(fake, st, { right = true, up = true }, 0.5)
	local yaw, pitch = cogwork.camera_get(pos)
	local moved = math.abs(yaw - 35) < 0.1 and math.abs(pitch - 35) < 0.1
	cogwork.control_step(fake, st, { jump = true }, 0.1)
	local yaw2, pitch2 = cogwork.camera_get(pos)
	report("the camera controller turns and tilts the camera with the keys", moved and yaw2 == 0 and pitch2 == 0,
		("%s %s then %s %s"):format(yaw, pitch, yaw2, pitch2))
	done()
end)

test("holding Space and Shift stops controlling", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "stop", nil, {})
	local fake, id = control_player(pos)
	local st = { kind = "camera", id = id, hold = 0, hud_time = 0, saved = { speed = 1, jump = 1 } }
	cogwork.control_step(fake, st, { jump = true, sneak = true }, 0.3)
	local early = st.stopped
	cogwork.control_step(fake, st, { jump = true, sneak = true }, 0.4)
	report("holding Space and Shift stops controlling", not early and st.stopped == true)
	done()
end)

test("the keys drive the robot", function (done)
	clear_area()
	local pos = make_robot(P(0, 1, 0), "stop")
	local fake, id = control_player(pos)
	local st = { kind = "drive", id = id, hold = 0, hud_time = 0, saved = {} }
	cogwork.control_step(fake, st, { up = true }, 0.05)
	local forward = vector.equals(cogwork.room_robot(id), P(0, 1, 1))
	core.after(1, function ()
		cogwork.control_step(fake, st, { jump = true }, 0.05)
		local up = vector.equals(cogwork.room_robot(id), P(0, 2, 1))
		report("the keys drive the robot", forward and up, ("forward=%s up=%s at %s"):format(tostring(forward), tostring(up), core.pos_to_string(cogwork.room_robot(id) or P(0, 0, 0))))
		done()
	end)
end)

test("fly mode holds the robot up only while it is controlled", function (done)
	clear_area()
	core.set_node(P(0, 0, 0), { name = "air" })
	local pos = make_robot(P(0, 5, 0), "stop", nil, {})
	local meta = core.get_meta(pos)
	local _, id = control_player(pos)
	local off = not cogwork.fly_held(pos)
	meta:set_int("control_fly", 1)
	local idle = not cogwork.fly_held(pos)
	cogwork.mark_controlled(id)
	local held = cogwork.fly_held(pos)
	meta:set_int("control_fly", 0)
	local without = not cogwork.fly_held(pos)
	report("fly mode holds the robot up only while it is controlled", off and idle and held and without,
		("off=%s idle=%s held=%s without=%s"):format(tostring(off), tostring(idle), tostring(held), tostring(without)))
	done()
end)

test("the camera looks up: a ceiling shows when it is tilted and not when it is level", function (done)
	clear_area()
	for _, obj in ipairs(core.get_objects_inside_radius(P(0, 1, 5), 30)) do
		if not obj:is_player() and not cogwork.is_visual(obj) then obj:remove() end
	end
	for x = -8, 8 do for z = 0, 14 do core.set_node(P(x, 5, z), { name = material }) end end
	local level = cogwork.view_job(P(0, 1, 0), { x = 0, y = 0, z = 1 })
	while not cogwork.view_step(level, 10) do end
	local rp = make_robot(P(20, 1, 0), "stop", nil, {})
	core.get_meta(rp):set_float("view_pitch", 40)
	local up = cogwork.view_job(P(0, 1, 0), cogwork.camera_direction(rp, { x = 0, y = 0, z = 1 }))
	while not cogwork.view_step(up, 10) do end
	local function centre (job)
		local c = job.pixels[(job.H / 2) * job.W + job.W / 2 + 1]
		return math.floor(c / 65536) % 256, math.floor(c / 256) % 256, c % 256
	end
	local lr, lg, lb = centre(level)
	local ur, ug, ub = centre(up)
	report("the camera looks up: a ceiling shows when it is tilted and not when it is level",
		lb > lr and not (ub > ur + 20), ("level %d,%d,%d up %d,%d,%d"):format(lr, lg, lb, ur, ug, ub))
	done()
end)

-- commands as the owner
local cmd_ran
core.register_chatcommand("cwtest", { privs = {}, func = function (name, param)
	cmd_ran = { name, param }
	return true, "did " .. param
end })
core.register_chatcommand("cwtest_shy", { privs = {}, allow_bot = false, func = function () return true end })
core.register_chatcommand("cwtest_admin", { privs = { cwtest_priv = true }, func = function () return true end })

test("commands as the owner", function (done)
	local auth = core.get_auth_handler()
	if not auth.get_auth("tester") then auth.create_auth("tester", "x") end
	local prog = 'command "cwtest hi"\nif ok\n  move up'

	clear_area()
	local off = make_robot(P(0, 1, 0), prog, nil)
	assert(cogwork.start(off))
	wait_for(off, 20, function ()
		local ran_off = cmd_ran ~= nil
		local stayed = vector.equals(find_robot() or P(9, 9, 9), P(0, 1, 0))

		clear_area()
		local on = make_robot(P(0, 1, 0), prog, nil)
		core.get_meta(on):set_int("owner_cmds", 1)
		assert(cogwork.start(on))
		wait_for(on, 20, function ()
			local went = lifted()
			local ran_on = cmd_ran and cmd_ran[1] == "tester" and cmd_ran[2] == "hi"

			local ok_shy = cogwork.run_as_owner("tester", "/cwtest_shy")
			local ok_priv, why_priv = cogwork.run_as_owner("tester", "cwtest_admin")
			local ok_deny = cogwork.run_as_owner("tester", "grant tester interact")
			local ok_none = cogwork.run_as_owner("tester", "no_such_command_x")
			local ok_cmd, answer = cogwork.run_as_owner("tester", "  /cwtest  a b ")

			local stranger = { get_player_name = function () return "stranger" end }
			local at = find_robot()   -- it flew up
			local meta = core.get_meta(at)
			meta:set_int("public", 1)
			local locked = meta:get_int("owner_cmds") == 1 and not cogwork.can_access(at, stranger)
			meta:set_int("owner_cmds", 0)
			local open = cogwork.can_access(at, stranger)

			report("commands as the owner", not ran_off and stayed and went and ran_on
				and not ok_shy and not ok_priv and why_priv:find("cwtest_priv") and not ok_deny
				and not ok_none and ok_cmd and answer == "did a b" and locked and open,
				("off ran=%s stayed=%s on went=%s ran=%s shy=%s priv=%s deny=%s none=%s cmd=%s %s locked=%s open=%s"):format(
					tostring(ran_off), tostring(stayed), tostring(went), tostring(ran_on), tostring(ok_shy),
					tostring(ok_priv), tostring(ok_deny), tostring(ok_none), tostring(ok_cmd), tostring(answer),
					tostring(locked), tostring(open)))
			done()
		end)
	end)
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
