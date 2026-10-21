-- Recipes. Each game gets ingredients that exist in it.

local S = ...
local compat = S.compat

compat.register_recipes(function (c)
	local function first (...)
		for _, key in ipairs({ ... }) do
			local item = c.item(key)
			if item then return item end
		end
	end

	local stone = first("stone", "cobble", "matter")
	local steel = first("steel", "tin", "plate")
	local glass = first("glass", "matter")
	local coal = first("coal", "circuit")
	local stick = first("stick", "matter")
	local copper = first("copper", "tin", "steel", "circuit")
	local clay = first("clay", "paper", "plate")
	local paper = first("paper", "plate")
	local trim = first("copper", "circuit", "steel")

	if c.family == "sbz" then
		local plate, circuit = c.item("plate"), c.item("circuit")
		local processor = "sbz_resources:simple_processor"
		local emitter = "sbz_resources:emitter"
		local dust = "sbz_resources:core_dust"
		local have = core.registered_items
		if plate and circuit and have[processor] and have[emitter] and have[dust] then
			-- harder than the other games: engraved processors, emitters and core dust
			core.register_craft({
				output = "cogwork:robot",
				recipe = {
					{ plate, processor, plate },
					{ emitter, dust, emitter },
					{ plate, processor, plate },
				},
			})
			core.register_craft({
				type = "shapeless", output = "cogwork:cassette",
				recipe = { plate, circuit, circuit },
			})
			core.register_craft({
				type = "shapeless", output = "cogwork:disk",
				recipe = { plate, plate, circuit, circuit },
			})
			core.register_craft({
				output = "cogwork:upgrade_hover",
				recipe = {
					{ plate, processor, plate },
					{ circuit, emitter, circuit },
					{ plate, circuit, plate },
				},
			})
			-- Flight is the late-game one: four Hover Upgrades plus antimatter,
			-- retaining and emittrium parts (cheaper stand-ins when a game lacks them)
			local have = core.registered_items
			local function part (name, fallback) return have[name] and name or fallback end
			local anti = part("sbz_resources:antimatter_plate", dust)
			local retaining = part("sbz_resources:retaining_circuit", processor)
			local emittrium = part("sbz_resources:emittrium_circuit", emitter)
			core.register_craft({
				output = "cogwork:upgrade_flight",
				recipe = {
					{ "cogwork:upgrade_hover", anti, "cogwork:upgrade_hover" },
					{ retaining, emittrium, retaining },
					{ "cogwork:upgrade_hover", anti, "cogwork:upgrade_hover" },
				},
			})
			return
		end
	end

	if stone and steel and glass and coal and stick and copper and clay then
		core.register_craft({
			output = "cogwork:robot",
			recipe = {
				{ stone, steel, glass },
				{ steel, coal, steel },
				{ stick, copper, clay },
			},
		})
	else
		core.log("warning", "[cogwork] no robot recipe for this game")
	end

	if steel and glass and coal then
		core.register_craft({
			output = "cogwork:upgrade_hover",
			recipe = {
				{ glass, steel, glass },
				{ steel, coal, steel },
				{ glass, steel, glass },
			},
		})
		-- Flight: four Hover Upgrades around gold and diamonds
		local gold, diamond = first("gold", "copper"), first("diamond", "gold", "steel")
		if gold and diamond then
			core.register_craft({
				output = "cogwork:upgrade_flight",
				recipe = {
					{ "cogwork:upgrade_hover", gold, "cogwork:upgrade_hover" },
					{ diamond, steel, diamond },
					{ "cogwork:upgrade_hover", gold, "cogwork:upgrade_hover" },
				},
			})
		end
	end

	if paper and coal and stick then
		core.register_craft({
			type = "shapeless", output = "cogwork:cassette",
			recipe = { paper, coal, stick },
		})
	end

	if paper and trim then
		core.register_craft({
			type = "shapeless", output = "cogwork:disk",
			recipe = { paper, paper, trim },
		})
	end
end)
