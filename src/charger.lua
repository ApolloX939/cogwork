-- Chargers: a robot standing on top gets its power cells charged.
--
-- Every cell that is not full takes CHARGE_RATE units a second, and a charger
-- draws that much for each cell it charges: two cells draw twice as much.
--
--   cogwork:charger          no network. Its source slot takes a spare Power Cell, or
--                            (with Technic) a battery or energy crystal item, and
--                            charges the robot from it.
--   cogwork:charger_lv / mv  Technic machines. The network's batteries feed it. MV
--                            draws less for the same charge.
--   cogwork:charger_ta       a Techage consumer on the electric cable. Techage's
--                            batteries (Akkus) only feed the network's pool, nothing
--                            charges an item from one directly, so this takes from
--                            the pool as every Techage machine does.
--   cogwork:charger_sbz      a Skyblock: Zero machine: its power network, with its
--                            batteries, feeds it.

local cogwork = ...
local S = cogwork.S
local compat = cogwork.compat

local RATE = 25                 -- cell units per second and cell
cogwork.CHARGE_RATE = RATE

-- what a cell costs to charge for a second, in the units of each power system
local TECHNIC_COST = { LV = 150, MV = 100 }   -- EU
local TECHAGE_COST = 4                        -- units per 2 second cycle
local SBZ_COST = 12                           -- power per second
local TECHNIC_UNITS_PER_EU = 0.1              -- a battery item's EU into cell units
local CELL_EFFICIENCY = 0.9                   -- moving charge from a spare cell loses a tenth

local function above (pos) return { x = pos.x, y = pos.y + 1, z = pos.z } end

--------------------------------------------------------------------------
-- what a charger does to the robot on it

