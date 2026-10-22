-- client/crown.lua
-- Record-holder feedback. The crown itself is rendered on the nametag plate
-- (spz-nametag reads the spz:records statebag); this file only handles the
-- steal toast and the ownership-tax payout notify.

-- Shown as a centre-screen flourish (spz-raceUI); ox_lib toast if it is off.
local function flourish(d, toast)
    if GetResourceState("spz-raceUI") == "started" then
        exports["spz-raceUI"]:ShowFlourish(d)
    else
        lib.notify(toast)
    end
end

RegisterNetEvent("SPZ:recordStolen", function(d)
    if not d or not d.text then return end
    flourish({ icon = "crown", title = "Track record!", value = d.text, color = "#f5b942", ms = 3600 },
        { title = "TRACK RECORD", description = d.text, type = "warning", duration = 7000, icon = "crown" })
end)

-- Track ownership tax payout.
RegisterNetEvent("SPZ:trackTax", function(d)
    if not d or not d.credits then return end
    local held = d.tracks or 1
    local recs = ("%d record%s"):format(held, held == 1 and "" or "s")
    flourish({ icon = "coins", title = "Track ownership", value = ("+$%d - %s"):format(d.credits, recs),
               color = "#22c55e", ms = 3000 },
        { title = "TRACK OWNERSHIP", type = "success", icon = "coins",
          description = ("+%d credits - %s held"):format(d.credits, recs) })
end)
