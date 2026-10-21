-- Cogwork language: tokenizer, parser/compiler and runtime helpers.
--
-- A program is a list of lines { indent = n, tokens = { "word", ... } }.
-- The text form is one line per program line, two spaces per indent level.
-- Pure Lua (no engine calls) so it can be tested outside Luanti.
-- Errors are raised with assert(false, value): the server's dbg mod wraps the
-- global error() and would announce every one of these (they are control flow).

local lang = {}

lang.commands = {}   -- name -> definition (see commands.lua)
lang.packages = {}   -- name -> { source = "...", unit = compiled or nil }

lang.DIR8 = { up = true, down = true, front = true, front_up = true,
	front_down = true, back = true, back_up = true, back_down = true }
lang.DIR4 = { forward = true, back = true, up = true, down = true }
lang.TURN = { left = true, right = true, around = true }

local DIR_ALIAS = { forward = "front", forward_up = "front_up",
	forward_down = "front_down" }

-- words that cannot be variable names
local KEYWORDS = {}
for w in ("if else loop repeat forever break continue fn return call use set add "
	.. "sub mul div mod join and or not true false matches"):gmatch("%S+") do
	KEYWORDS[w] = true
end
lang.KEYWORDS = KEYWORDS

local CMP = { ["="] = true, ["=="] = true, ["!="] = true, ["<"] = true,
	[">"] = true, ["<="] = true, [">="] = true, matches = true }
local ADD = { ["+"] = true, ["-"] = true }
local MUL = { ["*"] = true, ["/"] = true, ["%"] = true }
local BINWORDS = { ["and"] = true, ["or"] = true }

--------------------------------------------------------------------------
-- values

function lang.is_number_token (tok)
	return tok:match("^%-?%d+$") or tok:match("^%-?%d*%.%d+$") or tok:match("^%-?%d+%.%d*$")
end

function lang.tostr (v)
	if type(v) == "number" then
		if v % 1 == 0 and math.abs(v) < 1e15 then
			return string.format("%d", v)
		end
		return tostring(v)
	elseif v == nil then
		return ""
	end
	return tostring(v)
end

local function tonum (v)
	if type(v) == "number" then return v end
	if type(v) == "string" and lang.is_number_token(v) then return tonumber(v) end
	return nil
end
lang.tonum = tonum

function lang.truthy (v)
	return not (v == nil or v == false or v == 0 or v == "")
end
local truthy = lang.truthy

local function rt_error (ctx, msg)
	assert(false, { scratch = true, line = ctx and ctx.line, msg = msg })
end
lang.rt_error = rt_error

--------------------------------------------------------------------------
-- text <-> lines

