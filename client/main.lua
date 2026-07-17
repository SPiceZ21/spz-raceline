-- client/main.lua
-- Capture: distance-gated samples of the player's position + pedal state while
-- driving. Display: a flat ribbon painted on the road, coloured by what the
-- pedals were doing at that spot (green throttle, red brake, faint white coast).
--
-- Fully standalone — no framework, no server side, no NUI.

local Points     = {}     -- ring buffer of { x, y, z, s, brk }
local Head       = 1      -- next write slot (the oldest entry once full)
local Count      = 0
local Recording  = false
local Visible    = false
local ForceBreak = true   -- next sample starts a new segment run

local Quads = {}          -- precomputed visible ribbon segments

local C = Config.Colours
local StateColour = { [0] = C.coast, [1] = C.accel, [2] = C.brake }

local function Notify(msg)
    BeginTextCommandThefeedPost("STRING")
    AddTextComponentSubstringPlayerName(msg)
    EndTextCommandThefeedPostTicker(false, false)
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
        Wait(Recording and 50 or 400)

        if Recording then
            local ped = PlayerPedId()
            local veh = GetVehiclePedIsIn(ped, false)

            if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped then
                local pos = GetEntityCoords(veh)
                local dx = pos.x - (lastX or pos.x)
                local dy = pos.y - (lastY or pos.y)

                if lastX == nil or (dx * dx + dy * dy) >= Config.SampleDistance ^ 2 then
                    local brk = ForceBreak
                    if lastX and not brk then
                        -- Teleport / respawn: don't draw a line across the map
                        brk = (dx * dx + dy * dy) > Config.BreakDistance ^ 2
                    end
                    PushPoint(pos.x, pos.y, GroundedZ(pos), PedalState(), brk)
                    ForceBreak = false
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
    if on and not Visible then
        -- Seeing the line paint itself live is the point — show it too.
        Visible = true
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
-- For future integration (e.g. spz-races auto-recording a race, or ghost lines
-- loaded from another player) without this resource knowing about any of it.

exports("StartRecording", function() SetRecording(true) end)
exports("StopRecording",  function() SetRecording(false) end)
exports("IsRecording",    function() return Recording end)
exports("SetLineVisible", SetVisible)
exports("IsLineVisible",  function() return Visible end)
exports("ClearLine", function()
    ClearLine()
end)

-- Ordered oldest → newest copy of the current line.
exports("GetLine", function()
    local out = {}
    for k = 0, Count - 1 do
        local p = Points[OrderedIndex(k)]
        out[k + 1] = { x = p.x, y = p.y, z = p.z, s = p.s, brk = p.brk }
    end
    return out
end)

-- Replace the buffer with an externally captured line (same point format).
exports("LoadLine", function(pts)
    if type(pts) ~= "table" then return false end
    ClearLine()
    for i = 1, math.min(#pts, Config.MaxPoints) do
        local p = pts[i]
        if type(p) == "table" and p.x and p.y and p.z then
            PushPoint(p.x + 0.0, p.y + 0.0, p.z + 0.0, p.s or 0, p.brk or (i == 1))
        end
    end
    return Count > 0
end)
