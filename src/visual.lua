-- The robot you see: an entity on top of the robot node.
--
-- The node is the robot's body for the game (its inventory, program, forceload,
-- protection), drawn as nothing. The entity is what you point at (its hitbox is the
-- shape of the model): right-click opens it (sneak: goes in), punches work it. This entity is what is drawn:
-- the robot, hover or drone model with its face lit while it runs, turned the way the
-- robot faces, gliding when the robot moves or falls. A drone gets four rotor
-- entities that spin while it runs; a robot flying or hovering (a free block under
-- it) gets a few thruster particles.
--
-- Entities are not saved: they are made when a robot node is placed, moved with it,
-- removed when it is dug, and made again when its block loads (LBM) or an ABM finds
-- one missing. A visual whose node is gone removes itself.

local cogwork = ...

local VISUAL, ROTOR = "cogwork:visual", "cogwork:rotor"

-- What you point at, per model, in the model's own frame (its front is -Z; the box
-- turns with the entity) - measured from the meshes
cogwork.MODEL_SELECTION = {
	robot = { -0.5, -0.5, -0.46, 0.5, 0.5, 0.46, rotate = true },
	hover = { -0.46, -0.5, -0.34, 0.46, 0.5, 0.34, rotate = true },
	drone = { -0.47, -0.5, -0.47, 0.47, 0.2, 0.47, rotate = true },
}

-- What blocks players, on the node: the same, as wide on both sides (a node's box is
-- turned with its facedir, the model's with the entity's yaw: this one needs neither)
cogwork.MODEL_BOXES = {}
for kind, b in pairs(cogwork.MODEL_SELECTION) do
	local half = math.max(b[4], b[6])
	cogwork.MODEL_BOXES[kind] = { -half, b[2], -half, half, b[5], half }
end

local SPIN = 25   -- rotor speed, radians a second

-- where the rotors sit on the drone (1/10 of a node, relative to its middle)
local ROTORS = {
	{ x = -3.8, y = -0.3, z = -3.8 }, { x = 3.8, y = -0.3, z = -3.8 },
	{ x = -3.8, y = -0.3, z = 3.8 }, { x = 3.8, y = -0.3, z = 3.8 },
}

-- thruster particles: hover pads under the robot, rotors of the drone
local THRUST = {
	hover = { min = { x = -0.24, y = -0.5, z = -0.24 }, max = { x = 0.24, y = -0.5, z = 0.24 } },
	drone = { min = { x = -0.4, y = -0.1, z = -0.4 }, max = { x = 0.4, y = -0.1, z = 0.4 } },
}

local function textures (on)
	return { "cogwork_metal.png", on and "cogwork_face_on.png" or "cogwork_face.png",
		"cogwork_tread.png", "cogwork_accent.png", "cogwork_back.png" }
end

-- "robot", "hover" or "drone", and whether it runs, from the node name
local function parts (name)
	return name:match("^cogwork:(%a+)"), name:sub(-3) == "_on"
end

function cogwork.is_visual (obj)
	local le = obj:get_luaentity()
	return le ~= nil and (le.name == VISUAL or le.name == ROTOR)
end

-- let go of what hangs on the visual: its rotors and its particles
local function forget (self)
	for _, rotor in ipairs(self.rotors or {}) do
		if rotor:is_valid() then rotor:remove() end
	end
	self.rotors = nil
	if self.spawner then
		core.delete_particlespawner(self.spawner)
		self.spawner = nil
	end
end

core.register_entity(VISUAL, {
	initial_properties = {
		visual = "mesh",
		mesh = "cogwork_robot.obj",
		textures = textures(false),
		-- the models are made at entity scale, 10 units to the node
		visual_size = { x = 1, y = 1, z = 1 },
		physical = false,
		-- the robot you point at: the hitbox is the model (set per kind below)
		pointable = true,
		selectionbox = cogwork.MODEL_SELECTION.robot,
		static_save = false,
		collide_with_objects = false,
		makes_footstep_sound = false,
	},

	on_activate = function (self)
		self.object:set_armor_groups({ immortal = 1 })
		self.age = 0
	end,

	-- the robot node under this entity, if there is one
	robot_pos = function (self)
		local pos = self.object:get_pos()
		pos = pos and vector.round(pos)
		local node = pos and core.get_node_or_nil(pos)
		if node and cogwork.is_robot(node.name) then return pos end
	end,

	on_rightclick = function (self, clicker)
		local pos = self:robot_pos()
		if not pos or not clicker or not clicker:is_player() then return end
		local held = clicker:get_wielded_item()
		local res = cogwork.robot_rightclick(pos, clicker, held)
		if res and res:to_string() ~= held:to_string() then clicker:set_wielded_item(res) end
	end,

	on_punch = function (self, puncher, time_from_last_punch)
		local pos = self:robot_pos()
		if pos then cogwork.robot_punch(pos, puncher, true, time_from_last_punch) end
		return true      -- the entity itself takes no damage
	end,

	-- the robot is gone: so is this
	on_step = function (self, dtime)
		self.age = self.age + dtime
		if self.age < 1 then return end
		self.age = 0
		local pos = self.object:get_pos()
		if not pos then return end
		local node = core.get_node_or_nil(vector.round(pos))
		if node and not cogwork.is_robot(node.name) then
			forget(self)
			self.object:remove()
		end
	end,

	on_deactivate = function (self) forget(self) end,
})

