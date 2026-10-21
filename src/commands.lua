-- Built-in commands. Every definition is
--   { name, kind = "action" | "query", category, args = {...}, run = function(ctx, ...) }
-- Actions return ok, delay_seconds. Queries return a value.
-- World access goes through ctx.bot (see robot_ops.lua).

local lang = ...

local cmds = lang.commands

local DIR8   = { type = "dir8" }
local DIR4   = { type = "dir4" }
local TURN   = { type = "turn" }
local VAL    = { type = "val" }
local OPTVAL = { type = "val", optional = true }

local function register (def)
	assert(def.name and def.kind and def.run, "incomplete command definition")
	def.args = def.args or {}
	def.category = def.category or "action"
	cmds[def.name] = def
	return def
end
lang.register_command = register

local function action (name, category, args, run)
	return register({ name = name, kind = "action", category = category, args = args, run = run })
end

local function query (name, category, args, run)
	return register({ name = name, kind = "query", category = category, args = args, run = run })
end

--------------------------------------------------------------------------
-- movement and blocks

action("move", "move", { DIR4 }, function (ctx, dir) return ctx.bot:move(dir) end)
action("turn", "move", { TURN }, function (ctx, dir) return ctx.bot:turn(dir) end)
action("dig", "world", { DIR8 }, function (ctx, dir) return ctx.bot:dig(dir) end)
action("place", "world", { DIR8, OPTVAL }, function (ctx, dir, item)
	return ctx.bot:place(dir, item)
end)
action("interact", "world", { DIR8 }, function (ctx, dir) return ctx.bot:interact(dir) end)
-- no item: pick up dropped items, else hit an entity with bare hands;
-- with an item from storage: hit an entity with it (players are never hit)
action("punch", "world", { DIR8, OPTVAL }, function (ctx, dir, item)
	return ctx.bot:punch(dir, item)
end)

--------------------------------------------------------------------------
-- inventory transfers (container in front of the robot, or the world)

for _, def in ipairs({
	{ "pull", "from the container in front into the robot", "pull" },
	{ "put", "from the robot into the container in front", "put" },
	{ "drop", "from the robot into the world", "drop" },
	{ "trash", "destroys items in the robot", "trash" },
}) do
	local verb = def[3]
	action(verb, "inventory", { OPTVAL }, function (ctx, item)
		return ctx.bot:transfer(verb, item, false)
	end)
	action(verb .. "_stack", "inventory", { OPTVAL }, function (ctx, item)
		return ctx.bot:transfer(verb, item, true)
	end)
end

action("craft", "inventory", { VAL }, function (ctx, item)
	return ctx.bot:craft(item)
end)

--------------------------------------------------------------------------
-- program control

action("wait", "flow", { VAL }, function (ctx, n)
	n = lang.tonum(n)
	if not n or n < 0 then lang.rt_error(ctx, "'wait' needs a number of tenths of a second") end
	return true, n / 10
end)

action("stop", "flow", {}, function (ctx)
	assert(false, { scratch = true, stop = true, msg = "stopped" })
end)

-- chat: to the owner (no limit), to everyone / to one player (limited per player)
action("chat", "flow", { VAL }, function (ctx, text)
	return ctx.bot:chat(lang.tostr(text))
end)

action("say", "flow", { VAL }, function (ctx, text)
	return ctx.bot:say(lang.tostr(text))
end)

action("whisper", "flow", { VAL, VAL }, function (ctx, player, text)
	return ctx.bot:whisper(player, lang.tostr(text))
end)

--------------------------------------------------------------------------
-- events (see events.lua; the `events` package wraps these)

action("event_register", "flow", { VAL, VAL, VAL }, function (ctx, kind, radius, handler)
	return ctx.bot:event_register(ctx, kind, radius, handler)
end)

