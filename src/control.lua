-- Controlling a robot from inside it with the keys (the controller and the camera
-- controller of the room, see room_nodes.lua).
--
--   drive    W forward, S back, A turn left, D turn right, Space up, Shift down
--   camera   A and D turn the camera, W and S tilt it, Space puts it back to the front
--
-- Hold Space and Shift together for a moment to stop controlling. The player is held
-- in place while it lasts (physics speed and jump 0), a line on the screen says what
-- the keys do. Fly mode (set on the controller): the robot does not fall while it is
-- being controlled.

local cogwork = ...
local S = cogwork.S

local HOLD = 0.6            -- seconds of Space + Shift that stop it
local CAMERA_RATE = 70      -- degrees a second
local MAX_PITCH = 85
local FLY_GRACE = 20        -- seconds a robot stays up after the last control

local states = {}           -- player name -> state

--------------------------------------------------------------------------
-- fly mode

local controlled_until = {}  -- room id -> time

-- the robot of room id is being controlled (it is held up now, if fly mode is on)
function cogwork.mark_controlled (id)
	local now = core.get_us_time() / 1e6
	local fresh = (controlled_until[id] or 0) <= now
	controlled_until[id] = now + FLY_GRACE
	if fresh then
		-- when the grace is over the robot may fall
		core.after(FLY_GRACE + 0.5, function ()
			local rp = cogwork.room_robot(id)
			if rp then cogwork.settle_later(rp) end
		end)
	end
end

-- is the robot at pos held up by fly mode? (called by gravity.lua)
function cogwork.fly_held (pos)
	local meta = core.get_meta(pos)
	if meta:get_int("control_fly") ~= 1 then return false end
	local id = meta:get_int("room_id")
	return id > 0 and (controlled_until[id] or 0) > core.get_us_time() / 1e6
end

--------------------------------------------------------------------------
-- the camera

function cogwork.camera_set (rp, id, yaw, pitch)
	yaw = ((yaw + 180) % 360) - 180
	pitch = math.max(-MAX_PITCH, math.min(MAX_PITCH, pitch))
	local meta = core.get_meta(rp)
	meta:set_float("view_yaw", yaw)
	meta:set_float("view_pitch", pitch)
	cogwork.view_poke(id)
	return yaw, pitch
end

function cogwork.camera_get (rp)
	local meta = core.get_meta(rp)
	return meta:get_float("view_yaw"), meta:get_float("view_pitch")
end

--------------------------------------------------------------------------
-- starting and stopping

local function show (player, st, text)
	if st.hud then
		player:hud_change(st.hud, "text", text)
	else
		st.hud = player:hud_add({
			hud_elem_type = "text", position = { x = 0.5, y = 0.88 }, offset = { x = 0, y = 0 },
			text = text, number = 0xFFFFFF, alignment = { x = 0, y = 0 },
		})
	end
end

function cogwork.control_stop (player, why)
	local name = type(player) == "string" and player or player:get_player_name()
	local st = states[name]
	if not st then return false end
	states[name] = nil
	player = core.get_player_by_name(name)
	if player then
		player:set_physics_override({ speed = st.saved.speed, jump = st.saved.jump })
		if st.hud then player:hud_remove(st.hud) end
		if why then core.chat_send_player(name, why) end
	end
	local rp = cogwork.room_robot(st.id)
	if rp then cogwork.settle_later(rp) end
	return true
end

function cogwork.is_controlling (player)
	return states[player:get_player_name()] ~= nil
end

function cogwork.control_start (player, kind, id)
	local name = player:get_player_name()
	cogwork.control_stop(player)
	local rp = cogwork.room_robot(id)
	if not rp or not cogwork.can_access(rp, player) or cogwork.room_of_player(player) ~= id then return false end
	if kind == "drive" and cogwork.is_running(rp) then
		core.chat_send_player(name, S("Stop the program first."))
		return false
	end

	local po = player:get_physics_override()
	states[name] = { kind = kind, id = id, hold = 0, saved = { speed = po.speed, jump = po.jump }, hud_time = 0 }
	player:set_physics_override({ speed = 0, jump = 0 })
	if kind == "drive" then cogwork.mark_controlled(id) end
	core.chat_send_player(name, kind == "drive"
		and S("Controlling the robot: W S forward and back, A D turn, Space up, Shift down. Hold Space and Shift to stop.")
		or S("Controlling the camera: A D turn it, W S tilt it, Space to the front. Hold Space and Shift to stop."))
	return true
