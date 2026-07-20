-- client/main.lua
-- Capture is fully automatic: every race lap and time-trial lap is silently
-- recorded (position + pedal state, distance-gated). If the server says the
-- lap beat the player's stored best for the track, the line is submitted.
-- Display: a flat ribbon on the road — green throttle, red brake, faint white
-- coast — auto-loaded when near a track you have a stored line on.
--
-- Two buffers:
--   • Display buffer (ring) — what gets drawn. Only ever holds loaded lines.
--   • Cap (plain array)     — the lap currently being driven.

local Points  = {}     -- display ring buffer of { x, y, z, s, brk }
local Head    = 1      -- next write slot (the oldest entry once full)
local Count   = 0
local Visible = false

local Quads = {}       -- precomputed visible ribbon segments

-- Automatic capture state
local Cap          = {}     -- current-lap capture
local LastLap      = {}     -- frozen copy of the last completed lap
local LastLapReady = false  -- LastLap holds a submittable line
local CapStart     = 0      -- GetGameTimer() when the current lap capture began
local CapModel     = nil    -- vehicle model hash driven this lap (for the ghost)
local LastLapModel = nil    -- model frozen alongside LastLap
local SubmitTrack  = nil    -- server asked for a line we haven't closed yet
local Capturing    = false
local TTTrack      = nil    -- track name while in a time trial
local TTType       = nil    -- "circuit" | "sprint" while in a time trial
local InRace       = false
local HadLapEvent  = false  -- race: saw at least one SPZ:lapComplete (circuit)

-- Auto-display state
local AutoShown   = false   -- display buffer holds an auto-loaded line
local LoadedTrack = nil     -- which track's line is in the display buffer
local PendingLoad = nil     -- track whose line we've requested from the server
local Anchors     = {}      -- { { track, best, x, y, z }, ... }
local LineCache   = {}      -- track -> { points = ordered array, best = ms }

local C = Config.Colours
local StateColour = { [0] = C.coast, [1] = C.accel, [2] = C.brake }

local function Notify(msg)
    BeginTextCommandThefeedPost("STRING")
    AddTextComponentSubstringPlayerName(msg)
    EndTextCommandThefeedPostTicker(false, false)
end

local function FmtMs(ms)
    return string.format("%d:%05.2f", math.floor(ms / 60000), (ms % 60000) / 1000)
end

-- ── Ring buffer ───────────────────────────────────────────────────────────────

local function PushPoint(x, y, z, s, brk)
    Points[Head] = { x = x, y = y, z = z, s = s, brk = brk }
    Head  = (Head % Config.MaxPoints) + 1
    Count = math.min(Count + 1, Config.MaxPoints)
end

-- Index of the k-th point in oldest → newest order (k = 0 .. Count-1).
local function OrderedIndex(k)
    local start = (Count == Config.MaxPoints) and Head or 1
    return ((start + k - 1) % Config.MaxPoints) + 1
end

local function ClearLine()
    Points, Head, Count = {}, 1, 0
    Quads = {}
end