-- Handle events until event_leave; each handler runs to its end before the next
action("event_process", "flow", {}, function (ctx)
	if ctx.bot:event_count(ctx) == 0 then
		lang.rt_error(ctx, "nothing to process: call events.register first")
	end
	ctx.leave = false
	while not ctx.leave do
		local ev = ctx.bot:event_next(ctx)
		if ev then
			lang.call_named(ctx, ev.handler, ev.args)
		else
			ctx.yield(ctx.bot:event_idle(ctx))
		end
	end
	return true
end)

action("event_leave", "flow", {}, function (ctx)
	ctx.leave = true
	return true
end)

-- robot to robot, no limits; only robots that allow this one hear it
action("tell_bot", "flow", { VAL, VAL }, function (ctx, name, text)
	return ctx.bot:tell_bot(name, lang.tostr(text))
end)

action("tell_bots", "flow", { VAL }, function (ctx, text)
	return ctx.bot:tell_bots(lang.tostr(text))
end)

--------------------------------------------------------------------------
-- queries

query("counter", "check", {}, function (ctx) return ctx.counter end)
query("ok", "check", {}, function (ctx) return ctx.ok end)

query("detect", "check", { DIR8, OPTVAL }, function (ctx, dir, item)
	return ctx.bot:detect(dir, item)
end)
query("node", "check", { DIR8 }, function (ctx, dir) return ctx.bot:node(dir) end)
query("contains", "check", { OPTVAL }, function (ctx, item) return ctx.bot:contains(item) end)
query("fits", "check", { OPTVAL }, function (ctx, item) return ctx.bot:fits(item) end)
query("count", "check", { VAL }, function (ctx, item) return ctx.bot:count(item) end)
query("pos_x", "check", {}, function (ctx) return ctx.bot:coord("x") end)
query("pos_y", "check", {}, function (ctx) return ctx.bot:coord("y") end)
query("pos_z", "check", {}, function (ctx) return ctx.bot:coord("z") end)
query("facing", "check", {}, function (ctx) return ctx.bot:facing() end)

local function intpart (ctx, v, name)
	v = lang.tonum(v)
	if not v then lang.rt_error(ctx, "'" .. name .. "' needs a number") end
	return math.floor(v)
end

query("even", "check", { VAL }, function (ctx, v) return intpart(ctx, v, "even") % 2 == 0 end)
query("odd", "check", { VAL }, function (ctx, v) return intpart(ctx, v, "odd") % 2 == 1 end)
query("floor", "check", { VAL }, function (ctx, v) return intpart(ctx, v, "floor") end)
query("length", "check", { VAL }, function (ctx, v) return #lang.tostr(v) end)

-- robots that are running, listen for robot messages and allow this one
query("listeners", "check", {}, function (ctx) return #ctx.bot:listeners() end)
query("listener", "check", { VAL }, function (ctx, n)
	n = intpart(ctx, n, "listener")
	return ctx.bot:listeners()[n] or ""
end)

-- name of the entity (not an item or a player) in the block in dir, "" if none
query("entity", "check", { DIR8 }, function (ctx, dir) return ctx.bot:entity_at(dir) end)

-- pathfinding (see pathfind.lua; the `pathfind` package wraps these)
query("path_plan", "check", { VAL, VAL, VAL }, function (ctx, x, y, z)
	return ctx.bot:path_plan(ctx, x, y, z)
end)
query("path_plan_entity", "check", { VAL }, function (ctx, name)
	return ctx.bot:path_plan_entity(ctx, name)
end)
query("path_step", "check", {}, function (ctx) return ctx.bot:path_step(ctx) end)
query("path_left", "check", {}, function (ctx) return ctx.bot:path_left(ctx) end)
action("path_cancel", "flow", {}, function (ctx)
	ctx.bot:path_cancel(ctx)
	return true
end)

query("random", "check", { VAL }, function (ctx, n)
	n = intpart(ctx, n, "random")
	if n < 1 then lang.rt_error(ctx, "'random' needs a number above zero") end
	return ctx.bot:random(n)
end)

return cmds
