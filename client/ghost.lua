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

-- Spawn/despawn fade. The ghost used to pop in at the line and vanish at the
-- flag; easing the alpha reads as a car arriving rather than an entity appearing.
local FadeDir   = 0       -- 1 fading in, -1 fading out, 0 idle
local FadeStart = 0

-- Forward-declared: StartRun calls these before their definitions appear, and a
-- `local function` defined later would not be in scope there (it would silently
-- resolve to a nil global). Kept local so the names cannot collide with the
-- other files sharing this resource's environment.
local BeginFadeIn, BeginFadeOut, TickFade

-- Live ghost telemetry, derived from the replay spline (never stored).
local GhostTel = { speed = 0.0, ms = 0.0, lon = 0.0, lat = 0.0, g = 0.0, latG = 0.0 }

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
        -- Paint / mods / wheels of the car that actually set the lap.
        spec   = (type(entry.spec) == "table") and entry.spec or nil,
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
    FadeDir = 0
    RemoveGhostBlip()
    if GhostVeh ~= 0 and DoesEntityExist(GhostVeh) then
        DeleteEntity(GhostVeh)
    end
    GhostVeh = 0
end

-- Whether the ghost gets a map blip at all. Off is a legitimate preference: the
-- blip is a spoiler on a sprint, it tells you where the reference lap is before
-- you can see it. Read here rather than at spawn so toggling it mid-run works.
local ShowBlip = true

-- Map blip attached to the ghost car (purple, matches its "reference" role).
local function AddGhostBlip()
    if not ShowBlip then return end
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

    -- The replay unfreezes the car so its wheels can turn, but with collision
    -- off there is no ground to rest on — gravity then drags it under the map
    -- between our per-frame writes. Nothing about a ghost should fall.
    SetEntityHasGravity(GhostVeh, false)

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
                               steer = s.steer, rpm = s.rpm, flags = s.flags,
                               gear = s.gear,
                               -- wheels turn slower in proportion to the pace
                               w = s.w and { s.w[1] / f, s.w[2] / f,
                                             s.w[3] / f, s.w[4] / f } or nil }
                end
            end

            return { points = pts, best = avg, model = entry.model,
                     motion = mot, spec = entry.spec }
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

    -- Rebuild the car that actually set the lap (paint, mods, wheels, livery).
    -- Applied BEFORE the mode tint so "record"/"pace" colours still win.
    -- pcall'd: a mod value the ghost's model does not support must not abort
    -- the run and leave a half-placed car.
    if Route.spec and GC.applySpec ~= false then
        pcall(RL_SpecApply, GhostVeh, Route.spec)
    end

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
    BeginFadeIn()

    -- v4: start from the recorded pose so the first frame isn't a flat snap.
    if Route.motion then
        local m0 = Route.motion[1]
        FreezeEntityPosition(GhostVeh, true)
        SetEntityCoordsNoOffset(GhostVeh, m0.x, m0.y, m0.z + (GC.motionZLift or 0.0),
            false, false, false)
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

-- Hoisted out of the replay: defining these inside it allocated a closure on
-- every frame, for every ghost.
local function lerp(u, v, f) u = u or 0.0; return u + ((v or 0.0) - u) * f end
local function hasBit(flags, bit) return math.floor(flags / bit) % 2 == 1 end

-- ── Fade ──────────────────────────────────────────────────────────────────────

BeginFadeIn = function()
    if GhostVeh == 0 then return end
    FadeDir, FadeStart = 1, GetGameTimer()
    SetEntityAlpha(GhostVeh, 0, false)
end

BeginFadeOut = function()
    if FadeDir == -1 then return end          -- already on the way out
    FadeDir, FadeStart = -1, GetGameTimer()
end

