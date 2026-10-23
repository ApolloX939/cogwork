-- The viewscreen inside a robot: what the robot sees, drawn as a picture.
--
-- A picture is one ray per pixel from the robot's eye: exact voxel traversal through
-- a snapshot of the blocks around it (one VoxelManip read per picture, so it is always
-- current), then coarser steps (2, 4, 8 blocks) out to the view range, so far terrain
-- shows too. A hit takes the real average colour of the node's
-- texture (read from the mods' texture files, see png.lua), shaded by the face, the
-- light of the block in front of it and the distance. Terrain nobody has loaded is
-- haze. The picture is made a few milliseconds per server step so it never stalls
-- the server, then encoded as a PNG and put on the screen entity as a texture,
-- the same way ggraffiti's canvases are drawn.
--
-- Players and other entities are drawn as coloured boxes (blue: players).
--
-- Only rooms with a player in them are drawn, one picture every view_interval.

local cogwork = ...
local settings = cogwork.settings
local S = cogwork.S
local png = assert(loadfile(cogwork.modpath .. "/src/png.lua"))()

local floor, abs, huge = math.floor, math.abs, math.huge
local NEAR = 24                 -- blocks around the eye read in one go and traversed exactly
local SKY_HEIGHT = 48           -- a ray that climbed this far above the eye sees only sky
local BUDGET = 0.006            -- seconds of drawing per server step
local MAX_TEXTURE_BYTES = 40000 -- bigger texture files are not decoded
local MAX_LOADS = 64            -- blocks loaded from disk for one picture

--------------------------------------------------------------------------
-- node colours

local index           -- texture file name -> path
local texture_cache = {}   -- file name -> { r, g, b } or false

local function build_index ()
	index = {}
	local function add (dir)
		for _, file in ipairs(core.get_dir_list(dir, false) or {}) do
			if file:sub(-4) == ".png" and not index[file] then index[file] = dir .. "/" .. file end
		end
	end
	for _, modname in ipairs(core.get_modnames()) do add(core.get_modpath(modname) .. "/textures") end
	local game = core.get_game_info and core.get_game_info()
	if game and game.path then add(game.path .. "/textures") end
	add(core.get_worldpath() .. "/textures")
end

-- the file a tile (a string, or a table with a name) is made of; nil when it is
-- built by a modifier we cannot read
local function tile_file (tile)
	if type(tile) == "table" then tile = tile.name or tile.image end
	if type(tile) ~= "string" then return nil end
	tile = tile:gsub("^%(+", "")
	local base = tile:match("^([^%^%[%)]+)")
	if base and base:sub(-4) == ".png" then return base end
end

local function texture_color (file)
	local c = texture_cache[file]
	if c ~= nil then return c end
	index = index or (build_index() or index)
	local path = index[file]
	local handle = path and io.open(path, "rb")
	if handle then
		local data = handle:read("*a")
		handle:close()
		local ok, r, g, b = pcall(png.average, data, MAX_TEXTURE_BYTES)
		if ok and r then
			c = { r, g, b }
		end
	end
	texture_cache[file] = c or false
	return texture_cache[file]
end

local function name_color (name)
	-- no texture to read: a colour from the name, so different nodes look different
	local h = 0
	for i = 1, #name do h = (h * 31 + name:byte(i)) % 997 end
	local v = 110 + (h % 60)
	return { v, v - (h % 17), v - (h % 29) }
end

local node_info = {}    -- node name -> { clear = bool, top, bottom, side }

local function info_of (name)
	local info = node_info[name]
	if info then return info end

	local def = core.registered_nodes[name]
	if name == "air" or (def and def.drawtype == "airlike" and not cogwork.is_robot(name)) then
		info = { clear = true }
	elseif cogwork.is_robot(name) then
		local metal = { 150, 160, 180 }
		info = { top = metal, bottom = metal, side = metal }
	else
		local tiles = def and (def.tiles or def.special_tiles) or {}
		if def and (def.liquidtype or "none") ~= "none" and def.special_tiles and def.special_tiles[1] then
			tiles = def.special_tiles
		end
		local function color_of (i)
			local file = tile_file(tiles[i])
			return file and texture_color(file)
		end
		local top = color_of(1)
		local bottom = color_of(2) or top
		local side = color_of(3) or color_of(#tiles) or top
		local fallback
		if not (top or bottom or side) then
			local post = def and def.post_effect_color
			if post and post.r then
				fallback = { post.r, post.g, post.b }
			else
				fallback = name_color(name)
			end
		end
		info = { top = top or fallback or side or bottom, bottom = bottom or fallback or top or side,
			side = side or fallback or top or bottom }
	end
	node_info[name] = info
	return info
end

-- cached info for tests and the editor of nothing: node colours as the screen sees them
function cogwork.view_node_color (name, face)
	local info = info_of(name)
	return info.clear and nil or info[face or "side"]
end

--------------------------------------------------------------------------
-- the picture

local SKY_HORIZON, SKY_TOP, VOID, HAZE = { 176, 208, 236 }, { 92, 152, 226 }, { 24, 28, 44 }, { 150, 168, 190 }

local function sky_color (dy)
	if dy < -0.05 then return VOID end
	local t = dy < 0 and 0 or (dy > 1 and 1 or dy)
	t = t ^ 0.6
	return {
		SKY_HORIZON[1] + (SKY_TOP[1] - SKY_HORIZON[1]) * t,
		SKY_HORIZON[2] + (SKY_TOP[2] - SKY_HORIZON[2]) * t,
		SKY_HORIZON[3] + (SKY_TOP[3] - SKY_HORIZON[3]) * t,
	}
end

local function pack (r, g, b)
	if r < 0 then r = 0 elseif r > 255 then r = 255 end
	if g < 0 then g = 0 elseif g > 255 then g = 255 end
	if b < 0 then b = 0 elseif b > 255 then b = 255 end
	return 0xFF000000 + floor(r) * 65536 + floor(g) * 256 + floor(b)
end

local FACE_SHADE = { top = 1.0, side_x = 0.78, side_z = 0.9, bottom = 0.6 }

-- What the cell (x, y, z) holds: info, "unknown" when unloaded, false when clear.
-- What was seen is remembered between pictures (job.cache this half minute, job.old
-- the one before): the engine unloads the blocks nobody is near, and a picture must
-- not flicker with whatever happens to be in memory. Unknown is not remembered.
local function look (job, x, y, z)
	local key = (x + 32768) + 65536 * ((y + 32768) + 65536 * (z + 32768))
	local v = job.cache[key]
	if v ~= nil then return v end
	v = job.old[key]
	if v ~= nil then
		job.cache[key] = v
		return v
	end
	if job.unknown[key] then return "unknown" end

	local pos = { x = x, y = y, z = z }
	local node = core.get_node_or_nil(pos)
	if node == nil and job.loads < MAX_LOADS then
		-- nobody is near it: load that block from disk (never generate), a few per picture
		local block = floor(x / 16) + 4096 * (floor(y / 16) + 4096 * floor(z / 16))
		local failed = job.failed[block]
		if not job.tried[block] and not (failed and failed > job.now) then
			job.tried[block] = true
			job.loads = job.loads + 1
			core.load_area(pos)
			node = core.get_node_or_nil(pos)
			if node == nil then job.failed[block] = job.now + 60 end
		end
	end

	if node == nil or node.name == "ignore" then
		job.unknown[key] = true
		return "unknown"
	end
	local info = info_of(node.name)
	if info.clear then v = false else v = info end
	job.cache[key] = v
	return v
end

-- what a content id is: info, false when clear, "unknown" for ignore
local id_info = {}
local function classify (id)
	local what
	if id == core.CONTENT_IGNORE then
		what = "unknown"
	else
		local info = info_of(core.get_name_from_content_id(id))
		what = not info.clear and info or false
	end
	id_info[id] = what
	return what
end

-- the colour of a face that was hit t blocks away; (lx, ly, lz) is the clear cell in front of it
local function shade (info, face, lx, ly, lz, t, range)
	local c = info[(face == "side_x" or face == "side_z") and "side" or face]
	local light = core.get_node_light({ x = lx, y = ly, z = lz }) or 10
	-- the picture is exposed like a camera: dark places are dim, never black
	local k = FACE_SHADE[face] * (0.28 + 0.72 * (light / 15) ^ 1.2)
	local r, g, b = c[1] * k, c[2] * k, c[3] * k
	-- distance fades into haze
	local f = (t / range) ^ 2
	if f > 1 then f = 1 end
	f = f * 0.9
	return pack(r + (HAZE[1] - r) * f, g + (HAZE[2] - g) * f, b + (HAZE[3] - b) * f)
end

-- Nobody has loaded it. Looking up it is sky (the space above a robot is nearly always
-- empty); sideways or down it is haze.
local UNKNOWN = pack(HAZE[1] * 0.8, HAZE[2] * 0.8, HAZE[3] * 0.8)
local function unknown (dy)
	if dy > 0.02 then
		local sky = sky_color(dy)
		return pack(sky[1], sky[2], sky[3])
	end
	return UNKNOWN
end

-- the colour seen along a ray (dx, dy, dz: a unit vector) from the eye
-- Players and other entities: boxes in the picture. They are collected once per
-- picture (the nearest MAX_MARKS in range) and tested against every ray, in front of
-- the terrain they are nearer than. Players are blue, the rest orange; the face
-- shading and the haze are the terrain's.
local MARK_PLAYER, MARK_ENTITY = { 70, 190, 255 }, { 255, 140, 50 }

local function collect_marks (job, pos)
	local range = settings.view_range
	local marks = {}
	for _, obj in ipairs(core.get_objects_inside_radius(pos, range)) do
		local le = obj:get_luaentity()
		if not cogwork.is_visual(obj) and not (le and le.name == "__builtin:item") and not obj:get_attach() then
			local props = obj:get_properties()
			local p = obj:get_pos()
			if p and props and props.is_visible ~= false then
				local box = props.physical and props.collisionbox or props.selectionbox or props.collisionbox
				box = box or { -0.3, -0.3, -0.3, 0.3, 0.3, 0.3 }
				-- small things stay a few pixels big
				local cx, cy, cz = (box[1] + box[4]) / 2, (box[2] + box[5]) / 2, (box[3] + box[6]) / 2
				local hx, hy, hz = math.max((box[4] - box[1]) / 2, 0.3), math.max((box[5] - box[2]) / 2, 0.3), math.max((box[6] - box[3]) / 2, 0.3)
				marks[#marks + 1] = {
					x1 = p.x + cx - hx, x2 = p.x + cx + hx, y1 = p.y + cy - hy, y2 = p.y + cy + hy,
					z1 = p.z + cz - hz, z2 = p.z + cz + hz,
					color = obj:is_player() and MARK_PLAYER or MARK_ENTITY,
					d = vector.distance(pos, p),
				}
			end
		end
	end
	table.sort(marks, function (a, b) return a.d < b.d end)
	for i = job.max_marks + 1, #marks do marks[i] = nil end
	return marks
end

-- where the ray from (ox, oy, oz) along (dx, dy, dz) enters the box: t and the face, or nil
local function hit_mark (m, ox, oy, oz, dx, dy, dz)
	local t0, t1, face = 0, huge, nil
	-- x
	if dx ~= 0 then
		local a, b = (m.x1 - ox) / dx, (m.x2 - ox) / dx
		if a > b then a, b = b, a end
		if a > t0 then t0, face = a, "side_x" end
		if b < t1 then t1 = b end
	elseif ox < m.x1 or ox > m.x2 then return nil end
	if dy ~= 0 then
		local a, b = (m.y1 - oy) / dy, (m.y2 - oy) / dy
		if a > b then a, b = b, a end
		if a > t0 then t0, face = a, dy < 0 and "top" or "bottom" end
		if b < t1 then t1 = b end
	elseif oy < m.y1 or oy > m.y2 then return nil end
	if dz ~= 0 then
		local a, b = (m.z1 - oz) / dz, (m.z2 - oz) / dz
		if a > b then a, b = b, a end
		if a > t0 then t0, face = a, "side_z" end
		if b < t1 then t1 = b end
	elseif oz < m.z1 or oz > m.z2 then return nil end
	if t0 > t1 or not face then return nil end
	return t0, face
end

local function cast (job, dx, dy, dz)
	local ox, oy, oz = job.ox, job.oy, job.oz
	local range = settings.view_range
	local own = job.own

	local x, y, z = floor(ox + 0.5), floor(oy + 0.5), floor(oz + 0.5)
	local sx, sy, sz = dx > 0 and 1 or -1, dy > 0 and 1 or -1, dz > 0 and 1 or -1
	local tdx = dx ~= 0 and abs(1 / dx) or huge
	local tdy = dy ~= 0 and abs(1 / dy) or huge
	local tdz = dz ~= 0 and abs(1 / dz) or huge
	local tmx = dx ~= 0 and ((dx > 0 and (x + 0.5 - ox) or (ox - (x - 0.5))) * tdx) or huge
	local tmy = dy ~= 0 and ((dy > 0 and (y + 0.5 - oy) or (oy - (y - 0.5))) * tdy) or huge
	local tmz = dz ~= 0 and ((dz > 0 and (z + 0.5 - oz) or (oz - (z - 0.5))) * tdz) or huge

	-- the snapshot around the eye: no engine call per cell
	local data = job.data
	local ex1, ex2, ey1, ey2, ez1, ez2 = job.ex1, job.ex2, job.ey1, job.ey2, job.ez1, job.ez2
	local ys, zs = job.ys, job.zs

	local t = 0
	while true do
		local face, px, py, pz = nil, x, y, z
		if tmx < tmy and tmx < tmz then
			t = tmx; tmx = tmx + tdx; x = x + sx; face = "side_x"
		elseif tmy < tmz then
			t = tmy; tmy = tmy + tdy; y = y + sy; face = sy > 0 and "bottom" or "top"
		else
			t = tmz; tmz = tmz + tdz; z = z + sz; face = "side_z"
		end
		if t > range then break end
		if x < ex1 or x > ex2 or y < ey1 or y > ey2 or z < ez1 or z > ez2 then break end
		if not (own and x == own.x and y == own.y and z == own.z) then
			local id = data[(z - ez1) * zs + (y - ey1) * ys + (x - ex1) + 1]
			local what = id_info[id]
			if what == nil then what = classify(id) end
			if what == "unknown" then return unknown(dy), huge end
			if what then return shade(what, face, px, py, pz, t, range), t end
		end
	end

	-- beyond that, coarser and coarser steps: far terrain without a ray per block
	local stride = 2
	while t < range do
		-- high above the eye there is nothing worth looking for
		if dy * t > SKY_HEIGHT then break end
		t = t + stride
		if t > 64 then stride = 4 end
		if t > 112 then stride = 8 end
		local cx, cy, cz = floor(ox + dx * t + 0.5), floor(oy + dy * t + 0.5), floor(oz + dz * t + 0.5)
		local what = look(job, cx, cy, cz)
		if what == "unknown" then return unknown(dy), huge end
		if what then
			-- the face the ray came in by: the axis it travels along most
			local face
			if abs(dy) >= abs(dx) and abs(dy) >= abs(dz) then face = dy < 0 and "top" or "bottom"
			elseif abs(dx) > abs(dz) then face = "side_x" else face = "side_z" end
			return shade(what, face, cx, cy + (face == "top" and 1 or 0), cz, t, range), t
		end
	end

	local sky = sky_color(dy)
	return pack(sky[1], sky[2], sky[3]), huge
end

-- A picture to make: the eye and the way it looks.
-- pos: the robot's block, front: the way the camera looks (a unit vector: the robot's
-- facing, turned and tilted by the camera controller)
-- remembers: a table kept between the pictures of one screen (blocks that would not load)
function cogwork.view_job (pos, front, remembers)
	local W, H = settings.view_width, settings.view_height
	local now = core.get_us_time() / 1e6
	local mem = remembers or {}
	mem.cur, mem.old, mem.failed = mem.cur or {}, mem.old or {}, mem.failed or {}
	if now > (mem.rotate or 0) then
		-- every ten seconds what was seen last time is forgotten (far terrain only)
		mem.old, mem.cur, mem.rotate = mem.cur, {}, now + 10
	end
	-- the blocks around the eye, as they are now (never generated: unloaded ones are ignore)
	local ex, ey, ez = floor(pos.x + 0.5), floor(pos.y + 0.5), floor(pos.z + 0.5)
	local vm = core.get_voxel_manip()
	local emin, emax = vm:read_from_map({ x = ex - NEAR, y = ey - NEAR, z = ez - NEAR },
		{ x = ex + NEAR, y = ey + NEAR, z = ez + NEAR })
	mem.buffer = mem.buffer or {}
	-- the horizontal part of the view, as a unit vector (the eye sits a little ahead)
	local hlen = math.sqrt(front.x * front.x + front.z * front.z)
	local hx, hz = 0, 1
	if hlen > 1e-6 then hx, hz = front.x / hlen, front.z / hlen end
	local job = {
		data = vm:get_data(mem.buffer),
		ex1 = emin.x, ex2 = emax.x, ey1 = emin.y, ey2 = emax.y, ez1 = emin.z, ez2 = emax.z,
		ys = emax.x - emin.x + 1, zs = (emax.x - emin.x + 1) * (emax.y - emin.y + 1),
		W = W, H = H, total = W * H, next = 0, pixels = {}, tried = {}, loads = 0, unknown = {},
		cache = mem.cur, old = mem.old, failed = mem.failed, now = now,
		ox = pos.x + hx * 0.3, oy = pos.y + 0.3, oz = pos.z + hz * 0.3,
		fx = front.x, fy = front.y or 0, fz = front.z,
		-- right of the view (horizontal) and up from it
		rx = hz, rz = -hx,
		ux = -(front.y or 0) * hx, uy = front.x * hx + front.z * hz, uz = -(front.y or 0) * hz,
		own = { x = pos.x, y = pos.y, z = pos.z },
		tan = math.tan(math.rad(100 / 2)),
		max_marks = 24,
	}
	job.marks = collect_marks(job, { x = job.ox, y = job.oy, z = job.oz })
	return job
end

-- draw for up to budget seconds; true when the picture is finished
function cogwork.view_step (job, budget)
	local W, H, pixels, tan = job.W, job.H, job.pixels, job.tan
	local aspect = W / H
	local range = settings.view_range
	-- right of the view, and up from it
	local rx, rz = job.rx, job.rz
	local ux, uy, uz = job.ux, job.uy, job.uz
	local t0 = os.clock()
	local i = job.next
	local loads = job.loads
	while i < job.total do
		local px, py = i % W, floor(i / W)
		local u = ((px + 0.5) / W * 2 - 1) * tan
		local v = (1 - (py + 0.5) / H * 2) * tan / aspect
		local dx, dy, dz = job.fx + rx * u + ux * v, job.fy + uy * v, job.fz + rz * u + uz * v
		local len = math.sqrt(dx * dx + dy * dy + dz * dz)
		dx, dy, dz = dx / len, dy / len, dz / len
		local color, tt = cast(job, dx, dy, dz)
		-- an entity nearer than the terrain hides it
		for _, m in ipairs(job.marks) do
			local te, face = hit_mark(m, job.ox, job.oy, job.oz, dx, dy, dz)
			if te and te < tt and te <= range then
				tt = te
				local k = FACE_SHADE[face]
				local f = math.min(1, (te / range) ^ 2) * 0.9
				color = pack(m.color[1] * k + (HAZE[1] - m.color[1] * k) * f,
					m.color[2] * k + (HAZE[2] - m.color[2] * k) * f,
					m.color[3] * k + (HAZE[3] - m.color[3] * k) * f)
			end
		end
		pixels[i + 1] = color
		i = i + 1
		-- a pixel that loaded a block from disk may have taken long: look at the clock at once
		if (i % 8 == 0 or job.loads ~= loads) and os.clock() - t0 > budget then break end
		loads = job.loads
	end
	job.next = i
	return i >= job.total
end

-- the finished picture as a texture string
function cogwork.view_texture (job)
	local data = core.encode_png(job.W, job.H, job.pixels, 6)
	return "[png:" .. core.encode_base64(data)
end

-- a picture with no signal: grey static
function cogwork.view_static ()
	local W, H = settings.view_width, settings.view_height
	local pixels = {}
	local seed = os.time()
	for i = 1, W * H do
		seed = (seed * 1103515245 + 12345) % 2147483648
		local v = 40 + floor(seed / 65536) % 70
		pixels[i] = pack(v, v, v + 6)
	end
	return "[png:" .. core.encode_base64(core.encode_png(W, H, pixels, 6))
end

--------------------------------------------------------------------------
-- the screen: an entity with the picture as its texture

core.register_entity("cogwork:screen", {
	initial_properties = {
		visual = "upright_sprite",
		textures = { "blank.png", "blank.png" },
		visual_size = { x = 8, y = 5 },
		physical = false,
		pointable = false,
		static_save = false,
		glow = 14,
	},
	on_activate = function (self) self.object:set_armor_groups({ immortal = 1 }) end,
})

local function find_screen (pos)
	for _, obj in ipairs(core.get_objects_inside_radius(pos, 0.6)) do
		local le = obj:get_luaentity()
		if le and le.name == "cogwork:screen" then return obj end
	end
end

-- the screen at pos (made when there is none)
function cogwork.view_screen (pos, size)
	local obj = find_screen(pos) or core.add_entity(pos, "cogwork:screen")
	if obj then
		obj:set_properties({ visual_size = size })
		-- faces back into the room
		obj:set_yaw(math.pi)
	end
	return obj
end

-- Put a picture on the screen; a screen that went missing (entities in blocks nobody is
-- near are put away) is made again.
function cogwork.view_set (pos, texture, size)
	local obj = find_screen(pos) or cogwork.view_screen(pos, size or { x = 8, y = 5 })
	if not obj then return end
	-- the same picture again (nothing moved) is not sent to the clients again
	local le = obj:get_luaentity()
	if le and le.picture == texture then return end
	if le then le.picture = texture end
	obj:set_properties({ textures = { texture, "blank.png" } })
end

--------------------------------------------------------------------------
-- the line under the screen: where the robot is and which way the camera looks

local COMPASS = {
	{ "N", "+Z" }, { "NE", "+X +Z" }, { "E", "+X" }, { "SE", "+X -Z" },
	{ "S", "-Z" }, { "SW", "-X -Z" }, { "W", "-X" }, { "NW", "-X +Z" },
}

-- "N (+Z), level" for a viewing direction (north is +Z, east +X)
function cogwork.direction_text (front)
	if front.x * front.x + front.z * front.z < 1e-6 then
		return front.y > 0 and "straight up" or "straight down"
	end
	local bearing = math.deg(math.atan2(front.x, front.z))
	local at = COMPASS[(math.floor((bearing + 22.5) / 45) % 8) + 1]
	local pitch = math.floor(math.deg(math.asin(math.max(-1, math.min(1, front.y or 0)))) + 0.5)
	local tilt = pitch > 2 and ("up %d°"):format(pitch) or (pitch < -2 and ("down %d°"):format(-pitch) or "level")
	return ("%s (%s), %s"):format(at[1], at[2], tilt)
end

function cogwork.view_info_text (pos, front)
	-- plain text: a nametag is not translated for each player
	return ("Robot at %d, %d, %d  |  Looking %s"):format(pos.x, pos.y, pos.z, cogwork.direction_text(front))
end

core.register_entity("cogwork:screen_text", {
	initial_properties = {
		visual = "sprite", textures = { "blank.png" }, visual_size = { x = 0.01, y = 0.01 },
		physical = false, pointable = false, static_save = false,
		nametag = "", nametag_color = "#ffffff", nametag_bgcolor = "#000000b0",
	},
})

-- the text under the screen at screen_pos (made when there is none)
function cogwork.view_info (screen_pos, text)
	local at = { x = screen_pos.x, y = screen_pos.y - 4.05, z = screen_pos.z - 0.06 }
	local found
	for _, obj in ipairs(core.get_objects_inside_radius(at, 0.5)) do
		local le = obj:get_luaentity()
		if le and le.name == "cogwork:screen_text" then found = obj end
	end
	found = found or core.add_entity(at, "cogwork:screen_text")
	local le = found and found:get_luaentity()
	if le and le.text ~= text then
		le.text = text
		found:set_properties({ nametag = text })
	end
end

--------------------------------------------------------------------------
-- the rooms being watched: each has a screen position and a way to find its robot

local watched = {}     -- room id -> { screen = pos, robot = function () -> pos, front, job, due }

function cogwork.view_watch (rid, screen_pos, locate, size)
	watched[rid] = watched[rid] or { due = 0 }
	watched[rid].screen = screen_pos
	watched[rid].locate = locate
	watched[rid].size = size
end

-- for tests and curiosity: how far the picture of a watched room is
function cogwork.view_state (rid)
	local w = watched[rid]
	if not w then return "not watched" end
	return w.job and ("drawing %d/%d"):format(w.job.next, w.job.total) or ("waiting, due in %.1f s"):format(w.due - core.get_us_time() / 1e6)
end

-- the picture of a room should be drawn again at once (the camera was moved)
function cogwork.view_poke (rid)
	local w = watched[rid]
	if w and not w.job then w.due = 0 end
end

function cogwork.view_unwatch (rid)
	watched[rid] = nil
end

-- the ids of the rooms being drawn (rooms.lua checks somebody is in each)
function cogwork.view_watched ()
	local list = {}
	for rid in pairs(watched) do list[#list + 1] = rid end
	return list
end

core.register_globalstep(function (dt)
	if next(watched) == nil then return end
	local now = core.get_us_time() / 1e6

	-- the budget is shared between the rooms that are drawing
	local drawing = 0
	for _, w in pairs(watched) do
		if w.job or now >= w.due then drawing = drawing + 1 end
	end
	if drawing == 0 then return end
	local each = BUDGET / drawing

	for rid, w in pairs(watched) do
		if not w.job and now >= w.due then
			local pos, front = w.locate()
			if pos then
				w.remembers = w.remembers or {}
				w.job = cogwork.view_job(pos, front, w.remembers)
				w.started = now
				w.info = cogwork.view_info_text(pos, front)
			else
				cogwork.view_set(w.screen, cogwork.view_static(), w.size)
				cogwork.view_info(w.screen, "No signal")
				w.due = now + settings.view_interval
			end
		end
		if w.job and cogwork.view_step(w.job, each) then
			cogwork.view_set(w.screen, cogwork.view_texture(w.job), w.size)
			cogwork.view_info(w.screen, w.info or "")
			w.job = nil
			-- the interval counts from the start of the picture
			w.due = w.started + settings.view_interval
		end
	end
end)
