-- client/motion.lua
-- P0 spike: high-fidelity motion capture for the ghost ("scene director" style).
--
-- The legacy line (v3 `p`) stays exactly as it was — it is distance-gated and
-- drives the painted ribbon. This module records a SECOND,
-- parallel stream at a FIXED RATE that exists purely to replay the car:
--
--   • fixed 25 Hz  — the old 2 m distance gate sampled slow corners at only ~7 Hz
--                    (fewest samples exactly where detail matters most)
--   • full rotation (quaternion) — the old line stored heading only, so the ghost
--                    stayed flat: no banking, no nose-dive, no kerb tilt
--   • raw Z         — not ground-snapped, so jumps and crests survive
--   • steer / rpm / flags — front wheels actually turn, engine note matches
--
-- Serialised as `r` inside the v4 line payload; readers that only know `p`
-- keep working unchanged.

RL_Motion = RL_Motion or {}

-- Stride is written into the payload (`rf`) so old recordings stay readable.
-- Base block is always 11: t,x,y,z,qx,qy,qz,qw,steer,rpm,flags.
-- Optional blocks are APPENDED, never inserted, so a stride recorded by an older
-- build still decodes to the same fields:
--   +4 wheels (w1..w4) at 12..15   — only when this build can replay them
--   +1 gear                        — last field
local LAYOUTS = {
    [11] = { wheels = nil, gear = nil },
    [12] = { wheels = nil, gear = 12 },
    [15] = { wheels = 12,  gear = nil },   -- recorded before gear existed
    [16] = { wheels = 12,  gear = 16 },
}

RL_MOTION_FIELDS = 16
local MAX_WHEELS = 4

--- Field layout for a stride, or nil when the stride is unknown. Shared with
--- the binary packer so both encodings follow the same field rules.
function RL_MotLayout(stride)
    return LAYOUTS[tonumber(stride) or -1]
end

local Buf      = {}    -- current lap's samples
local Frozen   = nil   -- last completed lap's samples

-- ── Wheel rotation natives ────────────────────────────────────────────────────
-- The per-wheel natives differ by game build: some expose
-- Get/SetVehicleWheelRotationSpeed (rad/s), others Get/SetVehicleWheelSpeed
-- (m/s), and older builds only have the getter. Assuming a name crashed the
-- replay ("attempt to call a nil value"), so resolve a MATCHING pair at runtime
-- and fall back to no wheel data at all when the setter is missing — the ghost
-- then derives spin from velocity as it did before.
local WheelGet, WheelSet

do
    local pairsToTry = {
        { get = rawget(_G, 'GetVehicleWheelRotationSpeed'),
          set = rawget(_G, 'SetVehicleWheelRotationSpeed') },
        { get = rawget(_G, 'GetVehicleWheelSpeed'),
          set = rawget(_G, 'SetVehicleWheelSpeed') },
    }
    for _, p in ipairs(pairsToTry) do
        if type(p.get) == 'function' and type(p.set) == 'function' then
            WheelGet, WheelSet = p.get, p.set
            break
        end
    end
end

--- True when this build can both read and write per-wheel rotation.
function RL_WheelsSupported()
    return WheelGet ~= nil and WheelSet ~= nil
end

function RL_WheelSet(veh, index, speed)
    if WheelSet then WheelSet(veh, index, speed) end
end

-- ── Driving wheels without recorded data ──────────────────────────────────────
-- Replay needs the wheels to turn even when the lap carries no per-wheel data
-- (a v4 line, or a build that could not READ wheel speeds when it recorded).
-- Playback only needs a SETTER, so one is resolved on its own here — pairing it
-- with a getter, as above, meant a build that can write but not read spun the
-- ghost's wheels not at all.
--
-- Ghosts have collision off and are positioned by hand every frame, so their
-- wheels never touch ground: nothing rolls them, and velocity alone cannot
-- (rotation comes from contact). They have to be driven explicitly.
local DriveSet, DriveUnit

