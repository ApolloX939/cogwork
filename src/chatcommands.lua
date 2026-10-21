local S = ...
local lang = S.lang
local T = S.S

core.register_chatcommand("cogwork", {
	params = "packages | package <name> | items",
	description = T("Information about Cogwork packages and item names"),
	func = function (name, param)
		local cmd, arg = param:match("^(%S*)%s*(.-)%s*$")

		if cmd == "packages" or cmd == "" then
			local out = {}
			for _, p in ipairs(S.list_packages()) do
				local pkg = lang.packages[p]
				out[#out + 1] = p .. " - " .. (pkg.meta.description or "")
			end
			return true, table.concat(out, "\n")

		elseif cmd == "package" then
			if not lang.packages[arg] then return false, T("No package '@1'.", arg) end
			local ok, unit = pcall(lang.get_package, arg, 0)
			if not ok then return false, lang.format_error(unit) end
			local names = {}
			for fname, fn in pairs(unit.fns) do
				names[#names + 1] = "call " .. arg .. "." .. fname .. " " .. table.concat(fn.params, " ")
			end
			table.sort(names)
			return true, table.concat(names, "\n")

		elseif cmd == "items" then
			local out = {}
			for _, key in ipairs(S.compat.alias_names()) do
				out[#out + 1] = "@" .. key .. " = " .. tostring(S.compat.item(key))
			end
			return true, table.concat(out, "\n")
		end

		return false, T("Usage: /cogwork packages | package <name> | items")
	end,
})
