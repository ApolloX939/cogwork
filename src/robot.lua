-- The robot node.

local S = ...
local compat, settings = S.compat, S.settings
local T = S.S

local STORAGE = 32

function S.can_access (pos, player)
	if not player then return false end
	local name = player:get_player_name()
	local meta = core.get_meta(pos)
	local owner = meta:get_string("owner")
	if owner == "" or owner == name or meta:get_int("public") == 1 then
		return true
	end
	return core.check_player_privs(name, { protection_bypass = true })
end

function S.set_persist (pos, on)
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
	if name ~= "" then return T("Robot: @1", name) end
	return T("Robot")
end

local function on_construct (pos)
	local meta = core.get_meta(pos)
	local inv = meta:get_inventory()
	inv:set_size("main", STORAGE)
	inv:set_size("disk", 1)
	meta:set_string("infotext", T("Robot"))
end

local function on_destruct (pos)
	if S.moving then return end
	S.stop(pos)
	if core.get_meta(pos):get_int("persist") == 1 then
		core.forceload_free_block(pos, false)
	end
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

	for _, key in ipairs({ "program", "bot_name", "packages", "bot_allow" }) do
		local v = imeta:get_string(key)
		if v ~= "" then meta:set_string(key, v) end
	end
	meta:set_int("public", imeta:get_int("public"))
	meta:set_string("infotext", display_name(meta))

	if imeta:get_int("persist") == 1 then S.set_persist(pos, true) end
end

local function preserve_metadata (pos, oldnode, oldmeta, drops)
	local stack = drops[1]
	if not stack then return end
	local imeta = stack:get_meta()
	local fields = oldmeta.fields or oldmeta

	for _, key in ipairs({ "program", "bot_name", "packages", "bot_allow" }) do
		if fields[key] and fields[key] ~= "" then imeta:set_string(key, fields[key]) end
	end
	imeta:set_int("public", tonumber(fields.public) or 0)
	imeta:set_int("persist", tonumber(fields.persist) or 0)
	if fields.bot_name and fields.bot_name ~= "" then
		imeta:set_string("description", T("Robot: @1", fields.bot_name))
	end
end

local function can_dig (pos, player)
	return S.can_access(pos, player)
end

-- whatever was inside comes out with the robot
local function after_dig_node (pos, oldnode, oldmetadata, digger)
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

local function on_rightclick (pos, node, clicker, itemstack, pointed_thing)
	if S.acting then return itemstack end
	if not S.can_access(pos, clicker) then
		core.chat_send_player(clicker:get_player_name(), T("This robot belongs to @1.",
			core.get_meta(pos):get_string("owner")))
		return itemstack
	end

	local held = itemstack:get_name()
	if clicker:get_player_control().sneak then
		local res = S.cassette_load and S.cassette_load(pos, clicker, itemstack)
		if res then return res end
	end

	S.show_editor(pos, clicker)
	return itemstack
end

local function on_punch (pos, node, puncher, pointed_thing)
	if S.acting then return end
	if not puncher or not S.can_access(pos, puncher) then return end

	if puncher:get_player_control().sneak and S.is_running(pos) then
		S.stop(pos, "")
		core.chat_send_player(puncher:get_player_name(), T("Robot stopped."))
		return
	end

	if S.cassette_save then S.cassette_save(pos, puncher) end
end

local function allow_put (pos, listname, index, stack, player)
	if listname == "disk" and stack:get_name() ~= "cogwork:disk" then return 0 end
	return S.can_access(pos, player) and stack:get_count() or 0
end
local function allow_take (pos, listname, index, stack, player)
	return S.can_access(pos, player) and stack:get_count() or 0
end
local function allow_move (pos, from_list, from_index, to_list, to_index, count, player)
	return S.can_access(pos, player) and count or 0
end

local function register (name, on)
	local def = {
		description = T("Robot"),
		short_description = T("Robot"),
		_tt_help = T("A programmable robot"),
		drawtype = "mesh",
		mesh = "cogwork_robot.obj",
		tiles = {
			"cogwork_metal.png", on and "cogwork_face_on.png" or "cogwork_face.png",
			"cogwork_tread.png", "cogwork_accent.png", "cogwork_back.png",
		},
		inventory_image = "cogwork_robot_inv.png",
		wield_image = "cogwork_robot_inv.png",
		selection_box = { type = "fixed", fixed = { -0.5, -0.5, -0.5, 0.5, 0.5, 0.5 } },
		collision_box = { type = "fixed", fixed = { -0.5, -0.5, -0.5, 0.5, 0.5, 0.5 } },
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
	}

	if on then def.groups.not_in_creative_inventory = 1 end
	core.register_node(name, def)
end

register("cogwork:robot", false)
register("cogwork:robot_on", true)
