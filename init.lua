local modpath = core.get_modpath("cogwork")

cogwork = {}
local S = cogwork

S.modpath = modpath
S.S = core.get_translator("cogwork")

S.settings = {
	tick = tonumber(core.settings:get("cogwork_tick")) or 0.1,
	action_delay = math.max(0.1, tonumber(core.settings:get("cogwork_action_delay")) or 0.2),
	move_delay = math.max(0.1, tonumber(core.settings:get("cogwork_move_delay")) or 0.5),
	public_chat = core.settings:get_bool("cogwork_public_chat", true),
	use_on_place = core.settings:get_bool("cogwork_use_on_place", true),
	resume_on_start = core.settings:get_bool("cogwork_resume_on_start", false),
	step_budget = tonumber(core.settings:get("cogwork_step_budget")) or 200,
}

S.lang = assert(loadfile(modpath .. "/src/lang.lua"))()
assert(loadfile(modpath .. "/src/commands.lua"))(S.lang)
S.compat = assert(loadfile(modpath .. "/src/compat.lua"))()

for _, file in ipairs({ "robot_ops", "runtime", "api", "packages", "robot", "editor",
	"cassette", "crafting", "chatcommands" }) do
	assert(loadfile(modpath .. "/src/" .. file .. ".lua"))(S)
end

core.log("action", "[cogwork] loaded (" .. S.compat.family .. ")")
