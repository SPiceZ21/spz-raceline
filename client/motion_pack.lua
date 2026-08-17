-- client/motion_pack.lua
-- Binary packing for the motion stream.
--
-- The flat numeric array serialises to JSON at roughly 150 bytes per sample —
-- a two minute lap at 25 Hz is ~450 KB, which is heavy to store per player per
-- track and heavy to push over the wire. Packing the same data as quantised
-- binary costs 24 bytes per sample (~72 KB), and base64 for safe transport in
-- the existing TEXT column brings it to ~96 KB: about 4.7x smaller with no
-- visible loss.
--
-- Quantisation budget (all well under what the eye can resolve at speed):
--   position   1 cm      int32 absolute for the first sample, int16 deltas after
--   rotation   ~0.16°    smallest-three quaternion, 3 x 10 bits + 2 bit index
--   steering   0.5°      int8
--   rpm        1/255     uint8
--   wheels     0.01      int16
--   time       1 ms      uint32 first, uint16 deltas after
--
-- Layout is driven by the stride (see LAYOUTS in motion.lua), so a packed blob
-- decodes with the same field rules as the flat array.

local MAGIC   = 0x52   -- 'R'
local VERSION = 1

local MODE_DELTA = 0   -- int16 position deltas (normal)
local MODE_ABS   = 1   -- int32 absolute positions (used if any delta overflows)

local spack, sunpack = string.pack, string.unpack

-- ── base64 ────────────────────────────────────────────────────────────────────

local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local B64R = {}
for i = 1, #B64 do B64R[B64:sub(i, i)] = i - 1 end

