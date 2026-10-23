-- EMC values for the emc mod (Project E style, optional).
--
-- emc prices an item from its recipe. Skyblock: Zero's Emitter has none (it comes from
-- the game's progression), so emc cannot price it, and with it every Cogwork recipe
-- that uses one stays unresolved: the Large, Huge and Colossal cells, the Heavy armor,
-- the Self-Repair Module, the Self-Generator, the Combat, Hover and Flight Upgrades
-- and the robot itself. Give the Emitter a value (as emc does for the movable and the
-- colorium emitter) and the rest follows from the recipes.
--
-- This runs while the mods load, before emc solves the recipes.

local cogwork = ...

if not rawget(_G, "emc") then return end

local function base (item, value)
	if core.registered_items[item] and not emc.has(item) then
		emc.set(item, value)
	end
end

base("sbz_resources:emitter", 1000)
