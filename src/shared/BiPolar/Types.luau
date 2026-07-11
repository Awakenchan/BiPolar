--!strict
--!native
--!optimize 2

local BitBuffer = require(script.Parent.BitBuffer)

type Writer = BitBuffer.Writer
type Reader = BitBuffer.Reader

export type BipolarType = {
	__bipolar: true,
	bool: boolean?,
	optional: boolean?,
	struct: boolean?,
	inner: BipolarType?,
	finalize: ((Random) -> ())?,
	write: (Writer, any) -> (),
	read: (Reader) -> any,
}

local function shuffle(list: { any }, rng: Random)
	for i = #list, 2, -1 do
		local j = rng:NextInteger(1, i)
		list[i], list[j] = list[j], list[i]
	end
end

local Types = {}

local enumMapCache: { [any]: { [number]: any } } = {}
local function itemFromValue(enumType: any, value: number): any
	local map = enumMapCache[enumType]
	if not map then
		map = {}
		for _, item in enumType:GetEnumItems() do
			map[item.Value] = item
		end
		enumMapCache[enumType] = map
	end
	return map[value]
end

Types.u8 = {
	__bipolar = true,
	write = function(w: Writer, v: any) w:u8(v) end,
	read = function(r: Reader): any return r:u8() end,
} :: BipolarType

Types.i8 = {
	__bipolar = true,
	write = function(w: Writer, v: any) w:i8(v) end,
	read = function(r: Reader): any return r:i8() end,
} :: BipolarType

Types.u16 = {
	__bipolar = true,
	write = function(w: Writer, v: any) w:u16(v) end,
	read = function(r: Reader): any return r:u16() end,
} :: BipolarType

Types.i16 = {
	__bipolar = true,
	write = function(w: Writer, v: any) w:i16(v) end,
	read = function(r: Reader): any return r:i16() end,
} :: BipolarType

Types.u32 = {
	__bipolar = true,
	write = function(w: Writer, v: any) w:u32(v) end,
	read = function(r: Reader): any return r:u32() end,
} :: BipolarType

Types.i32 = {
	__bipolar = true,
	write = function(w: Writer, v: any) w:i32(v) end,
	read = function(r: Reader): any return r:i32() end,
} :: BipolarType

Types.uint = {
	__bipolar = true,
	write = function(w: Writer, v: any) w:varint(v) end,
	read = function(r: Reader): any return r:varint() end,
} :: BipolarType

Types.int = {
	__bipolar = true,
	write = function(w: Writer, v: any) w:varint(if v >= 0 then v * 2 else -v * 2 - 1) end,
	read = function(r: Reader): any
		local zz = r:varint()
		if zz % 2 == 0 then
			return zz / 2
		end
		return -(zz + 1) / 2
	end,
} :: BipolarType

Types.f16 = {
	__bipolar = true,
	write = function(w: Writer, v: any) w:f16(v) end,
	read = function(r: Reader): any return r:f16() end,
} :: BipolarType

Types.f24 = {
	__bipolar = true,
	write = function(w: Writer, v: any) w:f24(v) end,
	read = function(r: Reader): any return r:f24() end,
} :: BipolarType

Types.f32 = {
	__bipolar = true,
	write = function(w: Writer, v: any) w:f32(v) end,
	read = function(r: Reader): any return r:f32() end,
} :: BipolarType

Types.f64 = {
	__bipolar = true,
	write = function(w: Writer, v: any) w:f64(v) end,
	read = function(r: Reader): any return r:f64() end,
} :: BipolarType

Types.number = Types.f64

Types.string = {
	__bipolar = true,
	write = function(w: Writer, v: any) w:string(v) end,
	read = function(r: Reader): any return r:string() end,
} :: BipolarType

Types.boolean = {
	__bipolar = true,
	bool = true,
	write = function(w: Writer, v: any) w:u8(v and 1 or 0) end,
	read = function(r: Reader): any return r:u8() == 1 end,
} :: BipolarType

Types.bool = Types.boolean

