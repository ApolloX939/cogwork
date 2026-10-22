-- Structure: what a robot is made of and runs on.
--
--   armor      1 slot   Armor Plating. A robot only runs with armor in it. Armor
--                       takes damage (a weapon) and never breaks;
--                       at no durability it protects nothing, the power cells take
--                       the damage instead.
--   armor_mod  1 slot   Self-Repair Module: mends the armor, for power.
--   cells      2 slots  Power Cells. Every operation costs power. A robot runs while a
--                       cell has charge; no cell, or only empty cells: it stops.
--   augment    1 slot   Creative Capacitor (cells always full) or Self-Generator
--                       (charges one cell at a time).
--
-- Charge and durability live in the item stacks (so they travel with the item)
-- and show as the item's wear bar, which is why these are tools.

local S = ...
local T = S.S
local settings = S.settings
local Bot = S.Bot

-- durability lost per point of damage (a sword hit of 6 costs 6: four hits wear
-- out the lightest armor)
S.ARMOR_PER_DAMAGE = 1

local MAX_WEAR = 65535
local REPAIR_POINTS = 1
local NODE_LISTS = { armor = 1, armor_mod = 1, cells = 2, augment = 1 }
S.STRUCTURE_LISTS = NODE_LISTS

--------------------------------------------------------------------------
-- items

-- operations a cell holds, about (a move costs 1, see commands.lua)
S.CELL_TIERS = {
	{ id = "small", title = T("Small"), capacity = 450 },
	{ id = "medium", title = T("Medium"), capacity = 950 },
	{ id = "large", title = T("Large"), capacity = 1400 },
	{ id = "huge", title = T("Huge"), capacity = 2200 },
	{ id = "colossal", title = T("Colossal"), capacity = 3200 },
}

-- the lightest takes 24 damage, every tier 7 more
S.ARMOR_TIERS = {
	{ id = "basic", title = T("Basic"), durability = 24 },
	{ id = "reinforced", title = T("Reinforced"), durability = 31 },
	{ id = "heavy", title = T("Heavy"), durability = 38 },
}

local CELLS, ARMORS = {}, {}   -- item name -> tier
local REPAIR = "cogwork:armor_mod_repair"
local CAPACITOR = "cogwork:augment_capacitor"
local GENERATOR = "cogwork:augment_generator"
S.ITEM_REPAIR, S.ITEM_CAPACITOR, S.ITEM_GENERATOR = REPAIR, CAPACITOR, GENERATOR

for _, tier in ipairs(S.CELL_TIERS) do
	local name = "cogwork:cell_" .. tier.id
	CELLS[name] = tier
	core.register_tool(name, {
		description = T("Power Cell (@1)", tier.title),
		short_description = T("Power Cell (@1)", tier.title),
		_tt_help = T("Powers a robot: about @1 operations. Install it in the Structure tab", tier.capacity),
		inventory_image = "cogwork_cell_" .. tier.id .. ".png",
	})
end

for _, tier in ipairs(S.ARMOR_TIERS) do
	local name = "cogwork:armor_" .. tier.id
	ARMORS[name] = tier
	core.register_tool(name, {
		description = T("Robot Armor (@1)", tier.title),
		short_description = T("Robot Armor (@1)", tier.title),
		_tt_help = T("A robot only runs with armor. Takes @1 damage and never breaks", tier.durability),
		inventory_image = "cogwork_armor_" .. tier.id .. ".png",
	})
end

core.register_craftitem(REPAIR, {
	description = T("Self-Repair Module"),
	short_description = T("Self-Repair Module"),
	_tt_help = T("Armor modification: mends the robot's armor for power"),
	inventory_image = "cogwork_armor_mod_repair.png",
	stack_max = 1,
})

core.register_craftitem(CAPACITOR, {
	description = T("Creative Capacitor"),
	short_description = T("Creative Capacitor"),
	_tt_help = T("Power augmentation: all cells always full"),
	inventory_image = "cogwork_augment_capacitor.png",
	stack_max = 1,
})

