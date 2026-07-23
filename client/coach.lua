-- client/coach.lua
-- Telemetry coaching overlay. After a lap, compares the lap you just drove
-- against your reference (PB, or the track record if the record ghost is on)
-- and paints the road where you LOST time: red segments = you were slower
-- there, with the biggest loss zones flagged as markers ("BRAKE EARLY -0.31s").
--
-- This is the differentiator: no other FiveM racing script does telemetry
-- coaching. It reads the same per-2m throttle/brake capture the ghost uses.
--
-- Point format (shared with main.lua / ghost.lua):
--   { x, y, z, s (0 coast/1 throttle/2 brake), brk, t (ms since lap start) }

local CC = (Config.Coach) or {}
local CoachOn = CC.enabled ~= false

local Segments = {}   -- { { x, y, z, loss (ms), colour }, ... }
local Markers  = {}   -- worst spots: { x, y, z, loss, hint }

local LOSS_MIN     = CC.minLossMs     or 40     -- ignore noise below this
local MARKER_TOP   = CC.markerCount   or 4      -- how many "hot" markers
local DRAW_RANGE   = CC.drawRange     or 220.0
local SEG_WIDTH    = CC.width         or 0.5
local Z_LIFT       = CC.zLift         or 0.06

-- ── Reference resampling ──────────────────────────────────────────────────────
-- The two laps have different point counts and spacing, so compare them by
-- ARC LENGTH: for each point of the lap just driven, find the reference's
-- time at the same distance-into-lap. Delta = mine - ref (positive = slower).

local function cumulativeDist(pts)
    local cum = { 0.0 }
    for i = 2, #pts do
        local dx, dy = pts[i].x - pts[i-1].x, pts[i].y - pts[i-1].y
        cum[i] = cum[i-1] + math.sqrt(dx*dx + dy*dy)
    end
    return cum
end

-- Reference time at a given distance-into-lap (linear interp between anchors).
local function refTimeAt(refPts, refCum, dist)
    local n = #refPts
    if dist <= 0 then return refPts[1].t or 0 end
    if dist >= refCum[n] then return refPts[n].t or 0 end
    -- binary search the arc-length bracket
    local lo, hi = 1, n
    while lo < hi do
        local mid = (lo + hi) // 2
        if refCum[mid] < dist then lo = mid + 1 else hi = mid end
    end
    local i = math.max(2, lo)
    local span = refCum[i] - refCum[i-1]
    local f = span > 0 and (dist - refCum[i-1]) / span or 0.0
    local ta, tb = refPts[i-1].t or 0, refPts[i].t or 0
    return ta + (tb - ta) * f
end

local function stateHint(s)
    if s == 2 then return "BRAKE EARLIER" end
    if s == 1 then return "MORE THROTTLE" end
    return "CARRY SPEED"
end

