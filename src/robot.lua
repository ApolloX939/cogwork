-- The robot node.

local cogwork = ...
local compat, settings = cogwork.compat, cogwork.settings
local S = cogwork.S


function cogwork.can_access (pos, player)
	if not player then return false end
	local name = player:get_player_name()
	local meta = core.get_meta(pos)
	local owner = meta:get_string("owner")
	if owner == "" or owner == name or meta:get_int("public") == 1 then
		return true
	end
	return core.check_player_privs(name, { protection_bypass = true })
end

--------------------------------------------------------------------------
-- forceloading robots, per owner: at most cogwork_max_persist each

local persist_storage = core.get_mod_storage()
local persist_reg = core.deserialize(persist_storage:get_string("persist_reg")) or {}   -- owner -> { hash -> true }

local function persist_save ()
	persist_storage:set_string("persist_reg", core.serialize(persist_reg))
end

function cogwork.persist_register (owner, pos)
	persist_reg[owner] = persist_reg[owner] or {}
	persist_reg[owner][core.hash_node_position(pos)] = true
	persist_save()
end

function cogwork.persist_unregister (owner, pos)
	local list = persist_reg[owner]
	if list and list[core.hash_node_position(pos)] then
		list[core.hash_node_position(pos)] = nil
		if next(list) == nil then persist_reg[owner] = nil end
		persist_save()
	end
end

-- how many robots of owner keep an area loaded (not counting the one at except);
-- registrations of robots that are gone, or no longer forceload, are dropped
function cogwork.persist_count (owner, except)
	local list = persist_reg[owner]
	if not list then return 0 end
	local count, changed = 0, false
	for key in pairs(list) do
		local p = core.get_position_from_hash(key)
		local node = core.get_node_or_nil(p)
		if node and not (cogwork.is_robot(node.name) and core.get_meta(p):get_int("persist") == 1) then
			list[key] = nil
			changed = true
		elseif not (except and vector.equals(p, except)) then
			count = count + 1
		end
	end
	if changed then
		if next(list) == nil then persist_reg[owner] = nil end
		persist_save()
	end
	return count
end

-- Forceloading stops while the owner is offline for cogwork_persist_offline seconds (the
-- robots keep their setting and load their area again when the owner joins).
local suspended = {}          -- owner -> true
local offline_since = {}      -- owner -> time

-- does the robot at pos keep its area loaded now?
function cogwork.persist_active (pos)
	local meta = core.get_meta(pos)
	return meta:get_int("persist") == 1 and not suspended[meta:get_string("owner")]
end

local function persist_each (owner, fn)
	for key in pairs(persist_reg[owner] or {}) do fn(core.get_position_from_hash(key)) end
end

core.register_on_joinplayer(function (player)
	local name = player:get_player_name()
	offline_since[name] = nil
	if suspended[name] then
		suspended[name] = nil
		persist_each(name, function (p) core.forceload_block(p, false) end)
	end
end)

local offline_clock = 0
core.register_globalstep(function (dt)
	offline_clock = offline_clock + dt
	if offline_clock < 5 then return end
	offline_clock = 0
	local now = core.get_us_time() / 1e6
	for owner in pairs(persist_reg) do
		if owner ~= "" and not suspended[owner] then
			if core.get_player_by_name(owner) then
				offline_since[owner] = nil
			else
				offline_since[owner] = offline_since[owner] or now
				if now - offline_since[owner] >= cogwork.settings.persist_offline then
					suspended[owner] = true
					persist_each(owner, function (p) core.forceload_free_block(p, false) end)
				end
			end
		end
	end
end)

-- Returns true, or false and why. The limit does not hold for admins ("server" priv).
function cogwork.set_persist (pos, on)
	local meta = core.get_meta(pos)
	local owner = meta:get_string("owner")
	if on then
		local limit = cogwork.settings.max_persist
		if limit >= 0 and cogwork.persist_count(owner, pos) >= limit
			and not core.check_player_privs(owner, { server = true }) then
			return false, S("You can keep @1 robot(s) loaded at a time.", limit)
		end
		-- false means the limit is reached; nil is "already loaded another way"
		if suspended[owner] then
			-- its owner is away: the setting is kept, the area is not loaded
			meta:set_int("persist", 1)
			cogwork.persist_register(owner, pos)
			return true
		end
		if core.forceload_block(pos, false) ~= false then
			meta:set_int("persist", 1)
			cogwork.persist_register(owner, pos)
			return true
		end
		return false, S("Too many areas are kept loaded already.")
	end
	core.forceload_free_block(pos, false)
	meta:set_int("persist", 0)
	cogwork.persist_unregister(owner, pos)
	return true
