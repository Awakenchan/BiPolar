# BiPolar

A **kernel-based**, buffer-serialized networking library for Roblox (Rojo), in
strict-mode Luau. Built around one idea: **two-state values are the cheapest
thing on the wire.** Every boolean and every optional field is folded into a
packed **bitmask** — eight booleans cost one byte, an absent optional costs one
bit.

Ships with a **built-in network profiler**, a **per-server randomized wire
protocol**, **middleware hooks**, and **adaptive flood protection** that tunes
itself to each player so live games aren't false-flagged.

> One unified call API, deliberately *not* shaped like Roblox's remotes:
> `BiPolar:Fire("Reliable", packet, …)` — the channel is the first argument and a
> single `Fire` / `Invoke` works out the direction from where it runs.

## Features

| | |
| --- | --- |
| **Batching** | Batches all your events into a single event per frame |
| **Serialize** | Serializes all data into one buffer |
| **Many types** | 16-bit floats + 24-bit floats + many more |
| **Adaptive flood protection** | Learns each player's normal traffic; only acts on extreme outliers, so live play isn't false-flagged |
| **Server-side lock** | Per-packet inbound rate limit (`rateLimit = N`): caps how many times each player can land a packet per second — un-spammable attack / buy / respawn remotes, decoded then dropped before any handler runs |
| **Native codegen** | The hot serializers (`BitBuffer`, `Types`) are `--!native --!optimize 2` for compiled buffer math |
| **Remote functions** | Request a response — fully emulated over the batched reliable event (no unbatched RemoteFunction), so invokes batch with everything else |
| **Locked responses** | Server can demand an exact client response and kick on mismatch |
| **Unreliable** | UnreliableRemoteEvent support; channel chosen per call |
| **Middleware hooks** | Intercept / transform / veto any packet, inbound or outbound |
| **Per-runtime obfuscation** | Wire ids, field order & byte scramble are regenerated every server |
| **Profiler** | Grouped bandwidth breakdown + decoded/raw packet inspector |
| **Easy to use** | Simple and elegant, strict-mode Luau |

## Highlights

- **Kernel-based, batched transport** — one reliable RemoteEvent + one opt-in
  unreliable one carry the whole game. Request/response is **fully emulated over
  the reliable event** (everything routed by a numeric id and **batched once per
  frame**, `Heartbeat`) — there is no unbatched RemoteFunction, so invokes ride
  the same batch as events for the fewest possible remote calls. Both remotes
  get **random names per runtime** (the client finds them by class).
- **Bitmask packing** — booleans and optional-presence flags share a packed mask
  at the front of each struct. Verified: 8 booleans = 1 byte, absent optional =
  0 payload bytes.
- **Per-runtime obfuscated protocol** — the server is authoritative and rebuilds
  the whole protocol each run from a random seed: a random 16-bit wire id per
  packet, a shuffled struct **field order**, and a byte-keystream **scramble** on
  every buffer. It publishes the id map + seed as **attributes**; the client
  rebuilds the identical codec at runtime (`rebuildCodec`). The static kernel
  source only contains the generic rebuild step, so sniffed buffers and hardcoded
  ids don't carry across servers. (Obfuscation, not cryptography — the
  seed/attributes are readable by anyone who joins.)
- **Many float types** — `f16` (2-byte half) and `f24` (3-byte) alongside the
  usual ints/floats, for cheap-but-good-enough numbers.
- **Request/response without a RemoteFunction** — `defineFunction` + `:Invoke` /
  `:OnInvoke`, server handler **auto-receiving the player**, emulated over the
  batched reliable event (times out after 10s). `:InvokeExpect` locks the answer
  and **kicks** on a tampered/timed-out response.
- **Adaptive flood protection** — instead of fixed caps that legitimate bursts
  trip, the guard learns each player's own busiest second and only acts on traffic
  many times larger (or past an absurd absolute ceiling). Strikes decay on clean
  seconds and kicking is off by default, so a real player is never false-flagged.
  Tune (or switch back to fixed caps with `auto = false`) via `BiPolar.setSecurity`.
