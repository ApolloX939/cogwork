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
	event_max_radius = math.max(1, math.floor(tonumber(core.settings:get("cogwork_event_max_radius")) or 6)),
	event_max_interval = math.max(0.5, tonumber(core.settings:get("cogwork_event_max_interval")) or 3),
	path_max_nodes = math.max(100, math.floor(tonumber(core.settings:get("cogwork_path_max_nodes")) or 6000)),
	path_replan = math.max(0.5, tonumber(core.settings:get("cogwork_path_replan")) or 5),
	path_entity_radius = math.max(1, tonumber(core.settings:get("cogwork_path_entity_radius")) or 48),
	gravity = core.settings:get_bool("cogwork_gravity", true),
	particles = core.settings:get_bool("cogwork_particles", true),
	-- robots_can_float: a robot in water floats in it; off, it sinks to the bottom
	can_float = core.settings:get_bool("cogwork_robots_can_float", core.settings:get_bool("robots_can_float", true)),
	fall_range = math.max(1, math.floor(tonumber(core.settings:get("cogwork_fall_range")) or 128)),
	-- the Self-Generator charges one cell by generator_amount every generator_interval seconds
	generator_amount = math.max(1, tonumber(core.settings:get("cogwork_generator_amount")) or 10),
	generator_interval = math.max(5, tonumber(core.settings:get("cogwork_generator_interval")) or 5),
	-- the viewscreen inside a robot: picture size, how far it sees, seconds between pictures
	view_width = math.max(16, math.floor(tonumber(core.settings:get("cogwork_view_width")) or 96)),
	view_height = math.max(10, math.floor(tonumber(core.settings:get("cogwork_view_height")) or 60)),
	view_range = math.max(16, tonumber(core.settings:get("cogwork_view_range")) or 96),
	view_interval = math.max(0.5, tonumber(core.settings:get("cogwork_view_interval")) or 1),
	rooms = core.settings:get_bool("cogwork_rooms", true),
	chat_limit = math.max(1, math.floor(tonumber(core.settings:get("cogwork_chat_limit")) or 5)),
	chat_window = math.max(1, tonumber(core.settings:get("cogwork_chat_window")) or 10),
}

S.lang = assert(loadfile(modpath .. "/src/lang.lua"))()
assert(loadfile(modpath .. "/src/commands.lua"))(S.lang)
S.compat = assert(loadfile(modpath .. "/src/compat.lua"))()

for _, file in ipairs({ "robot_ops", "upgrades", "structure", "machines", "viewscreen", "rooms", "room_nodes", "runtime", "events", "pathfind", "api", "visual", "gravity", "packages", "robot", "editor",
	"cassette", "crafting", "structure_recipes", "charger", "chatcommands" }) do
	assert(loadfile(modpath .. "/src/" .. file .. ".lua"))(S)
end

core.log("action", "[cogwork] loaded (" .. S.compat.family .. ")")
