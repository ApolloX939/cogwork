-- Players: who is online and when somebody was last seen, for programs
-- (player_online, player_seen, players_online, player_nth; the `players` package wraps them).
--
-- Online is what the server says now. Last seen is kept in mod storage: the time a
-- player left (or the server stopped with them on), so it also covers the time since
-- this was installed only; a player never seen leaving is "unknown".

local cogwork = ...
local lang = cogwork.lang
local Bot = cogwork.Bot

local storage = core.get_mod_storage()

local function key (name) return "seen:" .. name end

local function mark (name)
	storage:set_int(key(name), os.time())
end

core.register_on_leaveplayer(function (player)
	mark(player:get_player_name())
end)

core.register_on_shutdown(function ()
	for _, player in ipairs(core.get_connected_players()) do mark(player:get_player_name()) end
end)

function cogwork.player_online (name)
	return core.get_player_by_name(tostring(name or "")) ~= nil
end

-- seconds since the player was online: 0 when online now, -1 when never seen
function cogwork.player_seen (name)
	name = tostring(name or "")
	if cogwork.player_online(name) then return 0 end
	local at = storage:get_int(key(name))
	if at == 0 then return -1 end
	return math.max(0, os.time() - at)
end

-- the names of the players online, in order
function cogwork.players_online ()
	local names = {}
	for _, player in ipairs(core.get_connected_players()) do names[#names + 1] = player:get_player_name() end
	table.sort(names, function (a, b) return a:lower() < b:lower() end)
	return names
end

--------------------------------------------------------------------------
-- for programs

function Bot:player_online (name)
	return cogwork.player_online(lang.tostr(name))
end

function Bot:player_seen (name)
	return cogwork.player_seen(lang.tostr(name))
end

function Bot:players_online ()
	return #cogwork.players_online()
end

-- the n-th player online ("" when there is none)
function Bot:player_nth (n)
	return cogwork.players_online()[n] or ""
end
