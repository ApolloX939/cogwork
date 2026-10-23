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

function cogwork.set_persist (pos, on)
	local meta = core.get_meta(pos)
	if on then
		-- false means the limit is reached; nil is "already loaded another way"
		if core.forceload_block(pos, false) ~= false then
			meta:set_int("persist", 1)
			return true
		end
		return false
	end
	core.forceload_free_block(pos, false)
	meta:set_int("persist", 0)
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

	-- A robot item that was never placed (crafted, /give, creative) comes with a Basic
	-- Armor and a full Small cell. From the first placement on the robot is marked
	-- no_emc, and so is the item it is dug into: it carries parts that cost nothing, so it
	-- must not be turned into EMC, and placing it again gives nothing more.
	if imeta:get_string("no_emc") ~= "true" then
		local inv = meta:get_inventory()
		inv:set_stack("armor", 1, ItemStack("cogwork:armor_basic"))
		inv:set_stack("cells", 1, ItemStack("cogwork:cell_small"))
	end
	meta:set_string("no_emc", "true")

	meta:set_string("infotext", display_name(meta))

	if imeta:get_int("persist") == 1 then cogwork.set_persist(pos, true) end
	cogwork.ensure_visual(pos)
end

local function preserve_metadata (pos, oldnode, oldmeta, drops)
	local stack = drops[1]
	if not stack then return end
	local imeta = stack:get_meta()
	local fields = oldmeta.fields or oldmeta

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
	local params = core.get_dig_params(def and def.groups or {}, wielded:get_tool_capabilities())
	if not params.diggable then return end

	local key = core.hash_node_position(pos)
	local now = core.get_us_time() / 1e6
	local progress = dig_progress[key]
	if not progress or now - progress.last > 1.5 then progress = { time = 0 } end
	progress.last = now
	progress.time = progress.time + math.min(math.max(tflp or 0, 0.2), 1)
	dig_progress[key] = progress
	if progress.time < params.time then return end

	dig_progress[key] = nil
	if core.is_protected(pos, puncher:get_player_name()) or not can_dig(pos, puncher) then return end
	core.node_dig(pos, node, puncher)
	if not core.is_creative_enabled(puncher:get_player_name()) then
		wielded:add_wear(params.wear)
		puncher:set_wielded_item(wielded)
	end
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
