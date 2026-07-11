--!strict
-- BenchmarksServer: place in ServerScriptService.
--
-- (1) Runs the serialization microbench in the REAL Roblox VM, where the hot
--     serializers run --!native --!optimize 2 — so these throughput numbers are
--     the live ones (the Lune bench is a conservative interpreter floor).
-- (2) Stands up receive counters + a baseline RemoteEvent so BenchmarksClient
--     can measure end-to-end wire bytes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BiPolar = require(ReplicatedStorage.Shared.BiPolar)
local Definitions = require(ReplicatedStorage:WaitForChild("Definitions"))
local BitBuffer = Definitions.BitBuffer

local ITERS = 50000

local function bench(fn: () -> (), iters: number): number
	for _ = 1, math.min(iters, 4000) do
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
	return best / iters * 1e9
end

local function runSerializeBench()
	print("BiPolar serialization benchmark (Roblox VM, --!native)")
	print(string.format("iterations: %d  (best of 6 trials)", ITERS))
	print(string.format("%-16s %7s %7s %6s %10s %10s %12s", "payload", "bytes", "json", "vs", "enc ns", "dec ns", "enc M/s"))
	print(string.rep("-", 76))

	for _, case in Definitions.cases do
		local value = case.make()
		local ty = case.ty

		local w0 = BitBuffer.Writer.new(64)
		ty.write(w0, value)
		local encoded = w0:result()
		local bytes = buffer.len(encoded)
		local json = Definitions.jsonLen(value)

		local reuse = BitBuffer.Writer.new(math.max(64, bytes * 2))
		local encNs = bench(function()
			reuse:reset()
			ty.write(reuse, value)
		end, ITERS)

		local decNs = bench(function()
			ty.read(BitBuffer.Reader.new(encoded))
		end, ITERS)

		print(string.format(
			"%-16s %7d %7d %5.1fx %10d %10d %12.2f",
			case.name, bytes, json, json / bytes,
			math.floor(encNs + 0.5), math.floor(decNs + 0.5),
			(1e9 / encNs) / 1e6
		))
	end
	print(string.rep("-", 76))
	print("enc/dec ns = nanoseconds per encode/decode · enc M/s = millions of encodes/sec\n")
end

-- Receive side: count BiPolar deliveries (the client measures bytes via the
-- profiler; the server just absorbs so nothing back-pressures).
local received: { [string]: number } = {}
for _, case in Definitions.cases do
	received[case.name] = 0
	BiPolar:On(case.packet, function()
		received[case.name] += 1
	end)
end

-- Baseline: a plain RemoteEvent the client fires the same tables over.
local baseline = Instance.new("RemoteEvent")
baseline.Name = Definitions.BASELINE_REMOTE
baseline.Parent = ReplicatedStorage
baseline.OnServerEvent:Connect(function() end)

task.defer(runSerializeBench)
print("[bench] server ready — start a client to run the network bytes benchmark")
