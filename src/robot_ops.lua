-- World actions of a robot. A Bot is created for each program run and is
-- the `ctx.bot` the language calls. Actions return ok, delay.

local S = ...
local lang, compat, settings = S.lang, S.compat, S.settings

local Bot = {}
Bot.__index = Bot

local LIST = "main"
local V = vector

local function stop_error (msg)
	assert(false, { scratch = true, stop = true, fatal = true, msg = msg })
end

function Bot.new (pos, owner)
	return setmetatable({ pos = vector.new(pos), owner = owner }, Bot)
end

--------------------------------------------------------------------------
-- geometry

local function robot_node (pos)
	local node = core.get_node_or_nil(pos)
	return node and S.is_robot(node.name) and node or nil
end

function Bot:node_info ()
	local node = robot_node(self.pos)
	if not node then stop_error("the robot is gone") end
	return node
end

function Bot:front_vec ()
	return V.multiply(core.facedir_to_dir(self:node_info().param2 % 32), -1)
end

local function dir_vector (front, name)
	local up, down = { x = 0, y = 1, z = 0 }, { x = 0, y = -1, z = 0 }
	local back = V.multiply(front, -1)

	if name == "front" or name == "forward" then return front
	elseif name == "back" then return back
	elseif name == "up" then return up
	elseif name == "down" then return down
	elseif name == "front_up" then return V.add(front, up)
	elseif name == "front_down" then return V.add(front, down)
	elseif name == "back_up" then return V.add(back, up)
	elseif name == "back_down" then return V.add(back, down)
	end
end

function Bot:target (dir)
	return V.add(self.pos, dir_vector(self:front_vec(), dir))
end

function Bot:facing ()
	local f = self:front_vec()
	if f.z > 0 then return "north" elseif f.x > 0 then return "east"
	elseif f.z < 0 then return "south" else return "west" end
end

function Bot:coord (axis) return self.pos[axis] end
function Bot:random (n) return math.random(n) end

--------------------------------------------------------------------------
-- helpers

local function fake_player (name)
	local real = name and core.get_player_by_name(name)
	if real then return real end
	return {
		get_player_name = function () return name or "" end,
		is_player = function () return false end,
		get_wielded_item = function () return ItemStack("") end,
		get_inventory = function () return nil end,
		get_look_dir = function () return { x = 0, y = 0, z = 1 } end,
		get_pos = function () return { x = 0, y = 0, z = 0 } end,
		get_player_control = function () return {} end,
		set_wielded_item = function () end,
		is_fake = true,
	}
end
S.fake_player = fake_player

function Bot:protected (pos)
	return core.is_protected(pos, self.owner or "")
end

function Bot:inv ()
	return core.get_meta(self.pos):get_inventory()
end

local function stack_name (item)
	if item == nil then return nil end
	if type(item) ~= "string" then item = lang.tostr(item) end
	if item == "" then return nil end
	return item
end

-- does an item name match a pattern ("group:x", exact name)
local function item_matches (name, want)
	if not want then return true end
	if want:sub(1, 6) == "group:" then
		return core.get_item_group(name, want:sub(7)) > 0
	end
	return name == want
end

local function can_fit (inv, item)
	return inv:room_for_item(LIST, ItemStack(item))
end

local function give (self, stack)
	-- put in storage; what does not fit drops in the world
	local inv = self:inv()
	local left = inv:add_item(LIST, stack)
	if not left:is_empty() then
		core.add_item(V.add(self.pos, { x = 0, y = 1, z = 0 }), left)
	end
end

function Bot:action_delay () return settings.action_delay end

--------------------------------------------------------------------------
-- queries

function Bot:node (dir)
	local node = core.get_node_or_nil(self:target(dir))
	if not node or node.name == "air" or node.name == "ignore" then return "" end
	return node.name
end

function Bot:detect (dir, item)
	local name = self:node(dir)
	if name == "" then return false end
	item = stack_name(item)
	if not item then return true end
	return item_matches(name, item)
end