local ANY_NIL, ANY_FALSE, ANY_TRUE, ANY_NUMBER, ANY_STRING = 0, 1, 2, 3, 4
local ANY_TABLE, ANY_VECTOR3, ANY_VECTOR2, ANY_CFRAME, ANY_COLOR3, ANY_BUFFER = 5, 6, 7, 8, 9, 10

local encodeAny: (Writer, any) -> ()
local decodeAny: (Reader) -> any

local function encodeAnyTable(w: Writer, tbl: { [any]: any })
	local n = #tbl
	w:varint(n)
	for i = 1, n do
		encodeAny(w, tbl[i])
	end
	local keys: { any } = {}
	for k in tbl do
		if not (type(k) == "number" and k >= 1 and k <= n and k % 1 == 0) then
			table.insert(keys, k)
		end
	end
	w:varint(#keys)
	for _, k in keys do
		encodeAny(w, k)
		encodeAny(w, tbl[k])
	end
end

function encodeAny(w: Writer, v: any)
	local ty = typeof(v)
	if v == nil then
		w:u8(ANY_NIL)
	elseif ty == "boolean" then
		w:u8(if v then ANY_TRUE else ANY_FALSE)
	elseif ty == "number" then
		w:u8(ANY_NUMBER)
		w:f64(v)
	elseif ty == "string" then
		w:u8(ANY_STRING)
		w:string(v)
	elseif ty == "buffer" then
		w:u8(ANY_BUFFER)
		w:string(buffer.tostring(v))
	elseif ty == "Vector3" then
		w:u8(ANY_VECTOR3)
		w:f32(v.X)
		w:f32(v.Y)
		w:f32(v.Z)
	elseif ty == "Vector2" then
		w:u8(ANY_VECTOR2)
		w:f32(v.X)
		w:f32(v.Y)
	elseif ty == "CFrame" then
		w:u8(ANY_CFRAME)
		local c = { v:GetComponents() }
		for i = 1, 12 do
			w:f32(c[i])
		end
	elseif ty == "Color3" then
		w:u8(ANY_COLOR3)
		w:f32(v.R)
		w:f32(v.G)
		w:f32(v.B)
	elseif ty == "table" then
		w:u8(ANY_TABLE)
		encodeAnyTable(w, v)
	else
		error(`BiPolar: t.any cannot serialize a "{ty}"`)
	end
end

function decodeAny(r: Reader): any
	local tag = r:u8()
	if tag == ANY_NIL then
		return nil
	elseif tag == ANY_FALSE then
		return false
	elseif tag == ANY_TRUE then
		return true
	elseif tag == ANY_NUMBER then
		return r:f64()
	elseif tag == ANY_STRING then
		return r:string()
	elseif tag == ANY_BUFFER then
		return buffer.fromstring(r:string())
	elseif tag == ANY_VECTOR3 then
		return Vector3.new(r:f32(), r:f32(), r:f32())
	elseif tag == ANY_VECTOR2 then
		return Vector2.new(r:f32(), r:f32())
	elseif tag == ANY_CFRAME then
		return CFrame.new(
			r:f32(), r:f32(), r:f32(),
			r:f32(), r:f32(), r:f32(),
			r:f32(), r:f32(), r:f32(),
			r:f32(), r:f32(), r:f32()
		)
	elseif tag == ANY_COLOR3 then
		return Color3.new(r:f32(), r:f32(), r:f32())
	elseif tag == ANY_TABLE then
		local out: { [any]: any } = {}
		local n = r:varint()
		for i = 1, n do
			out[i] = decodeAny(r)
		end
		local pairsCount = r:varint()
		for _ = 1, pairsCount do
			local k = decodeAny(r)
			out[k] = decodeAny(r)
		end
		return out
	end
	error(`BiPolar: t.any received a bad tag {tag}`)
end

Types.any = {
	__bipolar = true,
	write = function(w: Writer, v: any) encodeAny(w, v) end,
	read = function(r: Reader): any return decodeAny(r) end,
} :: BipolarType

Types.vector3 = {
	__bipolar = true,
	write = function(w: Writer, v: any)
		w:f32(v.X) w:f32(v.Y) w:f32(v.Z)
	end,
	read = function(r: Reader): any
		return Vector3.new(r:f32(), r:f32(), r:f32())
	end,
} :: BipolarType

Types.vector3half = {
	__bipolar = true,
	write = function(w: Writer, v: any)
		w:f16(v.X) w:f16(v.Y) w:f16(v.Z)
	end,
	read = function(r: Reader): any
		return Vector3.new(r:f16(), r:f16(), r:f16())
	end,
} :: BipolarType

Types.vector2 = {
	__bipolar = true,
	write = function(w: Writer, v: any)
		w:f32(v.X) w:f32(v.Y)
	end,
	read = function(r: Reader): any
		return Vector2.new(r:f32(), r:f32())
	end,
} :: BipolarType

Types.cframe = {
	__bipolar = true,
	write = function(w: Writer, v: any)
		local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = v:GetComponents()
		w:f32(x) w:f32(y) w:f32(z)
		w:f32(r00) w:f32(r01) w:f32(r02)
		w:f32(r10) w:f32(r11) w:f32(r12)
		w:f32(r20) w:f32(r21) w:f32(r22)
	end,
	read = function(r: Reader): any
		return CFrame.new(
			r:f32(), r:f32(), r:f32(),
			r:f32(), r:f32(), r:f32(),
			r:f32(), r:f32(), r:f32(),
			r:f32(), r:f32(), r:f32()
		)
	end,
} :: BipolarType

Types.color3 = {
	__bipolar = true,
	write = function(w: Writer, v: any)
		w:u8(math.floor(v.R * 255 + 0.5))
		w:u8(math.floor(v.G * 255 + 0.5))
		w:u8(math.floor(v.B * 255 + 0.5))
	end,
	read = function(r: Reader): any
		return Color3.fromRGB(r:u8(), r:u8(), r:u8())
	end,
} :: BipolarType

Types.color3uint8 = Types.color3
Types.content = Types.string

-- UI / layout datatypes.
Types.udim = {
	__bipolar = true,
	write = function(w: Writer, v: any) w:f32(v.Scale) w:i32(v.Offset) end,
	read = function(r: Reader): any return UDim.new(r:f32(), r:i32()) end,
} :: BipolarType

Types.udim2 = {
	__bipolar = true,
	write = function(w: Writer, v: any)
		w:f32(v.X.Scale) w:i32(v.X.Offset) w:f32(v.Y.Scale) w:i32(v.Y.Offset)
	end,
	read = function(r: Reader): any
		return UDim2.new(r:f32(), r:i32(), r:f32(), r:i32())
	end,
} :: BipolarType

Types.rect = {
	__bipolar = true,
	write = function(w: Writer, v: any)
		w:f32(v.Min.X) w:f32(v.Min.Y) w:f32(v.Max.X) w:f32(v.Max.Y)
	end,
	read = function(r: Reader): any
		return Rect.new(r:f32(), r:f32(), r:f32(), r:f32())
	end,
} :: BipolarType

Types.vector2int16 = {
	__bipolar = true,
	write = function(w: Writer, v: any) w:i16(v.X) w:i16(v.Y) end,
	read = function(r: Reader): any return Vector2int16.new(r:i16(), r:i16()) end,
} :: BipolarType

Types.vector3int16 = {
	__bipolar = true,
	write = function(w: Writer, v: any) w:i16(v.X) w:i16(v.Y) w:i16(v.Z) end,
	read = function(r: Reader): any return Vector3int16.new(r:i16(), r:i16(), r:i16()) end,
} :: BipolarType

-- Spatial / physics datatypes.
Types.region3 = {
	__bipolar = true,
	write = function(w: Writer, v: any)
		local p = v.CFrame.Position
		local s = v.Size
		w:f32(p.X) w:f32(p.Y) w:f32(p.Z) w:f32(s.X) w:f32(s.Y) w:f32(s.Z)
	end,
	read = function(r: Reader): any
		local cx, cy, cz = r:f32(), r:f32(), r:f32()
		local sx, sy, sz = r:f32(), r:f32(), r:f32()
		local h = Vector3.new(sx / 2, sy / 2, sz / 2)
		local c = Vector3.new(cx, cy, cz)
		return Region3.new(c - h, c + h)
	end,
} :: BipolarType

Types.ray = {
	__bipolar = true,
	write = function(w: Writer, v: any)
		w:f32(v.Origin.X) w:f32(v.Origin.Y) w:f32(v.Origin.Z)
		w:f32(v.Direction.X) w:f32(v.Direction.Y) w:f32(v.Direction.Z)
	end,
	read = function(r: Reader): any
		return Ray.new(Vector3.new(r:f32(), r:f32(), r:f32()), Vector3.new(r:f32(), r:f32(), r:f32()))
	end,
} :: BipolarType

Types.physicalProperties = {
	__bipolar = true,
	write = function(w: Writer, v: any)
		w:f32(v.Density) w:f32(v.Friction) w:f32(v.Elasticity)
		w:f32(v.FrictionWeight) w:f32(v.ElasticityWeight)
	end,
	read = function(r: Reader): any
		return PhysicalProperties.new(r:f32(), r:f32(), r:f32(), r:f32(), r:f32())
	end,
} :: BipolarType

-- Range / sequence / misc datatypes.
Types.numberRange = {
	__bipolar = true,
	write = function(w: Writer, v: any) w:f32(v.Min) w:f32(v.Max) end,
	read = function(r: Reader): any return NumberRange.new(r:f32(), r:f32()) end,
} :: BipolarType

Types.brickColor = {
	__bipolar = true,
	write = function(w: Writer, v: any) w:u16(v.Number) end,
	read = function(r: Reader): any return BrickColor.new(r:u16()) end,
} :: BipolarType

Types.dateTime = {
	__bipolar = true,
	write = function(w: Writer, v: any) w:f64(v.UnixTimestampMillis) end,
	read = function(r: Reader): any return DateTime.fromUnixTimestampMillis(r:f64()) end,
} :: BipolarType

Types.numberSequence = {
	__bipolar = true,
	write = function(w: Writer, v: any)
		local kp = v.Keypoints
		w:varint(#kp)
		for _, k in kp do
			w:f32(k.Time) w:f32(k.Value) w:f32(k.Envelope)
		end
	end,
	read = function(r: Reader): any
		local n = r:varint()
		local kps = table.create(n)
		for i = 1, n do
			kps[i] = NumberSequenceKeypoint.new(r:f32(), r:f32(), r:f32())
		end
		return NumberSequence.new(kps)
	end,
} :: BipolarType

Types.colorSequence = {
	__bipolar = true,
	write = function(w: Writer, v: any)
		local kp = v.Keypoints
		w:varint(#kp)
		for _, k in kp do
			local c = k.Value
			w:f32(k.Time)
			w:u8(math.floor(c.R * 255 + 0.5)) w:u8(math.floor(c.G * 255 + 0.5)) w:u8(math.floor(c.B * 255 + 0.5))
		end
	end,
	read = function(r: Reader): any
		local n = r:varint()
		local kps = table.create(n)
		for i = 1, n do
			local t = r:f32()
			kps[i] = ColorSequenceKeypoint.new(t, Color3.fromRGB(r:u8(), r:u8(), r:u8()))
		end
		return ColorSequence.new(kps)
	end,
} :: BipolarType

-- Bitmask datatypes (a packed flag set per face / axis).
Types.faces = {
	__bipolar = true,
	write = function(w: Writer, v: any)
		local b = 0
		if v.Top then b = bit32.bor(b, 1) end
		if v.Bottom then b = bit32.bor(b, 2) end
		if v.Left then b = bit32.bor(b, 4) end
		if v.Right then b = bit32.bor(b, 8) end
		if v.Back then b = bit32.bor(b, 16) end
		if v.Front then b = bit32.bor(b, 32) end
		w:u8(b)
	end,
	read = function(r: Reader): any
		local b = r:u8()
		local ids = {}
		if bit32.band(b, 1) ~= 0 then table.insert(ids, Enum.NormalId.Top) end
		if bit32.band(b, 2) ~= 0 then table.insert(ids, Enum.NormalId.Bottom) end
		if bit32.band(b, 4) ~= 0 then table.insert(ids, Enum.NormalId.Left) end
		if bit32.band(b, 8) ~= 0 then table.insert(ids, Enum.NormalId.Right) end
		if bit32.band(b, 16) ~= 0 then table.insert(ids, Enum.NormalId.Back) end
		if bit32.band(b, 32) ~= 0 then table.insert(ids, Enum.NormalId.Front) end
		return Faces.new(table.unpack(ids))
	end,
} :: BipolarType

Types.axes = {
	__bipolar = true,
	write = function(w: Writer, v: any)
		local b = 0
		if v.X then b = bit32.bor(b, 1) end
		if v.Y then b = bit32.bor(b, 2) end
		if v.Z then b = bit32.bor(b, 4) end
		w:u8(b)
	end,
	read = function(r: Reader): any
		local b = r:u8()
		local ids = {}
		if bit32.band(b, 1) ~= 0 then table.insert(ids, Enum.Axis.X) end
		if bit32.band(b, 2) ~= 0 then table.insert(ids, Enum.Axis.Y) end
		if bit32.band(b, 4) ~= 0 then table.insert(ids, Enum.Axis.Z) end
		return Axes.new(table.unpack(ids))
	end,
} :: BipolarType

-- Tween + font: small records that include Enum members.
Types.tweenInfo = {
	__bipolar = true,
	write = function(w: Writer, v: any)
		w:f32(v.Time)
		w:u8(v.EasingStyle.Value)
		w:u8(v.EasingDirection.Value)
		w:i32(v.RepeatCount)
		w:u8(if v.Reverses then 1 else 0)
		w:f32(v.DelayTime)
	end,
	read = function(r: Reader): any
		local time = r:f32()
		local style = itemFromValue(Enum.EasingStyle, r:u8())
		local dir = itemFromValue(Enum.EasingDirection, r:u8())
		local repeatCount = r:i32()
		local reverses = r:u8() == 1
		local delayTime = r:f32()
		return TweenInfo.new(time, style, dir, repeatCount, reverses, delayTime)
	end,
} :: BipolarType

Types.font = {
	__bipolar = true,
	write = function(w: Writer, v: any)
		w:string(v.Family)
		w:u16(v.Weight.Value)
		w:u8(v.Style.Value)
	end,
	read = function(r: Reader): any
		local family = r:string()
		local weight = itemFromValue(Enum.FontWeight, r:u16())
		local style = itemFromValue(Enum.FontStyle, r:u8())
		return Font.new(family, weight, style)
	end,
} :: BipolarType

-- Generic Enum support: t.enum(Enum.Material) serializes any EnumItem of that
-- enum as a varint of its .Value. t.enums.<Name> is a ready-made serializer for
-- every Roblox Enum (so t.enums.KeyCode, t.enums.Material, ... all exist).
function Types.enum(enumType: any): BipolarType
	return {
		__bipolar = true,
		write = function(w: Writer, v: any) w:varint(v.Value) end,
		read = function(r: Reader): any return itemFromValue(enumType, r:varint()) end,
	}
end

Types.enums = {} :: { [string]: BipolarType }
if typeof(Enum) == "Enums" then
	for _, et in Enum:GetEnums() do
		Types.enums[(string.gsub(tostring(et), "^Enum%.", ""))] = Types.enum(et)
	end
end

function Types.optional(inner: BipolarType): BipolarType
	return {
		__bipolar = true,
		optional = true,
		inner = inner,
		finalize = function(rng: Random)
			if inner.finalize then
				inner.finalize(rng)
			end
		end,
		write = function(w: Writer, v: any)
			if v == nil then
				w:u8(0)
			else
				w:u8(1)
				inner.write(w, v)
			end
		end,
		read = function(r: Reader): any
			if r:u8() == 1 then
				return inner.read(r)
			end
			return nil
		end,
	}
end

function Types.array(inner: BipolarType): BipolarType
	return {
		__bipolar = true,
		finalize = function(rng: Random)
			if inner.finalize then
				inner.finalize(rng)
			end
		end,
		write = function(w: Writer, v: any)
			w:varint(#v)
			for i = 1, #v do
				inner.write(w, v[i])
			end
		end,
		read = function(r: Reader): any
			local n = r:varint()
			local t = table.create(n)
			for i = 1, n do
				t[i] = inner.read(r)
			end
			return t
		end,
	}
end

function Types.map(keyType: BipolarType, valueType: BipolarType): BipolarType
	return {
		__bipolar = true,
		finalize = function(rng: Random)
			if keyType.finalize then
				keyType.finalize(rng)
			end
			if valueType.finalize then
				valueType.finalize(rng)
			end
		end,
		write = function(w: Writer, v: any)
			local n = 0
			for _ in v do
				n += 1
			end
			w:varint(n)
			for k, val in v do
				keyType.write(w, k)
				valueType.write(w, val)
			end
		end,
		read = function(r: Reader): any
			local n = r:varint()
			local t = {}
			for _ = 1, n do
				local k = keyType.read(r)
				t[k] = valueType.read(r)
			end
			return t
		end,
	}
end

type BitField = { name: string, kind: string, inner: BipolarType? }
type PlainField = { name: string, type: BipolarType }

function Types.struct(fields: { [string]: BipolarType }): BipolarType
	local names: { string } = {}
	for name in fields do
		table.insert(names, name)
	end
	table.sort(names)

	local bitFields: { BitField } = {}
	local plainFields: { PlainField } = {}
	for _, name in names do
		local ty = fields[name]
		assert(ty and ty.__bipolar, `BiPolar: field "{name}" is not a valid type`)
		if ty.bool then
			table.insert(bitFields, { name = name, kind = "bool" })
		elseif ty.optional then
			table.insert(bitFields, { name = name, kind = "optional", inner = ty.inner })
		else
			table.insert(plainFields, { name = name, type = ty })
		end
	end

	local bitCount = #bitFields
	local maskBytes = math.ceil(bitCount / 8)

	return {
		__bipolar = true,
		struct = true,
		finalize = function(rng: Random)
			shuffle(bitFields, rng)
			shuffle(plainFields, rng)
			for _, f in bitFields do
				if f.inner and f.inner.finalize then
					f.inner.finalize(rng)
				end
			end
			for _, f in plainFields do
				if f.type.finalize then
					f.type.finalize(rng)
				end
			end
		end,
		write = function(w: Writer, value: any)
			for byteIndex = 0, maskBytes - 1 do
				local b = 0
				for bit = 0, 7 do
					local f = bitFields[byteIndex * 8 + bit + 1]
					if f then
						local set: boolean
						if f.kind == "bool" then
							set = value[f.name] == true
						else
							set = value[f.name] ~= nil
						end
						if set then
							b = bit32.bor(b, bit32.lshift(1, bit))
						end
					end
				end
				w:u8(b)
			end

			for _, f in bitFields do
				if f.kind == "optional" and value[f.name] ~= nil then
					(f.inner :: BipolarType).write(w, value[f.name])
				end
			end

			for _, f in plainFields do
				f.type.write(w, value[f.name])
			end
		end,
		read = function(r: Reader): any
			local out: { [string]: any } = {}

			local masks = table.create(maskBytes)
			for i = 1, maskBytes do
				masks[i] = r:u8()
			end

			for idx = 1, bitCount do
				local f = bitFields[idx]
				local isSet = bit32.band(masks[(idx - 1) // 8 + 1], bit32.lshift(1, (idx - 1) % 8)) ~= 0
				if f.kind == "bool" then
					out[f.name] = isSet
				elseif isSet then
					out[f.name] = (f.inner :: BipolarType).read(r)
				end
			end

			for _, f in plainFields do
				out[f.name] = f.type.read(r)
			end

			return out
		end,
	}
end

return Types
