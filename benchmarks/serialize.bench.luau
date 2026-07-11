-- BiPolar serialization benchmark (offline, real numbers).
-- Run: lune run benchmarks/serialize.bench.luau
--
-- Loads the REAL BitBuffer + Types modules (the same code that ships) outside
-- Roblox and measures, per payload shape:
--   * wire size in bytes (BiPolar buffer)  vs  the same data as JSON text
--   * encode throughput  (ns/op and ops/sec)
--   * decode throughput  (ns/op and ops/sec)
-- Payload shapes mirror the QuickNet benchmark set (booleans / entities /
-- strings / numbers / dictionary) so the numbers are comparable in spirit.

local fs = require("@lune/fs")
local luau = require("@lune/luau")

local function loadModule(path: string, env: { [any]: any })
	local fn = luau.load(fs.readFile(path), { environment = env, injectGlobals = true, debugName = path })
	return fn()
end

local BitBuffer = loadModule("src/shared/BiPolar/BitBuffer.luau", {})
local Types = loadModule("src/shared/BiPolar/Types.luau", {
	require = function(x: any)
		return x
	end,
	script = { Parent = { BitBuffer = BitBuffer } },
})

-- ---------------------------------------------------------------------------
-- Tiny JSON encoder for the baseline byte count (a familiar, reproducible
-- stand-in for an unoptimized table sent over a raw RemoteEvent).
-- ---------------------------------------------------------------------------
local function jsonLen(v: any): number
	local t = type(v)
	if t == "number" then
		return #tostring(v)
	elseif t == "boolean" then
		return v and 4 or 5
	elseif t == "string" then
		return #v + 2
	elseif t == "table" then
		local isArray = #v > 0
		local n = 2 -- brackets/braces
		if isArray then
			for i = 1, #v do
				n += jsonLen(v[i]) + 1
			end
		else
			for k, val in v do
				n += #tostring(k) + 3 + jsonLen(val) + 1
			end
		end
		return n
	end
	return 4
end

-- ---------------------------------------------------------------------------
-- Timing: warm up, then take the best of several trials (least noisy).
-- ---------------------------------------------------------------------------
local function bench(fn: () -> (), iters: number): (number, number)
	for _ = 1, math.min(iters, 2000) do
		fn()
	end
	local best = math.huge
	for _ = 1, 6 do
		local t0 = os.clock()
		for _ = 1, iters do
			fn()
		end
		local dt = os.clock() - t0
		if dt < best then
			best = dt
		end
	end
	return best / iters * 1e9, iters / best
end

-- ---------------------------------------------------------------------------
-- Payload shapes.
-- ---------------------------------------------------------------------------
local function buildBools(n: number)
	local fields: { [string]: any } = {}
	local value: { [string]: any } = {}
	for i = 1, n do
		fields["b" .. i] = Types.boolean
		value["b" .. i] = (i % 3 == 0)
	end
	return Types.struct(fields), value
end

local function buildEntities(n: number)
	local entity = Types.struct({
		id = Types.u8, x = Types.u8, y = Types.u8,
		z = Types.u8, orientation = Types.u8, animation = Types.u8,
	})
	local arr = Types.array(entity)
	local value = table.create(n)
	for i = 1, n do
		value[i] = { id = i % 256, x = i % 200, y = (i * 3) % 200, z = (i * 7) % 200, orientation = i % 4, animation = i % 8 }
	end
	return arr, value
end

local function buildStrings(n: number)
	local arr = Types.array(Types.string)
	local value = table.create(n)
	for i = 1, n do
		value[i] = "entity_name_" .. string.format("%04d", i)
	end
	return arr, value
end

local function buildNumbers(n: number)
	local arr = Types.array(Types.u8)
	local value = table.create(n)
	for i = 1, n do
		value[i] = i % 256
	end
	return arr, value
end

local function buildDict(n: number)
	local m = Types.map(Types.string, Types.u8)
	local value: { [string]: number } = {}
	for i = 1, n do
		value["key_" .. string.format("%03d", i)] = i % 256
	end
	return m, value
end

local cases = {
	{ name = "Booleans x32 (struct/bitmask)", ty = { buildBools(32) } },
	{ name = "Entities x100 (6x u8 struct)", ty = { buildEntities(100) } },
	{ name = "Strings x50 (~16 chars)", ty = { buildStrings(50) } },
	{ name = "Numbers x500 (u8 array)", ty = { buildNumbers(500) } },
	{ name = "Dictionary x50 (string->u8)", ty = { buildDict(50) } },
}

-- ---------------------------------------------------------------------------
-- Run.
-- ---------------------------------------------------------------------------
local ITERS = 20000

local function encodeOnce(ty: any, value: any): buffer
	local w = BitBuffer.Writer.new(64)
	ty.write(w, value)
	return w:result()
end

print("BiPolar serialization benchmark")
print(string.format("iterations: %d  (best of 6 trials, Lune interpreter)\n", ITERS))
print(string.format("%-32s %7s %7s %6s %11s %11s", "payload", "bytes", "json", "vs", "encode", "decode"))
print(string.format("%-32s %7s %7s %6s %11s %11s", "", "", "", "json", "ns/op", "ns/op"))
print(string.rep("-", 84))

for _, case in cases do
	local ty, value = case.ty[1], case.ty[2]

	local encoded = encodeOnce(ty, value)
	local bytes = buffer.len(encoded)
	local json = jsonLen(value)

	-- correctness: round-trip must succeed
	local decoded = ty.read(BitBuffer.Reader.new(encoded))
	assert(decoded ~= nil, "decode returned nil for " .. case.name)

	local reuse = BitBuffer.Writer.new(math.max(64, bytes * 2))
	local encNs = bench(function()
		reuse:reset()
		ty.write(reuse, value)
	end, ITERS)

	local decNs = bench(function()
		ty.read(BitBuffer.Reader.new(encoded))
	end, ITERS)

	print(string.format(
		"%-32s %7d %7d %5.1fx %11s %11s",
		case.name,
		bytes,
		json,
		json / bytes,
		string.format("%d", math.floor(encNs + 0.5)),
		string.format("%d", math.floor(decNs + 0.5))
	))
end

print(string.rep("-", 84))
print("\nbytes  = BiPolar wire size       json = same data as JSON text (baseline)")
print("vs json = how many times smaller  ns/op = nanoseconds per encode / decode")
print("\nThroughput here is the Lune INTERPRETER (a conservative floor). On Roblox the")
print("hot serializers run --!native --!optimize 2, so live numbers are faster.")
print("Wire SIZES above are exact and identical everywhere.")