- **Middleware hooks** — `BiPolar.addInboundHook` / `addOutboundHook`, global or
  per-packet, can transform a payload or veto it, for logging, validation,
  compression, encryption, or ACLs.
- **Direction enforcement** — each packet is `c2s`, `s2c`, or `both`; the kernel
  drops inbound packets travelling the wrong way.
- **Debug dashboard** — press **F3**: draggable, **resizable** CLIENT / SERVER /
  NET panels. Client & (network-replicated) server metrics, a script-timing
  "hot scopes" profiler, and a MicroProfiler-style packet timeline you can pause
  and scrub for spikes.
- **Strict mode** — every module is `--!strict`.

## Installation

BiPolar is a plain Luau library — it has no Rojo runtime dependency, so use it
either way:

**With Rojo** — clone this repo and `rojo serve` / `rojo build`, or point your own
project at `src/shared/BiPolar` (this is what the demo does). Just make sure the
`BiPolar` folder ends up somewhere both the client and server can `require` it,
e.g. `ReplicatedStorage`.

**Without Rojo** — grab `BiPolarNetwork.rbxm` from the
[latest release](../../releases/latest) and drag it into
Studio (or right-click a service → *Insert from File*). Drop it in
`ReplicatedStorage` and `require` it — no toolchain, no build step. To rebuild the
model yourself from source: `rojo build model.project.json -o BiPolar.rbxm`.

Either way you get the same `BiPolar` ModuleScript; the rest of this README is
identical.

## Quick start

Define packets in a **shared** module required by both sides
([src/shared/Packets.luau](src/shared/Packets.luau)):

```lua
local BiPolar = require(ReplicatedStorage.Shared.BiPolar)
local t = BiPolar.types
local Direction = BiPolar.Direction

local PlayerState = BiPolar.define("PlayerState", {
    position  = t.vector3,
    health    = t.u8,
    sprinting = t.boolean,   -- ┐
    crouching = t.boolean,   -- ├─ all share a single mask byte
    jumping   = t.boolean,   -- │
    aiming    = t.boolean,   -- ┘
    target    = t.optional(t.u32), -- present? 1 bit. value? only if present.
}, { direction = Direction.Both })
```

Client:

```lua
BiPolar:Fire("Unreliable", PlayerState, { position = p, health = 100, sprinting = true,
    crouching = false, jumping = false, aiming = false })
```

Server:

```lua
BiPolar:On(PlayerState, function(player, data)
    -- data.sprinting, data.position, ...
end)
```

> Packet ids derive from the sorted set of names, so **both sides must define
> the same packets** — define them in a shared module.

## API

Define packets in a shared module:

`BiPolar.define(name, schema, config?)` → event packet
`BiPolar.defineFunction(name, requestSchema, responseSchema, config?)` → function packet

- `schema` / `requestSchema` / `responseSchema`: a `{ field = type }` table
  (becomes a struct), or a single type.
- `config.unreliable`: the **default** channel when you `Fire` without naming one
  (events only). You can always override per call with `"Reliable"`/`"Unreliable"`.
- `config.direction`: `"c2s"`, `"s2c"`, or `"both"` (default). One-way packets
  sent the wrong way are rejected by the kernel.
- `config.rateLimit` (number): **server-side lock** — the maximum number of
  inbound occurrences of this packet allowed **per player per second**. Excess is
  dropped before any listener or invoke handler runs, so a single remote can be
  made un-spammable (an attack at `rateLimit = 20`, a buy at `5`, a respawn at
  `2`, …). This is the per-action throttle on top of the global flood guard;
  enforced server-side (the server is trusted), `nil` means unlimited.

### Sending & receiving (`BiPolar:` methods)

The channel — `"Reliable"` or `"Unreliable"` — is the first argument to `Fire`,
and one `Fire`/`Invoke` infers direction from where it runs.

