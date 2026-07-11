# Changelog

All notable changes to BiPolar are documented here. This project adheres to
[Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-07-12

First public release.

### Added

- **Batched kernel transport** — one reliable RemoteEvent (plus one opt-in
  unreliable) carries the whole game; everything is routed by numeric id and
  batched once per frame on `Heartbeat`.
- **Bitmask packing** — booleans and optional-presence flags share a packed mask
  at the front of each struct (8 booleans = 1 byte, absent optional = 0 payload
  bytes).
- **Per-runtime obfuscated protocol** — random 16-bit packet ids, shuffled struct
  field order, and a byte-keystream buffer scramble, rebuilt from a per-server
  seed that the client mirrors at runtime.
- **Request/response without a RemoteFunction** — `defineFunction` + `:Invoke` /
  `:OnInvoke`, emulated over the batched reliable event; `:InvokeExpect` locks the
  answer and kicks on a tampered/timed-out response.
- **Adaptive flood protection** — learns each player's own busiest second and only
  acts on extreme outliers; strikes decay on clean seconds, kicking off by default.
- **Server-side per-packet lock** — `rateLimit = N` caps how often each player can
  land a specific packet per second, dropped before any handler runs.
- **Middleware hooks** — inbound/outbound, global or per-packet, to transform or
  veto any payload.
- **100+ wire types** — fixed ints, `uint`/`int` varints, `f16`/`f24`/`f32`/`f64`
  floats, `vector3half`, the full set of UI/engine datatypes, and ready-made
  serializers for every Roblox enum.
- **Native codegen** — hot serializers (`BitBuffer`, `Types`) run
  `--!native --!optimize 2`.
- **Built-in profiler + F3 debug dashboard** — draggable/resizable
  CLIENT / SERVER / NET panels, a MicroProfiler-style packet timeline you can pause
  and scrub, and a decoded-args + raw-buffer-hex inspector.
- **Prebuilt `BiPolar.rbxm`** model for drag-and-drop use without Rojo, alongside
  the Rojo source tree.

[1.0.0]: https://github.com/Awakenchan/BiPolar/releases/tag/v1.0.0
