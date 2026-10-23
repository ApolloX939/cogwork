-- Packages: libraries of functions.
--   * built-in ones come from packages/*.cog
--   * other mods add theirs with cogwork.register_package
--   * players keep their own on package disks and install them into a robot;
--     those live in the robot (meta "packages") and shadow the registered ones.

local cogwork = ...
local lang = cogwork.lang

local dir = cogwork.modpath .. "/packages"

for _, file in ipairs(core.get_dir_list(dir, false)) do
	local name = file:match("^(.+)%.cog$")
	if name then
		local f = assert(io.open(dir .. "/" .. file, "rb"))
		local source = f:read("*a")
		f:close()

		cogwork.register_package({
			name = name,
			title = source:match("# title:%s*([^\n]+)") or name,
			description = source:match("# description:%s*([^\n]+)") or "",
			source = source,
		})
	end
end

-- check them all now so a typo shows at startup, not in front of a player
core.register_on_mods_loaded(function ()
	for _, name in ipairs(cogwork.list_packages()) do
		local ok, err = cogwork.check_package(name)
		if not ok then
			core.log("error", "[cogwork] package '" .. name .. "': " .. err)
		end
	end
end)

--------------------------------------------------------------------------
-- packages installed in a robot

local function installed (meta)
	local raw = meta:get_string("packages")
	if raw == "" then return {} end
	return core.deserialize(raw) or {}
end

function cogwork.robot_packages (pos)
	return installed(core.get_meta(pos))
end

function cogwork.install_package (pos, name, source)
	local meta = core.get_meta(pos)
	local all = installed(meta)
	all[name] = source
	meta:set_string("packages", core.serialize(all))
end

function cogwork.remove_package (pos, name)
	local meta = core.get_meta(pos)
	local all = installed(meta)
	all[name] = nil
	meta:set_string("packages", core.serialize(all))
end

-- Compile a program with the robot's own packages in scope.
function cogwork.compile_for (pos, text)
	local overlay = {}
	for name, source in pairs(cogwork.robot_packages(pos)) do
		overlay[name] = { source = source, meta = {}, name = name }
	end
	return lang.compile_text(text, overlay)
end

-- The function definitions of a program, as library text for a disk.
-- Returns nil when the program has no functions.
function cogwork.extract_functions (text)
	local out, keep, has_fn = {}, false, false

	for _, line in ipairs(lang.parse_text(text)) do
		local kw = line.tokens[1]
		if #line.tokens > 0 and line.indent == 0 then
			keep = kw == "fn" or kw == "use" or kw == "#"
			if kw == "fn" then has_fn = true end
		end
		if keep then out[#out + 1] = line end
	end

	if not has_fn then return nil end
	return lang.to_text(out)
end

-- Check a library text: compiles with no top-level statements. Returns
-- nil, message when it is not usable as a package.
function cogwork.validate_library (text)
	local lines = lang.parse_text(text)
	for i, line in ipairs(lines) do
		local kw = line.tokens[1]
		if line.indent == 0 and kw and kw ~= "fn" and kw ~= "use" and kw ~= "#" then
			return nil, "line " .. i .. ": a package may only hold functions"
		end
	end
	local unit, err = lang.compile_text(text)
	if not unit then return nil, err end
	local n = 0
	for _ in pairs(unit.fns) do n = n + 1 end
	if n == 0 then return nil, "no functions" end
	return true
end