| Call | Side | Description |
| --- | --- | --- |
| `BiPolar:Fire("Reliable", packet, value)` | client | send to the server |
| `BiPolar:Fire("Reliable", packet, player, value)` | server | send to one player |
| `BiPolar:Fire("Reliable", packet, "All", value)` | server | send to everyone |
| `BiPolar:Fire("Reliable", packet, { except = p }, value)` | server | everyone but `p` |
| `BiPolar:Fire("Reliable", packet, { p1, p2 }, value)` | server | a list of players |
| `BiPolar:On(packet, handler)` → disconnect | both | server gets `(player, value)`, client gets `(value)` |
| `BiPolar:Invoke(packet, request)` → response | client | call the server, yields |
| `BiPolar:Invoke(packet, player, request)` → response | server | call a client, yields |
| `BiPolar:InvokeExpect(packet, player, request, expected, kickReason?)` → bool | server | call a client; **kick** on mismatch |
| `BiPolar:OnInvoke(packet, handler)` | both | server handler gets `(player, request)`, client gets `(request)` |

> **Listeners run inline.** Handlers are called directly on the kernel's receive
> path (not in a fresh thread per packet), so a handler that needs to yield for a
> while should `task.spawn` its own thread to avoid stalling the rest of the batch.

> The original packet methods (`packet:fireServer(value)`, `:listen`,
> `:invoke`, `:onInvoke`, `:invokeClientExpect`, …) still work if you prefer them,
> but `BiPolar:Fire` above is the intended surface.

### Middleware hooks

`BiPolar.addInboundHook(packet?, fn)` / `BiPolar.addOutboundHook(packet?, fn)` →
disconnect. Pass a packet to scope the hook to it, or `nil` for a global hook. The
hook gets `{ name, kind, dir, player, value }`; **mutate `info.value`** to
transform the payload, or **return `false`** to veto (drop inbound / cancel
outbound). Hooks cover events (both directions) and inbound function requests.

```lua
-- Drop empty chat before any listener sees it.
BiPolar.addInboundHook(Chat, function(info)
    if info.value.message == "" then return false end
end)
```

Also: `BiPolar.types`, `BiPolar.Direction`, `BiPolar.profiler`, `BiPolar.setSecurity`.

## Types (`BiPolar.types`)

| Type | Wire size | Lua type |
| --- | --- | --- |
| `u8 i8` | 1 byte | number |
| `u16 i16` | 2 bytes | number |
| `u32 i32` | 4 bytes | number |
| `uint` | 1+ bytes | number (varint, auto-sized) |
| `int` | 1+ bytes | number (zigzag varint, signed) |
| `f16` | 2 bytes | number (half float) |
| `f24` | 3 bytes | number (truncated f32) |
| `f32` | 4 bytes | number |
| `f64` / `number` | 8 bytes | number |
| `boolean` / `bool` | 1 bit\* | boolean |
| `string` | 1+ bytes | string |
| `vector3` | 12 bytes | Vector3 |
| `vector3half` | 6 bytes | Vector3 (half precision) |
| `vector2` | 8 bytes | Vector2 |
| `cframe` | 48 bytes | CFrame |
| `color3` | 3 bytes | Color3 |
| `optional(T)` | 1 bit\* + T | T? |
| `array(T)` | 1+ bytes | {T} |
| `map(K, V)` | 1+ bytes | {[K]: V} |
| `struct(fields)` | varies | record |
| `any` | 1+ bytes | dynamic tagged value (incl. buffer) |

\* inside a struct mask; 1 byte standalone.

### UI, tween & engine datatypes

| Type | Wire size | Lua type |
| --- | --- | --- |
| `udim` / `udim2` | 8 / 16 bytes | UDim / UDim2 |
| `rect` | 16 bytes | Rect |
| `vector2int16` / `vector3int16` | 4 / 6 bytes | Vector2int16 / Vector3int16 |
| `region3` | 24 bytes | Region3 |
| `ray` | 24 bytes | Ray |
| `numberRange` | 8 bytes | NumberRange |
| `brickColor` | 2 bytes | BrickColor |
| `dateTime` | 8 bytes | DateTime |
| `physicalProperties` | 20 bytes | PhysicalProperties |
| `tweenInfo` | 12 bytes | TweenInfo |
| `font` | 4+ bytes | Font |
| `faces` / `axes` | 1 byte | Faces / Axes (packed flags) |
| `numberSequence` / `colorSequence` | 1+ bytes | NumberSequence / ColorSequence |
| `color3uint8` / `content` | 3 B / 1+ B | aliases of `color3` / `string` |

