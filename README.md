# spz-raceline

> Racing-line trainer and time-trial ghost car · `v0.4.0`

## Overview

`spz-raceline` records your driving line in races and time trials and paints your best one
on the road as a flat ribbon: **green** on throttle, **red** braking, faint white
coasting. In time trials it also replays that lap as a translucent ghost car.

## Behaviour

- **Automatic capture** — every race and time-trial lap is recorded silently. A lap is
  stored (per player, per track) only when it beats your stored best; slower laps never
  overwrite. Times are server-measured by `spz-races`; the client supplies points only.
- **Rewound laps are never stored.** `spz-races` withholds `spz-raceline:lapCompleted` for
  any lap that won clock back off a rewind. Stored lines are replayed as ghost-bots and
  used as duel targets, so a refunded lap would seed a ghost nobody can beat.
- **Closed loops** — circuit captures run through the final-checkpoint → start-line
  stretch, and any residual seam is bridged with interpolated points at display time
  (`Config.LoopCloseRange`).
- **Auto-detect** — drive within `Config.AutoLoadRange` (default 150 m) of a track where
  you have a stored line and it loads and displays itself, hiding again when you leave.
- **Record crowns** — whoever holds a track's fastest line wears a gold crown on their
  nametag, rendered by `spz-nametag` from the `spz:records` statebag. Taking a record
  broadcasts to everyone and logs to Discord; crown counts refresh live for both the new
  and the dethroned holder.
- **Ghost car** — in time trials your best lap replays as your own vehicle model, brake
  lights lighting where you braked, launched in sync with each lap start (CP1 crossing).
  Lines recorded from v0.4 carry per-point timing so the ghost accelerates and brakes
  exactly where you did; older lines replay at distance-proportional pace.

## How it works

- Samples position + pedal state every `Config.SampleDistance` metres driven. Brake input
  beats throttle, so trail-braking reads as braking.
- Two buffers: the drawn display ring buffer, and a per-lap capture frozen at the lap
  boundary and submitted only when the server confirms the lap improved.
- Two-stage rendering: a slow thread rebuilds the nearby segment set every
  `Config.RebuildMs`; the per-frame thread only paints it (`Config.MaxDrawSegments` cap).
- Storage: the `racelines` table, owned by `spz-core/migrations/006_racelines.sql`. Lines
  are a flat JSON array of `x, y, z, state` quadruples; the first point doubles as the
  proximity anchor.

## Structure

| Side | File | Purpose |
|---|---|---|
| Shared | `config.lua` | Sampling, ranges, draw caps |
| Client | `client/main.lua` | Capture, storage bridge, rendering |
| Client | `client/ghost.lua` | Ghost car replay |
| Client | `client/crown.lua` | Track-crown display |
| Server | `server/main.lua` | Line persistence and best-lap gating |
| Server | `server/crown.lua` | Track crown ownership |
| Server | `server/tax.lua` | Crown tax rules |
| Server | `server/botlines.lua` | Bot reference lines |

## Commands

| Command | Effect |
|---|---|
| `/raceline show` · `/raceline hide` | Show or hide the line |
| `/raceline ghost` | Toggle the ghost car |
| `/raceline ghost pb` | Ghost your own best lap (default) |
| `/raceline ghost record` | Ghost the track record holder — gold car, fetched server-side |
| `/raceline ghost pace` | Ghost your session average — blue car, always catchable |

`Raceline: Toggle Display` is also bindable in Settings → Key Bindings.

## Exports

| Export | Description |
|---|---|
| `SetLineVisible(bool)` · `IsLineVisible()` | Display toggle |
| `GetLine()` · `LoadLine(points)` · `ClearLine()` | Read or replace the displayed line |
| `GetLineByPlayerId(id)` | Fetch another player's stored line |
| `GetBotLines()` | Reference lines for bots |
| `GetRecordSummary()` | Track record summary |
| `PublishCrown()` | Publish track crown ownership |

Point format: `{ x, y, z, s, brk }` where `s` = 0 coast / 1 throttle / 2 brake.

## Dependencies

`oxmysql` · `ox_lib`. Soft: `spz-identity` (player id), `spz-races` (lap events).

---

Part of [SPiceZ-Core](../README.md) · GPL-3.0
