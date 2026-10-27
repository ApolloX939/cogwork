-- Commands as the owner: a program runs a chat command ("command" "time 7000") with
-- the owner's name and privileges, also while the owner is offline.
--
-- Safeguards: the owner switches it on per robot in the Settings tab (and nobody else
-- can use or program a robot with it on, see cogwork.can_access); the owner's own
-- privileges decide, as for a typed command; the commands in cogwork_command_denylist
-- are never run; a command refuses robots with `allow_bot = false` in its definition;
-- mods that cancel commands (register_on_chatcommand) are asked first; one command
-- per cogwork_command_interval seconds and robot, each one logged. A command that
-- needs its player online (it looks the player up) fails by itself when the owner
-- is away.

local cogwork = ...
local lang, settings = cogwork.lang, cogwork.settings
local Bot = cogwork.Bot
local S = cogwork.S

local denied = {}
for name in settings.command_denylist:gmatch("[^,%s]+") do denied[name:lower()] = true end

function cogwork.owner_commands_on (pos)
	return settings.owner_commands and core.get_meta(pos):get_int("owner_cmds") == 1
end

-- Run "cmd params" as owner. Returns true, the answer or false, why not.
function cogwork.run_as_owner (owner, text)
	text = tostring(text or ""):gsub("^%s*/?", ""):gsub("%s+$", "")
	local name, param = text:match("^(%S+)%s*(.*)$")
	if not name then return false, S("No command given") end

	local def = core.registered_chatcommands[name]
	if not def then return false, S("Unknown command: @1", name) end
	if denied[name:lower()] or def.allow_bot == false then
		return false, S("The command @1 does not run for robots", name)
	end

	local ok, missing = core.check_player_privs(owner, def.privs or {})
	if not ok then
		return false, S("@1 lacks the privileges for @2: @3", owner, name, table.concat(missing, ", "))
	end

	cogwork.running_owner_command = true
	for _, callback in ipairs(core.registered_on_chatcommands) do
		if callback(owner, name, param) then
			cogwork.running_owner_command = nil
			return false, S("A mod stopped the command @1", name)
		end
	end
	cogwork.running_owner_command = nil

	core.log("action", ("[cogwork] a robot runs /%s %s as %s"):format(name, param, owner))
	local called, done, answer = pcall(def.func, owner, param)
	if not called then
		core.log("error", "[cogwork] /" .. name .. " as a robot: " .. tostring(done))
		return false, S("The command @1 failed", name)
	end
	return done ~= false, answer ~= nil and tostring(answer) or ""
end

function Bot:command (ctx, text)
	local pos = self.pos
	local owner = core.get_meta(pos):get_string("owner")

	local function refuse (why)
		ctx.command_reply = why
		return false, 0
	end

	if not cogwork.owner_commands_on(pos) or owner == "" then
		return refuse(S("This robot may not run commands: the owner switches it on in the Settings tab"))
	end
	if not core.get_auth_handler().get_auth(owner) then return refuse(S("The owner has no account")) end

	local t = core.get_us_time() / 1e6
	if ctx.last_command and t - ctx.last_command < settings.command_interval then
		return refuse(S("Commands come too fast"))
	end
	ctx.last_command = t

	local ok, answer = cogwork.run_as_owner(owner, text)
	ctx.command_reply = answer
	return ok, 0
end