end

local function display_name (meta)
	local name = meta:get_string("bot_name")
	local text = name ~= "" and S("Robot: @1", name) or S("Robot")
	if meta:get_string("flooded") ~= "" then text = S("@1 (flooded)", text) end
	return text
end

function cogwork.update_infotext (pos)
	local meta = core.get_meta(pos)
	meta:set_string("infotext", display_name(meta))
end

local function on_construct (pos)
	local meta = core.get_meta(pos)
	local inv = meta:get_inventory()
	inv:set_size("main", cogwork.STORAGE_BASE)
	inv:set_size("disk", 1)
	inv:set_size("upgrades", cogwork.UPGRADE_SLOTS)
	for list, size in pairs(cogwork.STRUCTURE_LISTS) do inv:set_size(list, size) end
	-- a new robot has no armor and no cells: it does not run until it gets them
	meta:set_int("structure_v", 1)
	meta:set_string("infotext", S("Robot"))
end

local function on_destruct (pos)
	if cogwork.moving then return end
	cogwork.room_robot_gone(pos)
	cogwork.stop(pos)
	if core.get_meta(pos):get_int("persist") == 1 then
		core.forceload_free_block(pos, false)
		cogwork.persist_unregister(core.get_meta(pos):get_string("owner"), pos)
	end
	-- last: stopping refreshes the model, which would make a new one
	cogwork.remove_visual(pos)
end

local function after_place_node (pos, placer, itemstack)
	local meta = core.get_meta(pos)
	local imeta = itemstack:get_meta()

	if placer and placer:is_player() then
		meta:set_string("owner", placer:get_player_name())

		-- the robot looks the way the player looks
		local look = placer:get_look_dir()
		look.y = 0
		if vector.length(look) > 0 then
			local p2 = core.dir_to_facedir(vector.multiply(look, -1))
			core.swap_node(pos, { name = "cogwork:robot", param2 = p2 })
		end
	end

	for _, key in ipairs({ "program", "bot_name", "packages", "bot_allow", "room_lock" }) do
		local v = imeta:get_string(key)
		if v ~= "" then meta:set_string(key, v) end
	end
	meta:set_int("public", imeta:get_int("public"))

	-- the room of a robot goes with it
	local room = imeta:get_int("room_id")
	if room > 0 then
		meta:set_int("room_id", room)
		cogwork.room_robot_at(room, pos)
	end

	-- A robot dug up takes everything in it along (storage, armor, cells, augmentation,
	-- upgrades, disk), and puts it back when it is placed.
	local saved = imeta:get_string("inventory")
	local restored = saved ~= "" and cogwork.restore_inventory(pos, saved)

	-- A robot item that was never placed (crafted, /give, creative) comes with a Basic
	-- Armor and a full Small cell. From the first placement on the robot is marked
	-- no_emc, and so is the item it is dug into: it carries parts that cost nothing, so it
	-- must not be turned into EMC, and placing it again gives nothing more.
	if not restored and imeta:get_string("no_emc") ~= "true" then
		local inv = meta:get_inventory()
		inv:set_stack("armor", 1, ItemStack("cogwork:armor_basic"))
		inv:set_stack("cells", 1, ItemStack("cogwork:cell_small"))
	end
	meta:set_string("no_emc", "true")

	meta:set_string("infotext", display_name(meta))
	if restored then
		-- the upgrades decide the model and the storage size, the structure the clock
		cogwork.sync_storage(pos)
		cogwork.refresh_structure_timer(pos)
		cogwork.refresh_variant(pos)
	end

	if imeta:get_int("persist") == 1 then
		local ok, why = cogwork.set_persist(pos, true)
		if not ok and placer and placer:is_player() then core.chat_send_player(placer:get_player_name(), why or "") end
	end
	cogwork.ensure_visual(pos)
end

