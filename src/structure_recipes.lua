-- Recipes of the structure items: power cells (five tiers), armor (three),
-- the Self-Repair Module, the Self-Generator and the Combat Upgrade. The
-- Creative Capacitor is creative-only: it has none.

local cogwork = ...
local compat = cogwork.compat

compat.register_recipes(function (c)
	local function first (...)
		for _, key in ipairs({ ... }) do
			local item = c.item(key)
			if item then return item end
		end
	end

	local have = core.registered_items
	local function part (name, fallback) return have[name] and name or fallback end

	local cell = { small = "cogwork:cell_small", medium = "cogwork:cell_medium", large = "cogwork:cell_large",
		huge = "cogwork:cell_huge", colossal = "cogwork:cell_colossal" }
	local armor = { basic = "cogwork:armor_basic", reinforced = "cogwork:armor_reinforced", heavy = "cogwork:armor_heavy" }

	local function craft (output, recipe)
		for _, row in ipairs(recipe) do
			for _, item in ipairs(row) do
				if item == nil then return end
			end
		end
		core.register_craft({ output = output, recipe = recipe })
	end

	if c.family == "sbz" then
		local plate, circuit = c.item("plate"), c.item("circuit")
		local processor = part("sbz_resources:simple_processor", circuit)
		-- the Emitter is a block of the world, not an item: emittrium circuits stand for it
		local emitter = part("sbz_resources:emittrium_circuit", processor)
		local dust = part("sbz_resources:core_dust", circuit)
		local anti = part("sbz_resources:antimatter_plate", dust)
		local retaining = part("sbz_resources:retaining_circuit", processor)
		local emittrium = part("sbz_resources:emittrium_circuit", emitter)
		-- the three batteries of the game stand for the cells' chemistry
		local b1 = part("sbz_power:battery", circuit)
		local b2 = part("sbz_power:advanced_battery", processor)
		local b3 = part("sbz_power:very_advanced_battery", processor)
		if not (plate and circuit) then return end

		craft(cell.small, { { plate, circuit, plate }, { circuit, b1, circuit }, { plate, circuit, plate } })
		craft(cell.medium, { { plate, processor, plate }, { cell.small, b2, cell.small }, { plate, processor, plate } })
		craft(cell.large, { { emitter, processor, emitter }, { cell.medium, b3, cell.medium }, { plate, processor, plate } })
		craft(cell.huge, { { emitter, retaining, emitter }, { cell.large, b3, cell.large }, { anti, processor, anti } })
		craft(cell.colossal, { { emittrium, retaining, emittrium }, { cell.huge, b3, cell.huge }, { anti, emitter, anti } })

		craft(armor.basic, { { plate, plate, plate }, { plate, circuit, plate }, { plate, plate, plate } })
		craft(armor.reinforced, { { plate, armor.basic, plate }, { processor, plate, processor }, { plate, plate, plate } })
		craft(armor.heavy, { { anti, armor.reinforced, anti }, { processor, emitter, processor }, { anti, plate, anti } })

		craft("cogwork:armor_mod_repair", { { processor, circuit, processor }, { retaining, emitter, retaining }, { plate, circuit, plate } })

		-- very, very, very expensive: a Colossal cell wrapped in emittrium and antimatter
		craft("cogwork:augment_generator", { { emittrium, anti, emittrium }, { anti, cell.colossal, anti }, { emittrium, anti, emittrium } })

		craft("cogwork:upgrade_combat", { { processor, anti, processor }, { plate, emitter, plate }, { processor, retaining, processor } })
		craft("cogwork:upgrade_storage", { { plate, circuit, plate }, { circuit, processor, circuit }, { plate, circuit, plate } })
		return
	end

	local steel, copper, gold = first("steel", "tin"), first("copper", "tin"), first("gold", "copper")
	local diamond, coal = first("diamond", "gold"), first("coal")
	if not (steel and copper and gold and diamond and coal) then
		core.log("warning", "[cogwork] no structure recipes for this game")
		return
	end

	craft(cell.small, { { steel, copper, steel }, { copper, coal, copper }, { steel, copper, steel } })
	craft(cell.medium, { { cell.small, gold, cell.small }, { gold, coal, gold }, { steel, gold, steel } })
	craft(cell.large, { { cell.medium, gold, cell.medium }, { diamond, coal, diamond }, { steel, gold, steel } })
	craft(cell.huge, { { cell.large, diamond, cell.large }, { diamond, coal, diamond }, { gold, diamond, gold } })
	craft(cell.colossal, { { cell.huge, diamond, cell.huge }, { diamond, gold, diamond }, { diamond, diamond, diamond } })

	craft(armor.basic, { { steel, steel, steel }, { steel, coal, steel }, { steel, steel, steel } })
	craft(armor.reinforced, { { steel, armor.basic, steel }, { steel, gold, steel }, { steel, steel, steel } })
	craft(armor.heavy, { { diamond, armor.reinforced, diamond }, { steel, gold, steel }, { diamond, steel, diamond } })

	craft("cogwork:armor_mod_repair", { { gold, steel, gold }, { copper, diamond, copper }, { gold, steel, gold } })

	-- very, very, very expensive: six diamonds around a Colossal cell
	craft("cogwork:augment_generator", { { diamond, diamond, diamond }, { gold, cell.colossal, gold }, { diamond, diamond, diamond } })

	craft("cogwork:upgrade_combat", { { steel, diamond, steel }, { gold, coal, gold }, { steel, diamond, steel } })

	local chest = first("chest")
	if chest then
		craft("cogwork:upgrade_storage", { { steel, chest, steel }, { copper, steel, copper }, { steel, steel, steel } })
	end
end)
