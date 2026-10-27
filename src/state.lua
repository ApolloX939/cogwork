-- State: values a program keeps in the robot, so it can carry on after the server
-- restarted (a resumed program starts from its first line, see the Settings tab's
-- "Resume after a restart"). Kept in meta "state", a table name -> number or text, and
-- they go with the robot when it is dug (its item) or moved, like the waypoints.

local cogwork = ...
local lang = cogwork.lang
local Bot = cogwork.Bot

local MAX_VALUES = 32
local MAX_NAME = 24
local MAX_TEXT = 200

local function load (pos)
	local raw = core.get_meta(pos):get_string("state")
	return raw ~= "" and core.deserialize(raw) or {}
end

local function clean_name (name)
	name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if name == "" or #name > MAX_NAME then return nil end
	return name
end

-- names with their values, in order, for the editor and tests
function cogwork.state_of (pos)
	return load(pos)
end

-- Keep a value (a number or text). Returns true, or false and why.
function cogwork.state_set (pos, name, value)
	name = clean_name(name)
	if not name then return false, "bad name" end
	if type(value) ~= "number" then value = lang.tostr(value) end
	if type(value) == "string" and #value > MAX_TEXT then return false, "too long" end
	local all = load(pos)
	local count = 0
	for _ in pairs(all) do count = count + 1 end
	if all[name] == nil and count >= MAX_VALUES then return false, "too many" end
	all[name] = value
	core.get_meta(pos):set_string("state", core.serialize(all))
	return true
end

function cogwork.state_clear (pos, name)
	local all = load(pos)
	if name == nil then
		core.get_meta(pos):set_string("state", "")
		return true
	end
	name = clean_name(name)
	if not name or all[name] == nil then return false end
	all[name] = nil
	core.get_meta(pos):set_string("state", core.serialize(all))
	return true
end

--------------------------------------------------------------------------
-- for programs

function Bot:state_set (name, value)
	return cogwork.state_set(self.pos, name, value), 0
end

function Bot:state_forget (name)
	return cogwork.state_clear(self.pos, name or "") , 0
end

function Bot:state_has (name)
	name = clean_name(name)
	return name ~= nil and load(self.pos)[name] ~= nil
end

-- the value, or 0 when there is none (ask state_has)
function Bot:state_get (name)
	name = clean_name(name)
	local v = name and load(self.pos)[name]
	if v == nil then return 0 end
	return v
end