### Enums

`t.enum(Enum.X)` serializes any `EnumItem` of that enum as a varint of its
`.Value`. Every Roblox enum also gets a ready-made serializer at
`t.enums.<Name>` — `t.enums.KeyCode`, `t.enums.Material`, … (200+), so together
with the datatypes above there are **well over 100 types**.

```lua
local Input = BiPolar.define("Input", {
    key   = t.enums.KeyCode,           -- any KeyCode
    state = t.enum(Enum.UserInputState), -- equivalent, explicit
    tween = t.tweenInfo,
    anchor = t.udim2,
}, { direction = "c2s" })
```

### Keeping packets small

Bytes add up — pick the tightest type that still fits your data (all lossless
unless noted):

- The **per-message id is 1 byte** automatically when you have ≤255 packets (it
  only grows to 2 bytes beyond that) — no config needed.
- Use **`uint`/`int`** for integers whose magnitude is usually small: a value
  under 128 costs 1 byte instead of the fixed 2/4 of `u16`/`u32`.
- Use **`u8`** for 0–255 values (health, counts), **`f16`** for low-range floats
  (a 0–100 bar), **`f24`** when you need more than `f16` but not full `f32`.
- Use **`vector3half`** (6 B) for positions where sub-stud precision isn't
  critical; full `vector3` is 12 B.
- **Booleans and absent optionals are nearly free** — they live in the struct's
  packed bitmask.

The dominant cost is almost always full-precision floats (a `vector3` is 12 B),
so that's where downscaling helps most. Floats can't be shrunk losslessly, so
the library never silently reduces precision — you choose the type.

## Profiler

`BiPolar.profiler` measures every packet the local peer sends/receives:

```lua
local snap = BiPolar.profiler.snapshot()  -- cumulative totals
local rates = BiPolar.profiler.rates()    -- bytes/sec & count/sec per packet
BiPolar.profiler.onInterval(function(rates) ... end) -- live, every second

-- Per-message log (captured only while logging is on)
BiPolar.profiler.setLogging(true)
for _, entry in BiPolar.profiler.getLog() do
    -- entry.name, entry.dir, entry.kind, entry.bytes, entry.value, entry.raw
end
```

## Debug dashboard

Press **F3** on the client for the dashboard — three **draggable, resizable**
panels (grab the bottom-right grip):

- **CLIENT** — FPS/frame ms, ping, net recv/send, physics, Lua heap, total
  memory, instances, uptime, and your hottest **script scopes**.
- **SERVER** — the same server-side metrics, **streamed over the network** while
  the panel is open (so you can watch the server from a client).
- **NET** — a MicroProfiler-style packet **timeline** (one bar per frame; frames
  >2x the rolling average turn **red** so spikes pop), **P / pause** to freeze
  and **click a bar to scrub** to that frame, a bandwidth-share bar, a
  **scrollable heaviest-first packet list** (100+), and a **decoded args + raw
  buffer hex** inspector.

### Script timing ("hot scopes")

Instrument your own code so the dashboard shows what's heavy:

```lua
local BiPolar = require(ReplicatedStorage.Shared.BiPolar)

local stop = BiPolar.debug.scope("Pathfinding")
-- ...work...
stop()

-- or:
BiPolar.debug.measure("Pathfinding", computePath, start, goal)
```

`BiPolar.debug` also exposes `localSnapshot()`, `serverSnapshot()`, and the raw
`BiPolar.profiler` data API (`snapshot()`, `rates()`, `frames()`, `getLog()`).

## Flood protection

Adaptive by default — **no fixed numbers to hand-tune and false-trip on.** The
guard learns each player's own busiest legitimate second (`peak`) and only acts on
traffic past `factor ×` that, never below a generous floor and never above an
absolute hard ceiling. New players are only ceiling-checked during a short warmup
while it learns; strikes **decay** on clean seconds (so isolated spikes fade
instead of accumulating); and kicking is **off** by default. The net effect: a
real player is essentially never dropped or kicked, only genuine floods are.

