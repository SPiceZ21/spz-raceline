# spz-raceline

> Records your best line per track and paints it on the road.

![version](https://img.shields.io/badge/version-1.7.0-ff6200) ![SPiceZ-Core](https://img.shields.io/badge/SPiceZ--Core-beta-18181b)

## Overview

Every race and time-trial lap is recorded; your best lap's line is stored per track and drawn on the road as a ribbon (green throttle, red braking). In time trials it also replays as a ghost car.

## Features

- Automatic lap capture
- Best-line ribbon on the road
- Time-trial ghost car
- Track record crowns on nametags
- Track outlines for the vote screen

## Requirements

| Resource | Type |
|---|---|
| `oxmysql` | third-party |
| `ox_lib` | third-party |

## Installation

Included in the [txAdmin recipe](https://github.com/SPiceZ21/spz-txrecipe). Manual install:

1. Download `spz-raceline` from GitHub (latest release, or the repository) into your `resources` folder.
2. Add to `server.cfg`, after its requirements:

```cfg
ensure spz-raceline
```

## Configuration

- `config.lua`

See the file for every option.

## Commands

| Command | Who | Description |
|---|---|---|
| `/raceline` | player | Raceline options |
| `/racelinepanel` | player | Open the raceline panel (`F3`) |
| `/racelinetoggle` | player | Show / hide the line |
| `/ghostinfo` | dev | Ghost replay diagnostics |
| `/rlstatus` | dev | Recording / storage status |

## Key binds

Rebindable in **Settings → Key Bindings → FiveM**.

| Action | Default |
|---|---|
| Raceline: Toggle Display | _unbound_ |
| Raceline: Control panel | `F3` |

## Exports

| Export | Side |
|---|---|
| `GetLineByPlayerId` | server |
| `GetTrackOutline` | server |

```lua
exports["spz-raceline"]:GetLineByPlayerId(...)
```

---

Part of **SPiceZ-Core** — [documentation](https://github.com/SPiceZ21/Docs) · [all modules](https://github.com/SPiceZ21/Docs/blob/main/modules/README.md)
