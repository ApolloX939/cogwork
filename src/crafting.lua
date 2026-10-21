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
		local plate, circuit, matter = c.item("plate"), c.item("circuit"), c.item("matter")
		if plate and circuit and matter then
			core.register_craft({
				output = "cogwork:robot",
				recipe = {
					{ plate, circuit, plate },
					{ circuit, matter, circuit },
					{ plate, circuit, plate },
				},
			})
			core.register_craft({
				type = "shapeless", output = "cogwork:cassette",
				recipe = { plate, circuit },
			})
			core.register_craft({
				type = "shapeless", output = "cogwork:disk",
				recipe = { plate, plate, circuit },
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
