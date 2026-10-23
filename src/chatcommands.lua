local cogwork = ...
local lang = cogwork.lang
local S = cogwork.S

core.register_chatcommand("cogwork", {
	params = "packages | package <name> | items",
	description = S("Information about Cogwork packages and item names"),
	func = function (name, param)
		local cmd, arg = param:match("^(%S*)%s*(.-)%s*$")

		if cmd == "packages" or cmd == "" then
			local out = {}
			for _, p in ipairs(cogwork.list_packages()) do
				local pkg = lang.packages[p]
				out[#out + 1] = p .. " - " .. (pkg.meta.description or "")
			end
			return true, table.concat(out, "\n")

		elseif cmd == "package" then
			if not lang.packages[arg] then return false, S("No package '@1'.", arg) end
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
			for _, key in ipairs(cogwork.compat.alias_names()) do
				out[#out + 1] = "@" .. key .. " = " .. tostring(cogwork.compat.item(key))
			end
			return true, table.concat(out, "\n")
		end

		return false, S("Usage: /cogwork packages | package <name> | items")
	end,
})

core.register_chatcommand("bot", {
	params = "<robot name> <message>",
	description = S("Send a private message to a robot that is listening for them"),
	func = function (name, param)
		-- a name with spaces goes in quotes: /bot "Farm bot" hello
		local botname, message = param:match('^"([^"]+)"%s+(.+)$')
		if not botname then botname, message = param:match("^(%S+)%s+(.+)$") end
		if not botname then return false, S("Usage: /bot <robot name> <message>") end
		local ok, res = cogwork.whisper_to_bot(name, botname, message)
		if not ok then return false, res end
		return true, S("Sent to @1 robot(s).", res)
	end,
})