core.register_craftitem(GENERATOR, {
	description = T("Self-Generator"),
	short_description = T("Self-Generator"),
	_tt_help = T("Power augmentation: charges one cell at a time"),
	inventory_image = "cogwork_augment_generator.png",
	stack_max = 1,
})

local ACCEPTS = {
	armor = ARMORS,
	armor_mod = { [REPAIR] = true },
	cells = CELLS,
	augment = { [CAPACITOR] = true, [GENERATOR] = true },
}

-- may this item go in that list of a robot?
function S.structure_accepts (list, name)
	return ACCEPTS[list] ~= nil and ACCEPTS[list][name] ~= nil
end

--------------------------------------------------------------------------
-- charge and durability in the stacks

local function num (v, default) return tonumber(v) or default end

-- charge, capacity of a power cell stack (nil when it is none); no meta = full
function S.cell_info (stack)
	local tier = CELLS[stack:get_name()]
	if not tier then return nil end
	local charge = stack:get_meta():get("cogwork_charge")
	return num(charge, tier.capacity), tier.capacity
end

local function title_of (name, tiers_prefix)
	local def = core.registered_items[name]
	return def and def.description or name
end

function S.set_cell_charge (stack, charge)
	local tier = CELLS[stack:get_name()]
	if not tier then return end
	charge = math.max(0, math.min(tier.capacity, charge))
	local meta = stack:get_meta()
	meta:set_float("cogwork_charge", charge)
	stack:set_wear(math.floor((1 - charge / tier.capacity) * MAX_WEAR))
	meta:set_string("description", T("Power Cell (@1): @2 / @3", tier.title, math.floor(charge), tier.capacity))
end

-- durability, maximum of an armor stack (nil when it is none); no meta = new
function S.armor_info (stack)
	local tier = ARMORS[stack:get_name()]
	if not tier then return nil end
	return num(stack:get_meta():get("cogwork_durability"), tier.durability), tier.durability
end

function S.set_armor_durability (stack, durability)
	local tier = ARMORS[stack:get_name()]
	if not tier then return end
	durability = math.max(0, math.min(tier.durability, durability))
	local meta = stack:get_meta()
	meta:set_float("cogwork_durability", durability)
	stack:set_wear(math.floor((1 - durability / tier.durability) * MAX_WEAR))
	meta:set_string("description", T("Robot Armor (@1): @2 / @3", tier.title, math.floor(durability), tier.durability))
end

--------------------------------------------------------------------------
-- a robot's structure

local function inv_of (pos) return core.get_meta(pos):get_inventory() end

-- the lists exist (robots placed before they did get them, see ensure_structure)
local function size_lists (inv)
	for list, size in pairs(NODE_LISTS) do
		if inv:get_size(list) ~= size then inv:set_size(list, size) end
	end
end

-- Robots from before the structure existed got neither armor nor cells and would
-- never run: they get a Basic Armor and one full Small cell, once.
function S.ensure_structure (pos)
	local meta = core.get_meta(pos)
	local inv = meta:get_inventory()
	size_lists(inv)
	if meta:get_int("structure_v") == 0 then
		meta:set_int("structure_v", 1)
		inv:set_stack("armor", 1, ItemStack("cogwork:armor_basic"))
		inv:set_stack("cells", 1, ItemStack("cogwork:cell_small"))
	end
	S.sync_storage(pos)
end

function S.has_augment (pos, name)
	return inv_of(pos):get_stack("augment", 1):get_name() == name
end

function S.has_armor (pos)
	return ARMORS[inv_of(pos):get_stack("armor", 1):get_name()] ~= nil
end

