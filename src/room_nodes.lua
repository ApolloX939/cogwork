-- The blocks inside a robot's room (see rooms.lua). None can be dug or placed.
--
--   exit        the door: out next to the robot
--   chest       the robot's own storage (the editor's Storage tab)
--   bay         armor, cells, augmentation and upgrades (the Structure tab)
--   terminal    the program (the Program tab): program a robot in peace
--   waypoints   the Waypoints tab: save the robot's place and facing, remove waypoints
--   settings    the Settings tab: name, public, allow list and the entrance lock
--   controller  drive the robot with the keys (control.lua); sneak: the buttons
--   camera      turn and tilt the viewscreen's camera with the keys
-- The screen (an entity) is drawn in front of the screen panels; see viewscreen.lua.

local cogwork = ...
local S = cogwork.S
local compat = cogwork.compat
local esc = core.formspec_escape

local function register (name, def)
	def.groups = def.groups or {}
	def.groups.not_in_creative_inventory = 1
	def.diggable = false
	def.is_ground_content = false
	def.sounds = compat.metal_sounds()
	def.on_blast = function () end
	core.register_node("cogwork:room_" .. name, def)
end

local function tex (name) return "cogwork_room_" .. name .. ".png" end

-- the plain parts
register("wall", { description = S("Robot hull"), tiles = { tex("wall") } })
register("floor", { description = S("Robot floor"), tiles = { tex("floor"), tex("wall"), tex("wall") } })
register("light", { description = S("Robot light"), tiles = { tex("light") }, light_source = 14, paramtype = "light" })
register("frame", { description = S("Screen frame"), tiles = { tex("frame") } })
register("screen", { description = S("Screen panel"), tiles = { tex("screen") }, light_source = 6, paramtype = "light" })
register("console", { description = S("Console"), tiles = { tex("console_top"), tex("wall"), tex("console") } })

--------------------------------------------------------------------------
-- helpers

local function robot_of (pos, player)
	local id = cogwork.room_at(pos)
	local rp = id and cogwork.room_robot(id)
	if not rp then
		core.chat_send_player(player:get_player_name(), S("The robot is not there."))
		return nil
	end
	if not cogwork.can_access(rp, player) then
		core.chat_send_player(player:get_player_name(), S("This robot belongs to @1.", core.get_meta(rp):get_string("owner")))
		return nil
	end
	return rp, id
end

-- the editor of the robot, at a tab
local function open_editor (tab)
	return function (pos, node, player)
		local rp = robot_of(pos, player)
		if not rp then return end
		local s = cogwork.editor_session(player)
		s.tab = tab
		s.msg = ""
		cogwork.show_editor(rp, player)
	end
end

register("exit", {
	description = S("Door"), tiles = { tex("exit") },
	on_rightclick = function (pos, node, player) cogwork.room_exit(player) end,
	on_punch = function (pos, node, player) cogwork.room_exit(player) end,
})
register("chest", {
	description = S("Robot storage"), tiles = { tex("chest_top"), tex("wall"), tex("chest") },
	on_rightclick = open_editor("storage"),
})
register("bay", {
	description = S("Structure bay"), tiles = { tex("wall"), tex("wall"), tex("bay") },
	on_rightclick = open_editor("structure"),
})
register("terminal", {
	description = S("Program terminal"), tiles = { tex("terminal_top"), tex("wall"), tex("terminal") },
	on_rightclick = open_editor("program"),
})

register("waypoints", {
	description = S("Waypoint manager"), tiles = { tex("waypoints_top"), tex("wall"), tex("waypoints") },
	on_rightclick = open_editor("waypoints"),
})
register("settings", {
	description = S("Settings panel"), tiles = { tex("settings_top"), tex("wall"), tex("settings") },
	on_rightclick = open_editor("settings"),
})

--------------------------------------------------------------------------
-- the controller

