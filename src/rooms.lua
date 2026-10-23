-- Rooms: the inside of a robot. Sneak + right-click a robot to enter it.
--
-- Every robot that is entered gets a room of its own: a 16 x 10 x 16 chamber in
-- a reserved part of the map, with a viewscreen, a chest, a controller, a bay for
-- upgrades and parts, a terminal for the program, and a door out. The room belongs
-- to the robot (its id is in the robot's meta and in its item when dug), not to a
-- place: the robot moves and the room stays.
--
-- Like area_containers and Skyblock: Zero's room containers, the rooms live far from
-- play, are protected, and hold their players while the robot's block is kept loaded.
-- Those two mods never run together, but Cogwork can run next to either: the rooms
-- are out of the way of both (area_containers sits at the top of the map, Skyblock:
-- Zero's rooms between y -28000 and -15000; these are at the bottom), and every slot
-- is checked against the one that is installed.

local cogwork = ...
local S = cogwork.S
local settings = cogwork.settings
local storage = core.get_mod_storage()

local SIZE = { x = 16, y = 10, z = 16 }
local SPACING = 32
local floor = math.floor

cogwork.ROOM_SIZE = SIZE

--------------------------------------------------------------------------
-- where the rooms are

local base      -- { x, y, z } of room 1, fixed once chosen

local function map_limit ()
	return tonumber(core.get_mapgen_setting("mapgen_limit")) or 31000
end

-- Is a band of y levels used by the room container mod that is installed?
local function band_taken (y)
	if core.get_modpath("area_containers") then
		local level = 16 * (tonumber(core.settings:get("area_containers_y_level_blocks")) or 1931)
		if y <= level + 16 and y + SIZE.y >= level then return true end
	end
	if rawget(_G, "sbz_room_containers") then
		if y + SIZE.y >= -28000 - 64 and y <= -15000 + 64 then return true end
	end
	return false
end

local function choose_base ()
	local saved = storage:get_string("base")
	if saved ~= "" then
		local b = core.deserialize(saved)
		if b then return b end
	end

	local limit = map_limit()
	local y = floor((-limit + 1500) / 16) * 16
	while band_taken(y) and y > -limit + 300 do y = y - 64 end
	local b = { x = floor((-limit + 400) / 16) * 16, y = y, z = floor((-limit + 400) / 16) * 16 }
	storage:set_string("base", core.serialize(b))
	return b
end

local function columns ()
	return math.max(1, math.min(100, floor((2 * map_limit() - 1000) / SPACING)))
end

function cogwork.room_origin (id)
	base = base or choose_base()
	local cols = columns()
	return { x = base.x + ((id - 1) % cols) * SPACING, y = base.y, z = base.z + floor((id - 1) / cols) * SPACING }
end

-- the room a position is inside of (its chamber), or nil
function cogwork.room_at (pos)
	base = base or choose_base()
	if pos.y < base.y or pos.y >= base.y + SIZE.y then return nil end
	local dx, dz = pos.x - base.x, pos.z - base.z
	if dx < 0 or dz < 0 then return nil end
	if dx % SPACING >= SIZE.x or dz % SPACING >= SIZE.z then return nil end
	local col, row = floor(dx / SPACING), floor(dz / SPACING)
	if col >= columns() then return nil end
	return row * columns() + col + 1
end

--------------------------------------------------------------------------
-- the registry: which robot has which room, and where it is now

local reg = { next = 1, rooms = {} }

do
	local saved = storage:get_string("rooms")
	if saved ~= "" then reg = core.deserialize(saved) or reg end
end

local dirty = false
local function save ()
	if dirty then
		storage:set_string("rooms", core.serialize(reg))
		dirty = false
	end
end
core.register_on_shutdown(save)
local save_timer = 0
core.register_globalstep(function (dt)
	save_timer = save_timer + dt
	if save_timer > 15 then
		save_timer = 0
		save()
	end
end)

-- a room that does not clash with anything: skips slots the room containers use
local function slot_free (id)
	local o = cogwork.room_origin(id)
	local max = { x = o.x + SIZE.x, y = o.y + SIZE.y, z = o.z + SIZE.z }
	local sbz = rawget(_G, "sbz_room_containers")
	if sbz and sbz.room_areastore then
		local found = sbz.room_areastore:get_areas_in_area(o, max, true, false, false)
		if found and next(found) then return false end
	end
	return true
end

local function alloc (owner)
	local id = reg.next
	while not slot_free(id) do id = id + 1 end
	reg.next = id + 1
	reg.rooms[id] = { owner = owner }
	dirty = true
	return id
end

function cogwork.room_id (pos)
	return core.get_meta(pos):get_int("room_id")
end

-- the robot of a room: its position, with its block loaded; nil when it is not placed
function cogwork.room_robot (id)
	local r = reg.rooms[id]
	local pos = r and r.robot
	if not pos then return nil end
	core.load_area(pos)
	local node = core.get_node_or_nil(pos)
	if node and cogwork.is_robot(node.name) and cogwork.room_id(pos) == id then return pos end
end

function cogwork.room_owner (id)
	return reg.rooms[id] and reg.rooms[id].owner
end

-- the robot of room id is here now (placed, moved)
function cogwork.room_robot_at (id, pos)
	if id == 0 or not reg.rooms[id] then return end
	reg.rooms[id].robot = { x = pos.x, y = pos.y, z = pos.z }
	dirty = true
end

--------------------------------------------------------------------------
-- building a room

local function node_id (name) return core.get_content_id(name) end

-- local coordinates of what is in the room (x 0..15, y 0..9, z 0..15)
local SCREEN = { x1 = 4, x2 = 11, y1 = 3, y2 = 7 }      -- the screen on the north wall
local SPOTS = {
	exit = { { 7, 1, 0 }, { 8, 1, 0 }, { 7, 2, 0 }, { 8, 2, 0 } },
	chest = { { 2, 1, 7 } },
	bay = { { 2, 1, 9 } },
	terminal = { { 13, 1, 7 } },
	settings = { { 13, 1, 9 } },
	controller = { { 7, 1, 11 } },
	console = { { 6, 1, 11 }, { 8, 1, 11 } },
	light = { { 4, 9, 4 }, { 11, 9, 4 }, { 4, 9, 11 }, { 11, 9, 11 }, { 2, 0, 2 }, { 13, 0, 2 }, { 2, 0, 13 }, { 13, 0, 13 } },
}
cogwork.ROOM_SPAWN = { x = 7.5, y = 1, z = 2.5 }
cogwork.ROOM_SCREEN = { x = 7.5, y = 5, z = 14.46, w = 8, h = 5 }

local function build (id)
	local o = cogwork.room_origin(id)
	local min, max = o, { x = o.x + SIZE.x - 1, y = o.y + SIZE.y - 1, z = o.z + SIZE.z - 1 }
	local vm = core.get_voxel_manip()
	local emin, emax = vm:read_from_map(min, max)
	local area = VoxelArea:new({ MinEdge = emin, MaxEdge = emax })
	local data = vm:get_data()

	local wall, floor_, air = node_id("cogwork:room_wall"), node_id("cogwork:room_floor"), core.CONTENT_AIR
	local frame, screen = node_id("cogwork:room_frame"), node_id("cogwork:room_screen")
	for lx = 0, SIZE.x - 1 do
		for ly = 0, SIZE.y - 1 do
			for lz = 0, SIZE.z - 1 do
				local c = air
				if ly == 0 then c = floor_
				elseif ly == SIZE.y - 1 or lx == 0 or lx == SIZE.x - 1 or lz == 0 or lz == SIZE.z - 1 then c = wall end
				-- the screen on the far wall, in a frame
				if lz == SIZE.z - 1 then
					if lx >= SCREEN.x1 and lx <= SCREEN.x2 and ly >= SCREEN.y1 and ly <= SCREEN.y2 then
						c = screen
					elseif lx >= SCREEN.x1 - 1 and lx <= SCREEN.x2 + 1 and ly >= SCREEN.y1 - 1 and ly <= SCREEN.y2 + 1 then
						c = frame
					end
				end
				data[area:index(o.x + lx, o.y + ly, o.z + lz)] = c
			end
		end
	end
	for kind, list in pairs(SPOTS) do
		local c = node_id("cogwork:room_" .. kind)
		for _, p in ipairs(list) do data[area:index(o.x + p[1], o.y + p[2], o.z + p[3])] = c end
	end
	vm:set_data(data)
	vm:write_to_map(true)
end

-- the chamber exists and is built: then call back
local function ready (id, callback)
	local o = cogwork.room_origin(id)
	local max = { x = o.x + SIZE.x - 1, y = o.y + SIZE.y - 1, z = o.z + SIZE.z - 1 }
	core.emerge_area(o, max, function (_, _, remaining)
		if remaining > 0 then return end
		local marker = core.get_node_or_nil({ x = o.x + 7, y = o.y, z = o.z + 7 })
		if not marker or marker.name ~= "cogwork:room_floor" then build(id) end
		-- parts added after the room was built (the settings panel)
		for kind, list in pairs(SPOTS) do
			for _, p in ipairs(list) do
				local at = { x = o.x + p[1], y = o.y + p[2], z = o.z + p[3] }
				local node = core.get_node_or_nil(at)
				if node and node.name == "air" then core.set_node(at, { name = "cogwork:room_" .. kind }) end
			end
		end
		callback()
	end)
end

--------------------------------------------------------------------------
-- who is inside

local inside = {}       -- room id -> { player name -> true }

local function occupants (id)
	local list = {}
	for name in pairs(inside[id] or {}) do
		local p = core.get_player_by_name(name)
		if p then list[#list + 1] = p end
	end
	return list
end

function cogwork.room_of_player (player)
	local id = tonumber(player:get_meta():get_string("cogwork_room"))
	return id and id > 0 and id or nil
end

-- the viewscreen of a room: shown while somebody is in it
local function watch (id)
	local o = cogwork.room_origin(id)
	local sc = cogwork.ROOM_SCREEN
	local pos = { x = o.x + sc.x, y = o.y + sc.y, z = o.z + sc.z }
	local size = { x = sc.w, y = sc.h }
	cogwork.view_screen(pos, size)
	cogwork.view_watch(id, pos, function ()
		local rp = cogwork.room_robot(id)
		if not rp then return nil end
		local node = core.get_node(rp)
		return rp, vector.multiply(core.facedir_to_dir(node.param2 % 32), -1)
	end, size)
end

local function keep_loaded (id, on)
	local r = reg.rooms[id]
	if r and r.robot then
		if on then core.forceload_block(r.robot, true) else core.forceload_free_block(r.robot, true) end
	end
end

local function set_inside (player, id)
	local name = player:get_player_name()
	local had = inside[id] and next(inside[id])
	inside[id] = inside[id] or {}
	inside[id][name] = true
	player:get_meta():set_string("cogwork_room", tostring(id))
	if not had then
		keep_loaded(id, true)
	end
	watch(id)
end

local function set_outside (player)
	local id = cogwork.room_of_player(player)
	player:get_meta():set_string("cogwork_room", "")
	if id and inside[id] then
		inside[id][player:get_player_name()] = nil
		if next(inside[id]) == nil then
			inside[id] = nil
			cogwork.view_unwatch(id)
			keep_loaded(id, false)
		end
	end
	return id
end

--------------------------------------------------------------------------
-- in and out

local function walkable (pos)
	local node = core.get_node_or_nil(pos)
	if not node then return true end
	local def = core.registered_nodes[node.name]
	return not def or def.walkable ~= false or (def.liquidtype or "none") ~= "none"
end

-- a place for a player to stand next to the robot at pos
local function standing_spot (pos)
	local node = core.get_node_or_nil(pos)
	local front = { x = 0, y = 0, z = 1 }
	if node and cogwork.is_robot(node.name) then front = vector.multiply(core.facedir_to_dir(node.param2 % 32), -1) end
	local candidates = {
		vector.add(pos, front), vector.add(pos, { x = 0, y = 1, z = 0 }),
		vector.add(pos, vector.multiply(front, -1)),
		vector.add(pos, { x = front.z, y = 0, z = -front.x }), vector.add(pos, { x = -front.z, y = 0, z = front.x }),
	}
	for _, c in ipairs(candidates) do
		if not walkable(c) and not walkable({ x = c.x, y = c.y + 1, z = c.z }) then return c end
	end
	return { x = pos.x, y = pos.y + 2, z = pos.z }
end

local function teleport_out (player, pos)
	core.load_area(pos)
	local spot = standing_spot(pos)
	player:set_pos({ x = spot.x, y = spot.y - 0.4, z = spot.z })
end

-- The lock on the room's entrance (the robot's "room_lock"): "" = whoever can
-- use the robot, "allow" = its owner and the players in its allow list (the
-- Settings tab), "owner" = its owner only. Admins with protection_bypass pass.
cogwork.ROOM_LOCKS = { "", "allow", "owner" }

function cogwork.room_lock (pos)
	local lock = core.get_meta(pos):get_string("room_lock")
	return (lock == "allow" or lock == "owner") and lock or ""
end

function cogwork.can_enter (pos, player)
	if not cogwork.can_access(pos, player) then return false end
	local lock = cogwork.room_lock(pos)
	if lock == "" then return true end
	local name = player:get_player_name()
	local owner = core.get_meta(pos):get_string("owner")
	if owner == "" or owner == name or core.check_player_privs(name, { protection_bypass = true }) then return true end
	if lock == "allow" then
		for _, entry in ipairs(cogwork.bot_allow_list(pos)) do
			if (entry:match("^([^/]+)/") or entry) == name then return true end
		end
	end
	return false
end

-- Sneak + right-click: the player goes into the robot at pos.
function cogwork.room_enter (pos, player)
	if not settings.rooms then return false end
	if cogwork.room_of_player(player) then return false end
	local name = player:get_player_name()
	if not cogwork.can_enter(pos, player) then
		if cogwork.can_access(pos, player) then
			core.chat_send_player(name, S("The room of this robot is locked."))
		else
			core.chat_send_player(name, S("This robot belongs to @1.", core.get_meta(pos):get_string("owner")))
		end
		return false
	end

	local meta = core.get_meta(pos)
	local id = meta:get_int("room_id")
	if id == 0 or not reg.rooms[id] then
		id = alloc(meta:get_string("owner"))
		meta:set_int("room_id", id)
	end
	cogwork.room_robot_at(id, pos)

	core.chat_send_player(name, S("Going into the robot..."))
	ready(id, function ()
		local p = core.get_player_by_name(name)
		if not p or cogwork.room_of_player(p) then return end
		local o = cogwork.room_origin(id)
		set_inside(p, id)
		p:set_pos({ x = o.x + cogwork.ROOM_SPAWN.x, y = o.y + cogwork.ROOM_SPAWN.y - 0.4, z = o.z + cogwork.ROOM_SPAWN.z })
		p:set_look_horizontal(0)
	end)
	return true
end

-- the door: back out next to the robot
function cogwork.room_exit (player)
	local id = cogwork.room_of_player(player)
	if not id then return false end
	local pos = cogwork.room_robot(id)
	set_outside(player)
	if pos then
		teleport_out(player, pos)
	else
		core.chat_send_player(player:get_player_name(), S("The robot is not there: you are put at the spawn."))
		player:set_pos(core.setting_get_pos("static_spawnpoint") or { x = 0, y = 10, z = 0 })
	end
	return true
end

-- The lock changed: whoever it no longer lets in is put out next to the robot.
function cogwork.room_recheck (pos)
	local id = cogwork.room_id(pos)
	if not id then return end
	for _, p in ipairs(occupants(id)) do
		if not cogwork.can_enter(pos, p) then
			core.chat_send_player(p:get_player_name(), S("The room was locked: you are put out."))
			cogwork.room_exit(p)
		end
	end
end

-- The robot is dug (or destroyed): whoever is inside comes out where it stood.
function cogwork.room_robot_gone (pos)
	local id = cogwork.room_id(pos)
	if id == 0 or not reg.rooms[id] then return end
	for _, player in ipairs(occupants(id)) do
		set_outside(player)
		teleport_out(player, pos)
		core.chat_send_player(player:get_player_name(), S("The robot was taken apart: you are out."))
	end
	inside[id] = nil
	cogwork.view_unwatch(id)
	if reg.rooms[id].robot then
		keep_loaded(id, false)
		reg.rooms[id].robot = nil
		dirty = true
	end
end

-- The robot moved: its room knows where it is, and the block that is kept loaded follows.
function cogwork.room_robot_moved (from, to)
	local id = cogwork.room_id(to)
	if id == 0 or not reg.rooms[id] then return end
	local watching = inside[id] and next(inside[id])
	if watching then keep_loaded(id, false) end
	cogwork.room_robot_at(id, to)
	if watching then keep_loaded(id, true) end
end

core.register_on_joinplayer(function (player)
	local id = cogwork.room_of_player(player)
	if id then
		inside[id] = inside[id] or {}
		inside[id][player:get_player_name()] = true
		core.after(1, function ()
			if core.get_player_by_name(player:get_player_name()) then watch(id) keep_loaded(id, true) end
		end)
	end
end)

core.register_on_leaveplayer(function (player)
	local id = cogwork.room_of_player(player)
	if id and inside[id] then
		inside[id][player:get_player_name()] = nil
		if next(inside[id]) == nil then
			inside[id] = nil
			cogwork.view_unwatch(id)
			keep_loaded(id, false)
		end
	end
end)

-- Safety net: a room is only drawn while somebody online is in it (a player who left
-- by teleport, a crash or a command the code did not see).
local guard = 0
core.register_globalstep(function (dt)
	guard = guard + dt
	if guard < 3 then return end
	guard = 0
	if cogwork.room_guard_off then return end      -- tests with a player who is not online
	for _, id in ipairs(cogwork.view_watched()) do
		if #occupants(id) == 0 then
			inside[id] = nil
			cogwork.view_unwatch(id)
			keep_loaded(id, false)
		end
	end
end)

core.register_on_respawnplayer(function (player)
	set_outside(player)
end)

core.register_chatcommand("leave_robot", {
	description = S("Leave the robot you are inside of"),
	func = function (name)
		local player = core.get_player_by_name(name)
		if not player or not cogwork.room_of_player(player) then return false, S("You are not inside a robot.") end
		cogwork.room_exit(player)
		return true
	end,
})

--------------------------------------------------------------------------
-- nobody builds, digs or paints in a room (ggraffiti and the rest ask this too)

local is_protected = core.is_protected
function core.is_protected (pos, name)
	if cogwork.room_at(pos) then return true end
	return is_protected(pos, name)
end

-- the room's exports for the nodes and for tests
cogwork.room_occupants = occupants
cogwork.room_prepare = ready            -- the chamber exists and is built, then call back
cogwork.room_open_view = watch          -- draw the screen of a room
cogwork.room_next = function () return reg.next end

--------------------------------------------------------------------------
-- Skyblock: Zero sends every player below y -300 back to the core (the "you fell off
-- the platform" safety net), and the rooms are far below that. Its own room
-- container mod exempts its rooms by wrapping sbz_api.activate_safetynet (false: leave
-- the player alone); so do we, once every mod has loaded (our wrapper goes on top).
core.register_on_mods_loaded(function ()
	local api = rawget(_G, "sbz_api")
	if not (api and api.activate_safetynet) then return end
	local previous = api.activate_safetynet
	api.activate_safetynet = function (player_name, pos)
		if pos and cogwork.room_at(pos) then return false end
		return previous(player_name, pos)
	end
end)
