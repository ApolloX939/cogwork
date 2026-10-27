-- Waypoints: named places, with the way the robot faced there.
--
-- They are kept in the robot (meta "waypoints", a table name -> { x, y, z, facing }) and
-- go with it when it is dug (its item) or moved. The Waypoints tab of the editor saves
-- the robot's place and removes waypoints; programs use waypoint_save, waypoint_forget
-- and the waypoint_* queries (the `waypoint` package wraps them and walks to them).
-- Facing is a compass word: north is +Z, east +X, south -Z, west -X.

local cogwork = ...
local Bot = cogwork.Bot

local MAX_WAYPOINTS = 32
local MAX_NAME = 24

cogwork.WAYPOINT_FACINGS = { north = true, east = true, south = true, west = true }

local function load (pos)
	local raw = core.get_meta(pos):get_string("waypoints")
	return raw ~= "" and core.deserialize(raw) or {}
end

local function store (pos, all)
	core.get_meta(pos):set_string("waypoints", core.serialize(all))
end

-- a name a player can type and a list can show; nil when it is not one
local function clean_name (name)
	name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if name == "" or #name > MAX_NAME or name:find("[,;%[%]\\\n\r]") then return nil end
	return name
end
cogwork.waypoint_name = clean_name

function cogwork.waypoints_of (pos)
	return load(pos)
end

-- the names, in order
function cogwork.waypoint_names (pos)
	local names = {}
	for name in pairs(load(pos)) do names[#names + 1] = name end
	table.sort(names, function (a, b) return a:lower() < b:lower() end)
	return names
end

-- Save a waypoint. Returns true, or false and why.
function cogwork.waypoint_set (pos, name, x, y, z, facing)
	name = clean_name(name)
	if not name then return false, "bad name" end
	if not cogwork.WAYPOINT_FACINGS[facing] then return false, "bad facing" end
	local all = load(pos)
	local count = 0
	for _ in pairs(all) do count = count + 1 end
	if not all[name] and count >= MAX_WAYPOINTS then return false, "too many" end
	all[name] = { x = math.floor(x), y = math.floor(y), z = math.floor(z), facing = facing }
	store(pos, all)
	return true
end

function cogwork.waypoint_remove (pos, name)
	local all = load(pos)
	if all[name] == nil then return false end
	all[name] = nil
	store(pos, all)
	return true
end

-- the robot's own place and facing as a waypoint
function cogwork.waypoint_here (pos, name)
	local bot = Bot.new(pos, core.get_meta(pos):get_string("owner"))
	return cogwork.waypoint_set(pos, name, pos.x, pos.y, pos.z, bot:facing())
end

--------------------------------------------------------------------------
-- for programs

function Bot:waypoint_save (name)
	local ok = cogwork.waypoint_set(self.pos, name, self.pos.x, self.pos.y, self.pos.z, self:facing())
	return ok, 0
end

function Bot:waypoint_forget (name)
	name = clean_name(name)
	return name ~= nil and cogwork.waypoint_remove(self.pos, name), 0
end

function Bot:waypoint_has (name)
	name = clean_name(name)
	return name ~= nil and load(self.pos)[name] ~= nil
end

-- a coordinate or the facing of a waypoint; 0 or "" when there is none (ask waypoint_has)
function Bot:waypoint_get (name, key)
	name = clean_name(name)
	local wp = name and load(self.pos)[name]
	if not wp then return key == "facing" and "" or 0 end
	return wp[key]
end