core.register_entity(ROTOR, {
	initial_properties = {
		visual = "mesh",
		mesh = "cogwork_rotor.obj",
		textures = { "cogwork_tread.png" },
		visual_size = { x = 1, y = 1, z = 1 },
		physical = false,
		pointable = false,
		static_save = false,
		automatic_rotate = 0,
	},

	on_step = function (self, dtime)
		self.age = (self.age or 0) + dtime
		if self.age < 1 then return end
		self.age = 0
		-- the drone it was on is gone
		if not self.object:get_attach() then self.object:remove() end
	end,
})

-- the visual standing on the robot node at pos (one: extra ones are removed)
local function find_visual (pos)
	local found
	for _, obj in ipairs(core.get_objects_inside_radius(pos, 0.45)) do
		local le = obj:get_luaentity()
		if le and le.name == VISUAL then
			if found then
				forget(le)
				obj:remove()
			else
				found = obj
			end
		end
	end
	return found
end

local function set_rotors (obj, self, wanted, spinning)
	if not wanted then
		for _, rotor in ipairs(self.rotors or {}) do
			if rotor:is_valid() then rotor:remove() end
		end
		self.rotors = nil
		return
	end

	self.rotors = self.rotors or {}
	for i, at in ipairs(ROTORS) do
		local rotor = self.rotors[i]
		if not rotor or not rotor:is_valid() then
			rotor = core.add_entity(obj:get_pos(), ROTOR)
			if rotor then
				rotor:set_attach(obj, "", at, { x = 0, y = 0, z = 0 })
				self.rotors[i] = rotor
			end
		end
		if rotor and rotor:is_valid() then
			rotor:set_properties({ automatic_rotate = spinning and SPIN or 0 })
		end
	end
end

local function set_particles (obj, self, kind, flying)
	local want = cogwork.settings.particles and flying and THRUST[kind] and kind or nil
	if self.spawner and self.spawner_kind ~= want then
		core.delete_particlespawner(self.spawner)
		self.spawner = nil
	end
	if want and not self.spawner then
		local area = THRUST[want]
		self.spawner = core.add_particlespawner({
			amount = 6, time = 0, attached = obj,
			minpos = area.min, maxpos = area.max,
			minvel = { x = -0.1, y = -1.6, z = -0.1 }, maxvel = { x = 0.1, y = -0.8, z = 0.1 },
			minacc = { x = 0, y = 0, z = 0 }, maxacc = { x = 0, y = 0, z = 0 },
			minexptime = 0.25, maxexptime = 0.55,
			minsize = 0.7, maxsize = 1.3,
			texture = "cogwork_particle.png", glow = 8,
		})
		self.spawner_kind = want
	end
end

-- Make the visual of the robot at pos match it: model, face, direction, rotors,
-- particles. It is made when there is none.
function cogwork.update_visual (pos, obj)
	local node = core.get_node_or_nil(pos)
	if not node or not cogwork.is_robot(node.name) then return end

	obj = obj or find_visual(pos) or core.add_entity(vector.new(pos), VISUAL)
	local self = obj and obj:get_luaentity()
	if not self then return end

	local kind, on = parts(node.name)
	if self.kind ~= kind or self.on ~= on then
		obj:set_properties({ mesh = "cogwork_" .. kind .. ".obj", textures = textures(on),
			selectionbox = cogwork.MODEL_SELECTION[kind] })
		self.kind, self.on = kind, on
	end

	-- the model's front is -Z; the robot's front is the opposite of its facedir vector
	obj:set_yaw(core.dir_to_yaw(core.facedir_to_dir(node.param2 % 32)))

	set_rotors(obj, self, kind == "drone", on)
	set_particles(obj, self, kind, cogwork.gap_below(pos, 1) >= 1)
end

function cogwork.ensure_visual (pos)
	cogwork.update_visual(pos)
end

-- the robot node at pos is gone (dug)
function cogwork.remove_visual (pos)
	local obj = find_visual(pos)
	if obj then
		forget(obj:get_luaentity())
		obj:remove()
	end
end

-- the robot moved from one block to the next: its visual glides along
function cogwork.move_visual (from, to)
	local obj = find_visual(from)
	if obj then obj:move_to(vector.new(to), true) end
	cogwork.update_visual(to, obj)
end

core.register_lbm({
	label = "Cogwork visual",
	name = "cogwork:visual",
	nodenames = cogwork.ROBOT_NODES,
	run_at_every_load = true,
	action = function (pos) cogwork.ensure_visual(pos) end,
})
