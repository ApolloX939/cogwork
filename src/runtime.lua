-- Scheduler: runs each robot's program as a coroutine.

local cogwork = ...
local lang, compat, settings = cogwork.lang, cogwork.compat, cogwork.settings
local S = cogwork.S

local running = {}   -- pos hash -> run record
cogwork.running = running

local hash = core.hash_node_position

function cogwork.is_running (pos)
	return running[hash(pos)] ~= nil
end

function cogwork.running_line (pos)
	local r = running[hash(pos)]
	return r and r.ctx.line or nil
end

local function set_variant (pos, on)
	cogwork.refresh_variant(pos, on)
end

-- called by Bot:move
function cogwork.on_robot_moved (from, to)
	local r = running[hash(from)]
	if r then
		running[hash(from)] = nil
		running[hash(to)] = r
	end
end

function cogwork.stop (pos, message)
	local key = hash(pos)
	local r = running[key]
	running[key] = nil

	local node = core.get_node_or_nil(pos)
	if node and cogwork.is_robot(node.name) then
		set_variant(pos, false)
		if message ~= nil then core.get_meta(pos):set_string("error", message) end
		-- a robot that is off falls to the floor
		if cogwork.settle_later and not cogwork.moving then cogwork.settle_later(pos) end
	end

	return r ~= nil
end

function cogwork.start (pos)
	local node = core.get_node_or_nil(pos)
	if not node or not cogwork.is_robot(node.name) then return false, "no robot" end
	if running[hash(pos)] then return true end

	local meta = core.get_meta(pos)

	-- no armor, no cell, or nothing in the cells: the robot stays off
	cogwork.ensure_structure(pos)
	local why = cogwork.cannot_run(pos)
	if why then
		meta:set_string("error", why)
		return false, why
	end

	local unit, err = cogwork.compile_for(pos, meta:get_string("program"))
	if not unit then
		meta:set_string("error", err)
		return false, err
	end

	local bot = cogwork.Bot.new(pos, meta:get_string("owner"))
	local ctx = lang.new_ctx({ bot = bot, budget = settings.step_budget })
	ctx.spend = function (amount) return cogwork.spend(bot.pos, amount) end
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

	cogwork.stop(pos, message)
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
		elseif not cogwork.is_robot(node.name) then
			running[hash(pos)] = nil
		else
			-- armor taken out, cells run dry: stop (and stay off)
			r.check = (r.check or 0) - dt
			r.since = (r.since or 0) + dt
			local why
			if r.check <= 0 then
				r.check = 0.5
				why = cogwork.cannot_run(pos)
				if not why then
					-- staying above the floor costs power (hover and flight upgrades)
					local drain = cogwork.lift_drain(pos)
					if drain > 0 and not cogwork.spend(pos, drain * r.since) then
						why = S("Out of power: every power cell is empty")
					end
				end
				r.since = 0
				if why then cogwork.stop(pos, why) end
			end

			r.wait = r.wait - dt
			if not why and r.wait <= 0 then
				-- Callbacks the program triggers (a placed item's on_place right-clicks the
				-- node it is placed against: the robot) must not open the editor
				cogwork.acting = true
				local ok, res = coroutine.resume(r.co)
				cogwork.acting = false
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
	nodenames = { "cogwork:robot_on", "cogwork:hover_on", "cogwork:drone_on" },
	run_at_every_load = true,
	action = function (pos)
		if running[hash(pos)] then return end
		if settings.resume_on_start or core.get_meta(pos):get_int("resume") == 1 then
			cogwork.start(pos)
		else
			set_variant(pos, false)
		end
	end,
})