do
    local rads = rawget(_G, 'SetVehicleWheelRotationSpeed')   -- rad/s
    local mps  = rawget(_G, 'SetVehicleWheelSpeed')           -- m/s
    if type(rads) == 'function' then
        DriveSet, DriveUnit = rads, 'rads'
    elseif type(mps) == 'function' then
        DriveSet, DriveUnit = mps, 'mps'
    end
end

local WHEEL_RADIUS = 0.35   -- metres; close enough for every road car

function RL_WheelDriveSupported()
    return DriveSet ~= nil
end

--- Spin every wheel as though the car were rolling at `mps` metres per second.
function RL_WheelDrive(veh, mps)
    if not DriveSet then return end
    local value = (DriveUnit == 'rads') and (mps / WHEEL_RADIUS) or mps
    local n = math.min(GetVehicleNumberOfWheels(veh) or 4, MAX_WHEELS)
    for i = 0, n - 1 do
        pcall(DriveSet, veh, i, value)
    end
end

-- ── Quaternion helpers ────────────────────────────────────────────────────────

--- Shortest-arc spherical interpolation between two unit quaternions.
--- Falls back to normalised lerp when the inputs are nearly parallel (sin→0).
function RL_QuatSlerp(ax, ay, az, aw, bx, by, bz, bw, t)
    local dot = ax * bx + ay * by + az * bz + aw * bw

    -- Take the shorter path around the hypersphere.
    if dot < 0.0 then
        bx, by, bz, bw, dot = -bx, -by, -bz, -bw, -dot
    end

    if dot > 0.9995 then
        local x = ax + (bx - ax) * t
        local y = ay + (by - ay) * t
        local z = az + (bz - az) * t
        local w = aw + (bw - aw) * t
        local len = math.sqrt(x * x + y * y + z * z + w * w)
        if len <= 0.0 then return ax, ay, az, aw end
        return x / len, y / len, z / len, w / len
    end

    local theta0 = math.acos(dot)
    local sin0   = math.sin(theta0)
    local theta  = theta0 * t
    local s1     = math.sin(theta0 - theta) / sin0
    local s2     = math.sin(theta) / sin0

    return ax * s1 + bx * s2, ay * s1 + by * s2, az * s1 + bz * s2, aw * s1 + bw * s2
end

--- Angular velocity (rad/s) that carries orientation `a` to `b` over `dt`
--- seconds. Feeding this to the entity stops the rigid body fighting the
--- per-frame quaternion writes, which is what made the ghost twitch.
function RL_QuatAngularVelocity(ax, ay, az, aw, bx, by, bz, bw, dt)
    if not dt or dt <= 0.0 then return 0.0, 0.0, 0.0 end

    -- qd = b * conjugate(a)
    local cx, cy, cz, cw = -ax, -ay, -az, aw
    local qx = bw * cx + bx * cw + by * cz - bz * cy
    local qy = bw * cy - bx * cz + by * cw + bz * cx
    local qz = bw * cz + bx * cy - by * cx + bz * cw
    local qw = bw * cw - bx * cx - by * cy - bz * cz

    if qw < 0.0 then qx, qy, qz, qw = -qx, -qy, -qz, -qw end   -- shortest arc

    qw = math.max(-1.0, math.min(1.0, qw))
    local s = math.sqrt(math.max(0.0, 1.0 - qw * qw))
    if s < 1e-6 then return 0.0, 0.0, 0.0 end                  -- no rotation

    local scale = (2.0 * math.acos(qw)) / (s * dt)
    return qx * scale, qy * scale, qz * scale
end

-- ── Catmull-Rom ───────────────────────────────────────────────────────────────
-- Linear interpolation between 25 Hz samples chords every corner: at speed the
-- ghost visibly cut the apex compared to the line actually driven. A Catmull-Rom
-- spline passes exactly through every recorded point and curves between them, so
-- the replayed path matches what was driven.