end

--------------------------------------------------------------------------
-- the keys

local function status (st, rp)
	if st.kind == "camera" then
		local yaw, pitch = cogwork.camera_get(rp)
		return S("Camera: turned @1, tilted @2 (hold Space + Shift to stop)", math.floor(yaw + 0.5), math.floor(pitch + 0.5))
	end
	local charge, capacity = cogwork.charge_of(rp)
	local power = capacity > 0 and math.floor(charge / capacity * 100 + 0.5) or 0
	local fly = core.get_meta(rp):get_int("control_fly") == 1 and (" - " .. S("fly mode")) or ""
	return S("Robot at @1, power @2%", core.pos_to_string(rp), power) .. fly .. " (" .. S("hold Space + Shift to stop") .. ")"
end

-- one step of the keys for the controlling player (st: its state, ctl: its keys)
function cogwork.control_step (player, st, ctl, dt)
	if ctl.jump and ctl.sneak then
		st.hold = st.hold + dt
		if st.hold >= HOLD then
			st.stopped = true
			cogwork.control_stop(player, S("You let go of the controls."))
		end
		return
	end
	st.hold = 0

	local rp = cogwork.room_robot(st.id)
	if not rp then
		cogwork.control_stop(player, S("The robot is not there."))
		return
	end

	if st.kind == "camera" then
		local yaw, pitch = cogwork.camera_get(rp)
		local moved = false
		if ctl.left or ctl.right or ctl.up or ctl.down then
			yaw = yaw + ((ctl.right and 1 or 0) - (ctl.left and 1 or 0)) * CAMERA_RATE * dt
			pitch = pitch + ((ctl.up and 1 or 0) - (ctl.down and 1 or 0)) * CAMERA_RATE * dt
			moved = true
		elseif ctl.jump then
			yaw, pitch, moved = 0, 0, (yaw ~= 0 or pitch ~= 0)
		end
		if moved then cogwork.camera_set(rp, st.id, yaw, pitch) end
	else
		cogwork.mark_controlled(st.id)
		local kind, dir
		if ctl.up then kind, dir = "move", "forward"
		elseif ctl.down then kind, dir = "move", "back"
		elseif ctl.left then kind, dir = "turn", "left"
		elseif ctl.right then kind, dir = "turn", "right"
		elseif ctl.jump then kind, dir = "move", "up"
		elseif ctl.sneak then kind, dir = "move", "down"
		end
		if kind then
			local _, complaint = cogwork.drive_robot(rp, st.id, kind, dir)
			local now = core.get_us_time() / 1e6
			if complaint and (st.complained ~= complaint or now - (st.complained_at or 0) > 2) then
				st.complained, st.complained_at = complaint, now
				core.chat_send_player(player:get_player_name(), complaint)
			end
			rp = cogwork.room_robot(st.id) or rp
		end
	end

	st.hud_time = st.hud_time - dt
	if st.hud_time <= 0 then
		st.hud_time = 0.25
		show(player, st, status(st, rp))
	end
end

core.register_globalstep(function (dt)
	for name, st in pairs(states) do
		local player = core.get_player_by_name(name)
		if not player or cogwork.room_of_player(player) ~= st.id then
			states[name] = nil
			if player then
				player:set_physics_override({ speed = st.saved.speed, jump = st.saved.jump })
				if st.hud then player:hud_remove(st.hud) end
			end
		else
			cogwork.control_step(player, st, player:get_player_control(), dt)
		end
	end
end)

core.register_on_leaveplayer(function (player)
	states[player:get_player_name()] = nil
end)
