--!strict
--!native
--!optimize 2

local BitBuffer = {}

local scratch = buffer.create(4)

local function f32ToBits(value: number): number
	buffer.writef32(scratch, 0, value)
	return buffer.readu32(scratch, 0)
end

local function bitsToF32(bits: number): number
	buffer.writeu32(scratch, 0, bits)
	return buffer.readf32(scratch, 0)
end

local function f32ToHalf(value: number): number
	local x = f32ToBits(value)
	local sign = bit32.band(bit32.rshift(x, 16), 0x8000)
	local exp = bit32.band(bit32.rshift(x, 23), 0xFF)
	local mant = bit32.band(x, 0x7FFFFF)
	if exp == 0xFF then
		if mant ~= 0 then
			return bit32.bor(sign, 0x7E00)
		end
		return bit32.bor(sign, 0x7C00)
	end
	local newExp = exp - 127 + 15
	if newExp >= 31 then
		return bit32.bor(sign, 0x7C00)
	elseif newExp <= 0 then
		if newExp < -10 then
			return sign
		end
		mant = bit32.bor(mant, 0x800000)
		local halfMant = bit32.rshift(mant, 14 - newExp)
		return bit32.bor(sign, halfMant)
	end
	return bit32.bor(sign, bit32.lshift(newExp, 10), bit32.rshift(mant, 13))
end

local function halfToF32(h: number): number
	local sign = bit32.band(bit32.rshift(h, 15), 0x1)
	local exp = bit32.band(bit32.rshift(h, 10), 0x1F)
	local mant = bit32.band(h, 0x3FF)
	local signBit = bit32.lshift(sign, 31)
	if exp == 0 then
		if mant == 0 then
			return bitsToF32(signBit)
		end
		local e = 0
		repeat
			e += 1
			mant = bit32.lshift(mant, 1)
		until bit32.band(mant, 0x400) ~= 0
		mant = bit32.band(mant, 0x3FF)
		local f32exp = 127 - 15 - e + 1
		return bitsToF32(bit32.bor(signBit, bit32.lshift(f32exp, 23), bit32.lshift(mant, 13)))
	elseif exp == 0x1F then
		return bitsToF32(bit32.bor(signBit, bit32.lshift(0xFF, 23), bit32.lshift(mant, 13)))
	end
	local f32exp = exp - 15 + 127
	return bitsToF32(bit32.bor(signBit, bit32.lshift(f32exp, 23), bit32.lshift(mant, 13)))
end

local Writer = {}
Writer.__index = Writer

export type Writer = typeof(setmetatable(
	{} :: { buf: buffer, size: number, cursor: number },
	Writer
))

function Writer.new(initialSize: number?): Writer
	local size = initialSize or 64
	return setmetatable({
		buf = buffer.create(size),
		size = size,
		cursor = 0,
	}, Writer)
end

function Writer:_reserve(n: number)
	local needed = self.cursor + n
	if needed <= self.size then
		return
	end
	local newSize = self.size
	repeat
		newSize *= 2
	until newSize >= needed
	local nb = buffer.create(newSize)
	buffer.copy(nb, 0, self.buf, 0, self.cursor)
	self.buf = nb
	self.size = newSize
end

function Writer:u8(v: number)
	local c = self.cursor
	if c + 1 > self.size then
		self:_reserve(1)
	end
	buffer.writeu8(self.buf, c, v)
	self.cursor = c + 1
end

function Writer:i8(v: number)
	local c = self.cursor
	if c + 1 > self.size then
		self:_reserve(1)
	end
	buffer.writei8(self.buf, c, v)
	self.cursor = c + 1
end

function Writer:u16(v: number)
	local c = self.cursor
	if c + 2 > self.size then
		self:_reserve(2)
	end
	buffer.writeu16(self.buf, c, v)
	self.cursor = c + 2
end

function Writer:i16(v: number)
	local c = self.cursor
	if c + 2 > self.size then
		self:_reserve(2)
	end
	buffer.writei16(self.buf, c, v)
	self.cursor = c + 2
end

function Writer:u32(v: number)
	local c = self.cursor
	if c + 4 > self.size then
		self:_reserve(4)
	end
	buffer.writeu32(self.buf, c, v)
	self.cursor = c + 4
end

function Writer:i32(v: number)
	local c = self.cursor
	if c + 4 > self.size then
		self:_reserve(4)
	end
	buffer.writei32(self.buf, c, v)
	self.cursor = c + 4
end

