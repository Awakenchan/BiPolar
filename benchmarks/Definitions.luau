--!strict
-- Shared benchmark definitions, required by BenchmarksServer and
-- BenchmarksClient. One BiPolar packet per payload shape (mirroring the
-- QuickNet benchmark set: booleans / entities / strings / numbers / dictionary),
-- plus the matching sample values and the raw type used by the serialize bench.
--
-- Placement (these live OUTSIDE the default Rojo tree on purpose):
--   Definitions       -> ReplicatedStorage  (shared)
--   BenchmarksServer   -> ServerScriptService
--   BenchmarksClient   -> StarterPlayer/StarterPlayerScripts

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BiPolar = require(ReplicatedStorage.Shared.BiPolar)
local t = BiPolar.types

export type Case = {
	name: string,
	packet: any,
	ty: any,
	make: () -> any,
}

local Definitions = {}

Definitions.BitBuffer = require(ReplicatedStorage.Shared.BiPolar.BitBuffer)

-- No rate limit on benchmark packets: we want to measure serialization, not the
-- server-side lock. Everything is client -> server.
local CFG = { direction = "c2s" }

local function boolFields(): { [string]: any }
	local f: { [string]: any } = {}
	for i = 1, 32 do
		f["b" .. i] = t.boolean
	end
	return f
end

local entityStruct = t.struct({
	id = t.u8, x = t.u8, y = t.u8, z = t.u8, orientation = t.u8, animation = t.u8,
})

local boolType = t.struct(boolFields())
local entityArray = t.array(entityStruct)
local stringArray = t.array(t.string)
local numberArray = t.array(t.u8)
local dictMap = t.map(t.string, t.u8)

Definitions.cases = {
	{
		name = "Booleans x32",
		packet = BiPolar.define("Bench_Booleans", boolType, CFG),
		ty = boolType,
		make = function()
			local v: { [string]: boolean } = {}
			for i = 1, 32 do
				v["b" .. i] = (i % 3 == 0)
			end
			return v
		end,
	},
	{
		name = "Entities x100",
		packet = BiPolar.define("Bench_Entities", entityArray, CFG),
		ty = entityArray,
		make = function()
			local v = table.create(100)
			for i = 1, 100 do
				v[i] = { id = i % 256, x = i % 200, y = (i * 3) % 200, z = (i * 7) % 200, orientation = i % 4, animation = i % 8 }
			end
			return v
		end,
	},
	{
		name = "Strings x50",
		packet = BiPolar.define("Bench_Strings", stringArray, CFG),
		ty = stringArray,
		make = function()
			local v = table.create(50)
			for i = 1, 50 do
				v[i] = "entity_name_" .. string.format("%04d", i)
			end
			return v
		end,
	},
	{
		name = "Numbers x500",
		packet = BiPolar.define("Bench_Numbers", numberArray, CFG),
		ty = numberArray,
		make = function()
			local v = table.create(500)
			for i = 1, 500 do
				v[i] = i % 256
			end
			return v
		end,
	},
	{
		name = "Dictionary x50",
		packet = BiPolar.define("Bench_Dict", dictMap, CFG),
		ty = dictMap,
		make = function()
			local v: { [string]: number } = {}
			for i = 1, 50 do
				v["key_" .. string.format("%03d", i)] = i % 256
			end
			return v
		end,
	},
} :: { Case }

-- Name of the RemoteEvent the network bench uses as the un-optimized baseline
-- (a plain table over a single RemoteEvent, no buffer).
Definitions.BASELINE_REMOTE = "Bench_BaselineRemote"

-- JSON-text byte count of a value: a familiar, reproducible stand-in for the
-- size of an unoptimized table, used by both the serialize and network benches.
function Definitions.jsonLen(v: any): number
	local ty = type(v)
	if ty == "number" then
		return #tostring(v)
	elseif ty == "boolean" then
		return if v then 4 else 5
	elseif ty == "string" then
		return #v + 2
	elseif ty == "table" then
		local n = 2
		if #v > 0 then
			for i = 1, #v do
				n += Definitions.jsonLen(v[i]) + 1
			end
		else
			for k, val in v do
				n += #tostring(k) + 3 + Definitions.jsonLen(val) + 1
			end
		end
		return n
	end
	return 4
end

return Definitions