-- The lists of a robot, to and from a string (an item's metadata). Each stack keeps its
-- own metadata: the charge of a cell, the wear of an armor.
local SAVED_LISTS = { "main", "armor", "armor_mod", "cells", "augment", "upgrades", "disk" }
local MAX_SAVED = 60000          -- longer than this does not fit an item's metadata

local function save_inventory (pos)
	local inv = core.get_meta(pos):get_inventory()
	local saved, empty = {}, true
	for _, list in ipairs(SAVED_LISTS) do
		local items = {}
		for i, stack in ipairs(inv:get_list(list) or {}) do
			items[i] = stack:to_string()
			if not stack:is_empty() then empty = false end
		end
		saved[list] = items
	end
	if empty then return "" end
	local text = core.serialize(saved)
	return #text <= MAX_SAVED and text or nil
end

-- Put a saved inventory in the robot at pos; false when it cannot be read.
function cogwork.restore_inventory (pos, text)
	local saved = core.deserialize(text)
	if type(saved) ~= "table" then return false end
	local inv = core.get_meta(pos):get_inventory()
	for _, list in ipairs(SAVED_LISTS) do
		local items = saved[list]
		if type(items) == "table" then
			if inv:get_size(list) < #items then inv:set_size(list, #items) end
			for i = 1, inv:get_size(list) do
				inv:set_stack(list, i, ItemStack(items[i] or ""))
			end
		end
	end
	return true
end

local carried = {}      -- hash of a position -> its contents went into the item

local function preserve_metadata (pos, oldnode, oldmeta, drops)
	local stack = drops[1]
	if not stack then return end
	local imeta = stack:get_meta()
	local fields = oldmeta.fields or oldmeta

	local saved = save_inventory(pos)
	if saved then
		if saved ~= "" then imeta:set_string("inventory", saved) end
		carried[core.hash_node_position(pos)] = true
	end

	for _, key in ipairs({ "program", "bot_name", "packages", "bot_allow", "room_lock" }) do
		if fields[key] and fields[key] ~= "" then imeta:set_string(key, fields[key]) end
	end
	imeta:set_int("public", tonumber(fields.public) or 0)
	imeta:set_int("persist", tonumber(fields.persist) or 0)
	if fields.no_emc == "true" then imeta:set_string("no_emc", "true") end
	if tonumber(fields.room_id) and tonumber(fields.room_id) > 0 then imeta:set_int("room_id", tonumber(fields.room_id)) end
	if fields.bot_name and fields.bot_name ~= "" then
		imeta:set_string("description", S("Robot: @1", fields.bot_name))
	end
end

local function can_dig (pos, player)
	return cogwork.can_access(pos, player)
end

-- whatever was inside comes out with the robot
local function after_dig_node (pos, oldnode, oldmetadata, digger)
	cogwork.restore_water(pos, oldmetadata and oldmetadata.fields)
	-- the contents went into the item (unless there were too many to fit)
	local key = core.hash_node_position(pos)
	if carried[key] then
		carried[key] = nil
		return
	end
	local lists = oldmetadata and oldmetadata.inventory or {}
	for _, list in pairs(lists) do
		for _, item in pairs(list) do
			local stack = ItemStack(item)
			if not stack:is_empty() then
				local left = stack
				if digger and digger:is_player() then
					left = digger:get_inventory():add_item("main", stack)
				end
				if not left:is_empty() then core.add_item(pos, left) end
			end
		end
	end
end

-- Right-click on the robot (its node, or the entity that is drawn on it, see visual.lua).
-- Returns the itemstack. Sneak + right-click goes into the robot (its room), except
-- with a cassette in hand: that loads the cassette's program.
function cogwork.robot_rightclick (pos, clicker, itemstack)
	if cogwork.acting then return itemstack end
	if not cogwork.can_access(pos, clicker) then
		core.chat_send_player(clicker:get_player_name(), S("This robot belongs to @1.",
			core.get_meta(pos):get_string("owner")))
		return itemstack
	end

	-- an empty bucket takes the water a flooded robot sits in, instead of opening it
	local filled = cogwork.fill_bucket(pos, clicker, itemstack)
	if filled then return filled end

	if clicker:get_player_control().sneak then
		local res = cogwork.cassette_load and cogwork.cassette_load(pos, clicker, itemstack)
		if res then return res end
		if cogwork.settings.rooms then
			cogwork.room_enter(pos, clicker)
			return itemstack
		end
	end

	cogwork.show_editor(pos, clicker)
	return itemstack
end

local function on_rightclick (pos, node, clicker, itemstack, pointed_thing)
	return cogwork.robot_rightclick(pos, clicker, itemstack)
end

-- what a weapon would do to a player: the sum of its damage groups
local function weapon_damage (stack)
	local caps = stack:get_tool_capabilities()
	local total = 0
	for _, v in pairs(caps and caps.damage_groups or {}) do total = total + v end
	return total
end

-- Digging a robot by punching its entity (the engine digs nodes, not entities): the
-- punches of a tool that can dig it add up to the dig time; a pause starts again.
local dig_progress = {}

local function dig_by_punching (pos, node, puncher, tflp)
	local def = core.registered_nodes[node.name]
	local wielded = puncher:get_wielded_item()
	-- the tool or the bare hand, whichever digs it
	local groups = def and def.groups or {}
	local params = core.get_dig_params(groups, wielded:get_tool_capabilities())
	local hand = core.get_dig_params(groups, ItemStack(""):get_tool_capabilities())
	if hand.diggable and (not params.diggable or hand.time < params.time) then
		params, wielded = hand, ItemStack("")
	end
	if not params.diggable then return end

	local key = core.hash_node_position(pos)
	local now = core.get_us_time() / 1e6
	local progress = dig_progress[key]
	if not progress or now - progress.last > 1.5 then progress = { time = 0 } end
	progress.last = now
	progress.time = progress.time + math.min(math.max(tflp or 0, 0.2), 1)
	dig_progress[key] = progress
	if progress.time < params.time then
		-- say how far it is (once a second)
		if now - (progress.said or 0) >= 1 then
			progress.said = now
			core.chat_send_player(puncher:get_player_name(),
				S("Picking up the robot: @1%", math.floor(progress.time / params.time * 100)))
		end
		return
	end

	dig_progress[key] = nil
	if core.is_protected(pos, puncher:get_player_name()) or not can_dig(pos, puncher) then return end
	core.node_dig(pos, node, puncher)
	if not wielded:is_empty() and not core.is_creative_enabled(puncher:get_player_name()) then
		wielded:add_wear(params.wear)
		puncher:set_wielded_item(wielded)
	end
end

-- Pick the robot up (the Settings tab button): as if dug, by anyone who may use it
function cogwork.pick_up (pos, player)
	local node = core.get_node_or_nil(pos)
	if not node or not cogwork.is_robot(node.name) then return false end
	if not can_dig(pos, player) or core.is_protected(pos, player:get_player_name()) then return false end
	return core.node_dig(pos, node, player) ~= false
end

-- Punching the robot (its node, or its entity: then `from_entity` and tflp, the time
-- since the puncher's last punch). Sneak + punch stops a running robot.
function cogwork.robot_punch (pos, puncher, from_entity, tflp)
	if cogwork.acting then return end
	if not puncher or not puncher:is_player() then return end
	local node = core.get_node(pos)

	-- somebody else hitting the robot with a weapon: the armor takes it
	local owner = core.get_meta(pos):get_string("owner")
	if puncher:get_player_name() ~= owner and core.settings:get_bool("enable_damage", true) then
		local wielded = puncher:get_wielded_item()
		local damage = weapon_damage(wielded)
		if damage > 1 and wielded:get_name() ~= "cogwork:cassette" then
			cogwork.damage(pos, damage * cogwork.ARMOR_PER_DAMAGE)
			if cogwork.is_running(pos) and cogwork.cannot_run(pos) then cogwork.stop(pos, cogwork.cannot_run(pos)) end
		end
	end

	if not cogwork.can_access(pos, puncher) then return end

	if puncher:get_player_control().sneak and cogwork.is_running(pos) then
		cogwork.stop(pos, "")
		core.chat_send_player(puncher:get_player_name(), S("Robot stopped."))
		return
	end

	if puncher:get_wielded_item():get_name() == "cogwork:cassette" then
		if cogwork.cassette_save then cogwork.cassette_save(pos, puncher) end
	elseif from_entity then
		dig_by_punching(pos, node, puncher, tflp)
	end
end

local function on_punch (pos, node, puncher, pointed_thing)
	cogwork.robot_punch(pos, puncher, false)
end

-- may this item go in this list of the robot?
local function list_accepts (listname, name)
	if listname == "disk" then return name == "cogwork:disk" end
	if listname == "upgrades" then return cogwork.UPGRADE_ITEMS[name] == true end
	if cogwork.STRUCTURE_LISTS[listname] then return cogwork.structure_accepts(listname, name) end
	return true
end

local function allow_put (pos, listname, index, stack, player)
	if not list_accepts(listname, stack:get_name()) then return 0 end
	return cogwork.can_access(pos, player) and stack:get_count() or 0
end
-- a Storage Upgrade stays while the slots it gives hold items: they would be lost
local function storage_blocked (pos, listname, name, player)
	if listname ~= "upgrades" or not cogwork.storage_removal_blocked(pos, name) then return false end
	if player and player.get_player_name then
		core.chat_send_player(player:get_player_name(), S("Empty the last storage slots first: the Storage Upgrade gives them."))
	end
	return true
end

local function allow_take (pos, listname, index, stack, player)
	if storage_blocked(pos, listname, stack:get_name(), player) then return 0 end
	return cogwork.can_access(pos, player) and stack:get_count() or 0
end
local function allow_move (pos, from_list, from_index, to_list, to_index, count, player)
	local moved = core.get_meta(pos):get_inventory():get_stack(from_list, from_index):get_name()
	if not list_accepts(to_list, moved) then return 0 end
	if to_list ~= "upgrades" and storage_blocked(pos, from_list, moved, player) then return 0 end
	return cogwork.can_access(pos, player) and count or 0
end

-- a part put in or taken out: a Flight Upgrade changes how the robot looks, the
-- structure lists change what it can do (and may stop it)
local function inventory_changed (pos, listname)
	if listname == "upgrades" then
		cogwork.refresh_variant(pos)
		cogwork.sync_storage(pos)
	end
	cogwork.structure_changed(pos, listname)
	-- an editor open on the robot shows what is in the slots now
	cogwork.editor_refresh(pos)
end
local function on_inventory_put (pos, listname) inventory_changed(pos, listname) end
local function on_inventory_take (pos, listname) inventory_changed(pos, listname) end
local function on_inventory_move (pos, from_list, from_index, to_list)
	inventory_changed(pos, from_list)
	inventory_changed(pos, to_list)
end

local function register (name, on, model)
	local def = {
		description = S("Robot"),
		short_description = S("Robot"),
		_tt_help = S("A programmable robot"),
		-- drawn by the robot's visual entity (visual.lua), the node is its invisible body
		drawtype = "airlike",
		inventory_image = "cogwork_robot_inv.png",
		wield_image = "cogwork_robot_inv.png",
		-- what you point at is the entity (visual.lua), shaped like the model; this tiny
		-- box in the middle is only reached when the entity is missing
		selection_box = { type = "fixed", fixed = { -0.05, -0.05, -0.05, 0.05, 0.05, 0.05 } },
		collision_box = { type = "fixed", fixed = cogwork.MODEL_BOXES[model] },
		sunlight_propagates = true,
		paramtype = "light",
		paramtype2 = "facedir",
		light_source = on and 4 or 0,
		groups = compat.robot_groups(on and { not_in_creative_inventory = 1 } or nil),
		sounds = compat.metal_sounds(),
		drop = "cogwork:robot",
		is_ground_content = false,

		on_construct = on_construct,
		on_destruct = on_destruct,
		after_place_node = after_place_node,
		preserve_metadata = preserve_metadata,
		can_dig = can_dig,
		after_dig_node = after_dig_node,
		on_rightclick = on_rightclick,
		on_punch = on_punch,
		allow_metadata_inventory_put = allow_put,
		allow_metadata_inventory_take = allow_take,
		allow_metadata_inventory_move = allow_move,
		on_timer = function (pos) return cogwork.structure_tick(pos) end,
		on_metadata_inventory_put = on_inventory_put,
		on_metadata_inventory_take = on_inventory_take,
		on_metadata_inventory_move = on_inventory_move,
	}

	if on or model ~= "robot" then def.groups.not_in_creative_inventory = 1 end
	core.register_node(name, def)
end

register("cogwork:robot", false, "robot")
register("cogwork:robot_on", true, "robot")
register("cogwork:hover", false, "hover")
register("cogwork:hover_on", true, "hover")
register("cogwork:drone", false, "drone")
register("cogwork:drone_on", true, "drone")
