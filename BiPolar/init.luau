--!strict
--[[
	BiPolar
	=======
	A kernel-based, buffer-serialized networking library for Roblox written in
	strict Luau, built for high-frequency traffic (combat, replication, movement).
	Everything funnels through one kernel: events and request/response are batched
	once per Heartbeat into a single buffer per channel, booleans and optionals are
	folded into a packed bitmask, the wire protocol is randomized per server, and
	inbound traffic is rate-limited both globally (flood guard) and per packet
	(server-side lock).

	====================================================================
	MODULE GUIDE  (each module, and how you use it)
	====================================================================

	init.luau            (this file) — the public surface.
	  - define / defineFunction to declare packets in a SHARED module.
	  - BiPolar:Fire / :Invoke / :On / :OnInvoke / :InvokeExpect to use them.
	  - BiPolar.types, .Direction, .profiler, .debug, .setSecurity, hooks.
	  Requires Kernel, Types, Profiler, Diagnostics.

	Kernel.luau          the brain. Nothing else touches a remote.
	  - Owns two RANDOM-named remotes (a reliable RemoteEvent and an Unreliable
	    RemoteEvent) and batches BOTH into one buffer per channel per Heartbeat.
	  - Builds a per-runtime obfuscated protocol (random wire ids, seeded struct
	    field-order shuffle, XOR byte scramble) published via attributes; clients
	    rebuild the identical codec at runtime.
	  - Request/response (:Invoke / :OnInvoke) is emulated over the reliable event
	    with request ids, so it batches with everything else — there is no
	    unbatched RemoteFunction path.
	  - Two layers of inbound protection: the adaptive FLOOD GUARD (global, per
	    player; learns each player's normal traffic) and the per-packet RATE LIMIT
	    / server-side lock (config.rateLimit). Plus direction enforcement.
	  Tuning: BiPolar.setSecurity. Internal API used only by this file.

	Types.luau           the serializers (`BiPolar.types`). --!native.
	  - Scalars: u8/i8/u16/i16/u32/i32, uint/int (varint), f16/f24/f32/f64.
	  - Composite: string, vector3, vector3half (6 B), vector2, cframe, color3,
	    optional(T), array(T), map(K,V), any (tagged dynamic), struct(fields).
	  - Engine datatypes: udim/udim2, rect, vector2int16/vector3int16, region3,
	    ray, numberRange, brickColor, dateTime, physicalProperties, tweenInfo,
	    font, faces/axes, numberSequence/colorSequence, color3uint8, content.
	  - Enums: enum(Enum.X) for any enum, plus enums.<Name> for every Roblox enum.
	  - struct packs every boolean + optional-presence flag into a leading bitmask
	    (8 booleans = 1 byte; absent optional = 0 payload bytes), then plain fields.

	BitBuffer.luau       growable buffer Writer/Reader. --!native.
	  - Writer: u8..f64, varint, string, raw, result, reset (keeps capacity).
	  - Reader: the symmetric reads + eof. Half/truncated-float bit math lives here.

	Profiler.luau        `BiPolar.profiler` — per-packet bytes/counts.
	  - snapshot() totals, rates() per-second, onInterval(cb), per-frame frames()
	    for the timeline, and an opt-in per-message log (setLogging/getLog/onLog).

	Diagnostics.luau     `BiPolar.debug` — client/server metrics + "hot scopes".
	  - localSnapshot(), serverSnapshot() (streamed to clients), scope()/measure()
	    to time your own code so the dashboard shows what is heavy.

	DebugUI.luau         the F3 on-screen dashboard (client only, auto-loaded).
	  - Draggable/resizable CLIENT / SERVER / NET panels; the NET panel is a
	    MicroProfiler-style packet timeline you can pause (P) and scrub.

	====================================================================
	SETUP  — declare packets in a module required by BOTH sides
	====================================================================

	    local BiPolar = require(ReplicatedStorage.Shared.BiPolar)
	    local t = BiPolar.types
	    local Direction = BiPolar.Direction

	    local Move = BiPolar.define("Move", {
	        position  = t.vector3half,        -- 6 B
	        sprinting = t.boolean,            -- packed into the bitmask
	        target    = t.optional(t.u32),    -- presence packed into the bitmask
	    }, { direction = Direction.ClientToServer, unreliable = true, rateLimit = 60 })

	    local Fetch = BiPolar.defineFunction("Fetch", t.u32, { value = t.u32 })

	====================================================================
	CALL API  — channel is the FIRST argument, chosen per call
	====================================================================

	  client : BiPolar:Fire("Unreliable", Move, { position = p, sprinting = true })
	  server : BiPolar:Fire("Reliable", Move, player, value)    -- one player
	           BiPolar:Fire("Unreliable", Move, "All", value)   -- everyone
	           BiPolar:Fire("Reliable", Move, { except = p }, value)
	           BiPolar:Fire("Reliable", Move, { p1, p2 }, value)-- a list
	  listen : BiPolar:On(Move, function(player, value) ... end) -> disconnect
	  invoke : local res = BiPolar:Invoke(Fetch, request)          -- client
	           local res = BiPolar:Invoke(Fetch, player, request)  -- server
	           BiPolar:OnInvoke(Fetch, function(player, req) return ... end)
	           BiPolar:InvokeExpect(Fetch, player, req, expected, kickReason?)

	  (The original packet methods — Move:fireServer / :listen / Fetch:invoke /
	  etc. — still work, but the BiPolar:Fire style above is the intended surface.)

	====================================================================
	DEFINE & CONFIG
	====================================================================

	  BiPolar.define(name, schema, config?) -> Packet               one-way event
	  BiPolar.defineFunction(name, reqSchema, resSchema, config?) -> Packet
	     schema : { field = type } or a single type
	     config :
	       unreliable : default channel when Fire is called without one (events)
	       direction  : "c2s" | "s2c" | "both" (default); wrong-way traffic dropped
	       rateLimit  : SERVER-SIDE LOCK — max inbound occurrences of this packet per
	                    player per second. Excess is dropped before any listener or
	                    invoke handler runs. Use it to make an action un-spammable
	                    (an attack remote at rateLimit = 20, a buy remote at 5, ...).
	                    nil = unlimited. Enforced server-side; the server is trusted.

	  BiPolar.types        all data types (see Types.luau)
	  BiPolar.Direction    { ClientToServer = "c2s", ServerToClient = "s2c", Both }
	  BiPolar.profiler     network profiler (see Profiler.luau)
	  BiPolar.debug        diagnostics + hot scopes (see Diagnostics.luau)
	  BiPolar.setSecurity  tune the global flood guard (adaptive by default)
	  BiPolar.addInboundHook(packet?, fn) / addOutboundHook(packet?, fn) -> disconnect
	     middleware that can transform (mutate info.value) or veto (return false) a
	     packet. Pass a packet to scope it, or nil for a global hook.

	Exposed types: BipolarType, Packet, Hook, HookInfo
]]

local RunService = game:GetService("RunService")

local Types = require(script.Types)
local Kernel = require(script.Kernel)
local Profiler = require(script.Profiler)
local Diagnostics = require(script.Diagnostics)

local IS_SERVER = RunService:IsServer()

export type BipolarType = Types.BipolarType

type PacketConfig = {
	unreliable: boolean?,
	direction: string?,
	rateLimit: number?,
}

local Packet = {}
Packet.__index = Packet

export type Packet = typeof(setmetatable(
	{} :: {
		name: string,
		kind: string,
		direction: string,
		unreliable: boolean,
		rateLimit: number?,
		type: Types.BipolarType?,
		requestType: Types.BipolarType?,
		responseType: Types.BipolarType?,
		handlers: { (...any) -> () },
		invokeHandler: ((...any) -> any)?,
		wireId: number?,
	},
	Packet
))

function Packet:fireServer(value: any)
	assert(not IS_SERVER, "BiPolar: :fireServer() can only be called on the client")
	Kernel.fireServer(self :: any, value)
end

function Packet:fireClient(player: Player, value: any)
	assert(IS_SERVER, "BiPolar: :fireClient() can only be called on the server")
	Kernel.fireClient(self :: any, player, value)
end

function Packet:fireAllClients(value: any)
	assert(IS_SERVER, "BiPolar: :fireAllClients() can only be called on the server")
	Kernel.fireAllClients(self :: any, value)
end

function Packet:fireAllClientsExcept(except: Player, value: any)
	assert(IS_SERVER, "BiPolar: :fireAllClientsExcept() can only be called on the server")
	Kernel.fireAllClientsExcept(self :: any, except, value)
end

function Packet:listen(handler: (...any) -> ()): () -> ()
	assert(self.kind == "event", `BiPolar: "{self.name}" is a function -- use :onInvoke() instead of :listen()`)
	table.insert(self.handlers, handler)
	return function()
		local i = table.find(self.handlers, handler)
		if i then
			table.remove(self.handlers, i)
		end
	end
end

function Packet:invoke(request: any): any
	assert(not IS_SERVER, "BiPolar: :invoke() can only be called on the client")
	assert(self.kind == "function", `BiPolar: "{self.name}" is not a function packet`)
	return Kernel.invokeServer(self :: any, request)
end

function Packet:invokeClient(player: Player, request: any): any
	assert(IS_SERVER, "BiPolar: :invokeClient() can only be called on the server")
	assert(self.kind == "function", `BiPolar: "{self.name}" is not a function packet`)
	return Kernel.invokeClient(self :: any, player, request)
end

function Packet:invokeClientExpect(player: Player, request: any, expected: any, kickReason: string?): boolean
	assert(IS_SERVER, "BiPolar: :invokeClientExpect() can only be called on the server")
	assert(self.kind == "function", `BiPolar: "{self.name}" is not a function packet`)
	return Kernel.invokeClientExpect(self :: any, player, request, expected, kickReason)
end

function Packet:onInvoke(handler: (...any) -> any)
	assert(self.kind == "function", `BiPolar: "{self.name}" is not a function packet`)
	self.invokeHandler = handler
end

local Bipolar = {}

Bipolar.types = Types
Bipolar.profiler = Profiler
Bipolar.debug = Diagnostics
Bipolar.Direction = {
	ClientToServer = "c2s",
	ServerToClient = "s2c",
	Both = "both",
}

Bipolar.setSecurity = Kernel.setSecurity
Bipolar.addInboundHook = Kernel.addInboundHook
Bipolar.addOutboundHook = Kernel.addOutboundHook

export type Hook = Kernel.Hook
export type HookInfo = Kernel.HookInfo

local function resolveChannel(channel: string): boolean
	local c = if type(channel) == "string" then string.lower(channel) else ""
	if c == "reliable" or c == "r" then
		return true
	elseif c == "unreliable" or c == "u" then
		return false
	end
	error(`BiPolar: unknown channel "{tostring(channel)}" -- use "Reliable" or "Unreliable"`, 3)
end

function Bipolar:Fire(channel: string, packet: Packet, a: any, b: any)
	local reliable = resolveChannel(channel)
	if not IS_SERVER then
		Kernel.fireServer(packet :: any, a, reliable)
		return
	end
	local target, value = a, b
	if target == "All" then
		Kernel.fireAllClients(packet :: any, value, reliable)
	elseif typeof(target) == "Instance" then
		Kernel.fireClient(packet :: any, target :: Player, value, reliable)
	elseif type(target) == "table" and (target :: any).except ~= nil then
		Kernel.fireAllClientsExcept(packet :: any, (target :: any).except, value, reliable)
	elseif type(target) == "table" then
		for _, plr in target :: { Player } do
			Kernel.fireClient(packet :: any, plr, value, reliable)
		end
	else
		error('BiPolar:Fire: target must be a Player, a list of Players, "All", or { except = player }', 2)
	end
end

function Bipolar:Invoke(packet: Packet, a: any, b: any): any
	if IS_SERVER then
		return Kernel.invokeClient(packet :: any, a :: Player, b)
	end
	return Kernel.invokeServer(packet :: any, a)
end

function Bipolar:InvokeExpect(packet: Packet, player: Player, request: any, expected: any, kickReason: string?): boolean
	return Kernel.invokeClientExpect(packet :: any, player, request, expected, kickReason)
end

function Bipolar:On(packet: Packet, handler: (...any) -> ()): () -> ()
	return (packet :: any):listen(handler)
end

function Bipolar:OnInvoke(packet: Packet, handler: (...any) -> any)
	(packet :: any):onInvoke(handler)
end

local function resolveType(schema: any): Types.BipolarType
	if type(schema) == "table" and schema.__bipolar then
		return schema
	end
	return Types.struct(schema)
end

local function validateDirection(direction: string, name: string)
	assert(
		direction == "c2s" or direction == "s2c" or direction == "both",
		`BiPolar: invalid direction "{direction}" for packet "{name}"`
	)
end

function Bipolar.define(name: string, schema: any, config: PacketConfig?): Packet
	local cfg = config or {}
	local direction = cfg.direction or "both"
	validateDirection(direction, name)

	local packet = setmetatable({
		name = name,
		kind = "event",
		direction = direction,
		unreliable = cfg.unreliable == true,
		rateLimit = cfg.rateLimit,
		type = resolveType(schema),
		requestType = nil,
		responseType = nil,
		handlers = {},
		invokeHandler = nil,
		wireId = nil,
	}, Packet)

	Kernel.register(packet :: any)
	return packet
end

function Bipolar.defineFunction(name: string, requestSchema: any, responseSchema: any, config: PacketConfig?): Packet
	local cfg = config or {}
	local direction = cfg.direction or "both"
	validateDirection(direction, name)

	local packet = setmetatable({
		name = name,
		kind = "function",
		direction = direction,
		unreliable = false,
		rateLimit = cfg.rateLimit,
		type = nil,
		requestType = resolveType(requestSchema),
		responseType = resolveType(responseSchema),
		handlers = {},
		invokeHandler = nil,
		wireId = nil,
	}, Packet)

	Kernel.register(packet :: any)
	return packet
end

local snapshotSchema = {
	uptime = Types.f32,
	fps = Types.f16,
	frameMs = Types.f16,
	ping = Types.f16,
	recvKbps = Types.f16,
	sendKbps = Types.f16,
	physicsKbps = Types.f16,
	luaHeapMb = Types.f16,
	totalMemMb = Types.f16,
	instances = Types.u32,
	players = Types.u16,
	heartbeatMs = Types.f16,
	hot = Types.array(Types.struct({ name = Types.string, ms = Types.f16 })),
}
local DebugStats = Bipolar.define("__BipolarDebugStats", snapshotSchema, { direction = "s2c" })
local DebugSubscribe = Bipolar.define("__BipolarDebugSub", Types.boolean, { direction = "c2s" })

if IS_SERVER then
	local Players = game:GetService("Players")
	local subscribers: { [Player]: boolean } = {}
	DebugSubscribe:listen(function(player: Player, on: boolean)
		subscribers[player] = if on then true else nil
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		subscribers[player] = nil
	end)
	task.spawn(function()
		while true do
			task.wait(1)
			if next(subscribers) ~= nil then
				local snap = Diagnostics.localSnapshot()
				for player in subscribers do
					DebugStats:fireClient(player, snap)
				end
			end
		end
	end)
else
	DebugStats:listen(function(snap)
		Diagnostics._setServerSnapshot(snap)
	end)
	Diagnostics._setSubscribeFn(function(on: boolean)
		DebugSubscribe:fireServer(on)
	end)
	require(script.DebugUI)
end

return Bipolar