local FORM = "cogwork:room_ctl"
local MOVES = {
	ctl_fwd = { "move", "forward" }, ctl_back = { "move", "back" },
	ctl_up = { "move", "up" }, ctl_down = { "move", "down" },
	ctl_left = { "turn", "left" }, ctl_right = { "turn", "right" }, ctl_around = { "turn", "around" },
}
local COST = { move = 1, turn = 0.5 }
local next_ok = {}

-- One move or turn of the robot of room id, for the buttons and for the keys (control.lua).
-- Returns the robot's position now and a complaint, if any.
function cogwork.drive_robot (rp, id, kind, dir)
	if cogwork.is_running(rp) then return rp, S("Stop the program first.") end
	cogwork.mark_controlled(id)
	local now = core.get_us_time() / 1e6
	local why = cogwork.cannot_run(rp)
	if why then return rp, why end
	if (next_ok[id] or 0) > now then return rp end
	if not cogwork.spend(rp, COST[kind]) then return rp, S("Out of power.") end

	local bot = cogwork.Bot.new(rp, core.get_meta(rp):get_string("owner"))
	local ok, delay = bot[kind](bot, dir)
	next_ok[id] = now + (delay or 0.2)
	return bot.pos, (not ok) and S("Something is in the way.") or nil
end

local function controller_form (rp)
	local meta = core.get_meta(rp)
	local running = cogwork.is_running(rp)
	local name = meta:get_string("bot_name")
	local charge, capacity = cogwork.charge_of(rp)
	local power = capacity > 0 and math.floor(charge / capacity * 100 + 0.5) or 0
	local armor = cogwork.armor_info(core.get_meta(rp):get_inventory():get_stack("armor", 1))
	local why = cogwork.cannot_run(rp)

	local fs = {
		"formspec_version[6]", "size[11,9]", "bgcolor[#1c1c24f0;true]",
		("label[0.5,0.6;%s]"):format(esc(S("Robot controller") .. (name ~= "" and (": " .. name) or ""))),
		("label[0.5,1.1;%s]"):format(esc(S("At @1, power @2%", core.pos_to_string(rp), power))),
		("label[0.5,1.6;%s]"):format(esc(running and S("Running its program: stop it to drive.") or (why or S("Ready.")))),
		("button[4.0,2.2;3,1;ctl_fwd;%s]"):format(esc(S("Forward"))),
		("button[0.5,3.5;3,1;ctl_left;%s]"):format(esc(S("Turn left"))),
		("button[4.0,3.5;3,1;ctl_around;%s]"):format(esc(S("Turn around"))),
		("button[7.5,3.5;3,1;ctl_right;%s]"):format(esc(S("Turn right"))),
		("button[4.0,4.8;3,1;ctl_back;%s]"):format(esc(S("Back"))),
		("button[0.5,2.2;3,1;ctl_up;%s]"):format(esc(S("Up"))),
		("button[0.5,4.8;3,1;ctl_down;%s]"):format(esc(S("Down"))),
		("button[7.5,2.2;3,1;ctl_power;%s]"):format(esc(running and S("Stop the program") or S("Run the program"))),
		("button[7.5,4.8;3,1;ctl_keys;%s]"):format(esc(S("Drive with the keys"))),
		("checkbox[0.5,6.1;ctl_fly;%s;%s]"):format(esc(S("Fly mode: no falling while controlled")), core.get_meta(rp):get_int("control_fly") == 1 and "true" or "false"),
		("label[0.5,7.0;%s]"):format(esc(S("Keys: W S forward and back, A D turn, Space up, Shift down; hold both to stop.\nMoves cost power like the program's, and the height limit holds."))),
		("label[0.5,8.2;%s]"):format(esc(armor and S("Armor: @1", math.floor(armor)) or S("No armor"))),
	}
	return table.concat(fs)
end

register("controller", {
	description = S("Robot controller"), tiles = { tex("ctl_top"), tex("wall"), tex("ctl") },
	on_rightclick = function (pos, node, player)
		local rp = robot_of(pos, player)
		if rp then core.show_formspec(player:get_player_name(), FORM, controller_form(rp)) end
	end,
})

--------------------------------------------------------------------------
-- the camera controller

