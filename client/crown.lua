-- client/crown.lua
-- Record-holder feedback. The crown itself is rendered on the nametag plate
-- (spz-nametag reads the spz:records statebag); this file only handles the
-- steal toast and the ownership-tax payout notify.

RegisterNetEvent("SPZ:recordStolen", function(d)
    if not d or not d.text then return end
    lib.notify({
        title       = "TRACK RECORD",
        description  = d.text,
        type        = "warning",
        duration    = 7000,
        position    = "top",
        icon        = "crown",
    })
end)

-- Track ownership tax payout.
RegisterNetEvent("SPZ:trackTax", function(d)
    if not d or not d.credits then return end
    lib.notify({
        title       = "TRACK OWNERSHIP",
        description  = ("+%d credits — %d record%s held")
            :format(d.credits, d.tracks or 1, (d.tracks or 1) == 1 and "" or "s"),
        type        = "success",
        position    = "top",
        icon        = "coins",
    })
end)