-- The robot on the charger and the cells of it that are not full.
function cogwork.charger_needs (pos)
	local rp = above(pos)
	local node = core.get_node_or_nil(rp)
	if not node or not cogwork.is_robot(node.name) then return nil, {} end
	-- a Creative Capacitor keeps the cells full anyway
	if cogwork.has_augment(rp, cogwork.ITEM_CAPACITOR) then return rp, {} end

	local need = {}
	for _, cell in ipairs(cogwork.cells_of(rp)) do
		if cell.charge < cell.capacity - 0.01 then need[#need + 1] = cell end
	end
	return rp, need
end

-- Give each of the cells up to units; returns what was given in all.
function cogwork.charge_cells (robot_pos, cells, units)
	local inv = core.get_meta(robot_pos):get_inventory()
	local given = 0
	for _, cell in ipairs(cells) do
		local add = math.min(units, cell.capacity - cell.charge)
		if add > 0 then
			cogwork.set_cell_charge(cell.stack, cell.charge + add)
			inv:set_stack("cells", cell.index, cell.stack)
			given = given + add
		end
	end
	return given
end

local function status (pos, text)
	core.get_meta(pos):set_string("infotext", text)
end

--------------------------------------------------------------------------
-- the source slot of the plain charger

local function technic_tool (name)
	local tools = rawget(_G, "technic") and technic.power_tools
	return tools and tools[name] and technic.get_charge
end

-- How much a stack in the source slot can give, in cell units.
local function source_units (stack)
	if stack:is_empty() then return 0 end
	local charge = cogwork.cell_info(stack)
	if charge then return charge * CELL_EFFICIENCY end
	if technic_tool(stack:get_name()) then
		return (technic.get_charge(stack)) * TECHNIC_UNITS_PER_EU
	end
	return 0
end

-- take units out of the source stack (in place)
local function drain_source (stack, units)
	local charge = cogwork.cell_info(stack)
	if charge then
		cogwork.set_cell_charge(stack, charge - units / CELL_EFFICIENCY)
	elseif technic_tool(stack:get_name()) then
		technic.set_charge(stack, math.max(0, (technic.get_charge(stack)) - math.ceil(units / TECHNIC_UNITS_PER_EU)))
	end
end

local function source_accepts (name)
	return cogwork.cell_info(ItemStack(name)) ~= nil or technic_tool(name) ~= nil
end

function cogwork.charger_base_tick (pos)
	local rp, need = cogwork.charger_needs(pos)
	if not rp then status(pos, S("Charger: put a robot on top")) return true end
	if #need == 0 then status(pos, S("Charger: the cells are full")) return true end

	local inv = core.get_meta(pos):get_inventory()
	local stack = inv:get_stack("source", 1)
	local available = source_units(stack)
	if available <= 0 then status(pos, S("Charger: nothing in the source slot has charge")) return true end

	-- each cell takes its rate, as far as the source reaches
	local each = math.min(RATE, available / #need)
	local given = cogwork.charge_cells(rp, need, each)
	drain_source(stack, given)
	inv:set_stack("source", 1, stack)
	status(pos, S("Charger: charging @1 cell(s), @2 units/s", #need, math.floor(each * #need)))
	return true
end

--------------------------------------------------------------------------
-- Technic: the machine says what it wants (<TIER>_EU_demand) and the network
-- says what it gives (<TIER>_EU_input) once a second

function cogwork.charger_technic_run (tier, per_cell)
	local key = tier .. "_EU_"
	return function (pos)
		local meta = core.get_meta(pos)
		local rp, need = cogwork.charger_needs(pos)
		local demand = #need * per_cell
		meta:set_int(key .. "demand", demand)
		if not rp or #need == 0 then
			meta:set_string("infotext", S("@1 Charger: idle", tier))
		elseif meta:get_int(key .. "input") >= demand then
			cogwork.charge_cells(rp, need, RATE)
			meta:set_string("infotext", S("@1 Charger: charging @2 cell(s)", tier, #need))
		else
			meta:set_string("infotext", S("@1 Charger: not enough power", tier))
		end
	end
end

-- Techage: a consumer takes from the network's pool every cycle

local TA_CYCLE = 2

function cogwork.charger_techage_tick (pos)
	local Cable = techage.ElectricCable
	local rp, need = cogwork.charger_needs(pos)
	if not rp or #need == 0 then
		status(pos, S("TA Charger: idle"))
		return true
	end
	local demand = #need * TECHAGE_COST
	local consumed = networks.power.consume_power(pos, Cable, nil, demand) or 0
	if consumed > 0 then
		-- what the network gave decides what the cells get
		cogwork.charge_cells(rp, need, RATE * TA_CYCLE * consumed / demand)
		status(pos, S("TA Charger: charging @1 cell(s)", #need))
	else
		status(pos, S("TA Charger: no power"))
	end
	return true
end

-- Skyblock: Zero: the machine reports its consumption to the network

function cogwork.charger_sbz_action (pos, node, meta, supply, demand)
	local rp, need = cogwork.charger_needs(pos)
	if not rp or #need == 0 then
		meta:set_string("infotext", S("Charger: idle"))
		return 0
	end
	-- as many cells as the network has power to spare for, at least one
	local free = math.floor((supply - demand) / SBZ_COST)
	local n = math.max(1, math.min(#need, free))
	local cells = {}
	for i = 1, n do cells[i] = need[i] end
	cogwork.charge_cells(rp, cells, RATE)
	meta:set_string("infotext", S("Charger: charging @1 cell(s)", n))
	return n * SBZ_COST
end

--------------------------------------------------------------------------
-- the nodes

local function tiles (variant)
	return { "cogwork_charger_top_" .. variant .. ".png", "cogwork_charger_bottom.png",
		"cogwork_charger_side_" .. variant .. ".png" }
end

local function register (name, variant, description, extra)
	local def = {
		description = description,
		short_description = description,
		tiles = tiles(variant),
		groups = compat.robot_groups(),
		sounds = compat.metal_sounds(),
		is_ground_content = false,
	}
	for k, v in pairs(extra) do def[k] = v end
	core.register_node(name, def)
end

local function source_formspec ()
	return "formspec_version[4]size[10.5,9]"
		.. "label[0.5,0.6;" .. core.formspec_escape(S("Source: a spare Power Cell or a Technic battery")) .. "]"
		.. "list[context;source;0.5,1;1,1;]"
		.. "label[0.5,2.4;" .. core.formspec_escape(S("A robot on top gets its cells charged from it.")) .. "]"
		.. "list[current_player;main;0.4,3.6;8,4;]listring[]"
end

register("cogwork:charger", "base", S("Charger"), {
	_tt_help = S("Charges the robot on top from a spare Power Cell or a Technic battery"),
	on_construct = function (pos)
		local meta = core.get_meta(pos)
		meta:get_inventory():set_size("source", 1)
		meta:set_string("formspec", source_formspec())
		core.get_node_timer(pos):start(1)
	end,
	on_timer = function (pos) return cogwork.charger_base_tick(pos) end,
	allow_metadata_inventory_put = function (pos, listname, index, stack)
		return source_accepts(stack:get_name()) and stack:get_count() or 0
	end,
	allow_metadata_inventory_move = function (pos, from_list, from_index, to_list, to_index, count)
		local moved = core.get_meta(pos):get_inventory():get_stack(from_list, from_index)
		return source_accepts(moved:get_name()) and count or 0
	end,
})

-- Technic: LV, and MV which draws less for the same charge
if rawget(_G, "technic") and technic.register_machine then
	for tier, cost in pairs(TECHNIC_COST) do
		local name = "cogwork:charger_" .. tier:lower()
		register(name, tier:lower(), S("@1 Charger", tier), {
			_tt_help = S("Technic machine: charges the robot on top, @1 EU a second per cell", cost),
			groups = (function ()
				local g = compat.robot_groups({ technic_machine = 1 })
				g["technic_" .. tier:lower()] = 1
				return g
			end)(),
			connect_sides = { "bottom", "front", "back", "left", "right" },
			technic_run = cogwork.charger_technic_run(tier, cost),
		})
		technic.register_machine(tier, name, technic.receiver)
	end
end

-- Techage
if rawget(_G, "techage") and techage.ElectricCable and rawget(_G, "networks") and networks.power then
	local Cable = techage.ElectricCable
	local name = "cogwork:charger_ta"
	register(name, "techage", S("TA Charger"), {
		_tt_help = S("Techage consumer: charges the robot on top from the electric network"),
		paramtype2 = "facedir",
		after_place_node = function (pos)
			Cable:after_place_node(pos)
			core.get_node_timer(pos):start(TA_CYCLE)
		end,
		after_dig_node = function (pos) Cable:after_dig_node(pos) end,
		on_timer = function (pos) return cogwork.charger_techage_tick(pos) end,
	})
	networks.power.register_nodes({ name }, Cable, "con", { "B", "R", "F", "L", "D" })
end

-- Skyblock: Zero
if rawget(_G, "sbz_api") and sbz_api.register_machine then
	sbz_api.register_machine("cogwork:charger_sbz", {
		description = S("Power Charger"),
		short_description = S("Power Charger"),
		_tt_help = S("Charges the robot on top from the power network"),
		tiles = tiles("sbz"),
		sounds = compat.metal_sounds(),
		groups = { sbz_machine = 1, pipe_conducts = 1, pipe_connects = 1, matter = 3, cracky = 3 },
		is_ground_content = false,
		power_needed = SBZ_COST,
		action = cogwork.charger_sbz_action,
	})
end

--------------------------------------------------------------------------
-- recipes

compat.register_recipes(function (c)
	local have = core.registered_items
	local function exists (item) return have[item] ~= nil or core.registered_aliases[item] ~= nil end
	local function craft (output, recipe, shapeless)
		if not have[output] then return end
		for _, row in ipairs(shapeless and { recipe } or recipe) do
			for _, item in ipairs(row) do
				if item == nil or (item:find(":", 1, true) and not exists(item)) then return end
			end
		end
		core.register_craft({ output = output, recipe = recipe, type = shapeless and "shapeless" or nil })
	end
	local function first (...)
		for _, key in ipairs({ ... }) do
			local item = c.item(key)
			if item then return item end
		end
	end

	local small = "cogwork:cell_small"
	if c.family == "sbz" then
		local plate, circuit = c.item("plate"), c.item("circuit")
		local processor = have["sbz_resources:simple_processor"] and "sbz_resources:simple_processor" or circuit
		craft("cogwork:charger", { { plate, processor, plate }, { circuit, small, circuit }, { plate, plate, plate } })
		craft("cogwork:charger_sbz", { "cogwork:charger", processor, circuit }, true)
	else
		local steel, copper, gold = first("steel", "tin"), first("copper", "tin"), first("gold", "copper")
		craft("cogwork:charger", { { steel, copper, steel }, { gold, small, gold }, { steel, steel, steel } })
		craft("cogwork:charger_lv", { "cogwork:charger", "technic:lv_cable", "technic:machine_casing" }, true)
		craft("cogwork:charger_mv", { "cogwork:charger", "technic:mv_cable", "technic:machine_casing", "technic:lv_transformer" }, true)
		craft("cogwork:charger_ta", { "cogwork:charger", "techage:electric_cableS", "techage:electric_cableS" }, true)
	end
end)