function Bot:count (item)
	item = stack_name(item)
	local total = 0
	for _, st in ipairs(self:inv():get_list(LIST) or {}) do
		if not st:is_empty() and item_matches(st:get_name(), item) then
			total = total + st:get_count()
		end
	end
	return total
end

function Bot:contains (item)
	item = stack_name(item)
	if not item then return not self:inv():is_empty(LIST) end
	return self:count(item) > 0
end

function Bot:fits (item)
	item = stack_name(item)
	local inv = self:inv()
	if not item then
		for _, st in ipairs(inv:get_list(LIST) or {}) do
			if st:is_empty() then return true end
		end
		return false
	end
	return can_fit(inv, item)
end

--------------------------------------------------------------------------
-- moving

function Bot:turn (dir)
	local node = self:node_info()
	local front = V.multiply(core.facedir_to_dir(node.param2 % 32), -1)
	local new
	if dir == "left" then new = { x = -front.z, y = 0, z = front.x }
	elseif dir == "right" then new = { x = front.z, y = 0, z = -front.x }
	else new = V.multiply(front, -1) end

	local p2 = core.dir_to_facedir(V.multiply(new, -1))
	core.swap_node(self.pos, { name = node.name, param2 = p2 })
	return true, settings.action_delay
end

-- The liquid source a node stands for (the source itself, or what a flowing
-- liquid belongs to), nil when it is no liquid. Any liquid: water, lava, oil, the
-- chemicals of Skyblock: Zero ...
local function liquid_source (name)
	local def = core.registered_nodes[name]
	if not def or def.liquidtype == nil or def.liquidtype == "none" then return nil end
	if def.liquidtype == "source" then return name end
	return def.liquid_alternative_source
end
S.liquid_source = liquid_source
S.water_source = liquid_source   -- the old name

-- may a robot be in this block: air, plants and the like, a liquid (it is "flooded")
local function passable (pos)
	local node = core.get_node_or_nil(pos)
	if not node or node.name == "ignore" then return false end
	if node.name == "air" then return true end
	local def = core.registered_nodes[node.name]
	if def and def.buildable_to and def.liquidtype == "none" then return true end
	return liquid_source(node.name) ~= nil
end

S.node_passable = passable

-- terrain nobody has loaded (or generated): reads as nil or "ignore"
local function unknown (pos)
	local node = core.get_node_or_nil(pos)
	return node == nil or node.name == "ignore"
end
S.node_unknown = unknown

-- Move the robot node (with everything in it) from one block to the next.
-- A robot in water is "flooded": it remembers the water source of its block,
-- puts that water back when it leaves and picks up the water of the block it
-- enters.
function S.relocate (from, to, node)
	local meta = core.get_meta(from)
	local data = meta:to_table()
	local persistent = meta:get_int("persist") == 1
	local entering = liquid_source(core.get_node(to).name) or ""
	local leaving = data.fields and data.fields.flooded or ""

	if persistent then core.forceload_free_block(from, false) end

	core.set_node(to, node)
	local moved = core.get_meta(to)
	moved:from_table(data)
	moved:set_string("flooded", entering)

	-- removing the old node must not stop the program or free the forceload
	S.moving = true
	if leaving ~= "" then
		core.set_node(from, { name = leaving })
	else
		core.remove_node(from)
	end
	S.moving = false
	core.check_for_falling(from)

	-- the robot you see goes along (before the model is refreshed for the new place)
	S.move_visual(from, to)

	-- the forceload follows the robot; past the server's limit it is lost
	if persistent and core.forceload_block(to, false) == false then
		moved:set_int("persist", 0)
	end

	S.on_robot_moved(from, to)
	S.room_robot_moved(from, to)
	S.editor_robot_moved(from, to)
	S.refresh_structure_timer(to)
	if S.update_infotext then S.update_infotext(to) end
	S.refresh_variant(to)
end

