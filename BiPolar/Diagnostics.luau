--!strict

local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local Players = game:GetService("Players")

local IS_SERVER = RunService:IsServer()

export type HotScope = { name: string, ms: number }
export type Snapshot = {
	uptime: number,
	fps: number,
	frameMs: number,
	ping: number,
	recvKbps: number,
	sendKbps: number,
	physicsKbps: number,
	luaHeapMb: number,
	totalMemMb: number,
	instances: number,
	players: number,
	heartbeatMs: number,
	hot: { HotScope },
}

local Diagnostics = {}

local startClock = os.clock()
local emaDt = 1 / 60

local accum: { [string]: number } = {}
local hot: { [string]: number } = {}

local serverSnap: Snapshot? = nil
local subscribeFn: ((boolean) -> ())? = nil

local function num(getter: () -> any): number
	local ok, value = pcall(getter)
	if ok and type(value) == "number" then
		return value
	end
	return 0
end

function Diagnostics.scope(name: string): () -> ()
	local start = os.clock()
	return function()
		accum[name] = (accum[name] or 0) + (os.clock() - start)
	end
end

function Diagnostics.measure(name: string, fn: (...any) -> ...any, ...: any): ...any
	local stop = Diagnostics.scope(name)
	local results = table.pack(fn(...))
	stop()
	return table.unpack(results, 1, results.n)
end

function Diagnostics.hotScopes(limit: number?): { HotScope }
	local list: { HotScope } = {}
	for name, ms in hot do
		table.insert(list, { name = name, ms = ms })
	end
	table.sort(list, function(a, b)
		return a.ms > b.ms
	end)
	local max = limit or 12
	while #list > max do
		table.remove(list)
	end
	return list
end

function Diagnostics.localSnapshot(): Snapshot
	return {
		uptime = os.clock() - startClock,
		fps = 1 / emaDt,
		frameMs = emaDt * 1000,
		ping = if IS_SERVER then 0 else num(function()
			return Players.LocalPlayer:GetNetworkPing() * 1000
		end),
		recvKbps = num(function()
			return Stats.DataReceiveKbps
		end),
		sendKbps = num(function()
			return Stats.DataSendKbps
		end),
		physicsKbps = num(function()
			return Stats.PhysicsReceiveKbps + Stats.PhysicsSendKbps
		end),
		luaHeapMb = collectgarbage("count") / 1024,
		totalMemMb = num(function()
			return Stats:GetTotalMemoryUsageMb()
		end),
		instances = num(function()
			return Stats.InstanceCount
		end),
		players = #Players:GetPlayers(),
		heartbeatMs = num(function()
			return Stats.HeartbeatTimeMs
		end),
		hot = Diagnostics.hotScopes(),
	}
end

function Diagnostics._setServerSnapshot(snapshot: Snapshot)
	serverSnap = snapshot
end

function Diagnostics.serverSnapshot(): Snapshot?
	return serverSnap
end

function Diagnostics._setSubscribeFn(fn: (boolean) -> ())
	subscribeFn = fn
end

function Diagnostics.subscribeServer(on: boolean)
	if subscribeFn then
		subscribeFn(on)
	end
end

local windowAcc = 0
RunService.Heartbeat:Connect(function(dt: number)
	emaDt += (dt - emaDt) * 0.1
	windowAcc += dt
	if windowAcc >= 1 then
		windowAcc = 0
		table.clear(hot)
		for name, secs in accum do
			hot[name] = secs * 1000
		end
		table.clear(accum)
	end
end)

return Diagnostics
