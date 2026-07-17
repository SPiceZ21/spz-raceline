-- client/main.lua
-- Capture: distance-gated samples of the player's position + pedal state while
-- driving. Display: a flat ribbon painted on the road, coloured by what the
-- pedals were doing at that spot (green throttle, red brake, faint white coast).
--
-- Two buffers:
--   • Display buffer (ring) — what gets drawn. Fed by manual /raceline rec, or
--     loaded with a stored best-lap line (TT ghost / proximity auto-load).
--   • Lap capture (plain array) — silently records the current time-trial lap.
--     If the server says the lap improved, this is what gets stored.

local Points     = {}     -- display ring buffer of { x, y, z, s, brk }
local Head       = 1      -- next write slot (the oldest entry once full)
local Count      = 0
local Recording  = false  -- manual recording (/raceline rec)
local Visible    = false
local ForceBreak = true   -- next manual sample starts a new segment run

local Quads = {}          -- precomputed visible ribbon segments

-- Time-trial integration
local Cap         = {}    -- current-lap capture
local LastLap     = {}    -- frozen copy of the last completed lap
local Capturing   = false
local TTTrack     = nil   -- track name while in a time trial
local AutoShown   = false -- display buffer holds an auto-loaded line
local LoadedTrack = nil   -- which track's line is in the display buffer
local PendingLoad = nil   -- track whose line we've requested from the server
local Anchors     = {}    -- { { track, best, x, y, z }, ... }
local LineCache   = {}    -- track -> { points = ordered array, best = ms }

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
    ForceBreak = true
end

-- ── Line (de)serialisation ────────────────────────────────────────────────────
-- Wire/DB format: flat array of x, y, z, state quadruples. brk is folded into
-- the state as +4 (states are 0..2, so 4..6 = same state + break marker).

local function FlattenLine(pts)
    local flat = {}
    for i = 1, #pts do
        local p = pts[i]
        local n = (i - 1) * 4
        flat[n + 1] = math.floor(p.x * 100 + 0.5) / 100
        flat[n + 2] = math.floor(p.y * 100 + 0.5) / 100
        flat[n + 3] = math.floor(p.z * 100 + 0.5) / 100
        flat[n + 4] = p.s + (p.brk and 4 or 0)
    end
    return flat
end

local function ExpandLine(flat)
    local pts = {}
    for i = 1, #flat, 4 do
        local s = flat[i + 3] or 0
        pts[#pts + 1] = {
            x = flat[i], y = flat[i + 1], z = flat[i + 2],
            s = s % 4, brk = s >= 4,
        }
    end
    return pts
end

