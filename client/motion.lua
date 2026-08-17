-- client/motion.lua
-- P0 spike: high-fidelity motion capture for the ghost ("scene director" style).
--
-- The legacy line (v3 `p`) stays exactly as it was — it is distance-gated and
-- drives the painted ribbon + coach analysis. This module records a SECOND,
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

-- Stride is written into the payload (`rf`) so old recordings stay readable:
--   v4 = 11 fields (no wheel speeds), v5 = 15 (adds per-wheel rotation).
RL_MOTION_FIELDS = 15   -- t,x,y,z,qx,qy,qz,qw,steer,rpm,flags,w1..w4
local FIELDS = RL_MOTION_FIELDS
local MAX_WHEELS = 4

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

    local flags = 0
    if brake then flags = flags + 1 end
    if handbrake then flags = flags + 2 end
    if IsVehicleInBurnout(veh) then flags = flags + 4 end
    if IsEntityInAir(veh) then flags = flags + 8 end

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
    }
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

    local stride = (src[1] and src[1].w) and FIELDS or 11

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
        if stride >= 15 then
            local w = s.w or {}
            flat[n + 12] = r2(w[1])
            flat[n + 13] = r2(w[2])
            flat[n + 14] = r2(w[3])
            flat[n + 15] = r2(w[4])
        end
    end
    return flat, stride
end

--- Rebuild samples from a flat array. `stride` comes from the payload (`rf`),
--- defaulting to 11 so v4 recordings (no wheel speeds) still decode.
function RL_MotExpand(flat, stride)
    stride = tonumber(stride) or 11
    if stride < 11 then return nil end
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
        if stride >= 15 then
            s.w = { flat[i + 11] or 0, flat[i + 12] or 0,
                    flat[i + 13] or 0, flat[i + 14] or 0 }
        end
        out[#out + 1] = s
    end
    return out
end
