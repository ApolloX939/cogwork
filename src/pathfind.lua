-- Pathfinding: plan a route through free blocks (the robot moves in the six
-- axis directions, it does not need a floor) and walk it a step at a time.
--
-- pathfind.start / start_entity plan and return the steps to go, or -1 when
-- there is no way. pathfind.step makes one move and returns the steps left
-- (0 = there, -1 = failed). The route is planned again every
-- settings.path_replan seconds and whenever a move is blocked, because the
-- world (and an entity) changes.
--
-- Terrain nobody has loaded is a wall, unless the robot has Forceload on: then
-- it is assumed to be open and the robot goes anyway; Bot:move loads or
-- generates the blocks as it arrives and moves the forceload along.

local S = ...
local lang, settings = S.lang, S.settings
local Bot = S.Bot
local V = vector

local DIRS = {
	{ x = 1, y = 0, z = 0 }, { x = -1, y = 0, z = 0 }, { x = 0, y = 1, z = 0 },
	{ x = 0, y = -1, z = 0 }, { x = 0, y = 0, z = 1 }, { x = 0, y = 0, z = -1 },
}

local STALL_BLOCKED = 3    -- moves refused in a row before giving up
local LOADING_WAIT = 10    -- seconds to wait for terrain to load or generate before giving up

local function now () return core.get_us_time() / 1e6 end

local function round_pos (p)
	return { x = math.floor(p.x + 0.5), y = math.floor(p.y + 0.5), z = math.floor(p.z + 0.5) }
end

--------------------------------------------------------------------------
-- a binary heap of { f, g, hash }: lowest f first, deeper (higher g) on ties
-- so open ground is crossed in a line instead of flooded

local function before (a, b)
	if a[1] ~= b[1] then return a[1] < b[1] end
	return a[2] > b[2]
end

local function heap_push (heap, item)
	local i = #heap + 1
	heap[i] = item
	while i > 1 do
		local parent = math.floor(i / 2)
		if before(heap[i], heap[parent]) then
			heap[i], heap[parent] = heap[parent], heap[i]
			i = parent
		else break end
	end
end

local function heap_pop (heap)
	local top = heap[1]
	local last = table.remove(heap)
	if #heap > 0 then
		heap[1] = last
		local i, n = 1, #heap
		while true do
			local l, r, best = i * 2, i * 2 + 1, i
			if l <= n and before(heap[l], heap[best]) then best = l end
			if r <= n and before(heap[r], heap[best]) then best = r end
			if best == i then break end
			heap[i], heap[best] = heap[best], heap[i]
			i = best
		end
	end
	return top
end

--------------------------------------------------------------------------
-- search

local function manhattan (a, b)
	return math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs(a.z - b.z)
end

-- Cells to walk from `from` (not included) to the goal, or nil.
-- goal: { pos = cell, near = true when next to it is enough }
local function search (bot, from, goal, forceloaded)
	local reached = goal.near
		and function (c) return manhattan(c, goal.pos) <= 1 end
		or function (c) return V.equals(c, goal.pos) end

	if reached(from) then return {} end

	local hash = core.hash_node_position
	local start = hash(from)
	local cells = { [start] = from }
	local g_of, parent, closed = { [start] = 0 }, {}, {}
	local heap = {}
	heap_push(heap, { manhattan(from, goal.pos), 0, start })

	-- known free blocks; unloaded ones count as free for a forceloaded robot
	local height = S.height_limit(from)
	local free_cache = {}
	local function free (c, h)
		local v = free_cache[h]
		if v ~= nil then return v end
		local node = core.get_node_or_nil(c)
		if node == nil or node.name == "ignore" then
			v = forceloaded
		else
			v = S.node_passable(c) and not bot:protected(c) or false
		end
		free_cache[h] = v
		return v
	end

	local expanded = 0
	local limit = settings.path_max_nodes
	-- do not wander off further than the trip is long, plus some room
	local reach = manhattan(from, goal.pos) * 2 + 24

	while #heap > 0 do
		local top = heap_pop(heap)
		local h = top[3]
		if not closed[h] then
			closed[h] = true
			local c = cells[h]
			if reached(c) then
				local path = {}
				while h ~= start do
					table.insert(path, 1, cells[h])
					h = parent[h]
				end
				return path
			end

			expanded = expanded + 1
			if expanded > limit then return nil end

			local g = g_of[h] + 1
			for _, d in ipairs(DIRS) do
				local n = { x = c.x + d.x, y = c.y + d.y, z = c.z + d.z }
				local nh = hash(n)
				if not closed[nh] and manhattan(n, from) <= reach
					and free(n, nh) and (g_of[nh] == nil or g < g_of[nh])
					and S.move_allowed(c, n, height, from) then
					cells[nh] = n
					g_of[nh] = g
					parent[nh] = h
					heap_push(heap, { g + manhattan(n, goal.pos), g, nh })
				end
			end
		end
	end
