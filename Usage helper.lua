--[[
================================================================================
 BiPolar — Usage Helper
 Every server/client usage in one place. This file is reference only (it's one
 big comment); copy the bits you need. Require path assumes the module lives at
 ReplicatedStorage.Shared.BiPolar.
================================================================================

--------------------------------------------------------------------------------
 0. REQUIRE  (anywhere: shared / client / server)
--------------------------------------------------------------------------------

	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local BiPolar = require(ReplicatedStorage.Shared.BiPolar)
	local t = BiPolar.types
	local Direction = BiPolar.Direction  -- { ClientToServer="c2s", ServerToClient="s2c", Both="both" }


--------------------------------------------------------------------------------
 1. SHARED — define packets in a module required by BOTH sides
    (ids derive from the packet names, so both sides MUST define the same set)
--------------------------------------------------------------------------------

	-- EVENT packet:  BiPolar.define(name, schema, config?)
	--   schema : { field = type }  (becomes a packed struct) OR a single type
	--   config : { unreliable: boolean?, direction: ("c2s"|"s2c"|"both")? }
	local Move = BiPolar.define("Move", {
		position  = t.vector3half,    -- pick the tightest type that fits (see types below)
		health    = t.u8,
		sprinting = t.boolean,        -- bools + optional-presence pack into one mask byte
		aiming    = t.boolean,
		target    = t.optional(t.u32) -- absent optional = 1 presence bit, 0 payload
	}, { direction = Direction.Both })

	-- single-type packet (no struct):
	local RequestRespawn = BiPolar.define("RequestRespawn", t.boolean, { direction = Direction.ClientToServer })

	-- FUNCTION packet (request/response):  BiPolar.defineFunction(name, reqSchema, resSchema, config?)
	--   config also takes  native: boolean?  -> use a REAL RemoteFunction round-trip
	--   (unbatched, no built-in timeout) instead of the emulated-over-RemoteEvent default.
	local Fetch  = BiPolar.defineFunction("Fetch", t.u32, { value = t.u32 }, { direction = Direction.ClientToServer })
	local Native = BiPolar.defineFunction("Native", t.u8, { ok = t.boolean }, { native = true })

	-- TYPES (BiPolar.types):
	--   u8 i8 u16 i16 u32 i32        fixed integers
	--   uint                          varint (small = 1 byte)
	--   int                           zigzag varint (signed, small = 1 byte)
	--   f16 (2B) f24 (3B) f32 (4B) f64/number (8B)
	--   boolean / bool                1 bit inside a struct mask
	--   string
	--   vector3 (12B) vector3half (6B) vector2 (8B) cframe (48B) color3 (3B)
	--   optional(T)  array(T)  map(K,V)  struct(fields)
	--   any                           dynamic self-describing value (incl. buffer)


--------------------------------------------------------------------------------
 2. CLIENT
--------------------------------------------------------------------------------

	-- Send an event to the server. Channel is the FIRST arg: "Reliable" | "Unreliable".
	BiPolar:Fire("Reliable",   Chat,  { message = "hi" })
	BiPolar:Fire("Unreliable", Move,  { position = p, health = 100, sprinting = true, aiming = false })
	BiPolar:Fire("Reliable",   RequestRespawn, true)            -- single-type packet

	-- Listen for events from the server. Returns a disconnect function.
	local disconnect = BiPolar:On(Chat, function(value)
		print(value.message)
	end)
	-- disconnect()  -- stop listening

	-- Request/response: call the server and yield for the reply.
	local res = BiPolar:Invoke(Fetch, 123)                      -- res.value
	local nat = BiPolar:Invoke(Native, 7)                       -- native RemoteFunction path


--------------------------------------------------------------------------------
 3. SERVER
--------------------------------------------------------------------------------

	-- Send an event. After the packet comes the TARGET, then the value:
	BiPolar:Fire("Reliable",   Chat, player,           { message = "to one" })   -- one Player
	BiPolar:Fire("Reliable",   Chat, { p1, p2 },       { message = "to some" })  -- a list of Players
	BiPolar:Fire("Reliable",   Chat, "All",            { message = "to all" })   -- everyone
	BiPolar:Fire("Unreliable", Move, { except = me },  moveData)                 -- everyone but `me`

	-- Listen for events from clients. Handler auto-receives the player.
	BiPolar:On(Move, function(player, value)
		-- player is the sender; value is the decoded payload
	end)

	-- Request/response from server -> client (yields for the reply):
	local res = BiPolar:Invoke(Fetch, player, 123)

	-- Invoke a client and KICK it if the answer isn't exactly `expected`:
	local ok = BiPolar:InvokeExpect(Fetch, player, request, { value = expected }, "Bad response")

	-- Handle requests clients make to the server (auto-receives the player):
	BiPolar:OnInvoke(Fetch, function(player, request)
		return { value = request * 2 }
	end)


--------------------------------------------------------------------------------
 4. MIDDLEWARE HOOKS  (client or server)
    Intercept/transform/veto packets. Pass a packet to scope the hook to it, or
    nil for a GLOBAL hook (runs for every packet). Returns a disconnect function.
    The hook gets info = { name, kind ("event"|"request"), dir ("in"|"out"),
    player, value }. Mutate info.value to transform; return false to veto
    (drop inbound / cancel outbound). Cover events both ways + inbound requests.
--------------------------------------------------------------------------------

	-- Drop empty chat before any listener sees it (inbound, scoped to Chat):
	BiPolar.addInboundHook(Chat, function(info)
		if info.value.message == "" then return false end
	end)

	-- Global outbound logger:
	local stop = BiPolar.addOutboundHook(nil, function(info)
		print("sending", info.name, info.dir)
	end)
	-- stop()  -- remove the hook


--------------------------------------------------------------------------------
 5. FLOOD PROTECTION  (server) — adaptive by default; you usually set nothing
--------------------------------------------------------------------------------

	BiPolar.setSecurity({
		auto = true,                  -- learn each player's traffic; act only on outliers (default)
		factor = 8,                   -- allow up to 8x a player's established peak
		warmupSeconds = 5,            -- learn-only grace right after joining
		floorPacketsPerSecond = 1000, floorBytesPerSecond = 1048576,  -- generous minimums
		hardPacketsPerSecond = 4000,  hardBytesPerSecond = 4194304,   -- absolute ceiling
		maxBufferBytes = 65536,       -- a single buffer larger than this is always dropped
		maxStrikes = 8,               -- sustained over-limit seconds before a kick
		kick = false,                 -- drop-only by default
	})

	-- Prefer fixed caps instead of adaptive:
	BiPolar.setSecurity({ auto = false, maxPacketsPerSecond = 240, maxBytesPerSecond = 131072 })


--------------------------------------------------------------------------------
 6. PROFILER & DEBUG  (client unless noted)
--------------------------------------------------------------------------------

	local snap  = BiPolar.profiler.snapshot()  -- cumulative totals
	local rates = BiPolar.profiler.rates()     -- bytes/sec & count/sec per packet
	BiPolar.profiler.onInterval(function(r) end)  -- live, every second
	BiPolar.profiler.setLogging(true)             -- capture per-message log
	for _, e in BiPolar.profiler.getLog() do      -- e.name/dir/kind/bytes/value/raw
	end

	-- Script-timing "hot scopes" (show on the F3 dashboard):
	local stopScope = BiPolar.debug.scope("Pathfinding")
	-- ...work...
	stopScope()
	BiPolar.debug.measure("Pathfinding", computePath, start, goal)  -- or wrap a call

	-- Press F3 in-game for the CLIENT / SERVER / NET dashboard (P = pause the timeline).


--------------------------------------------------------------------------------
 7. LEGACY packet methods (still supported; BiPolar:Fire above is the intended API)
--------------------------------------------------------------------------------

	-- client : packet:fireServer(value) / packet:invoke(req) / packet:onInvoke(fn)
	-- server : packet:fireClient(player, value) / packet:fireAllClients(value)
	--          packet:fireAllClientsExcept(player, value)
	--          packet:invokeClient(player, req) / packet:invokeClientExpect(...)
	-- both   : packet:listen(handler) -> disconnect


--------------------------------------------------------------------------------
 NOTES
--------------------------------------------------------------------------------
  * Channel ("Reliable"/"Unreliable") is chosen per Fire call; if omitted by the
    legacy methods it falls back to the packet's config.unreliable.
  * Direction is enforced: a packet sent the wrong way is dropped by the kernel.
  * Events are batched once per Heartbeat; native RemoteFunction invokes are not.
  * Reliable batches of 64+ bytes are Zstd-compressed automatically (engine
    EncodingService) when that makes them smaller (lossless — decoded bytes are
    identical). Unreliable batches are untouched. No API to call; it just
    happens on flush.
  * Listeners run INLINE on the receive path (not a thread per packet) — if a
    handler must yield for a while, task.spawn your own thread (see the demo's
    RequestRespawn -> LoadCharacter).
  * Define packets in a SHARED module required by both sides; you may also define
    packets after startup (they're integrated on the fly).
================================================================================
]]
