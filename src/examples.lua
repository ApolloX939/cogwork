-- Examples: programs to read and copy into a robot (the Examples tab of the editor).
-- Each is a file in examples/*.cog, the first lines "# title:" and "# description:", in
-- the order of the file names. The comments in the program say how to set it up.

local cogwork = ...
local lang = cogwork.lang

local dir = cogwork.modpath .. "/examples"
local list = {}

for _, file in ipairs(core.get_dir_list(dir, false)) do
	local name = file:match("^(.+)%.cog$")
	if name then
		local f = assert(io.open(dir .. "/" .. file, "rb"))
		local source = f:read("*a")
		f:close()
		list[#list + 1] = {
			name = name,
			title = source:match("# title:%s*([^\n]+)") or name,
			description = source:match("# description:%s*([^\n]+)") or "",
			-- the header lines are for the list; the program starts at the setup notes
			source = (source:gsub("^# title:[^\n]*\n", ""):gsub("^# description:[^\n]*\n", "")),
		}
	end
end
table.sort(list, function (a, b) return a.name < b.name end)

function cogwork.list_examples ()
	return list
end

-- do they all compile, with the packages they use? A typo shows at startup.
function cogwork.check_example (example)
	local unit, err = lang.compile_text(example.source)
	if not unit then return nil, err end
	return true
end

core.register_on_mods_loaded(function ()
	for _, example in ipairs(list) do
		local ok, err = cogwork.check_example(example)
		if not ok then core.log("error", "[cogwork] example '" .. example.name .. "': " .. tostring(err)) end
	end
end)