local CAMFORM = "cogwork:room_cam"
local CAMERA_STEP = 15      -- degrees a button turns the camera

local function camera_form (rp)
	local yaw, pitch = cogwork.camera_get(rp)
	return table.concat({
		"formspec_version[6]", "size[11,7.4]", "bgcolor[#1c1c24f0;true]",
		("label[0.5,0.6;%s]"):format(esc(S("Camera controller"))),
		("label[0.5,1.1;%s]"):format(esc(S("Turned @1, tilted @2 degrees", math.floor(yaw + 0.5), math.floor(pitch + 0.5)))),
		("button[4.0,1.8;3,1;cam_up;%s]"):format(esc(S("Look up"))),
		("button[0.5,3.1;3,1;cam_left;%s]"):format(esc(S("Turn left"))),
		("button[4.0,3.1;3,1;cam_center;%s]"):format(esc(S("To the front"))),
		("button[7.5,3.1;3,1;cam_right;%s]"):format(esc(S("Turn right"))),
		("button[4.0,4.4;3,1;cam_down;%s]"):format(esc(S("Look down"))),
		("button[7.5,1.8;3,1;cam_keys;%s]"):format(esc(S("Move it with the keys"))),
		("label[0.5,5.8;%s]"):format(esc(S("Keys: A D turn the camera, W S tilt it, Space to the front;\nhold Space and Shift to stop."))),
	})
end

register("camera", {
	description = S("Camera controller"), tiles = { tex("cam_top"), tex("wall"), tex("cam") },
	on_rightclick = function (pos, node, player)
		local rp = robot_of(pos, player)
		if rp then core.show_formspec(player:get_player_name(), CAMFORM, camera_form(rp)) end
	end,
})

core.register_on_player_receive_fields(function (player, formname, fields)
	if formname ~= CAMFORM then return end
	local id = cogwork.room_of_player(player)
	local rp = id and cogwork.room_robot(id)
	if not rp or not cogwork.can_access(rp, player) then return true end

	if fields.cam_keys then
		core.close_formspec(player:get_player_name(), CAMFORM)
		cogwork.control_start(player, "camera", id)
		return true
	end
	local yaw, pitch = cogwork.camera_get(rp)
	if fields.cam_left then yaw = yaw - CAMERA_STEP
	elseif fields.cam_right then yaw = yaw + CAMERA_STEP
	elseif fields.cam_up then pitch = pitch + CAMERA_STEP
	elseif fields.cam_down then pitch = pitch - CAMERA_STEP
	elseif fields.cam_center then yaw, pitch = 0, 0
	end
	cogwork.camera_set(rp, id, yaw, pitch)

	if not fields.quit then
		core.show_formspec(player:get_player_name(), CAMFORM, camera_form(rp))
	end
	return true
end)

core.register_on_player_receive_fields(function (player, formname, fields)
	if formname ~= FORM then return end
	local id = cogwork.room_of_player(player)
	local rp = id and cogwork.room_robot(id)
	if not rp or not cogwork.can_access(rp, player) then return true end
	local name = player:get_player_name()

	if fields.ctl_fly ~= nil then
		core.get_meta(rp):set_int("control_fly", fields.ctl_fly == "true" and 1 or 0)
		if fields.ctl_fly ~= "true" then cogwork.settle_later(rp) end
	end

	if fields.ctl_keys then
		core.close_formspec(name, FORM)
		cogwork.control_start(player, "drive", id)
		return true
	end

	if fields.ctl_power then
		if cogwork.is_running(rp) then
			cogwork.stop(rp, "")
		else
			local ok, err = cogwork.start(rp)
			if not ok then core.chat_send_player(name, err or "") end
		end
	end

	for button, move in pairs(MOVES) do
		if fields[button] then
			local at, complaint = cogwork.drive_robot(rp, id, move[1], move[2])
			rp = at
			if complaint then core.chat_send_player(name, complaint) end
		end
	end

	if not fields.quit then
		core.show_formspec(name, FORM, controller_form(rp))
	end
	return true
end)
