-- Lune test: executes the real BitBuffer + Types modules outside Roblox to
-- verify the bitmask packing and serialization round-trips.
-- Run: lune run tests/core.test.luau

local fs = require("@lune/fs")
local luau = require("@lune/luau")

local function loadModule(path: string, env: { [any]: any })
	local source = fs.readFile(path)
	local fn = luau.load(source, { environment = env, injectGlobals = true, debugName = path })
	return fn()
end

-- BitBuffer requires nothing; Types requires script.Parent.BitBuffer.
local BitBuffer = loadModule("src/shared/BiPolar/BitBuffer.luau", {})
local Types = loadModule("src/shared/BiPolar/Types.luau", {
	require = function(x: any)
		return x
	end,
	script = { Parent = { BitBuffer = BitBuffer } },
})

local passed = 0
local function check(name: string, cond: boolean)
	assert(cond, "FAILED: " .. name)
	passed += 1
	print("  ok - " .. name)
end

local function encode(ty, value): buffer
	local w = BitBuffer.Writer.new(16)
	ty.write(w, value)
	return w:result()
end

local function decode(ty, buf)
	return ty.read(BitBuffer.Reader.new(buf))
end

print("BitBuffer:")
do
	local w = BitBuffer.Writer.new(2)
	w:varint(300)
	local buf = w:result()
	check("varint(300) uses 2 bytes", buffer.len(buf) == 2)
	check("varint(300) round-trips", BitBuffer.Reader.new(buf):varint() == 300)

	local w2 = BitBuffer.Writer.new(2)
	w2:u8(1)
	w2:u32(4000000000)
	w2:string("hello")
	local b2 = w2:result()
	local r2 = BitBuffer.Reader.new(b2)
	check("u8 round-trips", r2:u8() == 1)
	check("u32 round-trips (auto-grow)", r2:u32() == 4000000000)
	check("string round-trips", r2:string() == "hello")
end

print("f16 / f24 floats:")
do
	-- Values exactly representable in half precision -> exact round-trip.
	for _, v in { 0, 1, -1, 0.5, -0.5, 1.5, -2.25, 100, 0.125, 65504 } do
		local w = BitBuffer.Writer.new(2)
		w:f16(v)
		local buf = w:result()
		check(`f16({v}) is 2 bytes`, buffer.len(buf) == 2)
		check(`f16({v}) round-trips exactly`, BitBuffer.Reader.new(buf):f16() == v)
	end

	-- Non-representable: within half-precision tolerance.
	local w2 = BitBuffer.Writer.new(2)
	w2:f16(3.14159)
	local got = BitBuffer.Reader.new(w2:result()):f16()
	check("f16(pi) within tolerance", math.abs(got - 3.14159) < 0.01)

	-- f24: 3 bytes, much tighter than f16, full f32 range.
	local w3 = BitBuffer.Writer.new(3)
	w3:f24(1.5)
	check("f24(1.5) is 3 bytes", buffer.len(w3:result()) == 3)
	check("f24(1.5) round-trips exactly", BitBuffer.Reader.new(w3:result()):f24() == 1.5)

	local w4 = BitBuffer.Writer.new(3)
	w4:f24(12345.678)
	local g4 = BitBuffer.Reader.new(w4:result()):f24()
	-- f24 drops 8 mantissa bits, so ULP near 12345 (2^13) is ~2^-2 = 0.25.
	check("f24(12345.678) within tolerance", math.abs(g4 - 12345.678) < 0.5)

	local w5 = BitBuffer.Writer.new(3)
	w5:f24(-9876.5)
	check("f24 handles negatives", BitBuffer.Reader.new(w5:result()):f24() == -9876.5)
end

