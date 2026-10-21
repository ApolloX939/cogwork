-- Scheduler: runs each robot's program as a coroutine.

local S = ...
local lang, compat, settings = S.lang, S.compat, S.settings

local running = {}   -- pos hash -> run record
S.running = running

local hash = core.hash_node_position

function S.is_running (pos)
	return running[hash(pos)] ~= nil
end

function S.running_line (pos)
	local r = running[hash(pos)]
	return r and r.ctx.line or nil
end

local function set_variant (pos, on)
	S.refresh_variant(pos, on)
end

-- called by Bot:move
function S.on_robot_moved (from, to)
	local r = running[hash(from)]
	if r then
		running[hash(from)] = nil
		running[hash(to)] = r
	end
end

function S.stop (pos, message)
	local key = hash(pos)
	local r = running[key]
	running[key] = nil

	local node = core.get_node_or_nil(pos)
	if node and S.is_robot(node.name) then
		set_variant(pos, false)
		if message ~= nil then core.get_meta(pos):set_string("error", message) end
	end

	return r ~= nil
end

function S.start (pos)
	local node = core.get_node_or_nil(pos)
	if not node or not S.is_robot(node.name) then return false, "no robot" end
	if running[hash(pos)] then return true end

	local meta = core.get_meta(pos)
	local unit, err = S.compile_for(pos, meta:get_string("program"))
	if not unit then
		meta:set_string("error", err)
		return false, err
	end

	local bot = S.Bot.new(pos, meta:get_string("owner"))
	local ctx = lang.new_ctx({ bot = bot, budget = settings.step_budget })
	ctx.alias = function (tok)
		local v = compat.alias(tok)
		if not v then
			lang.rt_error(ctx, "'" .. tok .. "' does not exist in this game")
		end
		return v
	end

	local co = coroutine.create(function () lang.run(unit, ctx) end)

	running[hash(pos)] = { co = co, ctx = ctx, bot = bot, wait = 0 }
	meta:set_string("error", "")
	set_variant(pos, true)
	return true
end

local function finish (r, err)
	local pos = r.bot.pos
	running[hash(pos)] = nil

	local message = ""
	if err ~= nil then
		if type(err) == "table" and err.stop then
			if err.fatal then return end
		elseif type(err) == "table" and err.scratch then
			message = lang.format_error(err)
		else
			message = "internal error: " .. tostring(err)
			core.log("error", "[cogwork] " .. debug.traceback(r.co, tostring(err)))
		end
	end

	S.stop(pos, message)
end

local timer = 0

core.register_globalstep(function (dt)
	timer = timer + dt
	if timer < settings.tick then return end
	dt, timer = timer, 0

	local list = {}
	for _, r in pairs(running) do list[#list + 1] = r end

	for _, r in ipairs(list) do
		local pos = r.bot.pos
		local node = core.get_node_or_nil(pos)

		if node == nil then
			-- block not loaded: the program pauses
		elseif not S.is_robot(node.name) then
			running[hash(pos)] = nil
		else
			r.wait = r.wait - dt
			if r.wait <= 0 then
				-- Callbacks the program triggers (a placed item's on_place right-clicks the
				-- node it is placed against: the robot) must not open the editor
				S.acting = true
				local ok, res = coroutine.resume(r.co)
				S.acting = false
				if not ok then
					finish(r, res)
				elseif coroutine.status(r.co) == "dead" then
					finish(r)
				else
					r.wait = tonumber(res) or 0
				end
			end
		end
	end
end)

-- robots that were running when the world was saved
core.register_lbm({
	label = "Cogwork resume",
	name = "cogwork:resume",
	nodenames = { "cogwork:robot_on", "cogwork:drone_on" },
	run_at_every_load = true,
	action = function (pos)
		if running[hash(pos)] then return end
		if settings.resume_on_start then
			S.start(pos)
		else
			set_variant(pos, false)
		end
	end,
})