-- ── Line (de)serialisation ────────────────────────────────────────────────────
-- Wire/DB format v2: { v = 2, m = modelHash, p = flat quintuples x,y,z,state,t }
-- where t = ms since lap start (drives the ghost's true pace). brk is folded
-- into state as +4 (states are 0..2, so 4..6 = same state + break marker).
-- v1 rows (plain flat quadruple array, no timing) still decode — the ghost
-- synthesises timing from distance for those.

local function FlattenLine(pts)
    local flat = {}
    for i = 1, #pts do
        local p = pts[i]
        local n = (i - 1) * 5
        flat[n + 1] = math.floor(p.x * 100 + 0.5) / 100
        flat[n + 2] = math.floor(p.y * 100 + 0.5) / 100
        flat[n + 3] = math.floor(p.z * 100 + 0.5) / 100
        flat[n + 4] = p.s + (p.brk and 4 or 0)
        flat[n + 5] = math.floor(p.t or 0)
    end
    -- LastLapModel first: FlattenLine always serialises the FROZEN lap
    return { v = 2, m = LastLapModel or CapModel or 0, p = flat }
end

local function ExpandLine(data)
    local pts = {}

    if type(data) == "table" and data.v == 2 and type(data.p) == "table" then
        local flat = data.p
        for i = 1, #flat, 5 do
            local s = flat[i + 3] or 0
            pts[#pts + 1] = {
                x = flat[i], y = flat[i + 1], z = flat[i + 2],
                s = s % 4, brk = s >= 4, t = flat[i + 4],
            }
        end
        return pts, data.m
    end

    -- v1: flat quadruples, no timing, no model
    if type(data) == "table" then
        for i = 1, #data, 4 do
            local s = data[i + 3] or 0
            pts[#pts + 1] = {
                x = data[i], y = data[i + 1], z = data[i + 2],
                s = s % 4, brk = s >= 4,
            }
        end
    end
    return pts, nil
end

-- Replace the display buffer with an ordered point array.
local function FillDisplay(pts)
    ClearLine()
    local n = math.min(#pts, Config.MaxPoints)
    for i = 1, n do
        local p = pts[i]
        PushPoint(p.x, p.y, p.z, p.s or 0, (i == 1) or p.brk or false)
    end

    -- Loop closure: a circuit lap ends where it began, but sampling and event
    -- latency leave a seam gap between the last and first point. If the ends
    -- are close, bridge them with interpolated points so the ribbon reads as
    -- one continuous loop.
    if n >= 3 then
        local first, last = pts[1], pts[n]
        local dx, dy, dz = first.x - last.x, first.y - last.y, first.z - last.z
        local d = math.sqrt(dx * dx + dy * dy)
        if d > 0.5 and d <= Config.LoopCloseRange then
            local steps = math.max(1, math.floor(d / Config.SampleDistance))
            for i = 1, steps - 1 do
                local t = i / steps
                PushPoint(last.x + dx * t, last.y + dy * t, last.z + dz * t, last.s, false)
            end
            PushPoint(first.x, first.y, first.z, first.s, false)
        end
    end
end

local function LoadDisplay(track)
    local entry = LineCache[track]
    if not entry then return false end
    FillDisplay(entry.points)
    Visible, AutoShown, LoadedTrack = true, true, track
    Notify(("Raceline: ~g~%s~s~ best line loaded (%s)"):format(track, FmtMs(entry.best or 0)))
    return true
end

local function ClearAutoDisplay()
    if not AutoShown then return end
    ClearLine()
    Visible, AutoShown, LoadedTrack = false, false, nil
end

-- ── Capture ───────────────────────────────────────────────────────────────────

local function PedalState()
    -- Brake (INPUT_VEH_BRAKE) wins over throttle: trail-braking with a
    -- feathered throttle should read as braking.
    if GetControlNormal(0, 72) > Config.BrakeDeadzone then return 2 end
    if GetControlNormal(0, 71) > Config.ThrottleDeadzone then return 1 end
    return 0
end

local function GroundedZ(pos)
    local ok, gz = GetGroundZFor_3dCoord(pos.x, pos.y, pos.z + 0.5, false)
    if ok then return gz + Config.HeightOffset end
    return pos.z - 0.3   -- roughly wheel height when collision is not loaded
end

CreateThread(function()
    local lastX, lastY
    while true do
        Wait(Capturing and 50 or 400)

        if Capturing then
            local ped = PlayerPedId()
            local veh = GetVehiclePedIsIn(ped, false)

            if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped then
                local pos = GetEntityCoords(veh)
                local dx = pos.x - (lastX or pos.x)
                local dy = pos.y - (lastY or pos.y)

                if lastX == nil or (dx * dx + dy * dy) >= Config.SampleDistance ^ 2 then
                    -- Teleport / respawn: don't draw a line across the map
                    local jump = lastX ~= nil and (dx * dx + dy * dy) > Config.BreakDistance ^ 2
                    if #Cap < Config.MaxPoints then
                        if #Cap == 0 then CapModel = GetEntityModel(veh) end
                        Cap[#Cap + 1] = {
                            x = pos.x, y = pos.y, z = GroundedZ(pos),
                            s = PedalState(), brk = (#Cap == 0) or jump,
                            t = GetGameTimer() - CapStart,   -- ghost pacing
                        }
                    end
                    lastX, lastY = pos.x, pos.y
                end
            end
        else
            lastX, lastY = nil, nil
        end
    end
end)

-- Freeze the current capture as the last completed lap.
local function FreezeLap()
    LastLap, LastLapReady = Cap, true
    LastLapModel = CapModel
    Cap = {}
    CapStart = GetGameTimer()   -- races: next lap's capture starts immediately
    -- A deferred submit (circuit TT waiting for the loop to close) fires now
    if SubmitTrack and #LastLap > 1 then
        TriggerServerEvent("spz-raceline:submitCapture", SubmitTrack, FlattenLine(LastLap))
        SubmitTrack = nil
    end
end

local function StopCapture()
    Capturing, Cap, SubmitTrack = false, {}, nil
end

-- ── Time-trial hooks (events already broadcast by spz-races) ─────────────────

RegisterNetEvent("SPZ:tt:Begin", function(data)
    TTTrack = data and data.track and data.track.name or nil
    TTType  = data and data.track and data.track.type or nil
    StopCapture()
    LastLapReady = false
    if not TTTrack then return end

    -- Show the stored best line as a ghost while practising
    if LineCache[TTTrack] then
        LoadDisplay(TTTrack)
    else
        PendingLoad = TTTrack
        TriggerServerEvent("spz-raceline:getLine", TTTrack)
    end
end)

-- CP1 crossing = the attempt has left the start line. Each TT attempt is a
-- standalone run from a standing start, so capture always begins fresh here.
-- Rolling laps: crossing the line fires LapComplete then LapStarted back to
-- back. Capture never stops — the lap is frozen off and the buffer restarts in
-- the same instant, so lap N+1's line begins exactly where lap N's ended and
-- no samples are dropped at the seam.
RegisterNetEvent("SPZ:tt:LapComplete", function()
    if not TTTrack then return end
    FreezeLap()          -- moves Cap -> LastLap and clears Cap
end)

RegisterNetEvent("SPZ:tt:LapStarted", function()
    if not TTTrack then return end
    Cap       = {}
    Capturing = true
    CapStart  = GetGameTimer()   -- lap clock starts at the line crossing
end)

RegisterNetEvent("SPZ:tt:Restarted", function()
    -- Lap aborted mid-drive. If the server already asked for the previous
    -- lap's line, send what we have — the time was legit, only the loop-close
    -- bridge is missing.
    if SubmitTrack and #Cap > 1 then FreezeLap() end
    StopCapture()
end)

RegisterNetEvent("SPZ:tt:End", function()
    if SubmitTrack and #Cap > 1 then FreezeLap() end
    StopCapture()
    TTTrack, TTType = nil, nil
    ClearAutoDisplay()   -- proximity scan will re-show it if still near
end)

-- ── Race hooks ────────────────────────────────────────────────────────────────
-- Race lap boundaries are measured at the final checkpoint and capture runs
-- continuously, so each frozen race lap naturally contains the full loop.

RegisterNetEvent("SPZ:go", function()
    InRace, HadLapEvent = true, false
    Cap, LastLapReady = {}, false
    Capturing = true
    CapStart  = GetGameTimer()
end)

RegisterNetEvent("SPZ:lapComplete", function()
    if not InRace then return end
    HadLapEvent = true
    FreezeLap()          -- Cap resets; capture continues into the next lap
end)

RegisterNetEvent("SPZ:raceFinished", function()
    if not InRace then return end
    -- Sprints never fire SPZ:lapComplete — the whole run is the lap. On
    -- circuits every lap was already frozen at its boundary; the leftover
    -- stub (final CP → finish line) must not overwrite it.
    if not HadLapEvent and #Cap > 1 then
        FreezeLap()
    end
    Capturing, Cap = false, {}
end)

-- Race over for everyone (results broadcast) or this player DNF'd/teleported
-- out — either way the race capture is done.
RegisterNetEvent("SPZ:raceEnd", function()
    InRace = false
    StopCapture()
end)

RegisterNetEvent("SPZ:tpToSafeZone", function()
    InRace = false
    StopCapture()
end)

-- ── Server round-trips ────────────────────────────────────────────────────────

RegisterNetEvent("spz-raceline:requestCapture", function(track)
    if LastLapReady and #LastLap > 1 then
        TriggerServerEvent("spz-raceline:submitCapture", track, FlattenLine(LastLap))
    else
        -- Circuit TT: the improved lap's loop hasn't closed yet (player is
        -- still driving final CP → start line). FreezeLap submits it then.
        SubmitTrack = track
    end
end)

RegisterNetEvent("spz-raceline:saved", function(track, bestMs, anchor)
    -- The freshly driven lap is the new best line — cache it and, if we're
    -- still on that track, swap the ghost immediately.
    LineCache[track] = { points = LastLap, best = bestMs, model = LastLapModel }
    LastLap, LastLapReady = {}, false

    local found = false
    for i = 1, #Anchors do
        if Anchors[i].track == track then
            Anchors[i].best = bestMs
            Anchors[i].x, Anchors[i].y, Anchors[i].z = anchor.x, anchor.y, anchor.z
            found = true
            break
        end
    end
    if not found then
        Anchors[#Anchors + 1] = { track = track, best = bestMs, x = anchor.x, y = anchor.y, z = anchor.z }
    end

    Notify(("Raceline: ~g~new best line saved~s~ — %s (%s)"):format(track, FmtMs(bestMs)))
    if TTTrack == track then LoadDisplay(track) end
end)

RegisterNetEvent("spz-raceline:anchors", function(list)
    Anchors = type(list) == "table" and list or {}
end)

RegisterNetEvent("spz-raceline:line", function(track, data, bestMs)
    if type(data) ~= "table" then return end
    local pts, model = ExpandLine(data)
    LineCache[track] = { points = pts, best = bestMs, model = model }

    if TTTrack == track or PendingLoad == track then
        PendingLoad = nil
        LoadDisplay(track)
    end
end)

-- ── Proximity auto-load ───────────────────────────────────────────────────────
-- When the player comes near where one of their stored lines starts, show it;
-- hide it again when they leave. Time trials and races pin the current line.

CreateThread(function()
    Wait(5000)   -- let identity load the profile first
    TriggerServerEvent("spz-raceline:getAnchors")

    while true do
        Wait(Config.AutoScanMs)

        if not TTTrack and not InRace and #Anchors > 0 then
            local pos = GetEntityCoords(PlayerPedId())
            local nearest, nearestDist

            for i = 1, #Anchors do
                local a = Anchors[i]
                local dx, dy = pos.x - a.x, pos.y - a.y
                local d = math.sqrt(dx * dx + dy * dy)
                if not nearestDist or d < nearestDist then
                    nearest, nearestDist = a, d
                end
            end

            if nearest and nearestDist <= Config.AutoLoadRange then
                if LoadedTrack ~= nearest.track then
                    if LineCache[nearest.track] then
                        LoadDisplay(nearest.track)
                    elseif PendingLoad ~= nearest.track then
                        PendingLoad = nearest.track
                        TriggerServerEvent("spz-raceline:getLine", nearest.track)
                    end
                end
            elseif AutoShown and (not nearest or nearestDist > Config.AutoUnloadRange) then
                ClearAutoDisplay()
            end
        end
    end
end)

-- ── Visible-set builder ───────────────────────────────────────────────────────
-- Distance-culling thousands of points every frame is wasted work; the nearby
-- set only changes as fast as the player moves. A slow thread precomputes the
-- ribbon quads, the draw thread just paints them.

CreateThread(function()
    while true do
        Wait(Config.RebuildMs)

        if Visible and Count > 1 then
            local ppos  = GetEntityCoords(PlayerPedId())
            local maxSq = Config.DrawDistance ^ 2
            local half  = Config.LineWidth * 0.5
            local out, n = {}, 0

            local prev = Points[OrderedIndex(0)]
            for k = 1, Count - 1 do
                local pt = Points[OrderedIndex(k)]
                if not pt.brk then
                    local mx = (prev.x + pt.x) * 0.5 - ppos.x
                    local my = (prev.y + pt.y) * 0.5 - ppos.y
                    if mx * mx + my * my <= maxSq then
                        local dx, dy = pt.x - prev.x, pt.y - prev.y
                        local len = math.sqrt(dx * dx + dy * dy)
                        if len > 0.01 then
                            -- Perpendicular in the road plane → ribbon corners
                            local px, py = -dy / len * half, dx / len * half
                            n = n + 1
                            out[n] = {
                                ax1 = prev.x + px, ay1 = prev.y + py, az = prev.z,
                                ax2 = prev.x - px, ay2 = prev.y - py,
                                bx1 = pt.x + px,   by1 = pt.y + py,   bz = pt.z,
                                bx2 = pt.x - px,   by2 = pt.y - py,
                                c   = StateColour[pt.s] or C.coast,
                            }
                            if n >= Config.MaxDrawSegments then break end
                        end
                    end
                end
                prev = pt
            end
            Quads = out
        elseif #Quads > 0 then
            Quads = {}
        end
    end
end)

-- ── Draw ──────────────────────────────────────────────────────────────────────

CreateThread(function()
    while true do
        if Visible and #Quads > 0 then
            for i = 1, #Quads do
                local q, c = Quads[i], Quads[i].c
                -- DrawPoly is one-sided; draw both windings so the ribbon is
                -- visible from either camera side (no alpha doubling — the
                -- opposite winding is always backface-culled).
                DrawPoly(q.ax1, q.ay1, q.az, q.ax2, q.ay2, q.az, q.bx1, q.by1, q.bz, c.r, c.g, c.b, c.a)
                DrawPoly(q.bx1, q.by1, q.bz, q.ax2, q.ay2, q.az, q.ax1, q.ay1, q.az, c.r, c.g, c.b, c.a)
                DrawPoly(q.ax2, q.ay2, q.az, q.bx2, q.by2, q.bz, q.bx1, q.by1, q.bz, c.r, c.g, c.b, c.a)
                DrawPoly(q.bx1, q.by1, q.bz, q.bx2, q.by2, q.bz, q.ax2, q.ay2, q.az, c.r, c.g, c.b, c.a)
            end
            Wait(0)
        else
            Wait(250)
        end
    end
end)

-- ── Control ───────────────────────────────────────────────────────────────────

local function SetVisible(on)
    Visible = on
    if not on then Quads = {} end
    Notify(on and "Raceline: display ~g~ON~s~" or "Raceline: display ~r~OFF~s~")
end

RegisterCommand("raceline", function(_, args)
    local sub = (args[1] or ""):lower()
    if sub == "show" then
        SetVisible(true)
    elseif sub == "hide" then
        SetVisible(false)
    elseif sub == "ghost" then
        local on = RL_GhostToggle and RL_GhostToggle()
        Notify(on and "Raceline: ghost car ~g~ON~s~" or "Raceline: ghost car ~r~OFF~s~")
    else
        Notify("Usage: /raceline show | hide | ghost")
    end
end, false)

-- Unbound by default — bindable in Settings → Key Bindings
RegisterCommand("racelinetoggle", function()
    SetVisible(not Visible)
end, false)
RegisterKeyMapping("racelinetoggle", "Raceline: Toggle Display", "keyboard", "")

-- ── Exports ───────────────────────────────────────────────────────────────────

exports("SetLineVisible", SetVisible)
exports("IsLineVisible",  function() return Visible end)
exports("ClearLine", function()
    ClearLine()
    AutoShown, LoadedTrack = false, nil
end)

-- Ordered oldest → newest copy of the current display line.
exports("GetLine", function()
    local out = {}
    for k = 0, Count - 1 do
        local p = Points[OrderedIndex(k)]
        out[k + 1] = { x = p.x, y = p.y, z = p.z, s = p.s, brk = p.brk }
    end
    return out
end)

-- Replace the display buffer with an externally captured line (same format).
exports("LoadLine", function(pts)
    if type(pts) ~= "table" then return false end
    FillDisplay(pts)
    AutoShown, LoadedTrack = false, nil
    return Count > 0
end)

-- ── Ghost accessor (same-resource global, read by client/ghost.lua) ──────────
function RL_GetEntry(track)
    return LineCache[track]
end
