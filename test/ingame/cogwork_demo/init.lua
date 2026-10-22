local S = cogwork

local PROGRAM = [[
use mining
# dig a tunnel, then come back
set depth = 6
call tunnel depth
repeat 2
  turn right
  if detect front and not detect up
    place front @torch
  else
    dig front
fn greet name
  chat "hello " + name
call greet "robot"
]]

local TOUR = {
	{ tab = "program", cat = "flow", line = 3, tok = 2 },
	{ tab = "program", cat = "world", line = 8, tok = 2 },
	{ tab = "program", cat = "fn", line = 5, tok = 1, pkg_view = "mining" },
	{ tab = "program", cat = "check", line = 7, tok = 3 },
	{ tab = "text" },
	{ tab = "storage" },
	{ tab = "structure" },
	{ tab = "packages", pkg = "mining" },
	{ tab = "settings" },
	{ tab = "packages", pkg = "movement" },
	{ tab = "help" },
}

core.register_on_joinplayer(function (player)
	local name = player:get_player_name()
	core.set_player_privs(name, { interact = true, fly = true, fast = true, noclip = true, creative = true, give = true })

	core.after(2, function ()
		local base = { x = 0, y = 20, z = 0 }
		core.emerge_area(vector.subtract(base, 20), vector.add(base, 20), function (_, _, remaining)
			if remaining > 0 then return end
			for x = -8, 8 do for z = -8, 8 do
				for y = 0, 6 do core.set_node(vector.add(base, { x = x, y = y, z = z }), { name = "air" }) end
				core.set_node(vector.add(base, { x = x, y = -1, z = z }), { name = S.compat.item("stone") or S.compat.item("matter") })
			end end
			player:set_pos(vector.add(base, { x = 0, y = 0.5, z = -4 }))
			player:set_look_horizontal(0)
			player:set_look_vertical(0.2)

			local pos = vector.add(base, { x = 0, y = 0, z = 0 })
			core.set_node(pos, { name = "cogwork:robot", param2 = core.dir_to_facedir({ x = 0, y = 0, z = -1 }) })
			local meta = core.get_meta(pos)
			meta:get_inventory():set_size("main", 16)
			meta:get_inventory():set_size("disk", 1)
			meta:set_string("owner", name)
			meta:set_string("bot_name", "Digger")
			meta:set_string("program", PROGRAM)
			meta:get_inventory():add_item("main", (S.compat.item("torch") or S.compat.item("matter")) .. " 20")
			meta:get_inventory():add_item("main", (S.compat.item("cobble") or S.compat.item("matter")) .. " 40")
			core.get_meta(vector.add(pos, { x = 2, y = 0, z = 0 })):set_string("x", "1")
			-- a second one, running, to see the lit face
			local p2 = vector.add(pos, { x = 3, y = 0, z = 0 })
			core.set_node(p2, { name = "cogwork:robot_on", param2 = 2 })

			local inv = player:get_inventory()
			inv:add_item("main", "cogwork:robot")
			inv:add_item("main", "cogwork:cassette")
			inv:add_item("main", "cogwork:disk")

			print("SBD READY")
			local i = 0
			local function step ()
				i = i + 1
				local t = TOUR[i]
				if not t then
					core.close_formspec(name, "cogwork:ed")
					player:set_physics_override({ gravity = 0 })
					player:set_pos(vector.add(base, { x = 0, y = 0.2, z = 2.2 }))
					player:set_look_horizontal(math.pi)
					player:set_look_vertical(0.25)
					print("SBD LOOK")
					return
				end
				local s = S.editor_session(player)
				for k, v in pairs(t) do s[k] = v end
				s.msg = ""
				S.show_editor(pos, player)
				print("SBD SHOW " .. i .. " " .. t.tab)
				core.after(9, step)
			end
			core.after(10, step)
		end)
	end)
end)
