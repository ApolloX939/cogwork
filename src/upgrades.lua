-- Upgrades: six slots in every robot.
--
-- A robot may be 1 block above the floor (floor = the nearest block that is
-- not free below it). Each Hover Upgrade lets it go one block higher, a
-- Flight Upgrade removes the limit. The limit applies to every move and to
-- the pathfinder, so a robot cannot climb 100 blocks into the air - except along
-- a wall: next to a solid block it may go on up (out of a shaft it dug).
-- See cogwork.move_allowed.
-- A robot with a Flight Upgrade is a "drone" (its own model).

local cogwork = ...
local S = cogwork.S

cogwork.UPGRADE_SLOTS = 6
cogwork.BASE_HEIGHT = 1

local HOVER, FLIGHT = "cogwork:upgrade_hover", "cogwork:upgrade_flight"
local COMBAT = "cogwork:upgrade_combat"
local STORAGE_UP = "cogwork:upgrade_storage"
cogwork.UPGRADE_ITEMS = { [HOVER] = true, [FLIGHT] = true, [COMBAT] = true, [STORAGE_UP] = true }

cogwork.STORAGE_BASE = 16        -- 8 x 2
cogwork.STORAGE_PER_UPGRADE = 4

core.register_craftitem(HOVER, {
	description = S("Hover Upgrade"),
	short_description = S("Hover Upgrade"),
	_tt_help = S("Robot upgrade: one more block above the floor (install in the Storage tab)"),
	inventory_image = "cogwork_upgrade_hover.png",
	stack_max = 1,
})

core.register_craftitem(FLIGHT, {
	description = S("Flight Upgrade"),
	short_description = S("Flight Upgrade"),
	_tt_help = S("Robot upgrade: no limit above the floor (install in the Storage tab)"),
	inventory_image = "cogwork_upgrade_flight.png",
	stack_max = 1,
})

core.register_craftitem(COMBAT, {
	description = S("Combat Upgrade"),
	short_description = S("Combat Upgrade"),
	_tt_help = S("Robot upgrade: its punch can hit players (not its owner), where pvp is on"),
	inventory_image = "cogwork_upgrade_combat.png",
	stack_max = 1,
})

core.register_craftitem(STORAGE_UP, {
	description = S("Storage Upgrade"),
	short_description = S("Storage Upgrade"),
	_tt_help = S("Robot upgrade: @1 more storage slots", cogwork.STORAGE_PER_UPGRADE),
	inventory_image = "cogwork_upgrade_storage.png",
	stack_max = 1,
})

-- is this upgrade installed in the robot at pos?
function cogwork.has_upgrade (pos, name)
	for _, stack in ipairs(core.get_meta(pos):get_inventory():get_list("upgrades") or {}) do
		if stack:get_name() == name then return true end
	end
	return false
end

-- robots placed before upgrades existed get their slots on first use
function cogwork.ensure_upgrade_slots (pos)
	local inv = core.get_meta(pos):get_inventory()
	if inv:get_size("upgrades") ~= cogwork.UPGRADE_SLOTS then
		inv:set_size("upgrades", cogwork.UPGRADE_SLOTS)
	end
end

-- How many Combat Upgrades the robot at pos has: a punch reaches that many blocks
-- (one with a single upgrade or none).
function cogwork.combat_count (pos)
	local n = 0
	for _, stack in ipairs(core.get_meta(pos):get_inventory():get_list("upgrades") or {}) do
		if stack:get_name() == COMBAT then n = n + 1 end
	end
	return n
end

-- Blocks above the floor the robot at pos may be, or nil when it can fly.
function cogwork.height_limit (pos)
	local list = core.get_meta(pos):get_inventory():get_list("upgrades") or {}
	local hovers = 0
	for _, stack in ipairs(list) do
		local name = stack:get_name()
		if name == FLIGHT then return nil end
		if name == HOVER then hovers = hovers + 1 end
	end
	return cogwork.BASE_HEIGHT + hovers
end