-- Replace the display buffer with an ordered point array.
local function FillDisplay(pts)
    ClearLine()
    for i = 1, math.min(#pts, Config.MaxPoints) do
        local p = pts[i]
        PushPoint(p.x, p.y, p.z, p.s or 0, (i == 1) or p.brk or false)
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
        local active = Recording or Capturing
        Wait(active and 50 or 400)

        if active then
            local ped = PlayerPedId()
            local veh = GetVehiclePedIsIn(ped, false)

            if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped then
                local pos = GetEntityCoords(veh)
                local dx = pos.x - (lastX or pos.x)
                local dy = pos.y - (lastY or pos.y)

                if lastX == nil or (dx * dx + dy * dy) >= Config.SampleDistance ^ 2 then
                    -- Teleport / respawn: don't draw a line across the map
                    local jump = lastX ~= nil and (dx * dx + dy * dy) > Config.BreakDistance ^ 2
                    local z = GroundedZ(pos)
                    local s = PedalState()

                    if Recording then
                        PushPoint(pos.x, pos.y, z, s, ForceBreak or jump)
                        ForceBreak = false
                    end
                    if Capturing and #Cap < Config.MaxPoints then
                        Cap[#Cap + 1] = { x = pos.x, y = pos.y, z = z, s = s, brk = (#Cap == 0) or jump }
                    end
                    lastX, lastY = pos.x, pos.y
                end
            else
                ForceBreak = true   -- left the driver seat: next run starts fresh
            end
        else
            ForceBreak = true
            lastX, lastY = nil, nil
        end
    end
end)

-- ── Time-trial hooks (events already broadcast by spz-races) ─────────────────

RegisterNetEvent("SPZ:tt:Begin", function(data)
    TTTrack = data and data.track and data.track.name or nil
    Cap, Capturing = {}, false
    if not TTTrack then return end

    -- Show the stored best line as a ghost while practising
    if LineCache[TTTrack] then
        LoadDisplay(TTTrack)
    else
        PendingLoad = TTTrack
        TriggerServerEvent("spz-raceline:getLine", TTTrack)
    end
end)

RegisterNetEvent("SPZ:tt:LapStarted", function()
    if not TTTrack then return end
    Cap, Capturing = {}, true
end)

-- Freeze the finished lap into its own buffer. The server's requestCapture
-- arrives after a DB round-trip — on circuits the player can cross CP1 and
-- start the next lap (which resets Cap) before that, so reading Cap directly
-- would lose the line.
RegisterNetEvent("SPZ:tt:LapComplete", function()
    Capturing = false
    LastLap = Cap
end)

RegisterNetEvent("SPZ:tt:Restarted", function()
    Cap, LastLap, Capturing = {}, {}, false
end)

RegisterNetEvent("SPZ:tt:End", function()
    TTTrack, Cap, LastLap, Capturing = nil, {}, {}, false
    ClearAutoDisplay()   -- proximity scan will re-show it if still near
end)

-- ── Server round-trips ────────────────────────────────────────────────────────

RegisterNetEvent("spz-raceline:requestCapture", function(track)
    if #LastLap > 1 then
        TriggerServerEvent("spz-raceline:submitCapture", track, FlattenLine(LastLap))
    end
end)

RegisterNetEvent("spz-raceline:saved", function(track, bestMs, anchor)
    -- The freshly driven lap is the new best line — cache it and, if we're
    -- still on that track, swap the ghost immediately. Cap is NOT touched:
    -- the next lap may already be capturing into it.
    LineCache[track] = { points = LastLap, best = bestMs }
    LastLap = {}

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

RegisterNetEvent("spz-raceline:line", function(track, flat, bestMs)
    if type(flat) ~= "table" then return end
    LineCache[track] = { points = ExpandLine(flat), best = bestMs }

    if TTTrack == track or PendingLoad == track then
        PendingLoad = nil
        if not Recording then LoadDisplay(track) end
    end
end)

-- ── Proximity auto-load ───────────────────────────────────────────────────────
-- When the player comes near where one of their stored lines starts, show it;
-- hide it again when they leave. Manual recording and time trials take priority.

CreateThread(function()
    Wait(5000)   -- let identity load the profile first
    TriggerServerEvent("spz-raceline:getAnchors")

    while true do
        Wait(Config.AutoScanMs)

        if not TTTrack and not Recording and #Anchors > 0 then
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

local function SetRecording(on)
    Recording = on
    if on then
        -- Manual recording owns the display buffer: evict any auto-loaded line
        if AutoShown then
            ClearLine()
            AutoShown, LoadedTrack = false, nil
        end
        if not Visible then Visible = true end
    end
    Notify(on and "Raceline: recording ~g~ON~s~" or "Raceline: recording ~r~OFF~s~")
end

RegisterCommand("raceline", function(_, args)
    local sub = (args[1] or ""):lower()
    if sub == "rec" or sub == "record" then
        SetRecording(not Recording)
    elseif sub == "show" then
        SetVisible(true)
    elseif sub == "hide" then
        SetVisible(false)
    elseif sub == "clear" then
        ClearLine()
        AutoShown, LoadedTrack = false, nil
        Notify("Raceline: ~y~cleared~s~")
    else
        Notify("Usage: /raceline rec | show | hide | clear")
    end
end, false)

-- Unbound by default — bindable in Settings → Key Bindings
RegisterCommand("racelinetoggle", function()
    SetVisible(not Visible)
end, false)
RegisterKeyMapping("racelinetoggle", "Raceline: Toggle Display", "keyboard", "")

-- ── Exports ───────────────────────────────────────────────────────────────────

exports("StartRecording", function() SetRecording(true) end)
exports("StopRecording",  function() SetRecording(false) end)
exports("IsRecording",    function() return Recording end)
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
