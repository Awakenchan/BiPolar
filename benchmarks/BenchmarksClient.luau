--!strict
-- BenchmarksClient: place in StarterPlayer/StarterPlayerScripts.
--
-- Measures the EXACT outbound wire size of each payload as BiPolar actually puts
-- it on the wire (read straight from the built-in profiler, so it includes the
-- packet id) and compares it to the same data as a JSON table. Then projects the
-- per-second bandwidth at a chosen tick rate and player count. Real packets are
-- sent to the server, which counts them.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BiPolar = require(ReplicatedStorage.Shared.BiPolar)
local Definitions = require(ReplicatedStorage:WaitForChild("Definitions"))

local SENDS = 300 -- copies fired per case to average the per-send size
local TICK_HZ = 20 -- projection: tick rate
local PLAYERS = 16 -- projection: players in the server

ReplicatedStorage:WaitForChild(Definitions.BASELINE_REMOTE)

local function bytesPerSend(case: Definitions.Case): number
	local name = case.packet.name
	local function out(): number
		local s = BiPolar.profiler.snapshot().packets[name]
		return if s then s.outBytes else 0
	end
	local value = case.make()
	local before = out()
	for _ = 1, SENDS do
		BiPolar:Fire("Reliable", case.packet, value)
	end
	return (out() - before) / SENDS
end

task.spawn(function()
	-- Warm up the protocol so the first send doesn't fold its handshake into the
	-- measurement.
	BiPolar:Fire("Reliable", Definitions.cases[1].packet, Definitions.cases[1].make())
	task.wait(1)

	print("BiPolar network bytes benchmark (exact, from the profiler)")
	print(string.format("projection: %d Hz, %d players\n", TICK_HZ, PLAYERS))
	print(string.format("%-16s %10s %8s %7s %12s %12s", "payload", "BiPolar B", "json B", "vs", "send KB/s", "recv KB/s"))
	print(string.rep("-", 72))

	for _, case in Definitions.cases do
		local b = bytesPerSend(case)
		local json = Definitions.jsonLen(case.make())
		local sendKbps = b * TICK_HZ / 1024
		local recvKbps = b * TICK_HZ * (PLAYERS - 1) / 1024
		print(string.format(
			"%-16s %10.1f %8d %5.1fx %12.2f %12.2f",
			case.name, b, json, json / b, sendKbps, recvKbps
		))
	end

	print(string.rep("-", 72))
	print("BiPolar B = exact bytes per send (incl. packet id) · json B = same data as JSON")
	print("send = your client's upload at the tick rate · recv = relayed from other players")
end)