--- Advances the fade and finishes the run once a fade-out completes.
TickFade = function()
    if FadeDir == 0 or GhostVeh == 0 or not DoesEntityExist(GhostVeh) then return end

    local dur  = GC.fadeMs or 400
    local full = GC.alpha or 150
    local t    = math.min(1.0, (GetGameTimer() - FadeStart) / dur)

    if FadeDir == 1 then
        SetEntityAlpha(GhostVeh, math.floor(full * t), false)
        if t >= 1.0 then FadeDir = 0 end
    else
        SetEntityAlpha(GhostVeh, math.floor(full * (1.0 - t)), false)
        if t >= 1.0 then
            FadeDir = 0
            SetEntityVisible(GhostVeh, false, false)
            FreezeEntityPosition(GhostVeh, true)
            SetEntityVelocity(GhostVeh, 0.0, 0.0, 0.0)
            SetEntityAngularVelocity(GhostVeh, 0.0, 0.0, 0.0)
            RemoveGhostBlip()
            Running = false
        end
    end
end

-- ── Rewind ────────────────────────────────────────────────────────────────────
-- The player's lap clock rewinds with their car, so the ghost — which exists
-- only to say "here is where you were at this point in the lap" — has to rewind
-- with it. If it kept running forward it would be comparing your rewound lap
-- against a clock that never stopped, and every rewind would hand it a lead you
-- never lost.
--
-- Live scrub: subtracted per frame, so the ghost visibly reverses alongside you.
-- Landing: folded into RunStart once, and the live figure drops back to 0.

local function RewindCreditMs()
    if GetResourceState("spz-races") ~= "started" then return 0 end
    return exports["spz-races"]:GetRewindCreditMs() or 0
end

AddEventHandler("SPZ:rewind:applied", function(ms)
    ms = tonumber(ms) or 0
    if ms <= 0 or not Running then return end
    RunStart = math.min(RunStart + ms, GetGameTimer())
end)