function Writer:f16(v: number)
	self:u16(f32ToHalf(v))
end

function Writer:f24(v: number)
	local top = bit32.rshift(f32ToBits(v), 8)
	local c = self.cursor
	if c + 3 > self.size then
		self:_reserve(3)
	end
	local b = self.buf
	buffer.writeu8(b, c, bit32.band(top, 0xFF))
	buffer.writeu8(b, c + 1, bit32.band(bit32.rshift(top, 8), 0xFF))
	buffer.writeu8(b, c + 2, bit32.band(bit32.rshift(top, 16), 0xFF))
	self.cursor = c + 3
end

function Writer:f32(v: number)
	local c = self.cursor
	if c + 4 > self.size then
		self:_reserve(4)
	end
	buffer.writef32(self.buf, c, v)
	self.cursor = c + 4
end

function Writer:f64(v: number)
	local c = self.cursor
	if c + 8 > self.size then
		self:_reserve(8)
	end
	buffer.writef64(self.buf, c, v)
	self.cursor = c + 8
end

function Writer:varint(n: number)
	local value = math.floor(n)
	while value >= 0x80 do
		self:u8(bit32.bor(bit32.band(value, 0x7F), 0x80))
		value = math.floor(value / 128)
	end
	self:u8(value)
end

function Writer:string(s: string)
	local len = #s
	self:varint(len)
	local c = self.cursor
	if c + len > self.size then
		self:_reserve(len)
		c = self.cursor
	end
	buffer.writestring(self.buf, c, s)
	self.cursor = c + len
end

function Writer:raw(src: buffer, count: number?)
	local n = count or buffer.len(src)
	local c = self.cursor
	if c + n > self.size then
		self:_reserve(n)
		c = self.cursor
	end
	buffer.copy(self.buf, c, src, 0, n)
	self.cursor = c + n
end

function Writer:result(): buffer
	local out = buffer.create(self.cursor)
	buffer.copy(out, 0, self.buf, 0, self.cursor)
	return out
end

function Writer:reset()
	self.cursor = 0
end

local Reader = {}
Reader.__index = Reader

export type Reader = typeof(setmetatable(
	{} :: { buf: buffer, len: number, cursor: number },
	Reader
))

function Reader.new(buf: buffer): Reader
	return setmetatable({
		buf = buf,
		len = buffer.len(buf),
		cursor = 0,
	}, Reader)
end

function Reader:eof(): boolean
	return self.cursor >= self.len
end

function Reader:u8(): number
	local c = self.cursor
	self.cursor = c + 1
	return buffer.readu8(self.buf, c)
end

function Reader:i8(): number
	local c = self.cursor
	self.cursor = c + 1
	return buffer.readi8(self.buf, c)
end

function Reader:u16(): number
	local c = self.cursor
	self.cursor = c + 2
	return buffer.readu16(self.buf, c)
end

function Reader:i16(): number
	local c = self.cursor
	self.cursor = c + 2
	return buffer.readi16(self.buf, c)
end

function Reader:u32(): number
	local c = self.cursor
	self.cursor = c + 4
	return buffer.readu32(self.buf, c)
end

function Reader:i32(): number
	local c = self.cursor
	self.cursor = c + 4
	return buffer.readi32(self.buf, c)
end

function Reader:f16(): number
	return halfToF32(self:u16())
end

function Reader:f24(): number
	local c = self.cursor
	local b = self.buf
	local b0 = buffer.readu8(b, c)
	local b1 = buffer.readu8(b, c + 1)
	local b2 = buffer.readu8(b, c + 2)
	self.cursor = c + 3
	local top = bit32.bor(b0, bit32.lshift(b1, 8), bit32.lshift(b2, 16))
	return bitsToF32(bit32.lshift(top, 8))
end

function Reader:f32(): number
	local c = self.cursor
	self.cursor = c + 4
	return buffer.readf32(self.buf, c)
end

function Reader:f64(): number
	local c = self.cursor
	self.cursor = c + 8
	return buffer.readf64(self.buf, c)
end

function Reader:varint(): number
	local result = 0
	local shift = 1
	while true do
		local b = self:u8()
		result += bit32.band(b, 0x7F) * shift
		if b < 0x80 then
			break
		end
		shift *= 128
	end
	return result
end

function Reader:string(): string
	local len = self:varint()
	local c = self.cursor
	self.cursor = c + len
	return buffer.readstring(self.buf, c, len)
end

BitBuffer.Writer = Writer
BitBuffer.Reader = Reader

return BitBuffer