-- the cell stacks: { index, stack, charge, capacity }
function S.cells_of (pos)
	local out = {}
	for i, stack in ipairs(inv_of(pos):get_list("cells") or {}) do
		local charge, capacity = S.cell_info(stack)
		if charge then out[#out + 1] = { index = i, stack = stack, charge = charge, capacity = capacity } end
	end
	return out
end

function S.fill_cells (pos)
	local inv = inv_of(pos)
	for _, cell in ipairs(S.cells_of(pos)) do
		S.set_cell_charge(cell.stack, cell.capacity)
		inv:set_stack("cells", cell.index, cell.stack)
	end
end

-- total charge and capacity of the installed cells
function S.charge_of (pos)
	local charge, capacity = 0, 0
	for _, cell in ipairs(S.cells_of(pos)) do
		charge, capacity = charge + cell.charge, capacity + cell.capacity
	end
	return charge, capacity
end

-- can the robot run: a cell with charge (or a Creative Capacitor with a cell)
function S.has_power (pos)
	local charge = S.charge_of(pos)
	return charge > 0 or (S.has_augment(pos, CAPACITOR) and #S.cells_of(pos) > 0)
end

-- why a robot cannot run, or nil
function S.cannot_run (pos)
	if not S.has_armor(pos) then return T("No armor in the robot") end
	if #S.cells_of(pos) == 0 then return T("No power cell in the robot") end
	if not S.has_power(pos) then return T("Out of power: every power cell is empty") end
end

-- Use power. With a Creative Capacitor it is free. When there is not enough, the
-- cells are emptied and this is false: the robot stops.
function S.spend (pos, amount)
	if amount <= 0 then return true end
	if S.has_augment(pos, CAPACITOR) then
		S.fill_cells(pos)
		return #S.cells_of(pos) > 0
	end

	local inv = inv_of(pos)
	local cells = S.cells_of(pos)
	local left = amount
	for _, cell in ipairs(cells) do
		local take = math.min(cell.charge, left)
		if take > 0 then
			S.set_cell_charge(cell.stack, cell.charge - take)
			inv:set_stack("cells", cell.index, cell.stack)
			left = left - take
		end
	end
	return left <= 0
end

-- Damage to the robot (another player's weapon; liquids never hurt it): the armor
-- takes it until it has no durability left, then the power cells do.
function S.damage (pos, amount)
	if amount <= 0 then return end
	local inv = inv_of(pos)
	local armor = inv:get_stack("armor", 1)
	local durability = S.armor_info(armor)
	if durability and durability > 0 then
		local absorbed = math.min(durability, amount)
		S.set_armor_durability(armor, durability - absorbed)
		inv:set_stack("armor", 1, armor)
		amount = amount - absorbed
	end
	if amount > 0 then S.spend(pos, amount) end
end

--------------------------------------------------------------------------
-- the structure's own clock: the generator charges, the repair module mends

local function timer_wanted (pos)
	local inv = inv_of(pos)
	return inv:get_stack("augment", 1):get_name() == GENERATOR
		or inv:get_stack("armor_mod", 1):get_name() == REPAIR
end

function S.refresh_structure_timer (pos)
	local timer = core.get_node_timer(pos)
	if timer_wanted(pos) then
		if not timer:is_started() then timer:start(settings.generator_interval) end
	else
		timer:stop()
	end
end

-- Returns true while the timer should go on.
function S.structure_tick (pos)
	local node = core.get_node_or_nil(pos)
	if not node or not S.is_robot(node.name) then return false end
	local inv = inv_of(pos)

	-- Self-Generator: one cell at a time, the first that is not full
	if inv:get_stack("augment", 1):get_name() == GENERATOR then
		for _, cell in ipairs(S.cells_of(pos)) do
			if cell.charge < cell.capacity then
				S.set_cell_charge(cell.stack, cell.charge + settings.generator_amount)
				inv:set_stack("cells", cell.index, cell.stack)
				break
			end
		end
	end

	-- Self-Repair Module: a point of durability for a point of power, every tick (the
	-- lightest armor is whole again after two minutes)
	if inv:get_stack("armor_mod", 1):get_name() == REPAIR then
		local armor = inv:get_stack("armor", 1)
		local durability, max = S.armor_info(armor)
		if durability and durability < max then
			local charge = S.charge_of(pos)
			local points = math.min(REPAIR_POINTS, max - durability, math.floor(charge))
			if S.has_augment(pos, CAPACITOR) then points = math.min(REPAIR_POINTS, max - durability) end
			if points > 0 and S.spend(pos, points) then
				S.set_armor_durability(armor, durability + points)
				inv:set_stack("armor", 1, armor)
			end
		end
	end

	return timer_wanted(pos)
end

-- something in a structure list changed (a player, a robot's program)
function S.structure_changed (pos, listname)
	if not NODE_LISTS[listname] then return end
	if S.has_augment(pos, CAPACITOR) then S.fill_cells(pos) end
	S.refresh_structure_timer(pos)
	-- no armor or no power: the robot stops, and stays off
	if S.is_running(pos) and S.cannot_run(pos) then S.stop(pos, S.cannot_run(pos)) end
end

--------------------------------------------------------------------------
-- the robot's own commands: install and uninstall parts from its storage

local SLOT_LISTS = { armor_mod = "armor_mod", augment = "augment", cell = "cells" }

local function find_in_storage (inv, list, item)
	for i, stack in ipairs(inv:get_list("main") or {}) do
		local name = stack:get_name()
		if not stack:is_empty() and S.structure_accepts(list, name)
			and (item == nil or item == "" or name == item
				or (item:sub(1, 6) == "group:" and core.get_item_group(name, item:sub(7)) > 0)) then
			return i, stack
		end
	end
end

-- Put a part from storage into one of the robot's own slots: armor_mod, augment or
-- cell. A part in that slot goes back to storage. The armor stays: only a player
-- changes that.
function Bot:install (slot, item)
	local list = SLOT_LISTS[slot]
	if not list then return false, settings.action_delay end
	local inv = self:inv()
	local from, stack = find_in_storage(inv, list, item ~= nil and S.lang.tostr(item) or nil)
	if not from then return false, settings.action_delay end

	local index = 1
	if list == "cells" then
		-- an empty cell slot
		index = nil
		for i = 1, inv:get_size("cells") do
			if inv:get_stack("cells", i):is_empty() then index = i break end
		end
		if not index then return false, settings.action_delay end
	end

	local old = inv:get_stack(list, index)
	inv:set_stack("main", from, ItemStack())
	if not old:is_empty() then
		if not inv:room_for_item("main", old) then
			inv:set_stack("main", from, stack)
			return false, settings.action_delay
		end
		inv:add_item("main", old)
	end
	inv:set_stack(list, index, stack)
	S.structure_changed(self.pos, list)
	return true, settings.action_delay
end

-- Take a part out into storage. A power cell only while another one stays in the
-- robot (the one with the least charge goes): no cell, no power.
function Bot:uninstall (slot)
	local list = SLOT_LISTS[slot]
	if not list then return false, settings.action_delay end
	local inv = self:inv()

	local index
	if list == "cells" then
		local cells = S.cells_of(self.pos)
		if #cells < 2 then return false, settings.action_delay end
		table.sort(cells, function (a, b) return a.charge < b.charge end)
		index = cells[1].index
	else
		index = 1
	end

	local stack = inv:get_stack(list, index)
	if stack:is_empty() or not inv:room_for_item("main", stack) then return false, settings.action_delay end
	inv:set_stack(list, index, ItemStack())
	inv:add_item("main", stack)
	S.structure_changed(self.pos, list)
	return true, settings.action_delay
end

-- percent of the installed cells' capacity (100 with a Creative Capacitor)
function Bot:battery_level ()
	if S.has_augment(self.pos, CAPACITOR) and #S.cells_of(self.pos) > 0 then return 100 end
	local charge, capacity = S.charge_of(self.pos)
	if capacity == 0 then return 0 end
	return math.floor(charge / capacity * 100 + 0.5)
end

-- percent durability of the armor, -1 without armor
function Bot:armor_level ()
	local durability, max = S.armor_info(self:inv():get_stack("armor", 1))
	if not durability then return -1 end
	return math.floor(durability / max * 100 + 0.5)
end

function Bot:cell_count () return #S.cells_of(self.pos) end

local ITEM_SLOTS = { armor = { "armor", 1 }, armor_mod = { "armor_mod", 1 }, augment = { "augment", 1 },
	cell1 = { "cells", 1 }, cell2 = { "cells", 2 } }

-- name of what is in a slot ("" when empty): armor armor_mod augment cell1 cell2
function Bot:structure_item (slot)
	local where = ITEM_SLOTS[slot]
	if not where then return "" end
	return self:inv():get_stack(where[1], where[2]):get_name()
end