--- Returns false once the recorded lap has run out.
--- `cosmetic` false = far away, transform only (see LOD note below).
local function ReplayMotion(m, elapsed, cosmetic)
    local n = #m

    while MotCursor < n - 1 and m[MotCursor + 1].t <= elapsed do
        MotCursor = MotCursor + 1
    end
    -- ...and back again. The cursor used to be strictly monotonic, which is
    -- correct for a lap that only ever runs forward; a rewind moves `elapsed`
    -- backward, and a cursor left ahead of it would interpolate off the end of
    -- the wrong segment.
    while MotCursor > 1 and m[MotCursor].t > elapsed do
        MotCursor = MotCursor - 1
    end

    if elapsed >= m[n].t then return false end

    -- Four control points: the spline runs between p1 and p2, shaped by the
    -- neighbours either side. Ends clamp onto themselves.
    local p1 = m[MotCursor]
    local p2 = m[MotCursor + 1]
    local p0 = m[math.max(1, MotCursor - 1)]
    local p3 = m[math.min(n, MotCursor + 2)]

    local span = (p2.t or 0) - (p1.t or 0)
    local f    = span > 0 and (elapsed - p1.t) / span or 0.0
    local dt   = span > 0 and (span / 1000.0) or 0.0

    -- Position: Catmull-Rom through the recorded points (no chorded corners),
    -- on raw recorded Z so airtime survives.
    local x = RL_CatmullRom(p0.x, p1.x, p2.x, p3.x, f)
    local y = RL_CatmullRom(p0.y, p1.y, p2.y, p3.y, f)
    local z = RL_CatmullRom(p0.z, p1.z, p2.z, p3.z, f) + (GC.motionZLift or 0.0)

    -- Orientation: shortest-arc slerp. THE fidelity win over heading-only.
    local qx, qy, qz, qw = RL_QuatSlerp(p1.qx, p1.qy, p1.qz, p1.qw,
                                        p2.qx, p2.qy, p2.qz, p2.qw, f)

    -- ── Puppet physics ────────────────────────────────────────────────────────
    -- The car is driven entirely by these writes. It must stay UNFROZEN (a frozen
    -- entity ignores coord writes and the ghost just sits at the start line), so
    -- everything that could fight us is neutralised instead: no gravity, no
    -- collision, and linear + angular velocity fed to match the path so the rigid
    -- body moves WITH the transform rather than against it.
    FreezeEntityPosition(GhostVeh, false)
    SetEntityHasGravity(GhostVeh, false)

    -- Velocity from the spline tangent — the true instantaneous direction and
    -- speed along the curve, not a straight chord between samples.
    if dt > 0.0 then
        local vx = RL_CatmullRomDeriv(p0.x, p1.x, p2.x, p3.x, f) / dt
        local vy = RL_CatmullRomDeriv(p0.y, p1.y, p2.y, p3.y, f) / dt
        local vz = RL_CatmullRomDeriv(p0.z, p1.z, p2.z, p3.z, f) / dt

        SetEntityVelocity(GhostVeh, clampv(vx), clampv(vy), clampv(vz))

        local wx, wy, wz = RL_QuatAngularVelocity(
            p1.qx, p1.qy, p1.qz, p1.qw, p2.qx, p2.qy, p2.qz, p2.qw, dt)
        SetEntityAngularVelocity(GhostVeh, wx, wy, wz)

        -- Telemetry, taken from the same spline the car is being driven along, so
        -- it can never disagree with what you see. Nothing extra is stored:
        -- velocity is the first derivative, acceleration the second.
        local d2 = dt * dt
        local ax = RL_CatmullRomDeriv2(p0.x, p1.x, p2.x, p3.x, f) / d2
        local ay = RL_CatmullRomDeriv2(p0.y, p1.y, p2.y, p3.y, f) / d2
        local az = RL_CatmullRomDeriv2(p0.z, p1.z, p2.z, p3.z, f) / d2

        local speed = math.sqrt(vx * vx + vy * vy + vz * vz)   -- m/s
        local lon, lat = 0.0, 0.0
        if speed > 0.1 then
            -- Split acceleration into "along the direction of travel" (throttle /
            -- braking) and "across it" (cornering load) — the two a driver feels.
            local ux, uy, uz = vx / speed, vy / speed, vz / speed
            lon = ax * ux + ay * uy + az * uz
            local px, py, pz = ax - ux * lon, ay - uy * lon, az - uz * lon
            lat = math.sqrt(px * px + py * py + pz * pz)
        end

        GhostTel.speed = speed * 3.6      -- km/h
        GhostTel.ms    = speed
        GhostTel.lon   = lon              -- m/s²  (+ accelerating, − braking)
        GhostTel.lat   = lat              -- m/s²  cornering
        GhostTel.g     = lon / 9.81
        GhostTel.latG  = lat / 9.81
        GhostTel.rpm   = p1.rpm or 0
        GhostTel.gear  = p1.gear
    end

    SetEntityCoordsNoOffset(GhostVeh, x, y, z, false, false, false)
    SetEntityQuaternion(GhostVeh, qx, qy, qz, qw)

    -- Cosmetic channel, interpolated across the segment too — held constant it
    -- stepped 25 times a second, which read as a twitchy wheel and a stuttering
    -- engine note.
    --
    -- LOD: transform is what sells a ghost at range; the cosmetic channel is
    -- invisible past a few dozen metres but costs a native call each, every
    -- frame, per ghost. Skip it when far away.
    if not cosmetic then
        DisableCamCollisionForObject(GhostVeh)
        return true
    end

    SetVehicleSteeringAngle(GhostVeh, lerp(p1.steer, p2.steer, f))
    SetVehicleCurrentRpm(GhostVeh, lerp(p1.rpm, p2.rpm, f))

    -- Per-wheel rotation replays real lockup under braking and wheelspin on
    -- corner exit — velocity alone only ever gives spin proportional to speed.
    if p1.w and GC.applyWheels ~= false and RL_WheelsSupported() then
        local w2 = p2.w or p1.w
        for i = 0, 3 do
            local ws = p1.w[i + 1]
            if ws then RL_WheelSet(GhostVeh, i, lerp(ws, w2[i + 1], f)) end
        end
    else
        -- No recorded wheel data (or a build that could not read it when this
        -- lap was driven): drive the wheels off the replay's own speed instead.
        -- A ghost has collision off and is placed by hand every frame, so its
        -- wheels never touch ground — without this they sit dead still while the
        -- car flies down the road.
        RL_WheelDrive(GhostVeh, GhostTel.ms or 0.0)
    end

    -- Gear drives the tacho and the shift points in the engine note (and puts
    -- the reverse lights on by itself when it is 0).
    if p1.gear then SetVehicleCurrentGear(GhostVeh, math.floor(p1.gear)) end

    -- Discrete states snap at the sample, which is correct — a brake light is
    -- on or off, never half.
    local flags = p1.flags or 0

    SetVehicleBrakeLights(GhostVeh, hasBit(flags, 1))

    -- Light bits arrived with gear, so gear's presence marks a recording that
    -- actually has them. Without it there is no way to tell "lights were off"
    -- from "lights were never recorded", and older laps would replay dark.
    if p1.gear then
        SetVehicleLights(GhostVeh, hasBit(flags, 16) and 2 or 1)  -- 2 forced on, 1 forced off
        SetVehicleFullbeam(GhostVeh, hasBit(flags, 32))
    end

    DisableCamCollisionForObject(GhostVeh)
    return true