function lang.tokenize (s)
	if s:match("^%s*#") then
		return { "#", (s:gsub("^%s*#%s?", "")) }
	end

	local toks, i, n = {}, 1, #s

	while i <= n do
		local c = s:sub(i, i)

		if c:match("%s") then
			i = i + 1
		elseif c == '"' then
			local j = s:find('"', i + 1, true) or (n + 1)
			toks[#toks + 1] = s:sub(i, j - 1) .. '"'
			i = j + 1
		elseif c == "(" or c == ")" then
			toks[#toks + 1] = c
			i = i + 1
		else
			local j = s:find("[%s()]", i) or (n + 1)
			toks[#toks + 1] = s:sub(i, j - 1)
			i = j
		end
	end

	return toks
end

function lang.parse_text (text)
	local lines = {}

	for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
		raw = raw:gsub("\r", "")
		local lead = raw:match("^[ \t]*")
		local indent = 0
		local spaces = 0

		for ch in lead:gmatch(".") do
			if ch == "\t" then
				indent = indent + 1
				spaces = 0
			else
				spaces = spaces + 1
				if spaces == 2 then
					indent = indent + 1
					spaces = 0
				end
			end
		end

		lines[#lines + 1] = { indent = indent, tokens = lang.tokenize(raw) }
	end

	-- drop trailing blank lines
	while #lines > 0 and #lines[#lines].tokens == 0 do
		lines[#lines] = nil
	end

	return lines
end

function lang.to_text (lines)
	local out = {}

	for i, line in ipairs(lines) do
		if #line.tokens == 0 then
			out[i] = ""
		elseif line.tokens[1] == "#" then
			out[i] = string.rep("  ", line.indent) .. "# " .. (line.tokens[2] or "")
		else
			out[i] = string.rep("  ", line.indent) .. table.concat(line.tokens, " ")
		end
	end

	return table.concat(out, "\n")
end

--------------------------------------------------------------------------
-- compiler

local function cerr (line, msg)
	assert(false, { scratch = true, compile = true, line = line, msg = msg })
end

local function valid_var_name (name)
	return name and name:match("^[%a_][%w_%.]*$") and not KEYWORDS[name]
		and not lang.commands[name]
end

local function var_get (ctx, name)
	local v = ctx.scope.vars[name]
	if v == nil then v = ctx.globals[name] end
	if v == nil then
		rt_error(ctx, "variable '" .. name .. "' has no value")
	end
	return v
end

local function var_set (ctx, name, value)
	local scope = ctx.scope
	if scope.vars[name] ~= nil or scope == ctx.main_scope then
		scope.vars[name] = value
	elseif ctx.globals[name] ~= nil then
		ctx.globals[name] = value
	else
		scope.vars[name] = value
	end
end

local function exec_block (stmts, ctx)
	for i = 1, #stmts do
		local s = stmts[i]
		ctx.line = s.line

		ctx.steps = ctx.steps + 1
		if ctx.steps >= ctx.budget then
			ctx.steps = 0
			ctx.yield(0)
		end

		local sig, val = s.run(ctx)
		if sig then return sig, val end
	end
end

local function call_fn (ctx, fn, args)
	if ctx.depth >= 48 then
		rt_error(ctx, "call stack too deep in '" .. fn.name .. "'")
	end

	local scope = { vars = {} }
	for i, p in ipairs(fn.params) do scope.vars[p] = args[i] end

	local saved = ctx.scope
	ctx.scope = scope
	ctx.depth = ctx.depth + 1
	local sig, val = exec_block(fn.body, ctx)
	ctx.depth = ctx.depth - 1
	ctx.scope = saved

	if sig == "return" then return val end
	return nil
end

local function compare (op, a, b)
	if op == "matches" then
		local ok, res = pcall(string.find, lang.tostr(a), lang.tostr(b))
		return ok and res ~= nil
	end

	local na, nb = tonum(a), tonum(b)
	if na and nb then a, b = na, nb else a, b = lang.tostr(a), lang.tostr(b) end

	if op == "=" or op == "==" then return a == b
	elseif op == "!=" then return a ~= b
	elseif op == "<" then return a < b
	elseif op == ">" then return a > b
	elseif op == "<=" then return a <= b
	else return a >= b end
end

local function arith (ctx, op, a, b)
	local na, nb = tonum(a), tonum(b)

	if op == "+" and not (na and nb) then
		return lang.tostr(a) .. lang.tostr(b)
	end
	if not (na and nb) then
		rt_error(ctx, "'" .. op .. "' needs numbers")
	end

	if op == "+" then return na + nb
	elseif op == "-" then return na - nb
	elseif op == "*" then return na * nb
	elseif op == "/" then
		if nb == 0 then rt_error(ctx, "divide by zero") end
		return na / nb
	else
		if nb == 0 then rt_error(ctx, "divide by zero") end
		return na % nb
	end
end

local function normalize_dir (d)
	return DIR_ALIAS[d] or d
end

-- Parser state: { toks, pos, line, st }
-- st: { fns = name -> fnobj, uses = {pkgname...}, loops = n, in_fn = bool,
--       get_package = function(name) -> unit }
local P = {}
P.__index = P

function P:peek (k) return self.toks[self.pos + (k or 0)] end
function P:next ()
	local t = self.toks[self.pos]
	self.pos = self.pos + 1
	return t
end
function P:fail (msg) cerr(self.line, msg) end

function P:resolve_fn (name)
	local st = self.st
	local fn = st.fns[name]
	if fn then return fn end

	local pkg, fname = name:match("^(.-)%.([^.]+)$")
	if pkg then
		local unit = st.get_package(pkg, self.line)
		fn = unit and unit.fns[fname]
		if fn then return fn end
	end

	for _, pname in ipairs(st.uses) do
		local unit = st.get_package(pname, self.line)
		fn = unit and unit.fns[name]
		if fn then return fn end
	end

	self:fail("unknown function '" .. name .. "'")
end

function P:starts_primary (tok)
	if not tok or tok == ")" then return false end
	if CMP[tok] or ADD[tok] or MUL[tok] or BINWORDS[tok] then return false end
	return true
end

function P:parse_arg (spec, last, cmdname)
	local kind = spec.type

	if kind == "dir8" or kind == "dir4" or kind == "turn" then
		local tok = self:next()
		if not tok then self:fail("'" .. cmdname .. "' needs a direction") end
		tok = normalize_dir(tok)
		local set = kind == "dir8" and lang.DIR8 or kind == "dir4" and lang.DIR4 or lang.TURN
		if kind == "dir4" and tok == "front" then tok = "forward" end
		if not set[tok] then
			self:fail("'" .. tok .. "' is not a valid direction for '" .. cmdname .. "'")
		end
		return function() return tok end

	elseif kind == "name" then
		local tok = self:next()
		if not valid_var_name(tok) then
			self:fail("'" .. cmdname .. "' needs a variable name")
		end
		return nil, tok

	else -- "val"
		if spec.optional and not self:starts_primary(self:peek()) then
			return function() return nil end
		end
		if last and not spec.primary then return self:parse_expr() end
		return self:parse_primary()
	end
end

function P:parse_command_call (def, name)
	local argfns, names = {}, {}
	local nargs = #def.args

	for i, spec in ipairs(def.args) do
		local f, nm = self:parse_arg(spec, i == nargs and def.kind == "action", name)
		argfns[i], names[i] = f, nm
	end

	return argfns, names
end

function P:eval_args (argfns, names, ctx)
	local vals = {}
	for i = 1, #argfns do
		if names[i] then vals[i] = names[i] else vals[i] = argfns[i](ctx) end
	end
	return vals
end

function P:parse_primary ()
	local tok = self:next()
	if tok == nil then self:fail("expression expected") end

	if tok == "(" then
		local e = self:parse_expr()
		if self:next() ~= ")" then self:fail("missing ')'") end
		return e
	end

	if tok:sub(1, 1) == '"' then
		local s = tok:sub(2, -2)
		return function() return s end
	end

	if lang.is_number_token(tok) then
		local v = tonumber(tok)
		return function() return v end
	end

	if tok == "true" then return function() return true end end
	if tok == "false" then return function() return false end end

	if tok:find(":", 1, true) or tok:sub(1, 1) == "@" then
		return function(ctx) return ctx.alias(tok) end
	end

	if tok == "call" then
		local fname = self:next()
		if not fname then self:fail("'call' needs a function name") end
		local fn = self:resolve_fn(fname)
		local args = {}
		for i = 1, #fn.params do args[i] = self:parse_primary() end
		return function(ctx)
			local vals = {}
			for i = 1, #args do vals[i] = args[i](ctx) end
			return call_fn(ctx, fn, vals)
		end
	end

	local def = lang.commands[tok]
	if def and def.kind == "query" then
		local argfns, names = self:parse_command_call(def, tok)
		return function(ctx)
			return def.run(ctx, unpack(self:eval_args(argfns, names, ctx), 1, #argfns))
		end
	end

	if def and def.kind == "action" then
		self:fail("'" .. tok .. "' is an action, not a value")
	end

	if not valid_var_name(tok) then
		self:fail("unexpected '" .. tok .. "'")
	end

	return function(ctx) return var_get(ctx, tok) end
end

function P:parse_mul ()
	local left = self:parse_primary()
	while MUL[self:peek() or ""] do
		local op = self:next()
		local right, l = self:parse_primary(), left
		left = function(ctx) return arith(ctx, op, l(ctx), right(ctx)) end
	end
	return left
end

function P:parse_add ()
	local left = self:parse_mul()
	while ADD[self:peek() or ""] do
		local op = self:next()
		local right, l = self:parse_mul(), left
		left = function(ctx) return arith(ctx, op, l(ctx), right(ctx)) end
	end
	return left
end

function P:parse_cmp ()
	local left = self:parse_add()
	while CMP[self:peek() or ""] do
		local op = self:next()
		local right, l = self:parse_add(), left
		left = function(ctx) return compare(op, l(ctx), right(ctx)) end
	end
	return left
end

function P:parse_not ()
	if self:peek() == "not" then
		self:next()
		local e = self:parse_not()
		return function(ctx) return not truthy(e(ctx)) end
	end
	return self:parse_cmp()
end

function P:parse_and ()
	local left = self:parse_not()
	while self:peek() == "and" do
		self:next()
		local right, l = self:parse_not(), left
		left = function(ctx) return truthy(l(ctx)) and truthy(right(ctx)) end
	end
	return left
end

function P:parse_expr ()
	local left = self:parse_and()
	while self:peek() == "or" do
		self:next()
		local right, l = self:parse_and(), left
		left = function(ctx) return truthy(l(ctx)) or truthy(right(ctx)) end
	end
	return left
end

function P:expect_end ()
	local t = self:peek()
	if t ~= nil then self:fail("unexpected '" .. t .. "'") end
end

local function new_parser (toks, line, st)
	return setmetatable({ toks = toks, pos = 1, line = line, st = st }, P)
end

-- index of next line that is neither blank nor a comment
local function next_code (lines, i)
	while lines[i] and (#lines[i].tokens == 0 or lines[i].tokens[1] == "#") do
		i = i + 1
	end
	return i
end

local parse_block

local function parse_body (lines, i, indent, st)
	local j = next_code(lines, i)
	if lines[j] and lines[j].indent > indent then
		return parse_block(lines, i, lines[j].indent, st)
	end
	return {}, i
end

local function parse_statement (lines, i, indent, st)
	local line = lines[i]
	local toks = line.tokens
	local kw = toks[1]
	local p = new_parser(toks, i, st)
	p:next()

	if kw == "if" then
		local cond = p:parse_expr()
		p:expect_end()
		local body, j = parse_body(lines, i + 1, indent, st)
		local else_body

		local k = next_code(lines, j)
		local nl = lines[k]
		if nl and nl.indent == indent and nl.tokens[1] == "else" then
			if #nl.tokens == 1 then
				else_body, j = parse_body(lines, k + 1, indent, st)
			else
				-- "else if ..." becomes a nested if
				local sub = { indent = indent, tokens = { unpack(nl.tokens, 2) } }
				local saved = lines[k]
				lines[k] = sub
				local stmt
				stmt, j = parse_statement(lines, k, indent, st)
				lines[k] = saved
				stmt.line = k
				else_body = { stmt }
			end
		end

		return { line = i, run = function(ctx)
			if truthy(cond(ctx)) then
				return exec_block(body, ctx)
			elseif else_body then
				return exec_block(else_body, ctx)
			end
		end }, j

	elseif kw == "else" then
		cerr(i, "'else' without 'if'")

	elseif kw == "loop" or kw == "repeat" or kw == "forever" then
		local cond, count
		if kw == "loop" then cond = p:parse_expr()
		elseif kw == "repeat" then count = p:parse_expr() end
		p:expect_end()

		st.loops = st.loops + 1
		local body, j = parse_body(lines, i + 1, indent, st)
		st.loops = st.loops - 1

		return { line = i, run = function(ctx)
			local limit
			if count then
				limit = tonum(count(ctx))
				if not limit then rt_error(ctx, "'repeat' needs a number") end
			end

			local saved = ctx.counter
			local n = 0

			while true do
				ctx.counter = n
				if cond and not truthy(cond(ctx)) then break end
				if limit and n >= limit then break end

				local sig, val = exec_block(body, ctx)
				if sig == "break" then break end
				if sig == "return" then ctx.counter = saved return sig, val end

				n = n + 1
				ctx.steps = ctx.steps + 1
				if ctx.steps >= ctx.budget then
					ctx.steps = 0
					ctx.yield(0)
				end
			end

			ctx.counter = saved
		end }, j

	elseif kw == "break" or kw == "continue" then
		if st.loops == 0 then cerr(i, "'" .. kw .. "' outside a loop") end
		p:expect_end()
		return { line = i, run = function() return kw end }, i + 1

	elseif kw == "fn" then
		-- hoisted: the body was compiled in the first pass
		local fn = st.fn_by_line[i]
		if not fn then cerr(i, "functions must be at the top level") end
		local saved_loops, saved_in = st.loops, st.in_fn
		st.loops, st.in_fn = 0, true
		local body, j = parse_body(lines, i + 1, indent, st)
		st.loops, st.in_fn = saved_loops, saved_in
		fn.body = body
		return { line = i, run = function() end }, j

	elseif kw == "return" then
		local e
		if p:peek() ~= nil then e = p:parse_expr() end
		p:expect_end()
		return { line = i, run = function(ctx)
			return "return", e and e(ctx) or nil
		end }, i + 1

	elseif kw == "use" then
		return { line = i, run = function() end }, i + 1

	elseif kw == "call" then
		local fname = p:next()
		if not fname then cerr(i, "'call' needs a function name") end
		local fn = p:resolve_fn(fname)
		local args = {}
		for k = 1, #fn.params do
			args[k] = (k == #fn.params) and p:parse_expr() or p:parse_primary()
		end
		p:expect_end()
		return { line = i, run = function(ctx)
			local vals = {}
			for k = 1, #args do vals[k] = args[k](ctx) end
			call_fn(ctx, fn, vals)
		end }, i + 1

	elseif kw == "set" or kw == "add" or kw == "sub" or kw == "mul"
		or kw == "div" or kw == "mod" or kw == "join" then

		local name = p:next()
		if not valid_var_name(name) then
			cerr(i, "'" .. kw .. "' needs a variable name (not a command word)")
		end
		if p:peek() == "=" then p:next() end
		local e = p:parse_expr()
		p:expect_end()

		return { line = i, run = function(ctx)
			local v = e(ctx)
			if kw == "set" then
				var_set(ctx, name, v)
			elseif kw == "join" then
				local cur = ctx.scope.vars[name]
				if cur == nil then cur = ctx.globals[name] end
				var_set(ctx, name, lang.tostr(cur) .. lang.tostr(v))
			else
				local op = ({ add = "+", sub = "-", mul = "*", div = "/", mod = "%" })[kw]
				var_set(ctx, name, arith(ctx, op, var_get(ctx, name), v))
			end
		end }, i + 1
	end

	local def = lang.commands[kw]
	if def and def.kind == "action" then
		local argfns, names = p:parse_command_call(def, kw)
		p:expect_end()

		return { line = i, run = function(ctx)
			local vals = p:eval_args(argfns, names, ctx)
			local ok, delay = def.run(ctx, unpack(vals, 1, #argfns))
			ctx.ok = ok ~= false
			if delay and delay > 0 then ctx.yield(delay) end
		end }, i + 1
	end

	if def then cerr(i, "'" .. kw .. "' is a value, not an action") end
	if st.fns[kw] then
		cerr(i, "use 'call " .. kw .. "' to run a function")
	end

	cerr(i, "unknown command '" .. kw .. "'")
end

parse_block = function (lines, i, indent, st)
	local stmts = {}

	while true do
		i = next_code(lines, i)
		local line = lines[i]
		if not line or line.indent < indent then break end
		if line.indent > indent then cerr(i, "unexpected indent") end

		local stmt
		stmt, i = parse_statement(lines, i, indent, st)
		stmts[#stmts + 1] = stmt
	end

	return stmts, i
end

-- Compile program lines into a unit { main, fns, uses }.
-- opts.name: label used for package errors.
function lang.compile (lines, opts)
	opts = opts or {}

	local st = { fns = {}, uses = {}, loops = 0, fn_by_line = {},
		get_package = lang.get_package }
	local unit = { fns = st.fns, uses = st.uses, name = opts.name }

	-- first pass: function signatures and package imports
	for i, line in ipairs(lines) do
		local kw = line.tokens[1]
		if kw == "fn" then
			if line.indent ~= 0 then cerr(i, "functions must be at the top level") end
			local name = line.tokens[2]
			if not name or KEYWORDS[name] or lang.commands[name]
				or not name:match("^[%a_][%w_]*$") then
				cerr(i, "bad function name '" .. tostring(name) .. "'")
			end
			if st.fns[name] then cerr(i, "function '" .. name .. "' is defined twice") end

			local params = {}
			for k = 3, #line.tokens do
				local pn = line.tokens[k]
				if not valid_var_name(pn) or pn:find(".", 1, true) then
					cerr(i, "bad parameter name '" .. pn .. "'")
				end
				params[#params + 1] = pn
			end

			local fn = { name = name, params = params, body = {}, line = i, unit = unit }
			st.fns[name] = fn
			st.fn_by_line[i] = fn
		elseif kw == "use" then
			local pname = line.tokens[2]
			if not pname then cerr(i, "'use' needs a package name") end
			if not lang.get_package(pname, i) then
				cerr(i, "unknown package '" .. pname .. "'")
			end
			st.uses[#st.uses + 1] = pname
		end
	end

	-- second pass: bodies
	unit.main = parse_block(lines, 1, 0, st)
	return unit
end

-- Run a unit. ctx fields: yield, alias, budget (see lang.new_ctx).
function lang.run (unit, ctx)
	ctx.main_scope = { vars = ctx.globals }
	ctx.scope = ctx.main_scope
	exec_block(unit.main, ctx)
end

function lang.new_ctx (env)
	env = env or {}
	return {
		globals = {}, depth = 0, steps = 0, counter = 0, ok = true, line = 0,
		budget = env.budget or 200,
		yield = env.yield or coroutine.yield,
		alias = env.alias or function(s) return s end,
		bot = env.bot,
	}
end

--------------------------------------------------------------------------
-- packages

-- Register a package from source text. Compiled on first use.
function lang.register_package (name, source, meta)
	lang.packages[name] = { source = source, meta = meta or {}, name = name }
end

-- lang.overlay: { name = { source = "..." } } consulted before the registered
-- packages while a program is compiled (packages installed in one robot)
function lang.get_package (name, line)
	local pkg = (lang.overlay and lang.overlay[name]) or lang.packages[name]
	if not pkg then return nil end
	if pkg.unit then return pkg.unit end

	if pkg.compiling then
		cerr(line, "package '" .. name .. "' uses itself")
	end

	pkg.compiling = true
	local ok, res = pcall(lang.compile, lang.parse_text(pkg.source), { name = name })
	pkg.compiling = nil

	if not ok then
		if type(res) == "table" then
			res.msg = "package '" .. name .. "' line " .. tostring(res.line) .. ": " .. res.msg
			res.line = line
		end
		assert(false, res)
	end

	pkg.unit = res
	return res
end

-- Compile program text; returns unit or nil, "message"
function lang.compile_text (text, overlay)
	lang.overlay = overlay
	local ok, res = pcall(lang.compile, lang.parse_text(text))
	lang.overlay = nil
	if ok then return res end
	if type(res) == "table" and res.scratch then
		return nil, ("line " .. tostring(res.line) .. ": " .. res.msg), res.line
	end
	assert(false, res)
end

function lang.format_error (e)
	if type(e) == "table" and e.scratch then
		return (e.line and e.line > 0 and ("line " .. e.line .. ": ") or "") .. e.msg
	end
	return "internal error: " .. tostring(e)
end

return lang
