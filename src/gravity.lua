-- Gravity, water and buckets.
--
-- A robot that is not running falls to the floor (one block at a time, so
-- it looks like falling). A robot in water is "flooded", like a waterlogged
-- block: its node remembers the water source it replaced ("flooded" in its
-- meta), puts it back when it leaves or is dug, and a bucket can take it.
-- With robots_can_float a robot floats in the water, else it sinks.

local S = ...
local settings = S.settings
local T = S.S

local hash = core.hash_node_position
local below = function (pos) return { x = pos.x, y = pos.y - 1, z = pos.z } end

--------------------------------------------------------------------------
-- gravity

-- does something hold the robot at pos up?
local function supported (pos)
	local under = below(pos)
	local node = core.get_node_or_nil(under)
	if node == nil or node.name == "ignore" then return true end

	if S.water_source(node.name) then
		-- floating: a robot already in the water stays, one above it drops in
		return settings.can_float and core.get_meta(pos):get_string("flooded") ~= ""
	end
	return not S.node_passable(under)
end

-- is there a floor (or water to float in) within range blocks below pos?
-- Unloaded terrain is not looked into: no fall then.
local function floor_within (pos, range)
	for k = 1, range do
		local p = { x = pos.x, y = pos.y - k, z = pos.z }
		local node = core.get_node_or_nil(p)
		if node == nil or node.name == "ignore" then return false end
		if S.water_source(node.name) then
			if settings.can_float then return true end
		elseif not S.node_passable(p) then
			return true
		end
	end
	return false
end

local pending = {}

-- one step of falling for the robot at pos, then the next one a moment later
local function settle_step (pos)
	local node = core.get_node_or_nil(pos)
	if not node or not S.is_robot(node.name) then return end
	S.refresh_variant(pos)
	if not settings.gravity or S.is_running(pos) then return end
	if supported(pos) or not floor_within(pos, settings.fall_range) then return end

	local under = below(pos)
	local owner = core.get_meta(pos):get_string("owner")
	if core.is_protected(under, owner) then return end

	S.relocate(pos, under, node)
	local key = hash(under)
	pending[key] = true
	core.after(0.1, function ()
		pending[key] = nil
		settle_step(under)
	end)
end

-- a robot that may have lost its floor (stopped, placed, floor dug away)
function S.settle_later (pos)
	if not settings.gravity then return end
	local key = hash(pos)
	if pending[key] then return end
	pending[key] = true
	local p = vector.new(pos)
	core.after(0.2, function ()
		pending[key] = nil
		settle_step(p)
	end)
end

-- the safety net: floors dug away under a robot, robots loaded in mid-air; and a
-- running robot's model follows what is under it
core.register_abm({
	label = "Cogwork gravity",
	nodenames = S.ROBOT_NODES,
	interval = 2,
	chance = 1,
	catch_up = false,
	action = function (pos)
		S.ensure_visual(pos)
		if S.is_running(pos) then
			S.refresh_variant(pos)
		else
			S.settle_later(pos)
		end
	end,
})

--------------------------------------------------------------------------
-- flooding

-- a robot placed into water is flooded; one placed in the air falls
core.register_on_placenode(function (pos, newnode, placer, oldnode)
	if not S.is_robot(newnode.name) then return end
	local water = S.water_source(oldnode.name)
	if water then core.get_meta(pos):set_string("flooded", water) end
	if S.update_infotext then S.update_infotext(pos) end
	S.refresh_variant(pos)
	S.settle_later(pos)
end)

-- a flooded robot that is dug leaves its water behind
function S.restore_water (pos, fields)
	local water = fields and fields.flooded
	if water and water ~= "" and core.registered_nodes[water] then
		core.set_node(pos, { name = water })
	end
end

--------------------------------------------------------------------------
-- buckets: each bucket mod says what an empty bucket becomes when it takes
-- the water of a flooded robot

local adapters = {}

-- def.empty: the empty bucket's item name
-- def.filled: function (source_node_name) -> item name of the bucket full of it, or nil
function S.register_bucket (def)
	assert(def.empty and def.filled, "a bucket needs empty and filled")
	adapters[#adapters + 1] = def
end

-- Minetest Game and Hades-style bucket mod
S.register_bucket({
	empty = "bucket:bucket_empty",
	filled = function (source)
		local liquids = rawget(_G, "bucket") and bucket.liquids
		local def = liquids and liquids[source]
		return def and def.itemname
	end,
})

-- Skyblock: Zero: its Fluid Cells are its buckets, one for every liquid it has
S.register_bucket({
	empty = "sbz_chem:empty_fluid_cell",
	filled = function (source)
		local cells = rawget(_G, "sbz_api") and sbz_api.sources2fluid_cells
		return cells and cells[source]
	end,
})

-- Mineclonia and VoxeLibre
S.register_bucket({
	empty = "mcl_buckets:bucket_empty",
	filled = function (source)
		local liquids = rawget(_G, "mcl_buckets") and mcl_buckets.liquids
		local def = liquids and liquids[source]
		return def and def.bucketname
	end,
})

-- A player right-clicks the robot with itemstack. When it is flooded and the
-- stack is an empty bucket, the bucket takes the water; returns the stack the
-- player should hold then. nil: this is not a bucket for this robot.
function S.fill_bucket (pos, player, itemstack)
	local meta = core.get_meta(pos)
	local source = meta:get_string("flooded")
	if source == "" or not itemstack or itemstack:is_empty() then return nil end

	for _, adapter in ipairs(adapters) do
		if itemstack:get_name() == adapter.empty then
			local full = adapter.filled(source)
			if full then
				meta:set_string("flooded", "")
				if S.update_infotext then S.update_infotext(pos) end

				if itemstack:get_count() == 1 then return ItemStack(full) end
				local inv = player:get_inventory()
				local rest = inv and inv:add_item("main", ItemStack(full)) or ItemStack(full)
				if not rest:is_empty() then core.add_item(player:get_pos(), rest) end
				itemstack:take_item()
				return itemstack
			end
		end
	end
end

--------------------------------------------------------------------------
-- robots placed before the structure existed get a starter armor and cell, once

core.register_lbm({
	label = "Cogwork structure",
	name = "cogwork:structure",
	nodenames = S.ROBOT_NODES,
	run_at_every_load = false,
	action = function (pos) S.ensure_structure(pos) end,
})
