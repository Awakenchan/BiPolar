# BiPolar benchmarks

Real, runnable benchmarks for the wire size and serialization speed of the
library — plus an in-Studio harness for exact end-to-end bytes. Payload shapes
mirror the [QuickNet benchmark set](https://github.com/breadboardengineer1234/QuickNet/tree/main/benchmarks)
(booleans / entities / strings / numbers / dictionary) so the numbers are
comparable in spirit.

| File | Where it runs | Measures |
| --- | --- | --- |
| `serialize.bench.luau` | **Lune (offline)** | wire bytes + encode/decode throughput |
| `Definitions.luau` | Roblox (shared) | the payload shapes + BiPolar packets |
| `BenchmarksServer.luau` | Roblox · ServerScriptService | serialize throughput in the **native** VM |
| `BenchmarksClient.luau` | Roblox · StarterPlayerScripts | **exact** outbound bytes per send |

## 1. Offline serialization benchmark (run it now)

```bash
lune run benchmarks/serialize.bench.luau
```

Loads the real `BitBuffer` + `Types` modules outside Roblox and, per payload,
reports the BiPolar wire size, the same data as JSON text, and encode/decode
time. Sample run (numbers vary by machine; **bytes are exact and identical
everywhere**, throughput is a conservative interpreter floor):

```
payload                            bytes    json     vs      encode      decode
                                                   json       ns/op       ns/op
------------------------------------------------------------------------------------
Booleans x32 (struct/bitmask)          4     367  91.8x        2776        6544
Entities x100 (6x u8 struct)         601    6253  10.4x       72748      113390
Strings x50 (~16 chars)              851     952   1.1x       13648       16444
Numbers x500 (u8 array)              502    1784   3.6x       51622       48951
Dictionary x50 (string->u8)          451     643   1.4x       18654       21765
```

Reading it:

- **Booleans** are where bitmask packing wins hardest — 32 booleans are **4
  bytes** (one bit each) versus ~367 as a JSON array, **~92× smaller**.
- **Entities** (structs of `u8`) pack to 6 bytes each with no per-field overhead,
  **~10× smaller** than the tagged-table equivalent.
- **Strings** can't be shrunk losslessly, so the win there is just the length
  prefix vs quotes/commas — BiPolar never pretends otherwise.

## 2. In-Studio benchmarks

These can't run offline (they touch `game`), so they're placed by hand. They are
**not** in the default Rojo tree on purpose — drop them in:

| File | Parent |
| --- | --- |
| `Definitions.luau` | `ReplicatedStorage` |
| `BenchmarksServer.luau` | `ServerScriptService` |
| `BenchmarksClient.luau` | `StarterPlayer/StarterPlayerScripts` |

They require the shipped library at `ReplicatedStorage.Shared.BiPolar`, so run
them in a place that already has it (e.g. a `rojo build` of this repo). The
`Bench_*` packet names are isolated, so they don't collide with the demo.

**`BenchmarksServer`** runs the same serialization benchmark **inside the Roblox
VM**, where `BitBuffer` and `Types` execute under `--!native --!optimize 2` — so
those throughput numbers are the live ones (the Lune table above is the floor).
It prints on server start, and also stands up the receive counters.

**`BenchmarksClient`** reads each payload's **exact** outbound size straight from
the built-in profiler (`BiPolar.profiler`) — the real bytes on the wire,
including the 1-byte packet id — and projects send / recv KB/s at a tick rate and
player count you set at the top of the file.

## Notes on fairness

- The JSON column is a **reproducible stand-in** for an unoptimized table sent
  over a raw RemoteEvent, not a measurement of Roblox's internal table
  serialization (which isn't byte-introspectable at runtime). It's there for a
  familiar reference point; the BiPolar bytes are exact.
- Throughput is reported as the **best of several trials** after a warm-up, to
  cut GC and scheduling noise. It still varies run to run — treat the ratios and
  orders of magnitude as the signal, not the last digit.