function RL_B64Encode(data)
    local out, n = {}, #data
    local i = 1
    while i + 2 <= n do
        local a, b, c = data:byte(i, i + 2)
        local v = a * 65536 + b * 256 + c
        out[#out + 1] = B64:sub(math.floor(v / 262144) % 64 + 1, math.floor(v / 262144) % 64 + 1)
            .. B64:sub(math.floor(v / 4096) % 64 + 1, math.floor(v / 4096) % 64 + 1)
            .. B64:sub(math.floor(v / 64) % 64 + 1, math.floor(v / 64) % 64 + 1)
            .. B64:sub(v % 64 + 1, v % 64 + 1)
        i = i + 3
    end
    local rem = n - i + 1
    if rem == 1 then
        local a = data:byte(i)
        local v = a * 16
        out[#out + 1] = B64:sub(math.floor(v / 64) % 64 + 1, math.floor(v / 64) % 64 + 1)
            .. B64:sub(v % 64 + 1, v % 64 + 1) .. '=='
    elseif rem == 2 then
        local a, b = data:byte(i, i + 1)
        local v = (a * 256 + b) * 4
        out[#out + 1] = B64:sub(math.floor(v / 4096) % 64 + 1, math.floor(v / 4096) % 64 + 1)
            .. B64:sub(math.floor(v / 64) % 64 + 1, math.floor(v / 64) % 64 + 1)
            .. B64:sub(v % 64 + 1, v % 64 + 1) .. '='
    end
    return table.concat(out)
end

function RL_B64Decode(s)
    if type(s) ~= 'string' then return nil end
    s = s:gsub('[^A-Za-z0-9+/=]', '')
    local out = {}
    for i = 1, #s, 4 do
        local c1, c2, c3, c4 = s:sub(i, i), s:sub(i + 1, i + 1), s:sub(i + 2, i + 2), s:sub(i + 3, i + 3)
        local n1, n2 = B64R[c1], B64R[c2]
        if not n1 or not n2 then return nil end
        local n3, n4 = B64R[c3], B64R[c4]
        local v = n1 * 262144 + n2 * 4096 + (n3 or 0) * 64 + (n4 or 0)
        out[#out + 1] = string.char(math.floor(v / 65536) % 256)
        if c3 ~= '=' and c3 ~= '' then out[#out + 1] = string.char(math.floor(v / 256) % 256) end
        if c4 ~= '=' and c4 ~= '' then out[#out + 1] = string.char(v % 256) end
    end
    return table.concat(out)
end

-- ── Quaternion: smallest-three ────────────────────────────────────────────────
-- A unit quaternion has only three free components, so drop the largest (its
-- magnitude is implied) and store the rest at 10 bits each. q and -q describe
-- the same rotation, so the dropped component is normalised positive.

local INV_SQRT2 = 0.70710678118

local function packQuat(x, y, z, w)
    local comps = { x, y, z, w }
    local big, bigAbs = 1, -1.0
    for i = 1, 4 do
        local a = math.abs(comps[i])
        if a > bigAbs then big, bigAbs = i, a end
    end

    if comps[big] < 0.0 then
        for i = 1, 4 do comps[i] = -comps[i] end
    end

    local packed = (big - 1)
    for i = 1, 4 do
        if i ~= big then
            local v = math.max(-INV_SQRT2, math.min(INV_SQRT2, comps[i]))
            local q = math.floor(((v / INV_SQRT2) * 0.5 + 0.5) * 1023 + 0.5)
            packed = packed * 1024 + math.max(0, math.min(1023, q))
        end
    end
    return packed
end

local function unpackQuat(packed)
    local c = packed % 1024; packed = math.floor(packed / 1024)
    local b = packed % 1024; packed = math.floor(packed / 1024)
    local a = packed % 1024; packed = math.floor(packed / 1024)
    local big = packed % 4

    local function dq(q) return ((q / 1023) * 2.0 - 1.0) * INV_SQRT2 end
    local v1, v2, v3 = dq(a), dq(b), dq(c)

    local sum = v1 * v1 + v2 * v2 + v3 * v3
    local largest = math.sqrt(math.max(0.0, 1.0 - sum))

    local out = {}
    local k = 1
    local vals = { v1, v2, v3 }
    for i = 1, 4 do
        if i == big + 1 then
            out[i] = largest
        else
            out[i] = vals[k]; k = k + 1
        end
    end
    return out[1], out[2], out[3], out[4]
end

-- ── Pack / unpack ─────────────────────────────────────────────────────────────

local function clampInt(v, lo, hi)
    v = math.floor((v or 0) + 0.5)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

--- samples -> base64 string. Returns nil if there is nothing to pack.
function RL_MotPack(samples, stride)
    if type(samples) ~= 'table' or #samples < 4 then return nil end
    local L = RL_MotLayout(stride)
    if not L then return nil end

    local n = #samples

    -- Absolute centimetre grid, so reconstruction is exact rather than an
    -- accumulation of rounded deltas.
    local qx, qy, qz = {}, {}, {}
    for i = 1, n do
        qx[i] = math.floor((samples[i].x or 0) * 100 + 0.5)
        qy[i] = math.floor((samples[i].y or 0) * 100 + 0.5)
        qz[i] = math.floor((samples[i].z or 0) * 100 + 0.5)
    end

    -- Deltas normally fit int16 (±327 m per 40 ms); a teleport would not, so
    -- check first and fall back to absolute rather than corrupt the path.
    local mode = MODE_DELTA
    for i = 2, n do
        local dx, dy, dz = qx[i] - qx[i-1], qy[i] - qy[i-1], qz[i] - qz[i-1]
        if dx < -32768 or dx > 32767 or dy < -32768 or dy > 32767
           or dz < -32768 or dz > 32767 then
            mode = MODE_ABS
            break
        end
    end

    local buf = {}
    buf[#buf + 1] = spack('<BBBBI4', MAGIC, VERSION, stride, mode, n)

    for i = 1, n do
        local s = samples[i]

        -- time
        if i == 1 then
            buf[#buf + 1] = spack('<I4', clampInt(s.t, 0, 4294967295))
        else
            buf[#buf + 1] = spack('<I2', clampInt((s.t or 0) - (samples[i-1].t or 0), 0, 65535))
        end

        -- position
        if mode == MODE_ABS or i == 1 then
            buf[#buf + 1] = spack('<i4i4i4', qx[i], qy[i], qz[i])
        else
            buf[#buf + 1] = spack('<i2i2i2',
                qx[i] - qx[i-1], qy[i] - qy[i-1], qz[i] - qz[i-1])
        end

        buf[#buf + 1] = spack('<I4', packQuat(s.qx or 0, s.qy or 0, s.qz or 0, s.qw or 1))
        buf[#buf + 1] = spack('<i1', clampInt((s.steer or 0) * 2, -127, 127))
        buf[#buf + 1] = spack('<I1', clampInt((s.rpm or 0) * 255, 0, 255))
        buf[#buf + 1] = spack('<I1', clampInt(s.flags, 0, 255))

        if L.wheels then
            local w = s.w or {}
            for k = 1, 4 do
                buf[#buf + 1] = spack('<i2', clampInt((w[k] or 0) * 100, -32768, 32767))
            end
        end
        if L.gear then
            buf[#buf + 1] = spack('<I1', clampInt(s.gear, 0, 255))
        end
    end

    return RL_B64Encode(table.concat(buf))
end

--- base64 string -> samples. Returns nil on anything malformed.
function RL_MotUnpack(b64)
    local data = RL_B64Decode(b64)
    if type(data) ~= 'string' or #data < 8 then return nil end

    local ok, magic, version, stride, mode, n, pos = pcall(sunpack, '<BBBBI4', data)
    if not ok or magic ~= MAGIC or version ~= VERSION then return nil end

    local L = RL_MotLayout(stride)
    if not L or n < 4 or n > (Config.MaxMotionSamples or 7500) then return nil end

    local out = {}
    local px, py, pz, pt = 0, 0, 0, 0

    local good = pcall(function()
        for i = 1, n do
            local s = {}

            if i == 1 then
                pt, pos = sunpack('<I4', data, pos)
            else
                local d; d, pos = sunpack('<I2', data, pos)
                pt = pt + d
            end
            s.t = pt

            if mode == MODE_ABS or i == 1 then
                px, py, pz, pos = sunpack('<i4i4i4', data, pos)
            else
                local dx, dy, dz
                dx, dy, dz, pos = sunpack('<i2i2i2', data, pos)
                px, py, pz = px + dx, py + dy, pz + dz
            end
            s.x, s.y, s.z = px / 100, py / 100, pz / 100

            local q; q, pos = sunpack('<I4', data, pos)
            s.qx, s.qy, s.qz, s.qw = unpackQuat(q)

            local st, rp, fl
            st, pos = sunpack('<i1', data, pos)
            rp, pos = sunpack('<I1', data, pos)
            fl, pos = sunpack('<I1', data, pos)
            s.steer, s.rpm, s.flags = st / 2, rp / 255, fl

            if L.wheels then
                s.w = {}
                for k = 1, 4 do
                    local wv; wv, pos = sunpack('<i2', data, pos)
                    s.w[k] = wv / 100
                end
            end
            if L.gear then
                local g; g, pos = sunpack('<I1', data, pos)
                s.gear = g
            end

            out[i] = s
        end
    end)

    if not good or #out < 4 then return nil end
    return out
end
