-- A small PNG reader: the average colour of a texture, for the robot's viewscreen.
-- Pure Lua (no bit library: it must run wherever Luanti does). 8-bit and 1/2/4-bit
-- palette, gray, RGB(A) images, not interlaced; anything else gives nil.
--
-- The inflate part follows zlib's "puff": canonical Huffman codes read bit by bit.

local png = {}

local function bytes_to_int (s, i)
	local a, b, c, d = s:byte(i, i + 3)
	return ((a * 256 + b) * 256 + c) * 256 + d
end

--------------------------------------------------------------------------
-- inflate

local LEN_BASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEN_EXTRA = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DIST_BASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 }
local DIST_EXTRA = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
local CL_ORDER = { 17, 18, 19, 1, 9, 8, 10, 7, 11, 6, 12, 5, 13, 4, 14, 3, 15, 2, 16 }

-- a Huffman table from code lengths (lengths[0 .. n-1])
local function construct (lengths, n)
	local count, offs, symbol = {}, {}, {}
	for len = 0, 15 do count[len] = 0 end
	for sym = 0, n - 1 do count[lengths[sym]] = count[lengths[sym]] + 1 end
	offs[1] = 0
	for len = 1, 14 do offs[len + 1] = offs[len] + count[len] end
	for sym = 0, n - 1 do
		local len = lengths[sym]
		if len ~= 0 then
			symbol[offs[len]] = sym
			offs[len] = offs[len] + 1
		end
	end
	return { count = count, symbol = symbol }
end

local function inflate (data, start)
	local pos, bitbuf, bitcnt = start, 0, 0
	local out, n = {}, 0

	local function bits (need)
		local val = bitbuf
		while bitcnt < need do
			local byte = data:byte(pos)
			if not byte then error("png: out of data") end
			pos = pos + 1
			val = val + byte * 2 ^ bitcnt
			bitcnt = bitcnt + 8
		end
		bitbuf = math.floor(val / 2 ^ need)
		bitcnt = bitcnt - need
		return val % 2 ^ need
	end

	local function decode (h)
		local code, first, index = 0, 0, 0
		for len = 1, 15 do
			code = code + bits(1)
			local count = h.count[len]
			if code - count < first then return h.symbol[index + (code - first)] end
			index = index + count
			first = (first + count) * 2
			code = code * 2
		end
		error("png: bad code")
	end

	local function codes (lencode, distcode)
		while true do
			local sym = decode(lencode)
			if sym < 256 then
				n = n + 1
				out[n] = sym
			elseif sym == 256 then
				return
			else
				sym = sym - 257
				local len = LEN_BASE[sym + 1] + bits(LEN_EXTRA[sym + 1])
				local dsym = decode(distcode)
				local dist = DIST_BASE[dsym + 1] + bits(DIST_EXTRA[dsym + 1])
				for _ = 1, len do
					n = n + 1
					out[n] = out[n - dist]
				end
			end
		end
	end

	local fixed_len, fixed_dist
	repeat
		local last = bits(1)
		local kind = bits(2)
		if kind == 0 then
			-- stored
			bitbuf, bitcnt = 0, 0
			local len = data:byte(pos) + data:byte(pos + 1) * 256
			pos = pos + 4
			for i = 0, len - 1 do out[n + i + 1] = data:byte(pos + i) end
			n, pos = n + len, pos + len
		elseif kind == 1 then
			if not fixed_len then
				local l = {}
				for s = 0, 143 do l[s] = 8 end
				for s = 144, 255 do l[s] = 9 end
				for s = 256, 279 do l[s] = 7 end
				for s = 280, 287 do l[s] = 8 end
				fixed_len = construct(l, 288)
				local d = {}
				for s = 0, 29 do d[s] = 5 end
				fixed_dist = construct(d, 30)
			end
			codes(fixed_len, fixed_dist)
		elseif kind == 2 then
			local nlen, ndist, ncode = bits(5) + 257, bits(5) + 1, bits(4) + 4
			local lengths = {}
			for i = 0, 18 do lengths[i] = 0 end
			for i = 1, ncode do lengths[CL_ORDER[i] - 1] = bits(3) end
			local clcode = construct(lengths, 19)
			local ls, i = {}, 0
			while i < nlen + ndist do
				local sym = decode(clcode)
				if sym < 16 then
					ls[i] = sym
					i = i + 1
				else
					local prev, rep = 0, 0
					if sym == 16 then
						prev = ls[i - 1]
						rep = 3 + bits(2)
					elseif sym == 17 then
						rep = 3 + bits(3)
					else
						rep = 11 + bits(7)
					end
					for _ = 1, rep do
						ls[i] = prev
						i = i + 1
					end
				end
			end
			local ll, dl = {}, {}
			for k = 0, nlen - 1 do ll[k] = ls[k] end
			for k = 0, ndist - 1 do dl[k] = ls[nlen + k] end
			codes(construct(ll, nlen), construct(dl, ndist))
		else
			error("png: bad block")
		end
	until last == 1
	return out
end

--------------------------------------------------------------------------
-- PNG

local CHANNELS = { [0] = 1, [2] = 3, [3] = 1, [4] = 2, [6] = 4 }

