-- Machines next to a robot: what they report and how to switch them.
--
-- One reading per node, whatever mod it comes from:
--   mod      "sbz_power", "technic" or "techage"
--   state    "on", "off", or the machine's own word (techage: "running", "stopped", ...)
--   power    energy held (battery) or used/made (machines), nil when unknown
--   capacity what a battery holds, nil when unknown
--   level    0..100 charge in percent, nil when there is no way to tell
--   supply, demand   of the network the node is in (sbz_power), or of the node (technic)
--
-- Each adapter reads the mod's own fields and API; a mod that is not
-- installed is skipped.

local S = ...

local function pct (v, max)
	if not v or not max or max <= 0 then return nil end
	return math.max(0, math.min(100, math.floor(v / max * 100 + 0.5)))
end

--------------------------------------------------------------------------
-- Skyblock: Zero power: batteries keep "power" in their meta, machines are
-- "<name>_on" / "<name>_off", the switching station knows the network

local function sbz_info (pos, node, def)
	if not rawget(_G, "sbz_api") or core.get_item_group(node.name, "sbz_machine") ~= 1 then return nil end
	local meta = core.get_meta(pos)
	local info = { mod = "sbz_power" }

	local ok, on = pcall(sbz_api.is_on, pos)
	info.state = (ok and on) and "on" or "off"

	if core.get_item_group(node.name, "sbz_battery") == 1 then
		local max = def.battery_max
		if def.get_battery_max then
			local good, m = pcall(def.get_battery_max, pos, meta)
			if good then max = m end
		end
		info.power, info.capacity = meta:get_int("power"), max
		info.level = pct(info.power, max)
	else
		local used, made = meta:get_int("power_consumed"), meta:get_int("power_generated")
		info.power = made > 0 and made or used
	end

	-- the network this node is in
	local id = sbz_api.pos2network and sbz_api.pos2network[core.hash_node_position(pos)]
	local net = id and sbz_api.networks and sbz_api.networks[id]
	if net then
		info.supply, info.demand = net.supply, net.demand
		-- what the batteries of the network hold, in percent
		info.network_level = pct(net.battery_supply_only or net.battery_power, net.battery_max)
	end
	return info
end

local function sbz_switch (pos, node, on)
	if not rawget(_G, "sbz_api") or core.get_item_group(node.name, "sbz_machine") ~= 1 then return nil end
	local meta = core.get_meta(pos)
	if on then sbz_api.force_turn_on(pos, meta) else sbz_api.force_turn_off(pos, meta) end
	return true
end

--------------------------------------------------------------------------
-- Technic: "<TIER>_EU_input/demand/supply" in the meta, battery boxes keep
-- "internal_EU_charge" and show the charge as the digit of their node name

local function technic_info (pos, node)
	if not rawget(_G, "technic") or core.get_item_group(node.name, "technic_machine") ~= 1 then return nil end
	local meta = core.get_meta(pos)
	local info = { mod = "technic" }

	local tier
	for _, t in ipairs({ "lv", "mv", "hv" }) do
		if core.get_item_group(node.name, "technic_" .. t) == 1 then tier = t:upper() end
	end
	if tier then
		info.supply = meta:get_int(tier .. "_EU_supply")
		info.demand = meta:get_int(tier .. "_EU_demand")
		info.power = meta:get_int(tier .. "_EU_input")
	end

	if node.name:find("battery_box") then
		info.power = meta:get_int("internal_EU_charge")
		-- the box shows its charge in eighths in its name: ...battery_box0 .. 8
		local eighths = tonumber(node.name:match("battery_box(%d)$"))
		if eighths then info.level = math.floor(eighths / 8 * 100 + 0.5) end
		info.state = (meta:get_int(tier and (tier .. "_EU_input") or "x") > 0) and "charging" or "idle"
	else
		-- machines are named ..._active while working
		info.state = node.name:find("_active$") and "on" or "off"
		if meta:get_string("enabled") == "0" then info.state = "off" end
	end
	return info
end

