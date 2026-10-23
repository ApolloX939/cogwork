-- The robot's inventory for a player inside its room.
--
-- The editor draws the robot's slots from "nodemeta:x,y,z", and the game client reads
-- those lists from the node metadata it has itself: it only has it for the blocks near
-- the player. A player in a room is thousands of blocks from the robot, so the slots
-- did not show at all. A player in a room is given a detached inventory instead: a copy
-- of the robot's lists, sent to that player, whose changes are checked by the robot's
-- own rules (allow_metadata_inventory_*), copied to the robot and announced to it
-- (on_metadata_inventory_*) like any other change.

local cogwork = ...

local LISTS = { "main", "armor", "armor_mod", "cells", "augment", "upgrades", "disk" }
local proxies = {}      -- player name -> { inv = detached inventory, sig = what it holds }

local function robot_of (player)
	local id = cogwork.room_of_player(player)
	return id and cogwork.room_robot(id)
end

local function node_def (pos)
	return core.registered_nodes[core.get_node(pos).name]
end

local function signature (inv)
	local parts = {}
	for _, list in ipairs(LISTS) do
		local items = {}
		for _, stack in ipairs(inv:get_list(list) or {}) do items[#items + 1] = stack:to_string() end
		parts[#parts + 1] = list .. "=" .. inv:get_size(list) .. ":" .. table.concat(items, ",")
	end
	return table.concat(parts, ";")
end

-- make the copy hold what the robot holds
local function copy_in (rp, det)
	local real = core.get_meta(rp):get_inventory()
	for _, list in ipairs(LISTS) do
		det:set_size(list, real:get_size(list))
		if real:get_size(list) > 0 then det:set_list(list, real:get_list(list)) end
	end
	return real
end

-- what the player did to the copy goes to the robot
local function copy_out (rp, det, lists)
	local real = core.get_meta(rp):get_inventory()
	for _, list in ipairs(lists) do
		real:set_list(list, det:get_list(list))
	end
end

local function after (name, rp, det)
	copy_in(rp, det)
	local p = proxies[name]
	if p then p.sig = signature(det) end
end

local function make (player)
	local name = player:get_player_name()
	local det

	local function with_robot (fn, default)
		return function (inv, ...)
			local p = core.get_player_by_name(name)
			local rp = p and robot_of(p)
			if not rp then return default end
			return fn(rp, inv, p, ...)
		end
	end

	det = core.create_detached_inventory("cogwork_ed_" .. name, {
		allow_put = with_robot(function (rp, inv, p, listname, index, stack)
			return node_def(rp).allow_metadata_inventory_put(rp, listname, index, stack, p)
		end, 0),
		allow_take = with_robot(function (rp, inv, p, listname, index, stack)
			return node_def(rp).allow_metadata_inventory_take(rp, listname, index, stack, p)
		end, 0),
		allow_move = with_robot(function (rp, inv, p, from_list, from_index, to_list, to_index, count)
			return node_def(rp).allow_metadata_inventory_move(rp, from_list, from_index, to_list, to_index, count, p)
		end, 0),
		on_put = with_robot(function (rp, inv, p, listname, index, stack)
			copy_out(rp, inv, { listname })
			node_def(rp).on_metadata_inventory_put(rp, listname, index, stack, p)
			after(name, rp, inv)
		end),
		on_take = with_robot(function (rp, inv, p, listname, index, stack)
			copy_out(rp, inv, { listname })
			node_def(rp).on_metadata_inventory_take(rp, listname, index, stack, p)
			after(name, rp, inv)
		end),
		on_move = with_robot(function (rp, inv, p, from_list, from_index, to_list, to_index, count)
			copy_out(rp, inv, { from_list, to_list })
			node_def(rp).on_metadata_inventory_move(rp, from_list, from_index, to_list, to_index, count, p)
			after(name, rp, inv)
		end),
	}, name)
	return det
end

-- Where the editor finds the robot's slots for this player: the copy for a player in a
-- room (made up to date now), else the node itself.
function cogwork.inventory_location (pos, player)
	if not (player and player.get_meta and cogwork.room_of_player(player)) then
		return ("nodemeta:%d,%d,%d"):format(pos.x, pos.y, pos.z)
	end
	local name = player:get_player_name()
	local rp = robot_of(player) or pos
	local p = proxies[name]
	if not p then
		p = { inv = make(player) }
		proxies[name] = p
	end
	copy_in(rp, p.inv)
	p.sig = signature(p.inv)
	return "detached:cogwork_ed_" .. name
end

-- Did the robot's lists change since the copy was made (a program moved items, the
-- cells ran down)? Then the copy is brought up to date and this is true.
function cogwork.proxy_changed (player)
	local p = proxies[player:get_player_name()]
	local rp = p and robot_of(player)
	if not rp then return false end
	local real = core.get_meta(rp):get_inventory()
	if signature(real) == p.sig then return false end
	copy_in(rp, p.inv)
	p.sig = signature(p.inv)
	return true
end

core.register_on_leaveplayer(function (player)
	proxies[player:get_player_name()] = nil
end)