-- The average colour of the opaque pixels of a PNG file's contents: r, g, b (0-255)
-- and how much of the image is opaque (0-1). nil when it cannot be read, or when the
-- file is bigger than max_bytes (decoding is slow in Lua; big textures are not worth it).
function png.average (data, max_bytes)
	if max_bytes and #data > max_bytes then return nil end
	if data:sub(1, 8) ~= "\137PNG\r\n\26\n" then return nil end

	local pos, width, height, depth, ctype, interlace, key
	local idat, palette, alpha = {}, {}, {}
	pos = 9
	while pos < #data do
		local len = bytes_to_int(data, pos)
		local kind = data:sub(pos + 4, pos + 7)
		local body = pos + 8
		if kind == "IHDR" then
			width, height = bytes_to_int(data, body), bytes_to_int(data, body + 4)
			depth, ctype, interlace = data:byte(body + 8), data:byte(body + 9), data:byte(body + 12)
		elseif kind == "PLTE" then
			for i = 0, len / 3 - 1 do
				palette[i] = { data:byte(body + i * 3, body + i * 3 + 2) }
			end
		elseif kind == "tRNS" then
			for i = 0, len - 1 do alpha[i] = data:byte(body + i) end
			-- gray and RGB images name one colour that is transparent
			if ctype == 0 and len >= 2 then key = { alpha[0] * 256 + alpha[1] } end
			if ctype == 2 and len >= 6 then
				key = { alpha[0] * 256 + alpha[1], alpha[2] * 256 + alpha[3], alpha[4] * 256 + alpha[5] }
			end
		elseif kind == "IDAT" then
			idat[#idat + 1] = data:sub(body, body + len - 1)
		elseif kind == "IEND" then
			break
		end
		pos = body + len + 4
	end
	if not width or interlace ~= 0 or not CHANNELS[ctype] or #idat == 0 then return nil end

	local ok, raw = pcall(inflate, table.concat(idat), 3)   -- 2 bytes of zlib header
	if not ok then return nil end

	local channels = CHANNELS[ctype]
	local bits_pp = channels * depth
	local bpp = math.max(1, bits_pp / 8)
	local rowbytes = math.ceil(width * bits_pp / 8)
	-- an animated texture is a strip of frames: look at the first
	local rows = (height > width) and width or height

	local prev, row = {}, {}
	for i = 1, rowbytes do prev[i] = 0 end
	local sr, sg, sb, count, opaque = 0, 0, 0, 0, 0
	local at = 1
	for y = 1, rows do
		local filter = raw[at]
		at = at + 1
		for i = 1, rowbytes do
			local x = raw[at + i - 1] or 0
			local a = i > bpp and row[i - bpp] or 0
			local b = prev[i]
			local c = i > bpp and prev[i - bpp] or 0
			if filter == 1 then x = x + a
			elseif filter == 2 then x = x + b
			elseif filter == 3 then x = x + math.floor((a + b) / 2)
			elseif filter == 4 then
				local p = a + b - c
				local pa, pb, pc = math.abs(p - a), math.abs(p - b), math.abs(p - c)
				x = x + ((pa <= pb and pa <= pc) and a or (pb <= pc and b or c))
			end
			row[i] = x % 256
		end
		at = at + rowbytes

		for px = 0, width - 1 do
			local r, g, b, a = 0, 0, 0, 255
			if ctype == 6 then
				local o = px * 4 * depth / 8 + 1
				r, g, b, a = row[o], row[o + 1], row[o + 2], row[o + 3]
				if depth == 16 then o = px * 8 + 1 r, g, b, a = row[o], row[o + 2], row[o + 4], row[o + 6] end
			elseif ctype == 2 then
				local o = px * 3 * depth / 8 + 1
				r, g, b = row[o], row[o + (depth == 16 and 2 or 1)], row[o + (depth == 16 and 4 or 2)]
				if key and depth == 8 and r == key[1] and g == key[2] and b == key[3] then a = 0 end
			elseif ctype == 4 then
				local o = px * 2 * depth / 8 + 1
				r = row[o]
				g, b = r, r
				a = row[o + (depth == 16 and 2 or 1)]
			else
				-- gray or palette, 1/2/4/8 bits
				local v
				if depth == 8 then
					v = row[px + 1]
				elseif depth == 16 then
					v = row[px * 2 + 1]
				else
					local per = 8 / depth
					local byte = row[math.floor(px / per) + 1]
					local shift = (per - 1 - px % per) * depth
					v = math.floor(byte / 2 ^ shift) % 2 ^ depth
				end
				if ctype == 3 then
					local p = palette[v]
					if p then
						r, g, b = p[1], p[2], p[3]
					end
					a = alpha[v] or 255
				else
					if key and v == key[1] then a = 0 end
					if depth < 8 then v = v * 255 / (2 ^ depth - 1) end
					r, g, b = v, v, v
				end
			end
			count = count + 1
			if a >= 128 then
				sr, sg, sb, opaque = sr + r, sg + g, sb + b, opaque + 1
			end
		end
		prev, row = row, {}
	end

	if opaque == 0 then return nil end
	return math.floor(sr / opaque + 0.5), math.floor(sg / opaque + 0.5), math.floor(sb / opaque + 0.5), opaque / count
end

return png