```lua
-- These are the adaptive defaults (server). You usually don't need to set any.
BiPolar.setSecurity({
    auto = true,                 -- adaptive mode (default)
    factor = 8,                  -- allow up to 8× a player's established peak
    warmupSeconds = 5,           -- learn-only grace right after joining
    floorPacketsPerSecond = 1000, floorBytesPerSecond = 1048576, -- generous minimums
    hardPacketsPerSecond = 4000, hardBytesPerSecond = 4194304,   -- absolute ceiling
    maxBufferBytes = 65536,      -- a single buffer larger than this is always dropped
    maxStrikes = 8,              -- sustained over-limit seconds before a kick
    kick = false,                -- drop-only by default
})
```

Prefer the old behaviour? Set `auto = false` and the original fixed caps apply:

```lua
BiPolar.setSecurity({ auto = false, maxPacketsPerSecond = 240, maxBytesPerSecond = 131072 })
```

Non-buffer payloads and unknown ids are always rejected.

## Server-side lock (per-packet rate limit)

The global flood guard above watches a player's *whole* traffic. The per-packet
lock is finer: it caps how often each player can land **one specific packet** per
second, so an individual action can't be spammed even when total traffic is low.
Set `rateLimit = N` on the packet and the kernel drops the excess **server-side,
before any listener or invoke handler runs** — no debounce bookkeeping in your
game code.

```lua
-- An attack that may fire at most 20x/sec per player, a respawn at most 2x/sec.
local Attack  = BiPolar.define("Attack",  { dir = t.vector3half }, {
    direction = Direction.ClientToServer, unreliable = true, rateLimit = 20 })
local Respawn = BiPolar.define("Respawn", t.boolean, {
    direction = Direction.ClientToServer, rateLimit = 2 })

-- Works on function packets too (caps invokes per second per player):
local Buy = BiPolar.defineFunction("Buy", t.u16, { ok = t.boolean }, {
    direction = Direction.ClientToServer, rateLimit = 5 })
```

It's a per `(player, packet)` counter reset each second, enforced only on the
server (the server is trusted), and freed automatically when a player leaves.
`nil` / omitted means unlimited.

## How the bitmask works

A `struct` lays bytes out as:

```
[ mask bytes ][ present optional values ][ plain field values ]
```

The mask holds one bit per boolean (its value) and one bit per optional
(presence). Fields start name-sorted so both sides agree, then the per-runtime
seed shuffles the order identically on client and server.

## Project layout

```
src/shared/BiPolar/
  init.luau       -- public API (BiPolar:Fire / :Invoke / hooks / define)
  Kernel.luau     -- remotes, batching, randomized protocol, hooks, flood guard
  Types.luau      -- serializers + bitmask struct
  BitBuffer.luau  -- growable buffer Writer/Reader
  Profiler.luau    -- packet stats / rates / per-frame history
  Diagnostics.luau -- client/server metrics + script-timing scopes
  DebugUI.luau     -- F3 debug dashboard (client)
src/shared/Packets.luau   -- your shared packet definitions
src/client, src/server    -- demo usage
tests/core.test.luau      -- Lune test for the serializer core
web/index.html            -- interactive bandwidth simulator (open in a browser)
```

## Interactive web example

[`web/index.html`](web/index.html) is a self-contained page (no build step, no
dependencies) that encodes a movement packet with the **same byte model the
library uses** and graphs its bandwidth against a naive RemoteEvent table — turn
the send rate, player count, position precision and fields and watch sent / recv
move. It's the visual companion to the F3 profiler.

```bash
python -m http.server 8777 --directory web   # then open http://localhost:8777
```

## Building & dev tools

```bash
rojo build -o BipolarNetworking.rbxlx   # build a place
rojo serve                              # live-sync into Studio

selene src/                             # lint
lune run tests/core.test.luau           # run serializer tests
```