print("Buffer scramble (XOR keystream reversibility):")
do
	-- Mirrors the kernel's per-runtime scramble: XOR with a repeating keystream
	-- is symmetric, so unscramble(scramble(x)) == x.
	local key = { 0x3A, 0x91, 0xFE, 0x07, 0x55 }
	local function scramble(buf: buffer)
		for i = 0, buffer.len(buf) - 1 do
			buffer.writeu8(buf, i, bit32.bxor(buffer.readu8(buf, i), key[(i % #key) + 1]))
		end
	end
	local w = BitBuffer.Writer.new(8)
	w:u16(1234)
	w:string("payload")
	local original = buffer.tostring(w:result())
	local b = w:result()
	scramble(b)
	check("scrambled bytes differ", buffer.tostring(b) ~= original)
	scramble(b)
	check("double-scramble restores original", buffer.tostring(b) == original)
end

print("Auto-sizing integers (uint / int):")
do
	check("uint(5) is 1 byte", buffer.len(encode(Types.uint, 5)) == 1)
	check("uint(5) round-trips", decode(Types.uint, encode(Types.uint, 5)) == 5)
	check("uint(300) is 2 bytes", buffer.len(encode(Types.uint, 300)) == 2)
	check("uint(1000000) round-trips", decode(Types.uint, encode(Types.uint, 1000000)) == 1000000)
	check("int(-1) is 1 byte", buffer.len(encode(Types.int, -1)) == 1)
	for _, v in { 0, 1, -1, 63, -64, 12345, -98765 } do
		check(`int({v}) round-trips`, decode(Types.int, encode(Types.int, v)) == v)
	end
end

print("Dynamic any type:")
do
	local function deepEqual(a, b)
		if typeof(a) ~= typeof(b) then return false end
		if typeof(a) == "table" then
			for k, v in a do if not deepEqual(v, b[k]) then return false end end
			for k in b do if a[k] == nil then return false end end
			return true
		end
		return a == b
	end
	local function rt(v)
		return decode(Types.any, encode(Types.any, v))
	end
	check("any nil", rt(nil) == nil)
	check("any bool", rt(true) == true and rt(false) == false)
	check("any number", rt(3.14) == 3.14)
	check("any string", rt("hi\0bye") == "hi\0bye")
	check("any array", deepEqual(rt({ 1, 2, 3 }), { 1, 2, 3 }))
	check("any mixed table", deepEqual(rt({ 7, name = "x", on = true }), { 7, name = "x", on = true }))
	check("any nested", deepEqual(rt({ a = { 1, { 2, 3 } } }), { a = { 1, { 2, 3 } } }))
	do
		local b = buffer.fromstring("\10\20\30")
		local out = rt(b)
		check("any buffer round-trips", buffer.tostring(out) == "\10\20\30")
	end
end

print("Bitmask packing:")
do
	local eight = Types.struct({
		b1 = Types.boolean, b2 = Types.boolean, b3 = Types.boolean, b4 = Types.boolean,
		b5 = Types.boolean, b6 = Types.boolean, b7 = Types.boolean, b8 = Types.boolean,
	})
	local buf8 = encode(eight, {
		b1 = true, b2 = false, b3 = true, b4 = false,
		b5 = true, b6 = true, b7 = false, b8 = true,
	})
	check("8 booleans pack into 1 byte", buffer.len(buf8) == 1)

	local nine = Types.struct({
		b1 = Types.boolean, b2 = Types.boolean, b3 = Types.boolean,
		b4 = Types.boolean, b5 = Types.boolean, b6 = Types.boolean,
		b7 = Types.boolean, b8 = Types.boolean, b9 = Types.boolean,
	})
	check("9 booleans spill into 2 bytes", buffer.len(encode(nine, {
		b1 = true, b2 = true, b3 = true, b4 = true, b5 = true,
		b6 = true, b7 = true, b8 = true, b9 = true,
	})) == 2)

	local decoded = decode(eight, buf8)
	check("booleans decode correctly", decoded.b1 == true and decoded.b2 == false
		and decoded.b7 == false and decoded.b8 == true)
end

print("Struct round-trip + optionals:")
do
	local packet = Types.struct({
		a = Types.u8,
		name = Types.string,
		sprinting = Types.boolean,
		crouching = Types.boolean,
		target = Types.optional(Types.u32),
	})

	local withOpt = encode(packet, { a = 200, name = "hi", sprinting = true, crouching = false, target = 12345 })
	local d1 = decode(packet, withOpt)
	check("plain field decodes", d1.a == 200 and d1.name == "hi")
	check("packed booleans decode", d1.sprinting == true and d1.crouching == false)
	check("present optional decodes", d1.target == 12345)

	local noOpt = encode(packet, { a = 7, name = "hi", sprinting = false, crouching = true })
	local d2 = decode(packet, noOpt)
	check("absent optional decodes to nil", d2.target == nil)
	check("absent optional costs 0 payload bytes (4 less than present)",
		buffer.len(withOpt) - buffer.len(noOpt) == 4)
	check("mask byte shared: 2 bools + 1 optional = 1 mask byte",
		-- noOpt = mask(1) + a(1) + name(varint 1 + 2) = 5
		buffer.len(noOpt) == 5)
end

print("Struct decode across multiple mask bytes (bools + optionals interleaved):")
do
	-- 10 bit-fields force 2 mask bytes; mix bools and optionals, some present some
	-- absent, plus plain fields. Exercises the single-pass decode's byte/bit math.
	local packet = Types.struct({
		a1 = Types.boolean, o1 = Types.optional(Types.u8),
		a2 = Types.boolean, o2 = Types.optional(Types.u16),
		a3 = Types.boolean, o3 = Types.optional(Types.string),
		a4 = Types.boolean, o4 = Types.optional(Types.u32),
		a5 = Types.boolean, o5 = Types.optional(Types.f32),
		tail = Types.u16,
		label = Types.string,
	})
	local value = {
		a1 = true, a2 = false, a3 = true, a4 = false, a5 = true,
		o1 = 7, o3 = "present", o5 = -3.5, -- o2 and o4 absent
		tail = 65000, label = "end",
	}
	local d = decode(packet, encode(packet, value))
	check("multi-mask bools decode", d.a1 == true and d.a2 == false and d.a3 == true
		and d.a4 == false and d.a5 == true)
	check("present optionals decode", d.o1 == 7 and d.o3 == "present" and d.o5 == -3.5)
	check("absent optionals decode to nil", d.o2 == nil and d.o4 == nil)
	check("plain fields after mask decode", d.tail == 65000 and d.label == "end")
end

print("Array:")
do
	local arr = Types.array(Types.u16)
	local d = decode(arr, encode(arr, { 10, 20, 30, 65535 }))
	check("array round-trips", d[1] == 10 and d[2] == 20 and d[3] == 30 and d[4] == 65535)
end

print("Enum serializer (mock enum, no Roblox needed):")
do
	-- t.enum(enumType) writes an EnumItem's .Value as a varint and rebuilds it
	-- from enumType:GetEnumItems(). Mock the enum so this runs under Lune.
	local A, B, C = { Value = 0 }, { Value = 5 }, { Value = 300 }
	local mockEnum = { GetEnumItems = function() return { A, B, C } end }
	local enumTy = Types.enum(mockEnum)

	check("enum value 0 is 1 byte", buffer.len(encode(enumTy, A)) == 1)
	check("enum decodes back to the same item", decode(enumTy, encode(enumTy, B)) == B)
	check("enum value 300 (2-byte varint) round-trips", decode(enumTy, encode(enumTy, C)) == C)
	check("t.enum / t.enums exist", type(Types.enum) == "function" and type(Types.enums) == "table")
end

print("Batch + function framing (kernel wire format):")
do
	-- Mirrors the Kernel's message format inside one batched buffer:
	--   event            [u16 wireId][payload]
	--   function request [u16 wireId][u8 0][varint id][request payload]
	--   function response[u16 wireId][u8 1][varint id][response payload]
	local eventType = Types.struct({ x = Types.u8, flag = Types.boolean })
	local reqType = Types.u8
	local respType = Types.struct({ ok = Types.boolean, code = Types.u16 })

	local w = BitBuffer.Writer.new(16)
	w:u16(1001) -- event wireId
	eventType.write(w, { x = 42, flag = true })
	w:u16(2002) -- function wireId
	w:u8(0) -- request tag
	w:varint(7) -- request id
	reqType.write(w, 99)
	w:u16(2002) -- same function wireId
	w:u8(1) -- response tag
	w:varint(7) -- echoed request id
	respType.write(w, { ok = true, code = 500 })

	local r = BitBuffer.Reader.new(w:result())

	check("msg1 is the event wireId", r:u16() == 1001)
	local ev = eventType.read(r)
	check("event payload decodes", ev.x == 42 and ev.flag == true)

	check("msg2 is the function wireId", r:u16() == 2002)
	check("msg2 is a request (tag 0)", r:u8() == 0)
	check("msg2 request id", r:varint() == 7)
	check("request payload decodes", reqType.read(r) == 99)

	check("msg3 is the function wireId", r:u16() == 2002)
	check("msg3 is a response (tag 1)", r:u8() == 1)
	check("msg3 echoes request id", r:varint() == 7)
	local resp = respType.read(r)
	check("response payload decodes", resp.ok == true and resp.code == 500)

	check("batch fully consumed (eof)", r:eof())
end

print(string.format("\nAll %d checks passed.", passed))