--- Position on the spline between p1 and p2 (t = 0..1).
function RL_CatmullRom(p0, p1, p2, p3, t)
    local t2 = t * t
    local t3 = t2 * t
    return 0.5 * ((2.0 * p1)
        + (-p0 + p2) * t
        + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
        + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)
end

--- d/dt of the above — the true tangent, used for velocity so the car's speed
--- matches the curve it is actually following rather than a straight chord.
function RL_CatmullRomDeriv(p0, p1, p2, p3, t)
    local t2 = t * t
    return 0.5 * ((-p0 + p2)
        + 2.0 * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t
        + 3.0 * (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t2)
end

--- d²/dt² — acceleration along the spline.
---
--- Speed and acceleration are NOT recorded: they are already implied by the
--- position curve, so storing them would be redundant bytes that could also
--- disagree with the path. Taking them analytically from the same spline the car
--- is driven along means they always match what you see, and differencing
--- frame-to-frame speeds (the obvious alternative) would be full of noise.
function RL_CatmullRomDeriv2(p0, p1, p2, p3, t)
    return 0.5 * (2.0 * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3)
        + 6.0 * (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t)
end

-- ── Capture ───────────────────────────────────────────────────────────────────

function RL_MotReset()
    Buf = {}
end

function RL_MotClear()
    Buf, Frozen = {}, nil
end

--- One fixed-rate snapshot of the vehicle. `tMs` = ms since lap start.
function RL_MotSample(veh, tMs, brake, handbrake)
    local max = Config.MaxMotionSamples or 7500
    if #Buf >= max then return end

    local pos = GetEntityCoords(veh)
    local qx, qy, qz, qw = GetEntityQuaternion(veh)

    -- Bitfield: 1 brake · 2 handbrake · 4 burnout · 8 airborne
    --           16 headlights · 32 highbeams
    local flags = 0
    if brake then flags = flags + 1 end
    if handbrake then flags = flags + 2 end
    if IsVehicleInBurnout(veh) then flags = flags + 4 end
    if IsEntityInAir(veh) then flags = flags + 8 end

    local _, lightsOn, highBeams = GetVehicleLightsState(veh)
    if lightsOn then flags = flags + 16 end
    if highBeams then flags = flags + 32 end

    -- Per-wheel rotation speed. Recording it (rather than deriving spin from
    -- road speed) is what preserves lockup under braking and wheelspin on
    -- corner exit — the wheels stop and light up exactly where yours did.
    -- Only recorded when this build can also REPLAY it, so we never store data
    -- the ghost cannot use.
    local w = nil
    if WheelGet and WheelSet then
        w = {}
        local nWheels = math.min(GetVehicleNumberOfWheels(veh) or 4, MAX_WHEELS)
        for i = 0, MAX_WHEELS - 1 do
            w[i + 1] = (i < nWheels) and (WheelGet(veh, i) or 0.0) or 0.0
        end
    end

    Buf[#Buf + 1] = {
        t     = tMs,
        x     = pos.x, y = pos.y, z = pos.z,      -- raw Z: keep jumps/crests
        qx    = qx, qy = qy, qz = qz, qw = qw,    -- full orientation
        steer = GetVehicleSteeringAngle(veh),
        rpm   = GetVehicleCurrentRpm(veh),
        flags = flags,
        w     = w,
        gear  = GetVehicleCurrentGear(veh),
    }
end

--- Drop every sample newer than `maxT` (ms since lap start) from the running
--- buffer. Used when a rewind scrubs the car back: the samples after the
--- landing point describe driving that no longer happened, and leaving them in
--- would replay the ghost through a stretch the player un-drove.
--- Samples are appended in time order, so this only ever pops off the tail.
function RL_MotTrim(maxT)
    maxT = tonumber(maxT)
    if not maxT then return 0 end
    local dropped = 0
    while #Buf > 0 and (Buf[#Buf].t or 0) > maxT do
        Buf[#Buf] = nil
        dropped = dropped + 1
    end
    return dropped
end

--- Freeze the running buffer as the completed lap and start a fresh one.
function RL_MotFreeze()
    Frozen = Buf
    Buf = {}
end

function RL_MotCount()
    return #Buf
end

--- The last completed lap's samples (ready to replay locally, no round trip).
function RL_MotFrozen()
    return (type(Frozen) == "table" and #Frozen >= 4) and Frozen or nil
end

--- Narrowest stride that fits what the frozen lap actually captured. Keeping
--- this separate from flattening lets the packer ask for it without building
--- the flat array first.
function RL_MotStride()
    local s = Frozen and Frozen[1]
    if not s then return 11 end
    local hasWheels, hasGear = s.w ~= nil, s.gear ~= nil
    return hasWheels and (hasGear and 16 or 15) or (hasGear and 12 or 11)
end

-- ── Serialisation (flat numeric array — msgpack friendly) ────────────────────

local function r2(v) return math.floor((v or 0) * 100 + 0.5) / 100 end     -- 1 cm
local function r3(v) return math.floor((v or 0) * 1000 + 0.5) / 1000 end   -- quat/rpm

--- Flatten the FROZEN lap. Returns (flat, stride), or nil when there is nothing
--- worth sending. The stride narrows to 11 when no wheel data was captured, so
--- we never store zeroed wheel fields that would pin a ghost's wheels static on
--- a client whose build CAN replay them.
function RL_MotFlatten()
    local src = Frozen
    if type(src) ~= "table" or #src < 4 then return nil end

    local stride = RL_MotStride()
    local L      = LAYOUTS[stride]

    local flat = {}
    for i = 1, #src do
        local s = src[i]
        local n = (i - 1) * stride
        flat[n + 1]  = math.floor(s.t or 0)
        flat[n + 2]  = r2(s.x)
        flat[n + 3]  = r2(s.y)
        flat[n + 4]  = r2(s.z)
        flat[n + 5]  = r3(s.qx)
        flat[n + 6]  = r3(s.qy)
        flat[n + 7]  = r3(s.qz)
        flat[n + 8]  = r3(s.qw)
        flat[n + 9]  = r2(s.steer)
        flat[n + 10] = r3(s.rpm)
        flat[n + 11] = s.flags or 0
        if L.wheels then
            local w = s.w or {}
            for k = 0, MAX_WHEELS - 1 do
                flat[n + L.wheels + k] = r2(w[k + 1])
            end
        end
        if L.gear then flat[n + L.gear] = math.floor(s.gear or 0) end
    end
    return flat, stride
end

--- Rebuild samples from a flat array. `stride` comes from the payload (`rf`),
--- defaulting to 11 so v4 recordings (no wheel speeds) still decode.
function RL_MotExpand(flat, stride)
    stride = tonumber(stride) or 11
    local L = LAYOUTS[stride]
    if not L then return nil end                       -- unknown layout: ignore
    if type(flat) ~= "table" or #flat < stride * 4 then return nil end

    local out = {}
    for i = 1, #flat - (stride - 1), stride do
        local s = {
            t     = flat[i],
            x     = flat[i + 1], y = flat[i + 2], z = flat[i + 3],
            qx    = flat[i + 4], qy = flat[i + 5], qz = flat[i + 6], qw = flat[i + 7],
            steer = flat[i + 8],
            rpm   = flat[i + 9],
            flags = flat[i + 10] or 0,
        }
        if L.wheels then
            s.w = {}
            for k = 0, MAX_WHEELS - 1 do
                s.w[k + 1] = flat[i + L.wheels - 1 + k] or 0
            end
        end
        if L.gear then s.gear = flat[i + L.gear - 1] end
        out[#out + 1] = s
    end
    return out
end
