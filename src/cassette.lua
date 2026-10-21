-- Cassettes carry a whole program, package disks carry a library.

local S = ...
local T = S.S
local esc = core.formspec_escape

local CASSETTE = "cogwork:cassette"
local DISK = "cogwork:disk"

core.register_craftitem(CASSETTE, {
	description = T("Robot Cassette"),
	short_description = T("Robot Cassette"),
	_tt_help = T("Punch a robot to copy its program, sneak + right-click a robot to load it"),
	inventory_image = "cogwork_cassette.png",
	stack_max = 1,
	groups = { flammable = 1 },

	on_secondary_use = function (itemstack, user)
		if not user or not user:is_player() then return end
		local meta = itemstack:get_meta()
		local fs = "formspec_version[6]size[8,4.4]"
			.. "field[0.5,0.8;7,0.8;label;" .. esc(T("Label")) .. ";" .. esc(meta:get_string("label")) .. "]"
			.. "checkbox[0.5,2.3;readonly;" .. esc(T("Read only")) .. ";" .. (meta:get_int("readonly") == 1 and "true" or "false") .. "]"
			.. "button_exit[5,3.2;2.5,0.8;save;" .. esc(T("Save")) .. "]"
		core.show_formspec(user:get_player_name(), "cogwork:cassette", fs)
		return itemstack
	end,
})

core.register_on_player_receive_fields(function (player, formname, fields)
	if formname ~= "cogwork:cassette" then return end
	local stack = player:get_wielded_item()
	if stack:get_name() ~= CASSETTE then return true end

	local meta = stack:get_meta()
	if fields.label then
		meta:set_string("label", fields.label:sub(1, 40))
		local label = meta:get_string("label")
		meta:set_string("description", label ~= "" and T("Robot Cassette: @1", label) or T("Robot Cassette"))
	end
	if fields.readonly ~= nil then
		meta:set_int("readonly", fields.readonly == "true" and 1 or 0)
	end
	player:set_wielded_item(stack)
	return true
end)

-- punch: robot -> cassette
function S.cassette_save (pos, player)
	local stack = player:get_wielded_item()
	if stack:get_name() ~= CASSETTE then return end

	local name = player:get_player_name()
	local meta = stack:get_meta()
	if meta:get_int("readonly") == 1 and meta:get_string("program") ~= "" then
		core.chat_send_player(name, T("The cassette is read only."))
		return
	end

	local program = S.get_program(pos)
	meta:set_string("program", program)
	meta:set_string("packages", core.get_meta(pos):get_string("packages"))
	player:set_wielded_item(stack)
	core.chat_send_player(name, T("Program copied to the cassette."))
end

-- sneak + right-click: cassette -> robot
function S.cassette_load (pos, player, itemstack)
	if itemstack:get_name() ~= CASSETTE then return nil end
	local name = player:get_player_name()
	local program = itemstack:get_meta():get_string("program")

	if program == "" then
		core.chat_send_player(name, T("The cassette is empty."))
		return itemstack
	end

	S.stop(pos, "")
	local meta = core.get_meta(pos)
	meta:set_string("program", program)
	meta:set_string("packages", itemstack:get_meta():get_string("packages"))
	meta:set_string("error", "")
	core.chat_send_player(name, T("Program loaded from the cassette."))
	return itemstack
end

--------------------------------------------------------------------------
-- package disks

core.register_craftitem(DISK, {
	description = T("Package Disk"),
	short_description = T("Package Disk"),
	_tt_help = T("Holds a library of functions to install in a robot"),
	inventory_image = "cogwork_disk.png",
	stack_max = 1,
})

-- Write a package onto the disk in a robot's disk slot (replaces what it held)
function S.write_disk (inv, name, source)
	local stack = inv:get_stack("disk", 1)
	if stack:get_name() ~= DISK then return false end
	local meta = stack:get_meta()
	meta:set_string("package", name)
	meta:set_string("source", source)
	meta:set_string("description", T("Package Disk: @1", name))
	inv:set_stack("disk", 1, stack)
	return true
end

function S.read_disk (stack)
	if stack:get_name() ~= DISK then return nil end
	local meta = stack:get_meta()
	local name, source = meta:get_string("package"), meta:get_string("source")
	if name == "" or source == "" then return nil end
	return name, source
end