function Bot:move (dir)
	local node = self:node_info()
	local to = V.add(self.pos, dir_vector(self:front_vec(), dir))

	local from = self.pos
	local meta = core.get_meta(from)
	local persistent = meta:get_int("persist") == 1

	-- a forceloaded robot goes into terrain nobody has loaded: load it from
	-- disk now, or have it generated and try again a moment later
	if persistent and unknown(to) then
		core.load_area(to)
		if unknown(to) then
			core.emerge_area(to, to)
			return false, settings.move_delay
		end
	end

	if not passable(to) or self:protected(to) then
		return false, settings.action_delay
	end

	-- not higher above the floor than the upgrades allow
	if not S.move_allowed(from, to, S.height_limit(from), from) then
		return false, settings.action_delay
	end

	S.relocate(from, to, node)

	self.pos = to
	return true, settings.move_delay
end

--------------------------------------------------------------------------
-- digging and placing

function Bot:dig (dir)
	local pos = self:target(dir)
	local node = core.get_node_or_nil(pos)
	if not node or node.name == "air" or node.name == "ignore" then
		return false, settings.action_delay
	end

	local def = core.registered_nodes[node.name]
	if not def or def.diggable == false or S.is_robot(node.name)
		or self:protected(pos) then
		return false, settings.action_delay
	end

	local player = fake_player(self.owner)
	if def.can_dig then
		local ok, res = pcall(def.can_dig, pos, player)
		if ok and res == false then return false, settings.action_delay end
	end

	local meta = core.get_meta(pos)
	local drops = core.get_node_drops(node, compat.dig_tool())
	local oldmeta = meta:to_table()

	if def.preserve_metadata then
		pcall(def.preserve_metadata, pos, node, oldmeta, drops)
	end

	core.remove_node(pos)

	if def.after_dig_node then
		pcall(def.after_dig_node, pos, node, oldmeta, player)
	end

	for _, drop in ipairs(drops) do
		give(self, ItemStack(drop))
	end

	core.check_for_falling(pos)
	return true, settings.action_delay
end

-- the first node item in storage
function Bot:first_placeable ()
	for _, st in ipairs(self:inv():get_list(LIST) or {}) do
		if not st:is_empty() then
			local name = compat.place_substitute(st:get_name())
			if core.registered_nodes[name] then return st:get_name() end
		end
	end
end

function Bot:place (dir, item)
	local pos = self:target(dir)
	item = stack_name(item) or self:first_placeable()
	if not item then return false, settings.action_delay end

	local inv = self:inv()
	local have = ItemStack({ name = item, count = 1 })
	if not inv:contains_item(LIST, have) then return false, settings.action_delay end

	if not passable(pos) or self:protected(pos) then
		return false, settings.action_delay
	end

	local node_name = compat.place_substitute(item)
	local def = core.registered_items[node_name]
	if not core.registered_nodes[node_name] then
		return false, settings.action_delay
	end

	local vdir = V.subtract(pos, self.pos)
	local placer = fake_player(self.owner)
	local pt = { type = "node", under = V.new(self.pos), above = V.new(pos) }
	local placed = false

	if settings.use_on_place and def.on_place and def.on_place ~= core.item_place
		and node_name == item and not placer.is_fake then

		local before = core.get_node(pos).name
		local ok, left = pcall(def.on_place, ItemStack(item), placer, pt)
		if ok then
			placed = core.get_node(pos).name ~= before
		end
	end

	if not placed then
		local p2 = 0
		local pt2 = def.paramtype2
		if pt2 == "wallmounted" or pt2 == "colorwallmounted" then
			-- attached to the robot, like a player pointing at its face
			p2 = core.dir_to_wallmounted(V.multiply(vdir, -1))
		elseif pt2 == "facedir" or pt2 == "colorfacedir" then
			p2 = core.dir_to_facedir(V.multiply(self:front_vec(), -1))
		end

		core.set_node(pos, { name = node_name, param2 = p2 })
		if def.after_place_node then
			pcall(def.after_place_node, pos, placer, ItemStack(item), pt)
		end
		placed = true
	end

	if placed then inv:remove_item(LIST, have) end
	return placed, settings.action_delay
