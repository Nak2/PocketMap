-- Mount the selected BSP's embedded materials before the engine first loads them.
PocketMap.Pak = {}
local Pak = PocketMap.Pak
local mounted = {}

local function uint(s, pos, bytes)
	assert(pos >= 1 and pos + bytes - 1 <= #s, "Truncated BSP ZIP")
	local n = 0
	for i = bytes - 1, 0, -1 do n = n * 256 + s:byte(pos + i) end
	return n
end

local function le32(n)
	return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

-- Raw DEFLATE, as used by ZIP method 8. Canonical Huffman codes are read
-- most-significant bit first; the surrounding stream fields are little endian.
local function inflate(data, size, yield)
	local position, bits, count = 1, 0, 0
	local function read(n)
		while count < n do
			assert(position <= #data, "Truncated DEFLATE stream")
			bits = bits + data:byte(position) * 2 ^ count
			position, count = position + 1, count + 8
		end
		local value = bits % 2 ^ n
		bits, count = math.floor(bits / 2 ^ n), count - n
		return value
	end
	local function tree(lengths)
		local counts, codes, result, code = {}, {}, {}, 0
		for _, length in ipairs(lengths) do counts[length] = (counts[length] or 0) + 1 end
		for length = 1, 15 do
			code = (code + (length > 1 and counts[length - 1] or 0)) * 2
			assert(code + (counts[length] or 0) <= 2 ^ length, "Invalid Huffman tree")
			codes[length], result[length] = code, {}
		end
		for symbol, length in ipairs(lengths) do
			if length > 0 then
				result[length][codes[length]] = symbol - 1
				codes[length] = codes[length] + 1
			end
		end
		return result
	end
	local function decode(t)
		local code = 0
		for length = 1, 15 do
			code = code * 2 + read(1)
			local symbol = t[length][code]
			if symbol ~= nil then return symbol end
		end
		error("Invalid Huffman code")
	end
	local lengthBase = {3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258}
	local lengthExtra = {0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0}
	local distBase = {1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577}
	local distExtra = {0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13}
	local window, chunks, chunk, total = {}, {}, {}, 0
	local function emit(byte)
		total = total + 1
		assert(total <= size, "DEFLATE output exceeds declared size")
		window[(total - 1) % 32768] = byte
		chunk[#chunk + 1] = string.char(byte)
		if #chunk == 16384 then
			chunks[#chunks + 1], chunk = table.concat(chunk), {}
			if yield then yield() end
		end
	end
	local final
	repeat
		final = read(1) == 1
		local kind = read(2)
		if kind == 0 then
			bits, count = 0, 0
			local length, inverse = read(16), read(16)
			assert(length + inverse == 65535, "Invalid stored DEFLATE block")
			for _ = 1, length do emit(read(8)) end
		else
			assert(kind ~= 3, "Invalid DEFLATE block type")
			local literals, distances = {}, {}
			if kind == 1 then
				for i = 0, 287 do literals[i + 1] = i < 144 and 8 or i < 256 and 9 or i < 280 and 7 or 8 end
				for i = 1, 32 do distances[i] = 5 end
			else
				local nl, nd, nc = read(5) + 257, read(5) + 1, read(4) + 4
				local order = {16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15}
				local lengths = {}
				for i = 1, 19 do lengths[i] = 0 end
				for i = 1, nc do lengths[order[i] + 1] = read(3) end
				local codes, all = tree(lengths), {}
				while #all < nl + nd do
					local symbol = decode(codes)
					if symbol < 16 then all[#all + 1] = symbol
					else
						local value, n = 0, 0
						if symbol == 16 then
							assert(#all > 0, "Missing repeated code length")
							value, n = all[#all], read(2) + 3
						elseif symbol == 17 then n = read(3) + 3
						else n = read(7) + 11 end
						assert(#all + n <= nl + nd, "Too many code lengths")
						for _ = 1, n do all[#all + 1] = value end
					end
				end
				for i = 1, nl do literals[i] = all[i] end
				for i = 1, nd do distances[i] = all[nl + i] end
			end
			assert(literals[257] and literals[257] > 0, "Missing end-of-block code")
			local lt, dt = tree(literals), tree(distances)
			while true do
				local symbol = decode(lt)
				if symbol == 256 then break end
				if symbol < 256 then emit(symbol)
				else
					local index = symbol - 256
					assert(lengthBase[index], "Invalid DEFLATE length")
					local length = lengthBase[index] + read(lengthExtra[index])
					local distanceCode = decode(dt) + 1
					assert(distBase[distanceCode], "Invalid DEFLATE distance")
					local distance = distBase[distanceCode] + read(distExtra[distanceCode])
					assert(distance <= math.min(total, 32768), "Invalid DEFLATE back reference")
					for _ = 1, length do emit(window[(total - distance) % 32768]) end
				end
			end
		end
	until final
	assert(total == size, "Incorrect DEFLATE output size")
	chunks[#chunks + 1] = table.concat(chunk)
	return table.concat(chunks)
end

function Pak.Read(zip, yield)
	local entries = {}
	if #zip == 0 then return entries end
	local ending
	for i = #zip - 21, math.max(1, #zip - 65557), -1 do
		if zip:sub(i, i + 3) == "PK\5\6" and i + 21 + uint(zip, i + 20, 2) == #zip then ending = i break end
	end
	assert(ending, "Missing BSP ZIP directory")
	assert(uint(zip, ending + 4, 2) == 0 and uint(zip, ending + 6, 2) == 0, "Multi-disk ZIP is unsupported")
	local count, pos = uint(zip, ending + 10, 2), uint(zip, ending + 16, 4) + 1
	for _ = 1, count do
		assert(zip:sub(pos, pos + 3) == "PK\1\2", "Invalid BSP ZIP entry")
		local flags, method = uint(zip, pos + 8, 2), uint(zip, pos + 10, 2)
		local crc, packed, size = uint(zip, pos + 16, 4), uint(zip, pos + 20, 4), uint(zip, pos + 24, 4)
		local nameLength, extra, comment = uint(zip, pos + 28, 2), uint(zip, pos + 30, 2), uint(zip, pos + 32, 2)
		local offset = uint(zip, pos + 42, 4) + 1
		local name = zip:sub(pos + 46, pos + 45 + nameLength):lower():gsub("\\", "/")
		-- A material the game already has is left alone: mounted files win over the game's, and a map must not replace one for the whole session
		if name:match("^materials/") and (name:match("%.vmt$") or name:match("%.vtf$")) and not name:find("..", 1, true) and not name:find(":", 1, true) and not name:find("%z") and not file.Exists(name, "GAME") then
			assert(flags % 2 == 0, "Encrypted BSP material")
			assert(size <= 268435456, "BSP texture exceeds 256 MB")
			assert(zip:sub(offset, offset + 3) == "PK\3\4", "Invalid ZIP local header")
			local first = offset + 30 + uint(zip, offset + 26, 2) + uint(zip, offset + 28, 2)
			assert(first + packed - 1 <= #zip, "Truncated packed material")
			local data = zip:sub(first, first + packed - 1)
			if method == 8 then data = inflate(data, size, yield)
			elseif method == 14 then
				-- ZIP-LZMA stores two version bytes, a uint16 property length,
				-- encoder properties, then a raw LZMA stream. util.Decompress
				-- expects LZMA-alone: five property bytes and a uint64 size.
				local properties = uint(data, 3, 2)
				assert(properties == 5 and #data >= 9, "Invalid ZIP-LZMA properties")
				data = util.Decompress(data:sub(5, 9) .. le32(size) .. le32(0) .. data:sub(10), size)
				assert(data, "Could not decompress ZIP-LZMA material")
			else assert(method == 0, "Unsupported ZIP compression method " .. method) end
			assert(#data == size and tonumber(util.CRC(data)) == crc, "BSP material checksum mismatch")
			entries[#entries + 1] = { name = name, data = data, crc = crc }
		end
		pos = pos + 46 + nameLength + extra + comment
		if yield then yield() end
	end
	return entries
end

function Pak.Mount(bsp, yield)
	local zip = bsp:GetLumpString(40)
	if #zip == 0 then return 0 end
	local key = util.CRC(zip)
	if mounted[key] then return mounted[key] end
	local entries = Pak.Read(zip, yield)
	if #entries == 0 then return 0 end
	local header = { "GMAD", string.char(3), string.rep("\0", 16), "\0PocketMap materials\0{}\0PocketMap\0", le32(1) }
	for i, entry in ipairs(entries) do
		header[#header + 1] = le32(i) .. entry.name .. "\0" .. le32(#entry.data) .. le32(0) .. le32(entry.crc)
	end
	header[#header + 1] = le32(0)
	for _, entry in ipairs(entries) do header[#header + 1] = entry.data end
	local data = table.concat(header)
	data = data .. le32(tonumber(util.CRC(data)))
	file.CreateDir("pocketmap/pak")
	local path = "pocketmap/pak/" .. key .. ".gma.dat"
	file.Write(path, data)
	assert(game.MountGMA("data/" .. path), "Could not mount the BSP's packed materials")
	mounted[key] = #entries
	return #entries
end
