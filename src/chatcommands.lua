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

core.register_chatcommand("cogwork_forceloads", {
	params = "[enforce]",
	description = S("List the forceloading robots and the forceloaded blocks, and whether each robot's owner may forceload"),
	privs = { server = true },
	func = function (name, param)
		if param == "enforce" then
			return true, S("Stopped @1 robot(s) from forceloading.", cogwork.persist_enforce())
		end
		local out = { ("cogwork_max_persist = %d"):format(cogwork.settings.max_persist) }
		local registered = {}
		for _, e in ipairs(cogwork.persist_list()) do
			local bp = vector.new(math.floor(e.pos.x / 16), math.floor(e.pos.y / 16), math.floor(e.pos.z / 16))
			registered[core.hash_node_position(bp)] = true
			local state = e.suspended and "owner away, not loading" or "loading"
			local verdict = (e.admin and "owner has server")
				or (e.allowed and "within the limit") or "NOT ALLOWED (no server priv)"
			out[#out + 1] = ("%s %s block %s: %s, %s, %s"):format(
				e.owner, core.pos_to_string(e.pos), core.pos_to_string(bp),
				e.node or "not loaded", state, verdict)
		end
		if #out == 1 then out[#out + 1] = "no registered robots" end
		-- persistent forceloads of the engine (force_loaded.txt) that no robot accounts for
		local f = io.open(core.get_worldpath() .. "/force_loaded.txt", "r")
		local saved = f and core.deserialize(f:read("*all") or "") or {}
		if f then f:close() end
		for bh, count in pairs(saved) do
			if not registered[bh] then
				out[#out + 1] = ("forceloaded block %s x%d: no registered robot"):format(
					core.pos_to_string(core.get_position_from_hash(bh)), count)
			end
		end
		return true, table.concat(out, "\n")
	end,
})
