# spz-raceline

Standalone racing-line trainer. Records your driving line and paints it on the
road as a flat ribbon: **green** where you were on throttle, **red** where you
were braking, faint white where you coasted. Drive a lap, look down, learn
where your inputs actually happen.

No framework, no server side, no NUI — pure client draw natives.

## Usage

| Command | Effect |
|---|---|
| `/raceline rec` | Toggle recording (auto-shows the line) |
| `/raceline show` / `hide` | Toggle display |
| `/raceline clear` | Wipe the recorded line |

`Raceline: Toggle Display` is also bindable in Settings → Key Bindings.

## How it works

- Samples position + pedal state every `Config.SampleDistance` metres driven
  (ring buffer, `Config.MaxPoints` cap — oldest points fall off).
- Brake input wins over throttle, so trail-braking reads as braking.
- Teleports/respawns split the line instead of drawing across the map.
- Rendering is two-stage: a slow thread rebuilds the set of nearby segments
  every `Config.RebuildMs`, the per-frame thread only paints that set
  (`Config.MaxDrawSegments` cap).

## Exports (client)

`StartRecording()`, `StopRecording()`, `IsRecording()`, `SetLineVisible(bool)`,
`IsLineVisible()`, `ClearLine()`, `GetLine()` → ordered point array,
`LoadLine(points)` → replace the buffer (for ghost lines / race integration).

Point format: `{ x, y, z, s, brk }` where `s` = 0 coast / 1 throttle / 2 brake.

## Dependencies

None.