-- Does the block at pos hold a robot up? Anything it cannot be in does; terrain
-- nobody loaded does (it cannot be told); water does when robots can float,
-- else a robot sinks through it.
function cogwork.is_floor (pos)
	local node = core.get_node_or_nil(pos)
	if node == nil or node.name == "ignore" then return true end
	if cogwork.water_source(node.name) then return cogwork.settings.can_float end
	return not cogwork.node_passable(pos)
end

-- Free blocks between cell and the floor below it, counting no further than
-- limit + 1.
-- ignore: a position to read as free (the robot's own block).
function cogwork.gap_below (cell, limit, ignore)
	for k = 0, limit do
		local below = { x = cell.x, y = cell.y - 1 - k, z = cell.z }
		if not (ignore and vector.equals(below, ignore)) and cogwork.is_floor(below) then
			return k
		end
	end
	return limit + 1
end

local SIDES = {
	{ x = 1, y = 0, z = 0 }, { x = -1, y = 0, z = 0 },
	{ x = 0, y = 0, z = 1 }, { x = 0, y = 0, z = -1 },
}

-- is there a solid block beside cell to hold on to? (a shaft wall, a tower)
function cogwork.clinging (cell, ignore)
	for _, d in ipairs(SIDES) do
		local side = vector.add(cell, d)
		if not (ignore and vector.equals(side, ignore))
			and not cogwork.node_unknown(side) and not cogwork.node_passable(side) then
			return true
		end
	end
	return false
end

-- May the robot (limit from cogwork.height_limit) go from one cell to a neighbour?
--   * down: always, that only brings it closer to the floor
--   * within the limit above the floor at the new cell
--   * the new cell is next to a block (it holds on: along a wall, up a tower)
--   * up from a cell that is next to a block, so it can climb out of a shaft
--     it dug and step onto the surface above it
-- ignore: the robot's own block, which is no floor and no wall.
function cogwork.move_allowed (from, to, limit, ignore)
	if limit == nil or to.y < from.y then return true end
	if cogwork.gap_below(to, limit, ignore) <= limit then return true end
	if cogwork.clinging(to, ignore) then return true end
	return to.y > from.y and cogwork.clinging(from, ignore)
end

-- a short sentence for the Storage tab
function cogwork.height_text (pos)
	local limit = cogwork.height_limit(pos)
	if limit == nil then return S("Flying: no height limit") end
	return S("Up to @1 block(s) above the floor", limit)
end

-- for programs: blocks above the floor allowed, -1 when flying
function cogwork.Bot:height_limit ()
	return cogwork.height_limit(self.pos) or -1
end

--------------------------------------------------------------------------
-- storage: 16 slots, 4 more for every Storage Upgrade

function cogwork.storage_size (pos)
	local n = 0
	for _, stack in ipairs(core.get_meta(pos):get_inventory():get_list("upgrades") or {}) do
		if stack:get_name() == STORAGE_UP then n = n + 1 end
	end
	return cogwork.STORAGE_BASE + n * cogwork.STORAGE_PER_UPGRADE
end

-- Make the storage the size the upgrades give. It never shrinks over items: a robot
-- with more in it than it should hold (older robots had 32 slots) keeps the slots
-- up to its last item, until they are emptied.
function cogwork.sync_storage (pos)
	local inv = core.get_meta(pos):get_inventory()
	local want, have = cogwork.storage_size(pos), inv:get_size("main")
	if have > want then
		local last = 0
		for i, stack in ipairs(inv:get_list("main") or {}) do
			if not stack:is_empty() then last = i end
		end
		want = math.max(want, last)
	end
	if want ~= have then inv:set_size("main", want) end
end

-- Would taking this stack out of the upgrade slots cut slots that hold items?
function cogwork.storage_removal_blocked (pos, name)
	if name ~= STORAGE_UP then return false end
	local inv = core.get_meta(pos):get_inventory()
	local after = cogwork.storage_size(pos) - cogwork.STORAGE_PER_UPGRADE
	for i = after + 1, inv:get_size("main") do
		if not inv:get_stack("main", i):is_empty() then return true end
	end
	return false
end
