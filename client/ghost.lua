-- client/ghost.lua
-- Time-trial ghost car: replays the player's stored best-lap line as a local,
-- translucent, non-collidable vehicle. Starts in sync with each lap (CP1
-- crossing) and fades out when its lap is done; you race your own best.
--
-- Timing: v2/v3 lines carry per-point ms-since-lap-start, so the ghost brakes and
-- accelerates exactly where you did. v1 lines (recorded before timing existed)
-- get distance-proportional timing over the stored lap time — constant pace,
-- still a usable reference.
--
-- The line also carries CP split times (v3) for pace comparison at each
-- checkpoint, but the ghost itself runs a clean full-lap replay driven
-- entirely by per-point timing — no clock corrections mid-lap.
--
-- Reads the line cache from client/main.lua via the RL_GetEntry global (both
-- files share this resource's Lua environment).

local GC = Config.Ghost or { enabled = false }

local GhostOn    = GC.enabled ~= false   -- user toggle (/raceline ghost)
local TTTrack    = nil
local GhostVeh   = 0
local Route      = nil    -- { pts, times (cumulative ms), model }
local Running    = false
local RunStart   = 0      -- GetGameTimer() at lap start
local Cursor     = 1      -- current segment index (monotonic per run)
local MotCursor  = 1      -- same, for the v4 motion stream
local CurHeading = 0.0

-- ── Route preparation ─────────────────────────────────────────────────────────

local function BuildRoute(entry)
    local pts = entry.points
    if not pts or #pts < 3 then return nil end

    local times = {}
    if pts[1].t ~= nil and pts[#pts].t ~= nil and pts[#pts].t > 0 then
        -- v2/v3: true captured timing
        for i = 1, #pts do times[i] = pts[i].t or 0 end
    else
        -- v1 fallback: distribute the stored lap time over cumulative distance
        local total, cum = 0.0, { 0.0 }
        for i = 2, #pts do
            local dx, dy = pts[i].x - pts[i-1].x, pts[i].y - pts[i-1].y
            total = total + math.sqrt(dx * dx + dy * dy)
            cum[i] = total
        end
        local lapMs = entry.best or 60000
        for i = 1, #pts do
            times[i] = total > 0 and math.floor(cum[i] / total * lapMs) or 0
        end
    end

    return {
        pts    = pts,
        times  = times,
        model  = (entry.model and entry.model ~= 0) and entry.model or GC.fallbackModel,
        -- v4 fixed-rate motion stream (position + full orientation + steer/rpm).
        -- When present the replay uses it instead of the flat, heading-only line.
        motion = (Config.MotionCapture ~= false and type(entry.motion) == "table"
                  and #entry.motion >= 4) and entry.motion or nil,
    }
end

-- ── Ghost entity ──────────────────────────────────────────────────────────────

local GhostBlip = 0

local function RemoveGhostBlip()
    if GhostBlip ~= 0 and DoesBlipExist(GhostBlip) then RemoveBlip(GhostBlip) end
    GhostBlip = 0
end

local function DeleteGhost()
    Running = false
    RemoveGhostBlip()
    if GhostVeh ~= 0 and DoesEntityExist(GhostVeh) then
        DeleteEntity(GhostVeh)
    end
    GhostVeh = 0
end

-- Map blip attached to the ghost car (purple, matches its "reference" role).
local function AddGhostBlip()
    if GhostVeh == 0 or not DoesEntityExist(GhostVeh) then return end
    RemoveGhostBlip()
    GhostBlip = AddBlipForEntity(GhostVeh)
    SetBlipSprite(GhostBlip, 1)
    SetBlipColour(GhostBlip, 27)      -- purple/violet
    SetBlipScale(GhostBlip, 0.8)
    SetBlipAsShortRange(GhostBlip, false)
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentSubstringPlayerName("Ghost")
    EndTextCommandSetBlipName(GhostBlip)
end

local function SpawnGhost(model, at, heading)
    if not IsModelInCdimage(model) then model = GC.fallbackModel end
    RequestModel(model)
    local deadline = GetGameTimer() + 5000
    while not HasModelLoaded(model) and GetGameTimer() < deadline do Wait(25) end
    if not HasModelLoaded(model) then return false end

    -- Local-only (not networked): nobody else sees another player's ghost
    GhostVeh = CreateVehicle(model, at.x, at.y, at.z + (GC.zLift or 0.45), heading, false, false)
    SetModelAsNoLongerNeeded(model)
    if GhostVeh == 0 then return false end

    SetEntityAlpha(GhostVeh, GC.alpha or 150, false)
    SetEntityCollision(GhostVeh, false, false)
    SetEntityInvincible(GhostVeh, true)
    FreezeEntityPosition(GhostVeh, true)   -- we drive it by hand every frame
    SetVehicleEngineOn(GhostVeh, true, true, false)
    SetVehicleLights(GhostVeh, 2)
    return true
end

-- ── Replay ────────────────────────────────────────────────────────────────────

-- ── Ghost modes ───────────────────────────────────────────────────────────────
--   "pb"     — your own best lap (default)
--   "record" — the track record holder's actual lap (the server ghost)
--   "pace"   — your PB line replayed at your session-average pace: beatable
--              every lap, so there is always a target you can realistically catch
GhostMode = GhostMode or "pb"

local MODE_TINT = {
    pb     = nil,                  -- keep the car's own colours
    record = { 255, 215, 0 },      -- gold: the one to beat
    pace   = { 0, 170, 255 },      -- blue: the trainer
}

local function ResolveEntry()
    if GhostMode == "record" then
        local rec = RL_GetRecordEntry and RL_GetRecordEntry(TTTrack)
        return rec   -- nil on first call: fetch is async, hook retries below
    end

    local entry = RL_GetEntry and RL_GetEntry(TTTrack)
    if not entry then return nil end

    if GhostMode == "pace" then
        -- Rescale the PB timing to the session-average lap. Falls back to PB
        -- pace until at least one lap has been banked this session.
        local avg = RL_GetSessionAverage and RL_GetSessionAverage(TTTrack)
        if avg and entry.best and entry.best > 0 and avg > entry.best then
            local f, pts = avg / entry.best, {}
            for i, p in ipairs(entry.points) do
                pts[i] = { x = p.x, y = p.y, z = p.z, s = p.s, brk = p.brk,
                           t = p.t and math.floor(p.t * f) or nil }
            end

            -- Stretch the motion stream by the same factor, so the pace ghost
            -- keeps the real attitude/steering instead of dropping to the flat
            -- legacy path. Same line, same car body — just driven slower.
            local mot = nil
            if type(entry.motion) == "table" then
                mot = {}
                for i, s in ipairs(entry.motion) do
                    mot[i] = { t = math.floor((s.t or 0) * f),
                               x = s.x, y = s.y, z = s.z,
                               qx = s.qx, qy = s.qy, qz = s.qz, qw = s.qw,
                               steer = s.steer, rpm = s.rpm, flags = s.flags }
                end
            end

            return { points = pts, best = avg, model = entry.model, motion = mot }
        end
    end

    return entry
end

local function StartRun()
    if not GhostOn or not TTTrack then return end
    local entry = ResolveEntry()
    if not entry then return end

    Route = BuildRoute(entry)
    if not Route then return end

    local p1, p2 = Route.pts[1], Route.pts[2]
    local heading = math.deg(math.atan(-(p2.x - p1.x), p2.y - p1.y)) % 360

    if GhostVeh == 0 or not DoesEntityExist(GhostVeh) then
        if not SpawnGhost(Route.model, p1, heading) then return end
    else
        SetEntityCoordsNoOffset(GhostVeh, p1.x, p1.y, p1.z + (GC.zLift or 0.45), false, false, false)
        SetEntityHeading(GhostVeh, heading)
    end

    SetEntityVisible(GhostVeh, true, false)

    -- Mode tint so you always know WHICH ghost you're racing
    local tint = MODE_TINT[GhostMode]
    if tint then
        SetVehicleCustomPrimaryColour(GhostVeh, tint[1], tint[2], tint[3])
        SetVehicleCustomSecondaryColour(GhostVeh, tint[1], tint[2], tint[3])
    end

    CurHeading = heading
    Cursor     = 1
    MotCursor  = 1
    RunStart   = GetGameTimer()
    Running    = true

    -- v4: start from the recorded pose so the first frame isn't a flat snap.
    if Route.motion then
        local m0 = Route.motion[1]
        SetEntityCoordsNoOffset(GhostVeh, m0.x, m0.y, m0.z, false, false, false)
        SetEntityQuaternion(GhostVeh, m0.qx, m0.qy, m0.qz, m0.qw)
    end

    AddGhostBlip()
end

-- Record line arrived from the server mid-session: if we're waiting on it and
-- a lap is underway, nothing to do — the next LapStarted picks it up.
function RL_OnRecordEntry(track)
    -- no-op hook; kept so main.lua can notify without a hard dependency
end

local function LerpAngle(a, b, f)
    local diff = (b - a + 180.0) % 360.0 - 180.0
    return (a + diff * math.min(f, 1.0)) % 360.0
end

-- ── Motion replay (v4) ────────────────────────────────────────────────────────
-- Replays the fixed-rate stream: exact position, FULL orientation (so the car
-- banks, dives under braking and keeps its attitude over jumps), plus steering
-- and rpm. This is the "scene director" path — what you actually did, played back.

local function clampv(v) return math.max(-150.0, math.min(150.0, v)) end

--- Returns false once the recorded lap has run out.
local function ReplayMotion(m, elapsed)
    local n = #m

    while MotCursor < n - 1 and m[MotCursor + 1].t <= elapsed do
        MotCursor = MotCursor + 1
    end

    if elapsed >= m[n].t then return false end

    local a, b = m[MotCursor], m[MotCursor + 1]
    local span = (b.t or 0) - (a.t or 0)
    local f    = span > 0 and (elapsed - a.t) / span or 0.0

    -- Position: raw recorded Z — no ground snap, so airtime survives.
    local x = a.x + (b.x - a.x) * f
    local y = a.y + (b.y - a.y) * f
    local z = a.z + (b.z - a.z) * f

    -- Orientation: shortest-arc slerp. THE fidelity win over heading-only.
    local qx, qy, qz, qw = RL_QuatSlerp(a.qx, a.qy, a.qz, a.qw,
                                        b.qx, b.qy, b.qz, b.qw, f)

    -- Velocity keeps wheel rotation, engine audio and doppler alive while the
    -- explicit transform below pins the exact recorded path.
    local inv = span > 0 and (1000.0 / span) or 0.0
    FreezeEntityPosition(GhostVeh, false)
    SetEntityVelocity(GhostVeh,
        clampv((b.x - a.x) * inv), clampv((b.y - a.y) * inv), clampv((b.z - a.z) * inv))

    SetEntityCoordsNoOffset(GhostVeh, x, y, z, false, false, false)
    SetEntityQuaternion(GhostVeh, qx, qy, qz, qw)

    -- Cosmetic channel: front wheels actually turn, engine note matches.
    SetVehicleSteeringAngle(GhostVeh, a.steer or 0.0)
    SetVehicleCurrentRpm(GhostVeh, a.rpm or 0.0)

    local flags = a.flags or 0
    SetVehicleBrakeLights(GhostVeh, flags % 2 == 1)

    DisableCamCollisionForObject(GhostVeh)
    return true
end

CreateThread(function()
    while true do
        if Running and GhostVeh ~= 0 and DoesEntityExist(GhostVeh) then
            local elapsed = GetGameTimer() - RunStart

            -- v4 motion stream when the lap has one; otherwise the legacy line.
            if Route.motion then
                if not ReplayMotion(Route.motion, elapsed) then
                    SetEntityVisible(GhostVeh, false, false)
                    FreezeEntityPosition(GhostVeh, true)
                    SetEntityVelocity(GhostVeh, 0.0, 0.0, 0.0)
                    RemoveGhostBlip()
                    Running = false
                end
                Wait(0)
                goto continue
            end

            local pts, times = Route.pts, Route.times
            local n = #pts

            -- advance the cursor (monotonic; never scans the whole array)
            while Cursor < n - 1 and times[Cursor + 1] <= elapsed do
                Cursor = Cursor + 1
            end

            if elapsed >= times[n] then
                -- Ghost lap done: hide and wait for the player's next lap
                SetEntityVisible(GhostVeh, false, false)
                FreezeEntityPosition(GhostVeh, true)
                SetEntityVelocity(GhostVeh, 0.0, 0.0, 0.0)
                RemoveGhostBlip()
                Running = false
            else
                local a, b   = pts[Cursor], pts[Cursor + 1]
                local ta, tb = times[Cursor], times[Cursor + 1]
                local span   = tb - ta
                local f      = span > 0 and (elapsed - ta) / span or 0.0

                local x = a.x + (b.x - a.x) * f
                local y = a.y + (b.y - a.y) * f
                local z = a.z + (b.z - a.z) * f + (GC.zLift or 0.45)

                local target = math.deg(math.atan(-(b.x - a.x), b.y - a.y)) % 360
                CurHeading = LerpAngle(CurHeading, target, (GC.headingLerp or 10.0) * GetFrameTime())

                -- Feed the ghost its real segment velocity so the WHEELS SPIN.
                -- Frozen + teleported cars have zero road speed → static wheels.
                -- We unfreeze, apply velocity (drives wheel rotation), then pin the
                -- exact path position on top so it can't drift. Clamp per-axis so a
                -- lag spike (tiny span) can't fling a huge one-frame velocity.
                local inv = span > 0 and (1000.0 / span) or 0.0   -- ms → per-second
                local function clampv(v) return math.max(-120.0, math.min(120.0, v)) end
                FreezeEntityPosition(GhostVeh, false)
                SetEntityVelocity(GhostVeh,
                    clampv((b.x - a.x) * inv), clampv((b.y - a.y) * inv), clampv((b.z - a.z) * inv))

                SetEntityCoordsNoOffset(GhostVeh, x, y, z, false, false, false)
                SetEntityHeading(GhostVeh, CurHeading)

                -- Camera must ignore the ghost too. Entity collision is off,
                -- but the gameplay cam still sweeps against it and gets shoved
                -- when you drive through the ghost — same bug as player cars.
                DisableCamCollisionForObject(GhostVeh)

                -- brake lights where you braked
                SetVehicleBrakeLights(GhostVeh, b.s == 2)
            end
            Wait(0)
        else
            Wait(250)
        end
        ::continue::
    end
end)

-- ── Lifecycle (same TT events main.lua uses) ──────────────────────────────────

RegisterNetEvent("SPZ:tt:Begin", function(data)
    TTTrack = data and data.track and data.track.name or nil
    DeleteGhost()
end)

RegisterNetEvent("SPZ:tt:LapStarted", function()
    if not TTTrack then return end
    -- Restart the ghost in sync with the player's lap. RL_GetEntry is read
    -- fresh each lap, so a newly saved best becomes the ghost immediately.
    StartRun()
end)

RegisterNetEvent("SPZ:tt:Restarted", function()
    RemoveGhostBlip()
    if GhostVeh ~= 0 then SetEntityVisible(GhostVeh, false, false) end
    Running = false
end)

RegisterNetEvent("SPZ:tt:End", function()
    TTTrack = nil
    DeleteGhost()
end)

AddEventHandler("onResourceStop", function(res)
    if res == GetCurrentResourceName() then DeleteGhost() end
end)

-- ── Toggle (called from the /raceline command in main.lua) ───────────────────

function RL_GhostToggle()
    GhostOn = not GhostOn
    if not GhostOn then DeleteGhost() end
    return GhostOn
end

-- Cycle/set the ghost mode. Deletes the current ghost so the next lap spawns
-- the right line, model and tint.
function RL_GhostSetMode(mode)
    if mode ~= "pb" and mode ~= "record" and mode ~= "pace" then return nil end
    GhostMode = mode
    GhostOn   = true
    DeleteGhost()
    if mode == "record" and TTTrack and RL_GetRecordEntry then
        RL_GetRecordEntry(TTTrack)   -- kick off the async fetch now
    end
    return GhostMode
end
