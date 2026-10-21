-- Public API for other mods.

local S = ...
local lang = S.lang

-- cogwork.register_command{
--   name = "scan", kind = "action" or "query", category = "world",
--   args = { {type="dir8"}, {type="val", optional=true} },  -- dir8 dir4 turn val name
--   run = function(ctx, ...) ... end,   -- ctx.bot is the robot (pos, owner, inv ...)
-- }
-- Actions return ok, delay_seconds; queries return a value.
function S.register_command (def)
	assert(not lang.commands[def.name], "command already exists: " .. tostring(def.name))
	assert(not lang.KEYWORDS[def.name], "reserved word: " .. tostring(def.name))
	lang.register_command(def)
end

-- cogwork.register_package{ name = "mining", title = "...", description = "...",
--   source = "fn tunnel n\n  repeat n\n    dig front\n..." }
-- Programs load it with "use mining" or call "mining.tunnel 5".
function S.register_package (def)
	assert(def.name and def.source, "a package needs a name and source")
	assert(def.name:match("^[%a_][%w_]*$"), "bad package name")
	lang.register_package(def.name, def.source, {
		title = def.title or def.name,
		description = def.description or "",
	})
end

-- Check that a package compiles; returns true or nil, message
function S.check_package (name)
	local ok, err = pcall(lang.get_package, name, 0)
	if ok then return true end
	return nil, lang.format_error(err)
end

function S.list_packages ()
	local names = {}
	for name in pairs(lang.packages) do names[#names + 1] = name end
	table.sort(names)
	return names
end

-- the robot and the drone (a robot with a Flight Upgrade), each off or on
local NODES = { ["cogwork:robot"] = true, ["cogwork:robot_on"] = true,
	["cogwork:drone"] = true, ["cogwork:drone_on"] = true }
S.ROBOT_NODES = { "cogwork:robot", "cogwork:robot_on", "cogwork:drone", "cogwork:drone_on" }

function S.is_robot (name)
	return NODES[name] == true
end

-- the node name that suits a robot: a drone when it can fly, lit when running
function S.variant_name (pos, on)
	local fly = S.height_limit(pos) == nil
	return (fly and "cogwork:drone" or "cogwork:robot") .. (on and "_on" or "")
end

-- make the node look like what it is: robot or drone
function S.refresh_variant (pos, on)
	local node = core.get_node_or_nil(pos)
	if not node or not S.is_robot(node.name) then return end
	if on == nil then on = node.name:sub(-3) == "_on" end
	local want = S.variant_name(pos, on)
	if node.name ~= want then
		core.swap_node(pos, { name = want, param2 = node.param2 })
	end
end

function S.get_program (pos)
	return core.get_meta(pos):get_string("program")
end

function S.set_program (pos, text)
	core.get_meta(pos):set_string("program", text)
end