local function technic_switch (pos, node, on)
	if not rawget(_G, "technic") or core.get_item_group(node.name, "technic_machine") ~= 1 then return nil end
	local meta = core.get_meta(pos)
	-- supply converters and the like have an "enabled" field; others do not switch
	if meta:get_string("enabled") == "" then return false end
	meta:set_int("enabled", on and 1 or 0)
	return true
end

--------------------------------------------------------------------------
-- Techage: nodes have a number; techage.send_single asks them ("state",
-- "load", "delivered") and tells them ("on", "off")

local function techage_number (pos)
	if not rawget(_G, "techage") or not techage.get_node_number then return nil end
	local ok, number = pcall(techage.get_node_number, pos)
	return ok and number or nil
end

local function techage_ask (number, topic)
	local ok, res = pcall(techage.send_single, "0", number, topic)
	if ok and res ~= false and res ~= nil then return res end
end

local RUNNING = { running = true, on = true, active = true }

local function techage_info (pos)
	local number = techage_number(pos)
	if not number then return nil end

	local info = { mod = "techage" }
	local state = techage_ask(number, "state")
	if type(state) == "string" then
		info.state = RUNNING[state:lower()] and "on" or state:lower()
	end
	local delivered = tonumber(techage_ask(number, "delivered"))
	if delivered then info.power = delivered end
	local load = tonumber(techage_ask(number, "load"))
	if load then info.level = math.max(0, math.min(100, math.floor(load))) end
	return info
end

local function techage_switch (pos, node, on)
	local number = techage_number(pos)
	if not number then return nil end
	local ok, res = pcall(techage.send_single, "0", number, on and "on" or "off")
	return ok and res ~= false and res ~= nil
end

--------------------------------------------------------------------------

local READERS = { sbz_info, technic_info, techage_info }
local SWITCHES = { sbz_switch, technic_switch, techage_switch }

-- the reading for the node at pos, or nil when it is not a machine of a known mod
function S.machine_info (pos)
	local node = core.get_node_or_nil(pos)
	if not node or node.name == "ignore" then return nil end
	local def = core.registered_nodes[node.name] or {}
	for _, read in ipairs(READERS) do
		local info = read(pos, node, def)
		if info then return info end
	end
end

-- true when switched, false when the machine cannot be, nil when none
function S.machine_switch (pos, on)
	local node = core.get_node_or_nil(pos)
	if not node or node.name == "ignore" then return nil end
	for _, switch in ipairs(SWITCHES) do
		local res = switch(pos, node, on)
		if res ~= nil then return res end
	end
end

--------------------------------------------------------------------------
-- for programs (see commands.lua)

local Bot = S.Bot
local lang = S.lang

-- "" when the block is not a machine of a mod we know
function Bot:machine_state (dir)
	local info = S.machine_info(self:target(dir))
	return info and info.state or ""
end

-- a number of the reading, -1 when the block has no such value
function Bot:machine_reading (dir, key)
	local info = S.machine_info(self:target(dir))
	local v = info and info[key]
	return v == nil and -1 or v
end

-- seconds until the node timer of the block fires, -1 when none runs
function Bot:node_timer (dir)
	local timer = core.get_node_timer(self:target(dir))
	if not timer:is_started() then return -1 end
	return math.max(0, timer:get_timeout() - timer:get_elapsed())
end

local function matches (name, want)
	if want:sub(1, 6) == "group:" then return core.get_item_group(name, want:sub(7)) > 0 end
	return name == want
end

-- how many of item (all items when none) are in the inventory of the block
function Bot:node_stock (dir, item)
	item = item ~= nil and lang.tostr(item) or ""
	local inv = core.get_meta(self:target(dir)):get_inventory()
	local total = 0
	for _, list in pairs(inv:get_lists()) do
		for _, stack in ipairs(list) do
			if not stack:is_empty() and (item == "" or matches(stack:get_name(), item)) then
				total = total + stack:get_count()
			end
		end
	end
	return total
end

-- switch the machine in the block on or off
function Bot:machine_switch (dir, on)
	local pos = self:target(dir)
	if self:protected(pos) then return false, S.settings.action_delay end
	return S.machine_switch(pos, on) == true, S.settings.action_delay
end
