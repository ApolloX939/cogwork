-- Events: a program registers handlers by function name (events.register) and
-- then sits in events.process, which scans the world, collects messages and
-- calls the handlers one at a time.
--
--   nodes     one of the six blocks next to the robot changed (dir, node, change, detail)
--   entities  a non-item entity or player came within radius  (name, distance)
--   items     a dropped item came within radius               (item, count, distance)
--   chat      a public chat message                           (player, message)
--   whisper   a player sent the robot a private message       (player, message)
--   bot       another robot sent a message                    (from, message)
--   join_player   a player joined                             (player)
--   new_player    a player joined for the first time (before join_player)  (player)
--   leave_player  a player left                               (player, timed_out)
--   chatcommand   a player ran a chat command (not the hidden ones, nor robots') (player, command, params)
--   gift      another robot gave items                        (from, item, count, slot, player)
--
-- Chat is limited per player (settings.chat_limit messages in
-- settings.chat_window seconds), robot to robot and robot to owner are not.

local cogwork = ...
local lang, settings = cogwork.lang, cogwork.settings
local Bot = cogwork.Bot
local S = cogwork.S

local QUEUE_MAX = 32
local PER_SCAN_MAX = 8
local MIN_INTERVAL = 0.5

cogwork.event_kinds = { nodes = true, entities = true, items = true, chat = true,
	whisper = true, bot = true, join_player = true, new_player = true, leave_player = true,
	chatcommand = true, gift = true }

local function now () return core.get_us_time() / 1e6 end

local function rt_error (ctx, msg) lang.rt_error(ctx, msg) end

--------------------------------------------------------------------------
-- rate limits: a list of recent times per key

local function allow (store, key)
	local t = now()
	local list = store[key] or {}
	store[key] = list

	local keep = {}
	for _, at in ipairs(list) do
		if t - at < settings.chat_window then keep[#keep + 1] = at end
	end
	store[key] = keep

	if #keep >= settings.chat_limit then return false end
	keep[#keep + 1] = t
	return true
end

local sent = {}   -- "pub:owner" / "priv:owner>player" -> times

-- forget the idle ones now and then
local function sweep (store)
	local t = now()
	for key, list in pairs(store) do
		if #list == 0 or t - list[#list] >= settings.chat_window then store[key] = nil end
	end
end
local sweep_timer = 0
core.register_globalstep(function (dt)
	sweep_timer = sweep_timer + dt
	if sweep_timer < 60 then return end
	sweep_timer = 0
	sweep(sent)
end)

--------------------------------------------------------------------------
-- per-program state

local function state (ctx)
	if not ctx.events then
		ctx.events = { reg = {}, queue = {}, rate = {} }
	end
	return ctx.events
end

local function push (ctx, kind, args)
	local ev = state(ctx)
	local reg = ev.reg[kind]
	if not reg or #ev.queue >= QUEUE_MAX then return false end
	ev.queue[#ev.queue + 1] = { handler = reg.handler, args = args }
	return true
end

-- the radius sets how often the world is scanned: the nearer the limit, the slower
local function scan_interval (radius)
	return math.max(MIN_INTERVAL, radius / settings.event_max_radius * settings.event_max_interval)
end

function Bot:event_register (ctx, kind, radius, handler)
	kind = lang.tostr(kind):lower()
	handler = lang.tostr(handler)
	if not cogwork.event_kinds[kind] then
		rt_error(ctx, "unknown event '" .. kind .. "' (nodes, entities, items, chat, whisper, bot, join_player, new_player, leave_player, chatcommand, gift)")
	end
	if not lang.find_fn(ctx.unit, handler) then
		rt_error(ctx, "unknown function '" .. handler .. "' for the " .. kind .. " event")
	end

	local reg = { handler = handler }
	if kind == "entities" or kind == "items" then
		local r = lang.tonum(radius)
		if not r or r ~= math.floor(r) or r < 1 or r > settings.event_max_radius then
			rt_error(ctx, "the " .. kind .. " event needs a radius from 1 to " .. settings.event_max_radius)
		end
		reg.radius = r
		reg.interval = scan_interval(r)
	elseif kind == "nodes" then
		reg.interval = MIN_INTERVAL
	end
	reg.due = 0
	reg.seen = nil

	state(ctx).reg[kind] = reg
	return true, 0
end

function Bot:event_count (ctx)
	local n = 0
	for _ in pairs(state(ctx).reg) do n = n + 1 end
	return n
end

--------------------------------------------------------------------------
-- scanners

local SIDES = { "front", "back", "left", "right", "up", "down" }

local function side_vector (front, side)
	if side == "front" then return front
	elseif side == "back" then return vector.multiply(front, -1)
	elseif side == "left" then return { x = -front.z, y = 0, z = front.x }
	elseif side == "right" then return { x = front.z, y = 0, z = -front.x }
	elseif side == "up" then return { x = 0, y = 1, z = 0 }
	end
	return { x = 0, y = -1, z = 0 }
end

-- what is worth comparing about the block at p: its name, the contents of its
-- inventory lists, its node timer and what its machine reports
local function inventory_signatures (p)
	local sigs = {}
	local inv = core.get_meta(p):get_inventory()
	for name, list in pairs(inv:get_lists()) do
		local parts = {}
		for i, stack in ipairs(list) do parts[i] = stack:to_string() end
		sigs[name] = table.concat(parts, "|")
	end
	return sigs
end

local function snapshot (p, name)
	local snap = { name = name, inv = inventory_signatures(p) }

	local timer = core.get_node_timer(p)
	snap.timer = { started = timer:is_started(), elapsed = timer:get_elapsed() }

	local info = cogwork.machine_info(p)
	if info then
		snap.state = info.state
		snap.level = info.level or info.network_level
	end
	return snap
end

-- push one event per change of a block next to the robot:
--   node       the block was replaced                  detail: the name it had
--   inventory  a list of its inventory changed         detail: the list's name
--   timer      its node timer started, stopped or ran out and restarted
--   state      its machine switched                    detail: on, off, ...
--   power      the charge of its battery / network     detail: percent
local function changes (before, after, side, push_event)
	if before.name ~= after.name then
		push_event(side, after.name, "node", before.name)
		return
	end

	for list, sig in pairs(after.inv) do
		if before.inv[list] ~= nil and before.inv[list] ~= sig then
			push_event(side, after.name, "inventory", list)
		end
	end

	if before.timer.started ~= after.timer.started then
		push_event(side, after.name, "timer", after.timer.started and "started" or "stopped")
	elseif after.timer.started and after.timer.elapsed < before.timer.elapsed then
		push_event(side, after.name, "timer", "restarted")
	end

	if after.state ~= nil and before.state ~= nil and before.state ~= after.state then
		push_event(side, after.name, "state", after.state)
	end
	if after.level ~= nil and before.level ~= nil and before.level ~= after.level then
		push_event(side, after.name, "power", after.level)
	end
end

local function scan_nodes (bot, ctx, reg)
	local front = bot:front_vec()
	local last = reg.seen
	reg.seen = {}
	local fired = 0

	local function push_event (side, name, change, detail)
		if fired < PER_SCAN_MAX then
			fired = fired + 1
			push(ctx, "nodes", { side, name, change, detail })
		end
	end

	for _, side in ipairs(SIDES) do
		local p = vector.add(bot.pos, side_vector(front, side))
		local node = core.get_node_or_nil(p)
		if node and node.name ~= "ignore" then
			local snap = snapshot(p, node.name)
			reg.seen[side] = snap
			-- the first scan only learns what is there
			if last and last[side] then changes(last[side], snap, side, push_event) end
		else
			-- not loaded: keep what we knew
			reg.seen[side] = last and last[side] or nil
		end
	end
end

local function object_id (obj)
	return obj.get_guid and obj:get_guid() or obj
end

local function is_item (obj)
	local le = obj:get_luaentity()
	return le ~= nil and le.name == "__builtin:item"
end

local function scan_objects (bot, ctx, reg, kind)
	local last = reg.seen
	reg.seen = {}
	local fired = 0

	for _, obj in ipairs(core.get_objects_inside_radius(bot.pos, reg.radius)) do
		local item = is_item(obj)
		-- the robots' own bodies are no entities to react to
		if not cogwork.is_visual(obj) and item == (kind == "items") then
			local id = object_id(obj)
			reg.seen[id] = true
			if last and not last[id] and fired < PER_SCAN_MAX then
				local dist = math.floor(vector.distance(bot.pos, obj:get_pos()))
				if kind == "items" then
					local stack = ItemStack(obj:get_luaentity().itemstring or "")
					if not stack:is_empty() then
						push(ctx, "items", { stack:get_name(), stack:get_count(), dist })
						fired = fired + 1
					end
				else
					local name = obj:is_player() and obj:get_player_name()
						or (obj:get_luaentity() and obj:get_luaentity().name) or "unknown"
					push(ctx, "entities", { name, dist })
					fired = fired + 1
				end
			end
		end
	end
end

local function run_scans (bot, ctx)
	local t = now()
	for kind, reg in pairs(state(ctx).reg) do
		if reg.interval and t >= reg.due then
			reg.due = t + reg.interval
			if kind == "nodes" then scan_nodes(bot, ctx, reg)
			else scan_objects(bot, ctx, reg, kind) end
		end
	end
end

-- Next event to handle, or nil when there is none right now.
function Bot:event_next (ctx)
	run_scans(self, ctx)
	return table.remove(state(ctx).queue, 1)
end

-- how long process should sleep when it has nothing to do
function Bot:event_idle (ctx)
	-- waiting for something to happen is cheap, but not free
	if ctx.spend and not ctx.spend(0.02) then lang.rt_error(ctx, "out of power") end
	return math.max(settings.tick, 0.1)
end

--------------------------------------------------------------------------
-- chat

local function bot_label (pos)
	local meta = core.get_meta(pos)
	local name = meta:get_string("bot_name")
	return name ~= "" and name or "Robot"
end

-- every running program (with its position) listening for this kind
local function listening (kind)
	local out = {}
	for _, r in pairs(cogwork.running) do
		if r.ctx.events and r.ctx.events.reg[kind] then out[#out + 1] = r end
	end
	return out
end

-- one player's messages to one robot, limited
local function accept_from (r, kind, player)
	return allow(state(r.ctx).rate, kind .. ":" .. player)
end

core.register_on_chat_message(function (name, message)
	for _, r in ipairs(listening("chat")) do
		if accept_from(r, "chat", name) then push(r.ctx, "chat", { name, message }) end
	end
end)

-- chat commands, except the hidden ones (the /bot command among them) and those
-- a robot runs as its owner (a handler could start itself again)
local hidden = {}
for name in settings.chatcommand_hidden:gmatch("[^,%s]+") do hidden[name:lower()] = true end
hidden.bot = true

core.register_on_chatcommand(function (name, command, params)
	if cogwork.running_owner_command or hidden[command:lower()] then return end
	for _, r in ipairs(listening("chatcommand")) do
		if accept_from(r, "chatcommand", name) then push(r.ctx, "chatcommand", { name, command, params }) end
	end
end)

-- players coming and going: every running program registered for it hears it
local function tell_listeners (kind, args)
	for _, r in ipairs(listening(kind)) do push(r.ctx, kind, args) end
end

cogwork.tell_listeners = tell_listeners

core.register_on_newplayer(function (player)
	tell_listeners("new_player", { player:get_player_name() })
end)

core.register_on_joinplayer(function (player)
	tell_listeners("join_player", { player:get_player_name() })
end)

core.register_on_leaveplayer(function (player, timed_out)
	tell_listeners("leave_player", { player:get_player_name(), timed_out and true or false })
end)

-- a private message to a robot by its name; true, count or false, reason
function cogwork.whisper_to_bot (player, botname, message)
	local want = botname:lower()
	local found, delivered, limited = 0, 0, 0

	for _, r in ipairs(listening("whisper")) do
		local pos = r.bot.pos
		local meta = core.get_meta(pos)
		if bot_label(pos):lower() == want
			and (meta:get_string("owner") == player or meta:get_int("public") == 1
			or meta:get_int("public_talk") == 1) then
			found = found + 1
			if accept_from(r, "whisper", player) then
				push(r.ctx, "whisper", { player, message })
				delivered = delivered + 1
			else
				limited = limited + 1
			end
		end
	end

	if found == 0 then return false, S("No robot called '@1' is listening to you.", botname) end
	if delivered == 0 and limited > 0 then
		return false, S("Slow down: @1 messages every @2 seconds.", settings.chat_limit, settings.chat_window)
	end
	return true, delivered
end

local function chat_prefix (pos)
	return "<" .. bot_label(pos) .. "> "
end

-- to everyone, limited per owner
function Bot:say (text)
	if not settings.public_chat then return false, 0 end
	if not allow(sent, "pub:" .. (self.owner or "")) then return false, 0 end
	core.chat_send_all(chat_prefix(self.pos) .. text)
	return true, 0
end

-- to one player, limited per player
function Bot:whisper (player, text)
	player = lang.tostr(player)
	if not settings.public_chat or not core.get_player_by_name(player) then return false, 0 end
	if not allow(sent, "priv:" .. (self.owner or "") .. ">" .. player) then return false, 0 end
	core.chat_send_player(player, core.colorize("#c8a0ff", chat_prefix(self.pos) .. "(private) " .. text))
	return true, 0
end

--------------------------------------------------------------------------
-- robot to robot
--
-- A robot only hears robots of its own owner, and those the owner allowed in
-- the Settings tab: "Player" lets all of Player's robots in, "Player/Name"
-- only the one called Name. No limits.

local function parse_allow (meta)
	local list = {}
	for entry in meta:get_string("bot_allow"):gmatch("[^\n]+") do list[#list + 1] = entry end
	return list
end
cogwork.bot_allow_list = function (pos) return parse_allow(core.get_meta(pos)) end

function cogwork.bot_allow_set (pos, list)
	core.get_meta(pos):set_string("bot_allow", table.concat(list, "\n"))
end

local function allows (receiver_pos, sender_owner, sender_name)
	local meta = core.get_meta(receiver_pos)
	if sender_owner == meta:get_string("owner") then return true end
	for _, entry in ipairs(parse_allow(meta)) do
		local who, what = entry:match("^([^/]+)/(.+)$")
		if not who then who = entry end
		if who == sender_owner and (not what or what:lower() == sender_name:lower()) then
			return true
		end
	end
	return false
end

-- Running robots that listen for robots and let the one at pos in
-- (not the one at pos itself); each { pos, ctx, owner, name }.
local function listeners_of (pos, kind)
	local meta = core.get_meta(pos)
	local owner, name = meta:get_string("owner"), bot_label(pos)
	local out = {}
	for _, r in ipairs(listening(kind or "bot")) do
		local rpos = r.bot.pos
		if not vector.equals(rpos, pos) and allows(rpos, owner, name) then
			out[#out + 1] = { pos = rpos, ctx = r.ctx,
				owner = core.get_meta(rpos):get_string("owner"), name = bot_label(rpos) }
		end
	end
	return out
end

-- "Owner/Name" of each, for the Settings tab and the program
function cogwork.listeners_of (pos)
	local names = {}
	for _, l in ipairs(listeners_of(pos)) do names[#names + 1] = l.owner .. "/" .. l.name end
	table.sort(names)
	return names
end

function Bot:listeners ()
	return cogwork.listeners_of(self.pos)
end

local function deliver (self, ctx_filter, text)
	local meta = core.get_meta(self.pos)
	local from = meta:get_string("owner") .. "/" .. bot_label(self.pos)
	local n = 0
	for _, l in ipairs(listeners_of(self.pos)) do
		if ctx_filter(l) and push(l.ctx, "bot", { from, text }) then n = n + 1 end
	end
	return n
end

-- to the robots called name that listen to this one
function Bot:tell_bot (name, text)
	local want = lang.tostr(name):lower()
	local n = deliver(self, function (l) return l.name:lower() == want end, text)
	return n > 0, 0
end

-- to every robot that listens to this one
function Bot:tell_bots (text)
	local n = deliver(self, function () return true end, text)
	return n > 0, 0
end

--------------------------------------------------------------------------
-- items between robots
--
-- give_bot / give_slot move one stack at most to a running robot of that name
-- that registered for "gift" and allows the sender. A receiver with "Keep
-- received stacks apart" on (Settings tab) puts each gift in an empty slot,
-- tagged with the player it is for (item meta GIFT_FOR, which also stops the
-- stacks merging); any other receiver merges it and drops the tag.

local LIST = "main"
local GIFT_FOR = "cw_for"
cogwork.GIFT_FOR = GIFT_FOR

-- first empty slot of the list, or nil
local function empty_slot (inv)
	for i = 1, inv:get_size(LIST) do
		if inv:get_stack(LIST, i):is_empty() then return i end
	end
end

-- Put the stack into the receiver's storage; the slot it ended up in, or nil
-- (nothing changed) when it does not fit.
local function store_gift (rpos, stack, player)
	local meta = core.get_meta(rpos)
	local inv = meta:get_inventory()
	if meta:get_int("keep_apart") == 1 then
		local slot = empty_slot(inv)
		if not slot then return nil end
		stack:get_meta():set_string(GIFT_FOR, player)
		inv:set_stack(LIST, slot, stack)
		return slot
	end

	stack:get_meta():set_string(GIFT_FOR, "")
	if not inv:room_for_item(LIST, stack) then return nil end
	inv:add_item(LIST, stack)
	-- the slot it was added to is not known when it merges: tell the first one holding it
	for i = 1, inv:get_size(LIST) do
		if inv:get_stack(LIST, i):get_name() == stack:get_name() then return i end
	end
end

-- give `count` of the stack in slot `slot` of this robot's storage
local function give_from_slot (self, name, slot, count, player)
	local inv = self:inv()
	local st = slot >= 1 and slot <= inv:get_size(LIST) and inv:get_stack(LIST, slot)
	if not st or st:is_empty() then return false, 0 end

	local n = st:get_count()
	count = count ~= nil and lang.tonum(count)
	if count then n = math.min(n, math.max(1, math.floor(count))) end
	n = math.min(n, st:get_stack_max())

	local meta = core.get_meta(self.pos)
	local owner = meta:get_string("owner")
	local tag = player and lang.tostr(player) or ""
	if tag == "" then tag = st:get_meta():get_string(GIFT_FOR) end
	if tag == "" then tag = owner end
	local from = owner .. "/" .. bot_label(self.pos)

	local want = lang.tostr(name):lower()
	for _, l in ipairs(listeners_of(self.pos, "gift")) do
		local ev = state(l.ctx)
		if l.name:lower() == want and #ev.queue < QUEUE_MAX then
			local gift = ItemStack(st)
			gift:set_count(n)
			local at = store_gift(l.pos, gift, tag)
			if at then
				st:set_count(st:get_count() - n)
				inv:set_stack(LIST, slot, st)
				push(l.ctx, "gift", { from, gift:get_name(), n, at, tag })
				return true, 0
			end
		end
	end
	return false, 0
end

function Bot:give_slot (name, slot, count)
	return give_from_slot(self, name, slot, count, nil)
end

function Bot:give_bot (name, item, count, player)
	item = lang.tostr(item)
	local inv = self:inv()
	for i = 1, inv:get_size(LIST) do
		local st = inv:get_stack(LIST, i)
		if not st:is_empty() and cogwork.item_matches(st:get_name(), item ~= "" and item or nil) then
			return give_from_slot(self, name, i, count, player)
		end
	end
	return false, 0
end

function Bot:slot_count ()
	return self:inv():get_size(LIST)
end

-- what is in storage slot n: "item", "count" or "for"
function Bot:slot_info (n, what)
	local inv = self:inv()
	local st = n >= 1 and n <= inv:get_size(LIST) and inv:get_stack(LIST, n)
	if not st or st:is_empty() then return what == "count" and 0 or "" end
	if what == "item" then return st:get_name() end
	if what == "count" then return st:get_count() end
	return st:get_meta():get_string(GIFT_FOR)
end

-- Remove the tag from the stack in slot n so it merges with stacks that never
-- had one (it goes into the first stack of the item with room, else the first
-- empty slot, which can be another slot than n).
function Bot:untag_slot (n)
	local inv = self:inv()
	local st = n >= 1 and n <= inv:get_size(LIST) and inv:get_stack(LIST, n)
	if not st or st:is_empty() or st:get_meta():get_string(GIFT_FOR) == "" then return false, 0 end

	inv:set_stack(LIST, n, ItemStack(""))
	st:get_meta():set_string(GIFT_FOR, "")
	local left = inv:add_item(LIST, st)
	-- no room: it was not merged, put it back as it was
	if not left:is_empty() then
		left:get_meta():set_string(GIFT_FOR, "")
		inv:set_stack(LIST, n, left)
	end
	return true, 0
end

--------------------------------------------------------------------------
-- items to a player
--
-- give_player / give_player_slot put one stack at most into the inventory of an
-- online player (all or nothing, the tag is dropped) and tell them, within the
-- private message limits. cogwork_give_range limits the distance (0: none).

local function give_to_player (self, player, slot, count)
	player = lang.tostr(player)
	local obj = core.get_player_by_name(player)
	local inv = self:inv()
	local st = obj and slot >= 1 and slot <= inv:get_size(LIST) and inv:get_stack(LIST, slot)
	if not st or st:is_empty() then return false, 0 end
	if settings.give_range > 0 and vector.distance(self.pos, obj:get_pos()) > settings.give_range then
		return false, 0
	end

	local n = st:get_count()
	count = count ~= nil and lang.tonum(count)
	if count then n = math.min(n, math.max(1, math.floor(count))) end
	n = math.min(n, st:get_stack_max())

	local gift = ItemStack(st)
	gift:set_count(n)
	gift:get_meta():set_string(GIFT_FOR, "")
	local pinv = obj:get_inventory()
	if not pinv:room_for_item("main", gift) then return false, 0 end
	pinv:add_item("main", gift)

	st:set_count(st:get_count() - n)
	inv:set_stack(LIST, slot, st)

	if allow(sent, "priv:" .. (self.owner or "") .. ">" .. player) then
		core.chat_send_player(player, core.colorize("#c8a0ff", chat_prefix(self.pos)
			.. S("gave you @1 x @2", n, gift:get_description() ~= "" and gift:get_description() or gift:get_name())))
	end
	return true, 0
end

function Bot:give_player_slot (player, slot, count)
	return give_to_player(self, player, slot, count)
end

function Bot:give_player (player, item, count)
	item = lang.tostr(item)
	local inv = self:inv()
	for i = 1, inv:get_size(LIST) do
		local st = inv:get_stack(LIST, i)
		if not st:is_empty() and cogwork.item_matches(st:get_name(), item ~= "" and item or nil) then
			return give_to_player(self, player, i, count)
		end
	end
	return false, 0
end
