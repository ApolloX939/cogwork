-- Upgrades: five slots in every robot.
--
-- A robot may be 1 block above the floor (floor = the nearest block that is
-- not free below it). Each Hover Upgrade lets it go one block higher, a
-- Flight Upgrade removes the limit. The limit applies to every move and to
-- the pathfinder, so a robot cannot climb 100 blocks into the air - except along
-- a wall: next to a solid block it may go on up (out of a shaft it dug).
-- See S.move_allowed.
-- A robot with a Flight Upgrade is a "drone" (its own model).

local S = ...
local T = S.S

S.UPGRADE_SLOTS = 5
S.BASE_HEIGHT = 1

local HOVER, FLIGHT = "cogwork:upgrade_hover", "cogwork:upgrade_flight"
S.UPGRADE_ITEMS = { [HOVER] = true, [FLIGHT] = true }

core.register_craftitem(HOVER, {
	description = T("Hover Upgrade"),
	short_description = T("Hover Upgrade"),
	_tt_help = T("Robot upgrade: one more block above the floor (install in the Storage tab)"),
	inventory_image = "cogwork_upgrade_hover.png",
	stack_max = 1,
})

core.register_craftitem(FLIGHT, {
	description = T("Flight Upgrade"),
	short_description = T("Flight Upgrade"),
	_tt_help = T("Robot upgrade: no limit above the floor (install in the Storage tab)"),
	inventory_image = "cogwork_upgrade_flight.png",
	stack_max = 1,
})

-- robots placed before upgrades existed get their slots on first use
function S.ensure_upgrade_slots (pos)
	local inv = core.get_meta(pos):get_inventory()
	if inv:get_size("upgrades") ~= S.UPGRADE_SLOTS then
		inv:set_size("upgrades", S.UPGRADE_SLOTS)
	end
end

-- Blocks above the floor the robot at pos may be, or nil when it can fly.
function S.height_limit (pos)
	local list = core.get_meta(pos):get_inventory():get_list("upgrades") or {}
	local hovers = 0
	for _, stack in ipairs(list) do
		local name = stack:get_name()
		if name == FLIGHT then return nil end
		if name == HOVER then hovers = hovers + 1 end
	end
	return S.BASE_HEIGHT + hovers
end

-- Free blocks between cell and the floor below it, counting no further than
-- limit + 1. Terrain nobody loaded counts as floor (it cannot be told).
-- ignore: a position to read as free (the robot's own block).
function S.gap_below (cell, limit, ignore)
	for k = 0, limit do
		local below = { x = cell.x, y = cell.y - 1 - k, z = cell.z }
		if S.node_unknown(below) then return k end
		if not (ignore and vector.equals(below, ignore)) and not S.node_passable(below) then
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
function S.clinging (cell, ignore)
	for _, d in ipairs(SIDES) do
		local side = vector.add(cell, d)
		if not (ignore and vector.equals(side, ignore))
			and not S.node_unknown(side) and not S.node_passable(side) then
			return true
		end
	end
	return false
end

-- May the robot (limit from S.height_limit) go from one cell to a neighbour?
--   * down: always, that only brings it closer to the floor
--   * within the limit above the floor at the new cell
--   * the new cell is next to a block (it holds on: along a wall, up a tower)
--   * up from a cell that is next to a block, so it can climb out of a shaft
--     it dug and step onto the surface above it
-- ignore: the robot's own block, which is no floor and no wall.
function S.move_allowed (from, to, limit, ignore)
	if limit == nil or to.y < from.y then return true end
	if S.gap_below(to, limit, ignore) <= limit then return true end
	if S.clinging(to, ignore) then return true end
	return to.y > from.y and S.clinging(from, ignore)
end

-- a short sentence for the Storage tab
function S.height_text (pos)
	local limit = S.height_limit(pos)
	if limit == nil then return T("Flying: no height limit") end
	return T("Up to @1 block(s) above the floor", limit)
end

-- for programs: blocks above the floor allowed, -1 when flying
function S.Bot:height_limit ()
	return S.height_limit(self.pos) or -1
end