end

CreateThread(function()
    while true do
        if Running and GhostVeh ~= 0 and DoesEntityExist(GhostVeh) then
            -- Lap clock, minus the scrub currently in progress: the ghost runs
            -- backward while you rewind and picks up from the same moment you do.
            local elapsed = math.max(0, GetGameTimer() - RunStart - RewindCreditMs())

            -- v4 motion stream when the lap has one; otherwise the legacy line.
            if Route.motion then
                -- LOD by distance from the player. A ghost you are racing is
                -- right next to you; one half a lap away only needs to be in the
                -- right place, so drop its cosmetic natives and tick it less
                -- often. Keeps a replayed ghost affordable at any distance.
                local d = #(GetEntityCoords(PlayerPedId()) - GetEntityCoords(GhostVeh))
                local cosmetic = d < (GC.lodDistance or 70.0)
                local far      = d > (GC.farDistance or 160.0)

                if not ReplayMotion(Route.motion, elapsed, cosmetic) then
                    BeginFadeOut()
                elseif FadeDir == -1 then
                    -- A rewind pulled the clock back inside the lap after the
                    -- ghost had started to leave: it has a lap to run again.
                    BeginFadeIn()
                end
                TickFade()
                Wait(far and 50 or 0)
                goto continue
            end

            local pts, times = Route.pts, Route.times
            local n = #pts

            -- Walk the cursor to the segment holding `elapsed` — forward
            -- normally, backward when a rewind moves the clock back. Either way
            -- it steps from where it was, so it never scans the whole array.
            while Cursor < n - 1 and times[Cursor + 1] <= elapsed do
                Cursor = Cursor + 1
            end
            while Cursor > 1 and times[Cursor] > elapsed do
                Cursor = Cursor - 1
            end

            if elapsed >= times[n] then
                -- Ghost lap done: fade out, same as the motion path.
                BeginFadeOut()
            else
                -- Rewound back inside the lap while leaving: come back.
                if FadeDir == -1 then BeginFadeIn() end

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
                local vx, vy, vz = clampv((b.x - a.x) * inv), clampv((b.y - a.y) * inv), clampv((b.z - a.z) * inv)
                FreezeEntityPosition(GhostVeh, false)
                SetEntityVelocity(GhostVeh, vx, vy, vz)

                -- Velocity does not turn wheels on a car with no ground under it
                -- (see the motion path): drive them from the segment speed.
                RL_WheelDrive(GhostVeh, math.sqrt(vx * vx + vy * vy + vz * vz))

                SetEntityCoordsNoOffset(GhostVeh, x, y, z, false, false, false)
                SetEntityHeading(GhostVeh, CurHeading)

                -- Camera must ignore the ghost too. Entity collision is off,
                -- but the gameplay cam still sweeps against it and gets shoved
                -- when you drive through the ghost — same bug as player cars.
                DisableCamCollisionForObject(GhostVeh)

                -- brake lights where you braked
                SetVehicleBrakeLights(GhostVeh, b.s == 2)
            end
            TickFade()
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

-- ── Panel accessors ──────────────────────────────────────────────────────────
--
-- The control panel (client/panel.lua) lives in this same resource environment,
-- so it reads and writes ghost state through these globals rather than through
-- exports — an export round-trip to yourself is a serialisation for nothing.
--
-- Everything here is a SETTER as well as a getter on purpose: a panel that can
-- only report state is a status screen, and the whole point is that the driver
-- can change these between laps without leaving the car for a chat command.

function RL_GhostIsOn() return GhostOn end

function RL_GhostSetOn(on)
    GhostOn = on and true or false
    if not GhostOn then DeleteGhost() end
    return GhostOn
end

function RL_GhostGetMode() return GhostMode end

function RL_GhostIsRunning() return Running end

function RL_GhostGetTrack() return TTTrack end

--- Ghost transparency, applied live. Skipped while a fade is in flight — the
--- fade owns the alpha channel for those few hundred ms and would immediately
--- overwrite anything set here.
function RL_GhostSetAlpha(a)
    a = math.max(20, math.min(255, math.floor(tonumber(a) or 150)))
    GC.alpha = a
    if GhostVeh ~= 0 and DoesEntityExist(GhostVeh) and FadeDir == 0 then
        SetEntityAlpha(GhostVeh, a, false)
    end
    return a
end

function RL_GhostGetAlpha() return GC.alpha or 150 end

function RL_GhostBlipEnabled() return ShowBlip end

function RL_GhostSetBlip(on)
    ShowBlip = on and true or false
    if ShowBlip then
        if Running then AddGhostBlip() end
    else
        RemoveGhostBlip()
    end
    return ShowBlip
end

--- Everything the panel needs to describe the ghost in one call.
function RL_GhostStatus()
    return {
        on      = GhostOn,
        mode    = GhostMode,
        running = Running,
        track   = TTTrack,
        blip    = ShowBlip,
        alpha   = GC.alpha or 150,
        spec    = GC.applySpec  ~= false,
        wheels  = GC.applyWheels ~= false,
        -- Is there actually a lap to replay in the current mode? "Ghost is on"
        -- and "a ghost will appear" are different answers and the panel says so.
        hasLine = (TTTrack ~= nil) and (ResolveEntry() ~= nil) or false,
    }
end

--- The ghostinfo diagnostic, as data instead of console prints, so the panel can
--- show the answer to "why is my ghost pacing flat" in game.
function RL_GhostDiagnostics()
    local entry = ResolveEntry()
    if not entry then return nil end

    local r = BuildRoute(entry)
    if not r then return nil end

    local src = r.motion
    if not src then
        src = {}
        for i, p in ipairs(r.pts) do src[i] = { x = p.x, y = p.y, z = p.z, t = r.times[i] } end
    end

    local minS, maxS, sum, cnt = math.huge, -math.huge, 0.0, 0
    for i = 2, #src do
        local dtt = ((src[i].t or 0) - (src[i-1].t or 0)) / 1000.0
        if dtt > 0 then
            local dx = src[i].x - src[i-1].x
            local dy = src[i].y - src[i-1].y
            local dz = (src[i].z or 0) - (src[i-1].z or 0)
            local kmh = math.sqrt(dx*dx + dy*dy + dz*dz) / dtt * 3.6
            if kmh < minS then minS = kmh end
            if kmh > maxS then maxS = kmh end
            sum, cnt = sum + kmh, cnt + 1
        end
    end

    if cnt == 0 then return nil end

    return {
        mode    = GhostMode,
        motion  = r.motion and #r.motion or nil,
        points  = #r.pts,
        lapMs   = entry.best,
        holder  = entry.holder,
        minKmh  = minS,
        maxKmh  = maxS,
        avgKmh  = sum / cnt,
        spread  = maxS - minS,
    }
end

-- ── Telemetry access ─────────────────────────────────────────────────────────
-- Speed / acceleration of the ghost right now, derived from the replay spline.
-- Nothing is stored for these: velocity is the spline's first derivative and
-- acceleration its second, so they always agree with the path being driven.
--   speed km/h · ms m/s · lon m/s² (+throttle / −brake) · lat m/s² cornering
--   g / latG    the same in G · rpm 0..1 · gear
exports('GetGhostTelemetry', function()
    if not Running then return nil end
    return {
        speed = GhostTel.speed, ms   = GhostTel.ms,
        lon   = GhostTel.lon,   lat  = GhostTel.lat,
        g     = GhostTel.g,     latG = GhostTel.latG,
        rpm   = GhostTel.rpm,   gear = GhostTel.gear,
    }
end)

-- ── Diagnostic ───────────────────────────────────────────────────────────────
-- Answers "why does the ghost feel like it runs at a constant pace?". Prints
-- which replay path is live and the actual speed profile of the loaded lap: a
-- flat min/max here means the DATA is constant-pace, not the renderer.
RegisterCommand('ghostinfo', function()
    local entry = ResolveEntry and ResolveEntry()
    if not entry then
        print('[ghost] no line loaded for this track (mode: ' .. tostring(GhostMode) .. ')')
        return
    end

    local r = BuildRoute(entry)
    if not r then print('[ghost] line too short to replay') return end

    print(('[ghost] mode=%s  motion=%s  points=%d  lapMs=%s')
        :format(tostring(GhostMode), r.motion and ('yes (' .. #r.motion .. ' samples)') or 'NO',
                #r.pts, tostring(entry.best)))

    if not r.motion then
        local timed = r.pts[1].t ~= nil and r.pts[#r.pts].t ~= nil and r.pts[#r.pts].t > 0
        print(('[ghost] legacy line — per-point timing: %s')
            :format(timed and 'yes' or 'NO -> distance-proportional CONSTANT PACE'))
    end

    -- Speed profile straight off the spline the replay uses.
    local src = r.motion
    if not src then
        src = {}
        for i, p in ipairs(r.pts) do src[i] = { x = p.x, y = p.y, z = p.z, t = r.times[i] } end
    end

    local n, minS, maxS, sum, cnt = #src, math.huge, -math.huge, 0.0, 0
    local marks = {}
    for i = 2, n do
        local dtt = ((src[i].t or 0) - (src[i-1].t or 0)) / 1000.0
        if dtt > 0 then
            local dx = src[i].x - src[i-1].x
            local dy = src[i].y - src[i-1].y
            local dz = (src[i].z or 0) - (src[i-1].z or 0)
            local kmh = math.sqrt(dx*dx + dy*dy + dz*dz) / dtt * 3.6
            if kmh < minS then minS = kmh end
            if kmh > maxS then maxS = kmh end
            sum, cnt = sum + kmh, cnt + 1
            if #marks < 10 and (i % math.max(1, math.floor(n / 10)) == 0) then
                marks[#marks + 1] = ('%.0f'):format(kmh)
            end
        end
    end

    if cnt == 0 then print('[ghost] no usable timing in the line') return end
    print(('[ghost] speed km/h  min=%.0f  max=%.0f  avg=%.0f  spread=%.0f')
        :format(minS, maxS, sum / cnt, maxS - minS))
    print('[ghost] profile: ' .. table.concat(marks, ' '))
    print('[ghost] a spread near 0 means the stored lap itself is constant pace')
end, false)
