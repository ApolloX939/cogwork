-- Run with: luajit test/run.lua   (from the mod directory)
package.path = "./?.lua;" .. package.path

local lang = assert(loadfile("src/lang.lua"))()
assert(loadfile("src/commands.lua"))(lang)

local pass, fail = 0, 0

local function check (name, cond, extra)
	if cond then pass = pass + 1 else
		fail = fail + 1
		print("FAIL: " .. name .. (extra and (" -> " .. tostring(extra)) or ""))
	end
end

-- mock bot that records calls
local function new_bot ()
	local bot = { log = {}, x = 0, rnd = 1 }
	local function rec (name)
		return function (self, ...)
			local parts = { name }
			for _, a in ipairs({ ... }) do parts[#parts + 1] = tostring(a) end
			self.log[#self.log + 1] = table.concat(parts, " ")
			return true, 0
		end
	end
	for _, n in ipairs({ "move", "turn", "dig", "place", "interact", "craft" }) do bot[n] = rec(n) end
	function bot:transfer (verb, item, stack)
		self.log[#self.log + 1] = verb .. (stack and "_stack " or " ") .. tostring(item)
		return true, 0
	end
	function bot:chat (t) self.log[#self.log + 1] = "chat " .. t return true, 0 end
	function bot:detect (dir, item) return dir == "front" and item == "default:stone" end
	function bot:node (dir) return "air" end
	function bot:contains (item) return item == "a:b" end
	function bot:fits () return true end
	function bot:count () return 7 end
	function bot:coord () return 3 end
	function bot:facing () return "north" end
	function bot:random (n) return n end
	return bot
end

-- run text; returns log string, error message
local function run (text, opts)
	local unit, err = lang.compile_text(text)
	if not unit then return nil, err end

	local bot = new_bot()
	local yields = 0
	local ctx = lang.new_ctx({ bot = bot, budget = (opts or {}).budget,
		yield = function () yields = yields + 1 end })
	ctx.alias = function (s) return s end

	local ok, e = pcall(lang.run, unit, ctx)
	if not ok then
		if type(e) == "table" and e.stop then return table.concat(bot.log, ";"), nil, yields end
		return table.concat(bot.log, ";"), lang.format_error(e), yields
	end
	return table.concat(bot.log, ";"), nil, yields
end

local function expect (name, text, want, opts)
	local log, err = run(text, opts)
	check(name, log == want and not err, "got " .. tostring(log) .. " / " .. tostring(err))
end

local function expect_err (name, text, pattern)
	local log, err = run(text)
	check(name, err and err:find(pattern), tostring(err))
end

-- basics
expect("move/turn", "move forward\nturn left\ndig front_up", "move forward;turn left;dig front_up")
expect("forward alias", "dig forward_down", "dig front_down")
expect("place item", "place front default:stone", "place front default:stone")
expect("place bare", "place front", "place front")
expect("pull bare", "pull", "pull nil")
expect("pull stack", "pull_stack a:b", "pull_stack a:b")

-- variables and arithmetic
expect("set/add", "set x = 2\nadd x 3\nchat x", "chat 5")
expect("precedence", "set x = 2 + 3 * 4\nchat x", "chat 14")
expect("parens", "set x = (2 + 3) * 4\nchat x", "chat 20")
expect("string concat", 'set s = "a" + 1\nchat s', "chat a1")
expect("join", 'set s = "ab"\njoin s "cd"\nchat s', "chat abcd")
expect("division", "set x = 7 / 2\nchat x", "chat 3.5")
expect("mod", "set x = 7 % 4\nchat x", "chat 3")
expect("mod cmd", "set x = 7\nmod x 4\nchat x", "chat 3")

-- control flow
expect("if true", "if 1 < 2\n  chat \"y\"\nelse\n  chat \"n\"", "chat y")
expect("if else", "if 2 < 1\n  chat \"y\"\nelse\n  chat \"n\"", "chat n")
expect("else if", "set v = 2\nif v = 1\n  chat \"one\"\nelse if v = 2\n  chat \"two\"\nelse\n  chat \"many\"", "chat two")
expect("repeat", "repeat 3\n  move forward", "move forward;move forward;move forward")
expect("loop counter", "loop counter < 3\n  chat counter", "chat 0;chat 1;chat 2")
expect("loop var", "set i = 0\nloop i < 3\n  chat i\n  add i 1", "chat 0;chat 1;chat 2")
expect("repeat counter", "repeat 3\n  chat counter", "chat 0;chat 1;chat 2")
expect("break", "repeat 10\n  if counter = 2\n    break\n  chat counter", "chat 0;chat 1")
expect("continue", "repeat 4\n  if even counter\n    continue\n  chat counter", "chat 1;chat 3")
expect("forever+break", "forever\n  chat \"x\"\n  break", "chat x")
expect("nested loops", "repeat 2\n  repeat 2\n    move forward", "move forward;move forward;move forward;move forward")
expect("and/or/not", "if not 0 and (1 or 0)\n  chat \"ok\"", "chat ok")
expect("compare strings", 'if "a" != "b"\n  chat "ne"', "chat ne")
expect("matches", 'if "hello" matches "^he"\n  chat "m"', "chat m")

-- queries
expect("detect", "if detect front default:stone\n  dig front", "dig front")
expect("detect none", "if detect back\n  dig back", "")
expect("count", "set n = count a:b\nchat n", "chat 7")
expect("contains", "if contains a:b\n  chat \"has\"", "chat has")
expect("even/odd", "if odd 3 and even 4\n  chat \"eo\"", "chat eo")
expect("stop", "chat \"a\"\nstop\nchat \"b\"", "chat a")
expect("random", "set r = random 6\nchat r", "chat 6")

-- functions
expect("fn basic", "fn go n\n  repeat n\n    move forward\ncall go 2", "move forward;move forward")
expect("fn return", "fn double v\n  return v * 2\nset r = call double 4\nchat r", "chat 8")
expect("fn nested call", "fn a\n  move up\nfn b\n  call a\n  call a\ncall b", "move up;move up")
expect("fn recursion", "fn down n\n  if n > 0\n    move down\n    call down (n - 1)\ncall down 3", "move down;move down;move down")
expect("fn expr arg", "fn add2 a b\n  return a + b\nchat call add2 2 3", "chat 5")
expect("fn local scope", "set x = 1\nfn f\n  set x = 5\n  set y = 9\ncall f\nchat x", "chat 5")
expect("fn params shadow", "set a = 1\nfn f a\n  set a = 9\ncall f 2\nchat a", "chat 1")
expect("return in loop", "fn f\n  repeat 5\n    if counter = 1\n      return counter\n  return 99\nchat call f", "chat 1")
expect("return top", "chat \"a\"\nreturn\nchat \"b\"", "chat a")
expect("comment", "# hi\nmove up\n  # indented comment\nmove down", "move up;move down")
expect("blank lines", "move up\n\n\nmove down", "move up;move down")

-- packages
lang.register_package("util", "fn twice\n  move up\n  move up\nfn go n\n  repeat n\n    call twice\n")
lang.register_package("deep", "use util\nfn four\n  call twice\n  call twice\n")
expect("pkg qualified", "call util.twice", "move up;move up")
expect("pkg use", "use util\ncall go 1", "move up;move up")
expect("pkg depends", "use deep\ncall four", "move up;move up;move up;move up")
expect("pkg expr", "use util\nrepeat 1\n  call twice", "move up;move up")

-- errors
expect_err("unknown cmd", "frobnicate", "unknown command")
expect_err("bad dir", "dig sideways", "not a valid direction")
expect_err("dir missing", "dig", "needs a direction")
expect_err("extra token", "move forward now", "unexpected 'now'")
expect_err("unset var", "chat zzz", "has no value")
expect_err("else orphan", "else", "without")
expect_err("break outside", "break", "outside a loop")
expect_err("bad indent", "move up\n    move down", "unexpected indent")
expect_err("unknown fn", "call nope", "unknown function")
expect_err("unknown pkg", "use nope", "unknown package")
expect_err("fn nested", "if 1\n  fn f\n    move up", "top level")
expect_err("fn dup", "fn f\n  stop\nfn f\n  stop", "twice")
expect_err("call without keyword", "fn f\n  stop\nf", "use 'call f'")
expect("last arg expr", "fn f a\n  chat a\ncall f 1 + 1", "chat 2")
expect_err("var is command", "set count = 1", "variable name")
expect_err("div zero", "set x = 1 / 0", "divide by zero")
expect_err("arith text", 'set x = "a" * 2', "needs numbers")
expect_err("deep recursion", "fn f\n  call f\ncall f", "too deep")
expect_err("action as value", "set x = move", "is an action")
expect_err("error line", "move up\nmove up\nset q = 1 / 0", "line 3")

-- yielding keeps long loops responsive
do
	local _, err, yields = run("repeat 1000\n  set a = 1", { budget = 50 })
	check("budget yields", not err and yields >= 20, tostring(yields))
end

-- round trip
do
	local text = "fn f a\n  if a > 1\n    move up\n  else\n    move down\ncall f 2"
	local out = lang.to_text(lang.parse_text(text))
	check("text round trip", out == text, out)
	local t2 = lang.to_text(lang.parse_text("\tmove up\n"))
	check("tab indent", t2 == "  move up", t2)
end

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
