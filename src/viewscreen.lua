-- The viewscreen inside a robot: what the robot sees, drawn as a picture.
--
-- A picture is one ray per pixel from the robot's eye: exact voxel traversal for
-- the first blocks, then coarser steps (2, 4, 8 blocks) out to the view range, so
-- far terrain shows too. A hit takes the real average colour of the node's
-- texture (read from the mods' texture files, see png.lua), shaded by the face, the
-- light of the block in front of it and the distance. Terrain nobody has loaded is
-- haze. The picture is made a few milliseconds per server step so it never stalls
-- the server, then encoded as a PNG and put on the screen entity as a texture,
-- the same way ggraffiti's canvases are drawn.
--
-- Only rooms with a player in them are drawn, one picture every view_interval.

local S = ...
local settings = S.settings
local png = assert(loadfile(S.modpath .. "/src/png.lua"))()

local floor, abs, huge = math.floor, math.abs, math.huge
local NEAR = 36                 -- cells traversed exactly
local BUDGET = 0.004            -- seconds of drawing per server step
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
	if name == "air" or (def and def.drawtype == "airlike" and not S.is_robot(name)) then
		info = { clear = true }
	elseif S.is_robot(name) then
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
function S.view_node_color (name, face)
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

	local t = 0
	for _ = 1, NEAR do
		local face, px, py, pz = nil, x, y, z
		if tmx < tmy and tmx < tmz then
			t = tmx; tmx = tmx + tdx; x = x + sx; face = "side_x"
		elseif tmy < tmz then
			t = tmy; tmy = tmy + tdy; y = y + sy; face = sy > 0 and "bottom" or "top"
		else
			t = tmz; tmz = tmz + tdz; z = z + sz; face = "side_z"
		end
		if t > range then break end
		if not (own and x == own.x and y == own.y and z == own.z) then
			local what = look(job, x, y, z)
			if what == "unknown" then return unknown(dy) end
			if what then return shade(what, face, px, py, pz, t, range) end
		end
	end

	-- beyond that, coarser and coarser steps: far terrain without a ray per block
	local stride = 2
	while t < range do
		t = t + stride
		if t > 64 then stride = 4 end
		if t > 112 then stride = 8 end
		local cx, cy, cz = floor(ox + dx * t + 0.5), floor(oy + dy * t + 0.5), floor(oz + dz * t + 0.5)
		local what = look(job, cx, cy, cz)
		if what == "unknown" then return unknown(dy) end
		if what then
			-- the face the ray came in by: the axis it travels along most
			local face
			if abs(dy) >= abs(dx) and abs(dy) >= abs(dz) then face = dy < 0 and "top" or "bottom"
			elseif abs(dx) > abs(dz) then face = "side_x" else face = "side_z" end
			return shade(what, face, cx, cy + (face == "top" and 1 or 0), cz, t, range)
		end
	end

	local sky = sky_color(dy)
	return pack(sky[1], sky[2], sky[3])
end

-- A picture to make: the eye and the way it looks.
-- pos: the robot's block, front: its facing vector (a unit vector in the horizontal plane)
-- remembers: a table kept between the pictures of one screen (blocks that would not load)
function S.view_job (pos, front, remembers)
	local W, H = settings.view_width, settings.view_height
	local now = core.get_us_time() / 1e6
	local mem = remembers or {}
	mem.cur, mem.old, mem.failed = mem.cur or {}, mem.old or {}, mem.failed or {}
	if now > (mem.rotate or 0) then
		-- every half minute what was seen last time is forgotten
		mem.old, mem.cur, mem.rotate = mem.cur, {}, now + 30
	end
	return {
		W = W, H = H, total = W * H, next = 0, pixels = {}, tried = {}, loads = 0, unknown = {},
		cache = mem.cur, old = mem.old, failed = mem.failed, now = now,
		ox = pos.x + front.x * 0.3, oy = pos.y + 0.3, oz = pos.z + front.z * 0.3,
		fx = front.x, fz = front.z,
		own = { x = pos.x, y = pos.y, z = pos.z },
		tan = math.tan(math.rad(100 / 2)),
	}
end

-- draw for up to budget seconds; true when the picture is finished
function S.view_step (job, budget)
	local W, H, pixels, tan = job.W, job.H, job.pixels, job.tan
	local aspect = W / H
	-- right of the facing direction
	local rx, rz = job.fz, -job.fx
	local t0 = os.clock()
	local i = job.next
	local loads = job.loads
	while i < job.total do
		local px, py = i % W, floor(i / W)
		local u = ((px + 0.5) / W * 2 - 1) * tan
		local v = (1 - (py + 0.5) / H * 2) * tan / aspect
		local dx, dy, dz = job.fx + rx * u, v, job.fz + rz * u
		local len = math.sqrt(dx * dx + dy * dy + dz * dz)
		pixels[i + 1] = cast(job, dx / len, dy / len, dz / len)
		i = i + 1
		-- a pixel that loaded a block from disk may have taken long: look at the clock at once
		if (i % 8 == 0 or job.loads ~= loads) and os.clock() - t0 > budget then break end
		loads = job.loads
	end
	job.next = i
	return i >= job.total
end

-- the finished picture as a texture string
function S.view_texture (job)
	local data = core.encode_png(job.W, job.H, job.pixels, 6)
	return "[png:" .. core.encode_base64(data)
end

-- a picture with no signal: grey static
function S.view_static ()
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
function S.view_screen (pos, size)
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
function S.view_set (pos, texture, size)
	local obj = find_screen(pos) or S.view_screen(pos, size or { x = 8, y = 5 })
	if obj then obj:set_properties({ textures = { texture, "blank.png" } }) end
end

--------------------------------------------------------------------------
-- the rooms being watched: each has a screen position and a way to find its robot

local watched = {}     -- room id -> { screen = pos, robot = function () -> pos, front, job, due }

function S.view_watch (rid, screen_pos, locate, size)
	watched[rid] = watched[rid] or { due = 0 }
	watched[rid].screen = screen_pos
	watched[rid].locate = locate
	watched[rid].size = size
end

-- for tests and curiosity: how far the picture of a watched room is
function S.view_state (rid)
	local w = watched[rid]
	if not w then return "not watched" end
	return w.job and ("drawing %d/%d"):format(w.job.next, w.job.total) or ("waiting, due in %.1f s"):format(w.due - core.get_us_time() / 1e6)
end

function S.view_unwatch (rid)
	watched[rid] = nil
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
				w.job = S.view_job(pos, front, w.remembers)
			else
				S.view_set(w.screen, S.view_static(), w.size)
				w.due = now + settings.view_interval
			end
		end
		if w.job and S.view_step(w.job, each) then
			S.view_set(w.screen, S.view_texture(w.job), w.size)
			w.job = nil
			w.due = now + settings.view_interval
		end
	end
end)