end

function Bot:interact (dir)
	local pos = self:target(dir)
	local node = core.get_node_or_nil(pos)
	local def = node and core.registered_nodes[node.name]
	if not def or self:protected(pos) then return false, settings.action_delay end

	local player = fake_player(self.owner)
	local pt = { type = "node", under = pos, above = self.pos }
	local ok = false

	if def.on_rightclick then
		ok = pcall(def.on_rightclick, pos, node, player, ItemStack(""), pt)
	elseif def.on_punch then
		ok = pcall(def.on_punch, pos, node, player, pt)
	end
	return ok, settings.action_delay
end

--------------------------------------------------------------------------
-- transfers

local PULL_LISTS = { "main", "dst", "output", "storage" }
local PUT_LISTS = { "main", "src", "input", "storage" }

local function container (self, mode)
	local cpos = self:target("front")
	if self:protected(cpos) then return nil end
	local node = core.get_node_or_nil(cpos)
	if not node or S.is_robot(node.name) then return nil end

	local meta = core.get_meta(cpos)
	local inv = meta:get_inventory()
	if not inv then return nil end

	for _, list in ipairs(mode == "pull" and PULL_LISTS or PUT_LISTS) do
		if inv:get_size(list) > 0 then return cpos, inv, list, node end
	end
end

local function notify (cpos, node, callback, list, stack, owner)
	local def = core.registered_nodes[node.name]
	local fn = def and def[callback]
	if fn then pcall(fn, cpos, list, 1, stack, fake_player(owner)) end
end

-- Move stacks matching `item` from src_inv/src_list to dst_inv/dst_list.
-- `limit` is the maximum item count. Returns the number moved.
local function move_items (src_inv, src_list, dst_inv, dst_list, item, limit, on_move)
	local moved = 0

	for i = 1, src_inv:get_size(src_list) do
		if moved >= limit then break end
		local st = src_inv:get_stack(src_list, i)

		if not st:is_empty() and item_matches(st:get_name(), item) then
			local take = ItemStack(st)
			take:set_count(math.min(st:get_count(), limit - moved))
			local left = dst_inv:add_item(dst_list, take)
			local did = take:get_count() - left:get_count()

			if did > 0 then
				take:set_count(did)
				src_inv:remove_item(src_list, take)
				moved = moved + did
				if on_move then on_move(take) end
			end
		end
	end

	return moved
end

function Bot:transfer (verb, item, stack)
	item = stack_name(item)
	local inv = self:inv()
	local delay = settings.action_delay
	local limit

	if item and not item:find("^group:") then
		limit = stack and ItemStack(item):get_stack_max() or 1
	else
		-- no item named: everything; with a group: one, or a stack
		limit = (item and not stack) and 1 or math.huge
		if item and stack then limit = 99 end
	end

	if verb == "pull" or verb == "put" then
		local cpos, cinv, clist, cnode = container(self, verb)
		if not cpos then return false, delay end

		local moved
		if verb == "pull" then
			moved = move_items(cinv, clist, inv, LIST, item, limit, function (st)
				notify(cpos, cnode, "on_metadata_inventory_take", clist, st, self.owner)
			end)
		else
			moved = move_items(inv, LIST, cinv, clist, item, limit, function (st)
				notify(cpos, cnode, "on_metadata_inventory_put", clist, st, self.owner)
			end)
		end
		return moved > 0, delay
	end

	-- drop / trash take from the robot's own storage
	local moved = 0
	local drop_pos = self:target("front")
	if not passable(drop_pos) then drop_pos = V.add(self.pos, { x = 0, y = 1, z = 0 }) end

	for i = 1, inv:get_size(LIST) do
		if moved >= limit then break end
		local st = inv:get_stack(LIST, i)

		if not st:is_empty() and item_matches(st:get_name(), item) then
			local take = ItemStack(st)
			take:set_count(math.min(st:get_count(), limit - moved))
			inv:remove_item(LIST, take)
			moved = moved + take:get_count()
			if verb == "drop" then core.add_item(drop_pos, take) end
		end
	end

	return moved > 0, delay