-- Build the comparison. `mine` and `ref` are ordered point arrays with .t set.
local function Analyse(mine, ref)
    Segments, Markers = {}, {}
    if not mine or not ref or #mine < 3 or #ref < 3 then return false end
    if not mine[#mine].t or not ref[#ref].t then return false end   -- need timing

    local refCum = cumulativeDist(ref)
    local myCum  = cumulativeDist(mine)
    if refCum[#ref] <= 0 then return false end

    -- Per-point cumulative delta, then per-segment marginal loss.
    local prevDelta = 0.0
    local hot = {}   -- candidate markers
    for i = 1, #mine do
        local myT  = mine[i].t or 0
        local refT = refTimeAt(ref, refCum, myCum[i])
        local delta = myT - refT                 -- cumulative, ms
        local marginal = delta - prevDelta       -- lost in THIS segment
        prevDelta = delta

        if i > 1 then
            local a, b = mine[i-1], mine[i]
            local colour
            if marginal > 6 then colour = { 235, 45, 45, 180 }      -- losing here
            elseif marginal < -6 then colour = { 40, 220, 90, 150 } -- gaining
            else colour = { 150, 150, 150, 70 } end                 -- neutral
            Segments[#Segments+1] = {
                ax=a.x, ay=a.y, az=a.z, bx=b.x, by=b.y, bz=b.z, c=colour,
            }
            if marginal > LOSS_MIN then
                hot[#hot+1] = { x=b.x, y=b.y, z=b.z, loss=marginal, s=b.s }
            end
        end
    end

    -- Keep only the worst few markers, spaced out (skip near-duplicates)
    table.sort(hot, function(p, q) return p.loss > q.loss end)
    for _, h in ipairs(hot) do
        local near = false
        for _, m in ipairs(Markers) do
            local dx, dy = h.x - m.x, h.y - m.y
            if dx*dx + dy*dy < 900 then near = true break end   -- within 30 m
        end
        if not near then
            Markers[#Markers+1] = {
                x=h.x, y=h.y, z=h.z, loss=h.loss, hint=stateHint(h.s),
            }
            if #Markers >= MARKER_TOP then break end
        end
    end

    return #Segments > 0
end

-- ── Public entry: analyse the lap just driven vs a reference ──────────────────
-- Called from main.lua on LapComplete when coaching is on.
function RL_CoachAnalyse(mine, ref)
    if not CoachOn then return end
    Analyse(mine, ref)
end

function RL_CoachClear()
    Segments, Markers = {}, {}
end

function RL_CoachToggle()
    CoachOn = not CoachOn
    if not CoachOn then RL_CoachClear() end
    return CoachOn
end
exports("IsCoachOn", function() return CoachOn end)

-- ── Draw ──────────────────────────────────────────────────────────────────────

local function drawSeg(s, half, px, py)
    local dx, dy = s.bx - s.ax, s.by - s.ay
    local len = math.sqrt(dx*dx + dy*dy)
    if len < 0.01 then return end
    local ox, oy = -dy/len*half, dx/len*half
    local az, bz = s.az + Z_LIFT, s.bz + Z_LIFT
    local c = s.c
    DrawPoly(s.ax+ox, s.ay+oy, az, s.ax-ox, s.ay-oy, az, s.bx+ox, s.by+oy, bz, c[1],c[2],c[3],c[4])
    DrawPoly(s.bx+ox, s.by+oy, bz, s.ax-ox, s.ay-oy, az, s.ax+ox, s.ay+oy, az, c[1],c[2],c[3],c[4])
    DrawPoly(s.ax-ox, s.ay-oy, az, s.bx-ox, s.by-oy, bz, s.bx+ox, s.by+oy, bz, c[1],c[2],c[3],c[4])
    DrawPoly(s.bx+ox, s.by+oy, bz, s.bx-ox, s.by-oy, bz, s.ax-ox, s.ay-oy, az, c[1],c[2],c[3],c[4])
end

CreateThread(function()
    while true do
        if CoachOn and #Segments > 0 then
            local p = GetEntityCoords(PlayerPedId())
            local half = SEG_WIDTH * 0.5
            local maxSq = DRAW_RANGE * DRAW_RANGE

            for i = 1, #Segments do
                local s = Segments[i]
                local mx, my = (s.ax+s.bx)*0.5 - p.x, (s.ay+s.by)*0.5 - p.y
                if mx*mx + my*my <= maxSq then drawSeg(s, half, p.x, p.y) end
            end

            for i = 1, #Markers do
                local m = Markers[i]
                local dx, dy = m.x - p.x, m.y - p.y
                if dx*dx + dy*dy <= maxSq then
                    SetDrawOrigin(m.x, m.y, m.z + 1.4, 0)
                    SetTextScale(0.34, 0.34)
                    SetTextFont(4)
                    SetTextCentre(true)
                    SetTextColour(255, 80, 80, 220)
                    SetTextOutline()
                    BeginTextCommandDisplayText("STRING")
                    AddTextComponentSubstringPlayerName(
                        ("%s  -%.2fs"):format(m.hint, m.loss / 1000))
                    EndTextCommandDisplayText(0.0, 0.0)
                    ClearDrawOrigin()
                end
            end
            Wait(0)
        else
            Wait(300)
        end
    end
end)