end

--------------------------------------------------------------------------
-- targets

-- nearest non-item entity (or player) called name near the robot; its cell
local function find_entity (bot, name)
	local best, best_d
	for _, obj in ipairs(core.get_objects_inside_radius(bot.pos, settings.path_entity_radius)) do
		local le = obj:get_luaentity()
		local label = obj:is_player() and obj:get_player_name() or (le and le.name)
		if label == name and not (le and le.name == "__builtin:item") then
			local d = V.distance(bot.pos, obj:get_pos())
			if not best_d or d < best_d then best, best_d = obj, d end
		end
	end
	return best and round_pos(best:get_pos())
end

local function goal_of (bot, target)
	if target.entity then
		local cell = find_entity(bot, target.entity)
		return cell and { pos = cell, near = true }
	end
	return { pos = target.pos }
end

-- plan again from where the robot is; returns the steps or -1
local function plan (ctx)
	local st = ctx.path
	local bot = ctx.bot
	st.planned = now()
	st.cells, st.idx = {}, 0
	st.from = vector.new(bot.pos)

	local goal = goal_of(bot, st.target)
	if not goal then return -1 end

	local forceloaded = core.get_meta(bot.pos):get_int("persist") == 1
	local cells = search(bot, bot.pos, goal, forceloaded)
	if not cells then return -1 end

	st.cells = cells
	return #cells
end

local function begin (ctx, target)
	ctx.path = { target = target, stalls = 0 }
	local n = plan(ctx)
	if n < 0 then ctx.path = nil end
	return n
end

local function number (ctx, v, what)
	local n = lang.tonum(v)
	if not n then lang.rt_error(ctx, "pathfind needs a number for " .. what) end
	return math.floor(n + 0.5)
end

-- plan a path to a position; steps, or -1
function Bot:path_plan (ctx, x, y, z)
	return begin(ctx, { pos = { x = number(ctx, x, "x"), y = number(ctx, y, "y"), z = number(ctx, z, "z") } })
end

-- plan a path to the nearest entity (or player) called name; steps, or -1
function Bot:path_plan_entity (ctx, name)
	name = lang.tostr(name)
	if name == "" then lang.rt_error(ctx, "pathfind needs an entity name") end
	return begin(ctx, { entity = name })
end

function Bot:path_left (ctx)
	local st = ctx.path
	return st and (#st.cells - st.idx) or -1
end

function Bot:path_cancel (ctx)
	ctx.path = nil
end

-- One move along the path. Returns the steps left, 0 when there, -1 when it
-- failed (no way, blocked for good, or the target is gone).
function Bot:path_step (ctx)
	local st = ctx.path
	if not st then return -1 end

	local function fail ()
		ctx.path = nil
		return -1
	end

	-- somebody moved the robot, or it is time to look again
	local expected = st.idx == 0 and st.from or st.cells[st.idx]
	if now() - st.planned >= settings.path_replan or not V.equals(expected, self.pos) then
		if plan(ctx) < 0 then return fail() end
	end
	if st.idx >= #st.cells then
		ctx.path = nil
		return 0
	end

	local cell = st.cells[st.idx + 1]
	local loading = S.node_unknown(cell)
	-- a step costs what a move does
	if not loading and ctx.spend and not ctx.spend(1) then lang.rt_error(ctx, "out of power") end
	local ok, delay = self:step_to(cell)

	if ok then
		st.idx = st.idx + 1
		st.stalls, st.waiting_since = 0, nil
		if delay and delay > 0 then ctx.yield(delay) end
		local left = #st.cells - st.idx
		if left == 0 then
			-- a followed entity may have moved while we walked
			if st.target.entity and plan(ctx) > 0 then return #st.cells end
			ctx.path = nil
		end
		return left
	end

	if loading then
		-- terrain is being loaded or generated: wait for it
		st.waiting_since = st.waiting_since or now()
		if now() - st.waiting_since > LOADING_WAIT then return fail() end
		ctx.yield(math.max(delay or 0, 0.25))
		return #st.cells - st.idx
	end

	st.stalls = st.stalls + 1
	if st.stalls >= STALL_BLOCKED or plan(ctx) < 0 then return fail() end
	ctx.yield(delay or settings.move_delay)
	return #st.cells - st.idx
end