end

--------------------------------------------------------------------------
-- crafting

-- Find an item in storage for a recipe slot ("name" or "group:x")
local function find_in_storage (inv, want, used)
	for i, st in ipairs(inv:get_list(LIST)) do
		if not st:is_empty() and item_matches(st:get_name(), want) then
			local left = st:get_count() - (used[i] or 0)
			if left > 0 then return i, st:get_name() end
		end
	end
end

local function try_recipe (inv, recipe)
	if recipe.type ~= "normal" and recipe.type ~= nil then return nil end
	local width = recipe.width
	if width == 0 then width = 3 end
	if width > 3 then return nil end

	local used, grid, taken = {}, {}, {}

	-- recipe.items is keyed by grid index (1..9 for width 3)
	local keys = {}
	for k in pairs(recipe.items) do keys[#keys + 1] = k end
	table.sort(keys)

	for _, k in ipairs(keys) do
		local want = recipe.items[k]
		local i, name = find_in_storage(inv, want, used)
		if not i then return nil end
		used[i] = (used[i] or 0) + 1
		taken[#taken + 1] = name
		grid[k] = name
	end

	local list = {}
	local size = recipe.width == 0 and 9 or width * 3
	for k = 1, size do list[k] = grid[k] or "" end

	local result, after
	if recipe.width == 0 then
		-- shapeless: pack ingredients in order
		list = {}
		for _, name in ipairs(taken) do list[#list + 1] = name end
		while #list < 9 do list[#list + 1] = "" end
		result, after = core.get_craft_result({ method = "normal", width = 3, items = list })
	else
		result, after = core.get_craft_result({ method = "normal", width = width, items = list })
	end

	if result and not result.item:is_empty() then
		return result, after, taken
	end
end

function Bot:craft (item)
	item = stack_name(item)
	local delay = settings.action_delay
	if not item then return false, delay end

	local inv = self:inv()
	local recipes = core.get_all_craft_recipes(item)
	if not recipes then return false, delay end

	for _, recipe in ipairs(recipes) do
		local result, after, taken = try_recipe(inv, recipe)

		if result and result.item:get_name() == ItemStack(item):get_name() then
			-- ingredients are consumed, then the results (and replacements) added
			local left = {}
			for _, name in ipairs(taken) do
				left[name] = (left[name] or 0) + 1
			end
			for name, n in pairs(left) do
				inv:remove_item(LIST, ItemStack({ name = name, count = n }))
			end

			give(self, result.item)
			for _, repl in ipairs(result.replacements or {}) do give(self, repl) end
			-- each grid cell held one item: what is left in it (a replacement
			-- such as an empty bucket, or an unused ingredient) is returned
			for _, st in ipairs(after and after.items or {}) do
				if not st:is_empty() then give(self, st) end
			end
			return true, delay
		end
	end

	return false, delay
end

--------------------------------------------------------------------------
-- punching: pick up dropped items, or hit an entity

-- objects around the middle of the block in dir: items, other entities
local function objects_at (pos, hit_players, owner)
	local items, others = {}, {}
	for _, obj in ipairs(core.get_objects_inside_radius(pos, 1.25)) do
		local le = obj:get_luaentity()
		if S.is_visual(obj) then
			-- a robot's own body is nobody to hit
		elseif le and le.name == "__builtin:item" then
			items[#items + 1] = obj
		elseif obj:is_player() then
			-- players are only hit by a robot with the Combat Upgrade (never its owner)
			if hit_players and obj:get_player_name() ~= owner then others[#others + 1] = obj end
		else
			others[#others + 1] = obj
		end
	end
	table.sort(others, function (a, b)
		return V.distance(a:get_pos(), pos) < V.distance(b:get_pos(), pos)
	end)
	return items, others
end

-- name of the nearest entity (not an item or a player) in the block in dir, or ""
function Bot:entity_at (dir)
	local _, others = objects_at(self:target(dir))
	local le = others[1] and others[1]:get_luaentity()
	return le and le.name or ""
end

-- the first stack in storage that is item (or in group:x)
local function find_stack (inv, item)
	for i, st in ipairs(inv:get_list(LIST) or {}) do
		if not st:is_empty() and item_matches(st:get_name(), item) then return i, st end
	end
end

function Bot:punch (dir, item)
	local pos = self:target(dir)
	local delay = settings.action_delay
	if self:protected(pos) then return false, delay end

	item = stack_name(item)
	-- the Combat Upgrade lets it hit players, for its online owner, where pvp is on
	local combat = S.has_upgrade(self.pos, "cogwork:upgrade_combat")
		and core.settings:get_bool("enable_pvp", true) and core.settings:get_bool("enable_damage", true)
		and self.owner ~= nil and core.get_player_by_name(self.owner) ~= nil
	local items, others = objects_at(pos, combat, self.owner)
	-- every Combat Upgrade after the first reaches one block further along dir,
	-- up to the first block in the way or protected one
	local step = dir_vector(self:front_vec(), dir)
	local cell = pos
	for _ = 2, S.combat_count(self.pos) do
		cell = V.add(cell, step)
		if not passable(cell) or self:protected(cell) then break end
		local _, more = objects_at(cell, combat, self.owner)
		for _, obj in ipairs(more) do
			local seen = false
			for _, o in ipairs(others) do if o == obj then seen = true break end end
			if not seen then others[#others + 1] = obj end
		end
	end
	table.sort(others, function (a, b)
		return V.distance(a:get_pos(), self.pos) < V.distance(b:get_pos(), self.pos)
	end)

	-- bare hands: pick up what lies there first
	if not item then
		local got = false
		for _, obj in ipairs(items) do
			local le = obj:get_luaentity()
			local stack = ItemStack(le.itemstring or "")
			if not stack:is_empty() then
				local left = self:inv():add_item(LIST, stack)
				if left:get_count() < stack:get_count() then got = true end
				if left:is_empty() then obj:remove() else le.itemstring = left:to_string() end
			end
		end
		if got then return true, delay end
	end

	local target = others[1]
	if not target then return false, delay end

	local index, stack
	if item then
		index, stack = find_stack(self:inv(), item)
		if not index then return false, delay end
	else
		stack = ItemStack("")
	end

	local caps = stack:get_tool_capabilities()
	local interval = caps.full_punch_interval or 1
	local owner = self.owner and core.get_player_by_name(self.owner)
	target:punch(owner, interval, caps, V.direction(self.pos, target:get_pos()))

	-- a tool wears with every hit
	local uses = caps.punch_attack_uses
	if index and uses and uses > 0 then
		stack:add_wear(math.ceil(65535 / uses))
		self:inv():set_stack(LIST, index, stack)
	end
	return true, math.max(delay, interval)
end

-- Move into the neighbouring block cell (used by pathfinding): up and down,
-- straight on, backwards, or turn first when it is to the side.
function Bot:step_to (cell)
	local d = V.subtract(cell, self.pos)
	if d.y == 1 then return self:move("up") end
	if d.y == -1 then return self:move("down") end

	local f = self:front_vec()
	if V.equals(d, f) then return self:move("forward") end
	if V.equals(d, V.multiply(f, -1)) then return self:move("back") end

	local turned = V.equals(d, { x = f.z, y = 0, z = -f.x }) and "right" or "left"
	local _, turn_delay = self:turn(turned)
	local ok, delay = self:move("forward")
	return ok, turn_delay + (delay or 0)
end

--------------------------------------------------------------------------
-- chat

-- To the owner only, no limits. Public and private messages are in events.lua.
function Bot:chat (text)
	local name = core.get_meta(self.pos):get_string("bot_name")
	if name == "" then name = "Robot" end

	if self.owner and self.owner ~= "" then
		core.chat_send_player(self.owner, "<" .. name .. "> " .. text)
	end
	return true, 0
end

S.Bot = Bot
