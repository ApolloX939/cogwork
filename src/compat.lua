-- Game compatibility: material names, sounds, groups and recipes for
-- Minetest Game style games, Mineclonia/VoxeLibre, Hades Revisited and
-- Skyblock: Zero. Everything is looked up when the mods have loaded, so
-- optional dependencies can come in any order.

local compat = {}

local has = core.get_modpath

if has("mcl_core") then compat.family = "mcl"
elseif has("hades_core") then compat.family = "hades"
elseif has("sbz_resources") then compat.family = "sbz"
elseif has("default") then compat.family = "mtg"
else compat.family = "other" end

--------------------------------------------------------------------------
-- materials: "@name" in programs, and recipe ingredients

local candidates = {
	stone   = { "default:stone", "mcl_core:stone", "hades_core:stone" },
	cobble  = { "default:cobble", "mcl_core:cobble", "hades_core:cobble" },
	dirt    = { "default:dirt", "mcl_core:dirt", "hades_core:dirt" },
	sand    = { "default:sand", "mcl_core:sand", "hades_core:sand" },
	gravel  = { "default:gravel", "mcl_core:gravel", "hades_core:gravel" },
	glass   = { "default:glass", "mcl_core:glass", "hades_core:glass" },
	planks  = { "default:wood", "mcl_core:wood", "hades_core:wood" },
	log     = { "default:tree", "mcl_core:tree", "hades_core:tree" },
	sapling = { "default:sapling", "mcl_core:sapling", "hades_core:sapling" },
	torch   = { "default:torch", "mcl_torches:torch", "hades_torches:torch",
		"hades_core:torch" },
	chest   = { "default:chest", "mcl_chests:chest", "hades_chests:chest",
		"hades_core:chest" },
	coal    = { "default:coal_lump", "mcl_core:coal_lump", "hades_core:coal_lump" },
	stick   = { "default:stick", "mcl_core:stick", "hades_core:stick" },
	steel   = { "default:steel_ingot", "mcl_core:iron_ingot", "hades_core:steel_ingot" },
	copper  = { "default:copper_ingot", "mcl_copper:copper_ingot", "hades_core:copper_ingot" },
	tin     = { "default:tin_ingot", "hades_core:tin_ingot" },
	gold    = { "default:gold_ingot", "mcl_core:gold_ingot", "hades_core:gold_ingot" },
	diamond = { "default:diamond", "mcl_core:diamond", "hades_core:diamond" },
	clay    = { "default:clay_lump", "mcl_core:clay_lump", "hades_core:clay_lump" },
	paper   = { "default:paper", "mcl_core:paper", "hades_core:paper" },
	book    = { "default:book", "mcl_books:book", "hades_core:book" },
	-- Skyblock: Zero
	matter  = { "sbz_resources:matter_blob" },
	plate   = { "sbz_resources:matter_plate" },
	circuit = { "sbz_resources:simple_circuit" },
}

-- Skyblock: Zero has no stone, dirt or wood: its basic block stands in
local fallbacks = {
	stone = "matter", cobble = "matter", dirt = "matter", sand = "matter",
	gravel = "matter", planks = "matter", log = "matter", glass = "matter",
}

function compat.item (key)
	local list = candidates[key]
	if list then
		for _, name in ipairs(list) do
			if core.registered_items[name] then return name end
		end
	end
	if fallbacks[key] and key ~= fallbacks[key] then
		return compat.item(fallbacks[key])
	end
	return nil
end

-- "@stone" -> the game's stone; other names pass through
function compat.alias (name)
	if name:sub(1, 1) == "@" then
		return compat.item(name:sub(2))
	end
	return name
end

function compat.alias_names ()
	local names = {}
	for k in pairs(candidates) do names[#names + 1] = k end
	table.sort(names)
	return names
end

--------------------------------------------------------------------------
-- sounds and node properties

function compat.metal_sounds ()
	if core.global_exists("default") and default.node_sound_metal_defaults then
		return default.node_sound_metal_defaults()
	elseif core.global_exists("mcl_sounds") and mcl_sounds.node_sound_metal_defaults then
		return mcl_sounds.node_sound_metal_defaults()
	elseif core.global_exists("hades_sounds") and hades_sounds.node_sound_metal_defaults then
		return hades_sounds.node_sound_metal_defaults()
	elseif core.global_exists("sbz_audio") and sbz_audio.machine then
		return sbz_audio.machine()
	end
	return nil
end

-- one groups table that every supported game's digging understands
function compat.robot_groups (extra)
	-- cracky: Minetest Game style pickaxes and Hades Revisited; pickaxey and
	-- handy: Mineclonia/VoxeLibre; oddly_breakable_by_hand lets the bare hand
	-- dig it in Skyblock: Zero, Hades Revisited and Minetest Game
	local groups = { cracky = 2, pickaxey = 1, handy = 1, level = 1,
		oddly_breakable_by_hand = 2, building_block = 1,
		_mcl_hardness = 2, _mcl_blast_resistance = 6 }
	for k, v in pairs(extra or {}) do groups[k] = v end
	return groups
end

-- tool used to decide what a dug node drops
local pick_candidates = { "default:pick_diamond", "mcl_tools:pick_diamond",
	"hades_core:pick_diamond", "sbz_tools:pick_diamond" }

function compat.dig_tool ()
	for _, name in ipairs(pick_candidates) do
		if core.registered_items[name] then return name end
	end
	return ""
end

--------------------------------------------------------------------------
-- placing seeds and the like: item -> node that actually grows

local explicit_substitutes = {
	["mcl_farming:wheat_seeds"]    = "mcl_farming:wheat_1",
	["mcl_farming:carrot_item"]    = "mcl_farming:carrot_1",
	["mcl_farming:potato_item"]    = "mcl_farming:potato_1",
	["mcl_farming:beetroot_seeds"] = "mcl_farming:beetroot_0",
	["mcl_farming:melon_seeds"]    = "mcl_farming:melontige_1",
	["mcl_farming:pumpkin_seeds"]  = "mcl_farming:pumpkintige_1",
}

function compat.place_substitute (name)
	local def = core.registered_items[name]
	if def and core.registered_nodes[name] then return name end

	local sub = explicit_substitutes[name]
	if sub and core.registered_nodes[sub] then return sub end

	local mod, base = name:match("^([^:]+):(.+)$")
	if not mod then return name end

	local stems = { base }
	local s = base:match("^seed_(.+)$") or base:match("^(.+)_seeds?$")
		or base:match("^(.+)_item$")
	if s then stems[#stems + 1] = s end

	for _, stem in ipairs(stems) do
		for _, suffix in ipairs({ "_1", "_0" }) do
			local try = mod .. ":" .. stem .. suffix
			if core.registered_nodes[try] then return try end
		end
	end

	return name
end

--------------------------------------------------------------------------
-- recipes (registered once all mods are loaded)

local recipes = {}

function compat.register_recipes (add)
	recipes[#recipes + 1] = add
end

core.register_on_mods_loaded(function ()
	for _, add in ipairs(recipes) do add(compat) end
end)

return compat
