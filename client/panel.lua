-- client/panel.lua
-- Control panel for the racing line and the ghost car.
--
-- Everything here was already controllable — through `/raceline show|hide|ghost
-- [pb|record|pace]`, a config file the player cannot open, and an unbound key.
-- That is a control surface for the person who wrote it. This is the same set of
-- controls as an ox_lib menu, plus a radial entry, so a driver can change the
-- reference they are racing against between laps without typing.
--
-- The menus are REBUILT on every open rather than registered once at startup.
-- ox_lib context options are a static snapshot: an option registered at load
-- would say "Ghost: OFF" forever. Rebuilding is cheap (a few tables) and it is
-- the only way each row can read as the live state of the thing it toggles.

local PANEL   = 'spz_rl_panel'
local LINE    = 'spz_rl_line'
local GHOST   = 'spz_rl_ghost'
local MODE    = 'spz_rl_ghost_mode'
local RADIAL  = 'spz_rl_radial'

local function fmtMs(ms)
    if not ms or ms <= 0 then return '—' end
    return ('%d:%05.2f'):format(math.floor(ms / 60000), (ms % 60000) / 1000)
end

local function notify(msg, kind)
    lib.notify({ title = 'Raceline', description = msg, type = kind or 'inform', duration = 2500 })
end

-- Colour carries the state as fast as the words do: green is live, grey is off.
local ON_COLOUR  = '#3ad45a'
local OFF_COLOUR = '#8a8a8a'

local MODE_LABEL = {
    pb     = 'Your best lap',
    record = 'Track record',
    pace   = 'Session pace',
}

local MODE_DESC = {
    pb     = 'Your own fastest stored lap for this track.',
    record = 'The record holder\'s actual lap, in gold. The one to beat.',
    pace   = 'Your line replayed at this session\'s average lap — beatable today.',
}

local buildMenus   -- forward declaration: the option callbacks re-open the menus

--- Re-open a menu after changing something through it, so the row the player
--- just pressed reflects what it now does.
local function reopen(id)
    buildMenus()
    lib.showContext(id)
end

-- ── Racing line ───────────────────────────────────────────────────────────────

local function lineOptions()
    local s = RL_LineStatus()

    return {
        {
            title       = s.visible and 'Display: ON' or 'Display: OFF',
            description = s.points > 0
                and ('%d points%s%s'):format(
                        s.points,
                        s.track and (' · ' .. s.track) or '',
                        s.best and (' · ' .. fmtMs(s.best)) or '')
                or 'No line loaded — drive a lap or come near a stored track',
            icon        = 'route',
            iconColor   = s.visible and ON_COLOUR or OFF_COLOUR,
            onSelect    = function()
                RL_SetLineVisible(not s.visible)
                reopen(LINE)
            end,
        },
        {
            title       = 'Ribbon width',
            description = ('%.2f m'):format(Config.LineWidth),
            icon        = 'arrows-left-right',
            onSelect    = function()
                local r = lib.inputDialog('Racing line', {
                    { type = 'slider', label = 'Ribbon width (m)', min = 10, max = 120,
                      default = math.floor(Config.LineWidth * 100), step = 5 },
                })
                if r and r[1] then Config.LineWidth = r[1] / 100 end
                reopen(LINE)
            end,
        },
        {
            title       = 'Draw distance',
            description = ('%d m of line rendered ahead'):format(math.floor(Config.DrawDistance)),
            icon        = 'eye',
            onSelect    = function()
                local r = lib.inputDialog('Racing line', {
                    { type = 'slider', label = 'Draw distance (m)', min = 40, max = 400,
                      default = math.floor(Config.DrawDistance), step = 10 },
                })
                if r and r[1] then Config.DrawDistance = r[1] + 0.0 end
                reopen(LINE)
            end,
        },
        {
            title       = 'Clear loaded line',
            description = 'Empties the display buffer. Auto-load can bring it back near a stored track.',
            icon        = 'trash',
            disabled    = s.points == 0,
            onSelect    = function()
                RL_ClearDisplay()
                notify('Line cleared', 'success')
                reopen(LINE)
            end,
        },
    }
end

-- ── Ghost ─────────────────────────────────────────────────────────────────────

local function modeOptions()
    local cur = RL_GhostGetMode()
    local out = {}

    for _, mode in ipairs({ 'pb', 'record', 'pace' }) do
        out[#out + 1] = {
            title       = MODE_LABEL[mode] .. (mode == cur and '  ✓' or ''),
            description = MODE_DESC[mode],
            icon        = mode == 'record' and 'trophy' or (mode == 'pace' and 'gauge-high' or 'user'),
            iconColor   = mode == cur and ON_COLOUR or nil,
            onSelect    = function()
                RL_GhostSetMode(mode)
                -- Deliberate: the mode change deletes the current ghost, so it
                -- takes effect at the START of the next lap, not mid-corner.
                notify('Ghost: ' .. MODE_LABEL[mode] .. ' (from next lap)', 'success')
                reopen(GHOST)
            end,
        }
    end

    return out
end

local function ghostOptions()
    local g = RL_GhostStatus()

    return {
        {
            title       = g.on and 'Ghost car: ON' or 'Ghost car: OFF',
            description = (not g.track) and 'Not in a time trial — the ghost runs on TT laps'
                or (g.running and 'Running now'
                or (g.hasLine and 'Ready — spawns at the next lap start'
                or 'No stored lap for this track in this mode')),
            icon        = 'ghost',
            iconColor   = g.on and ON_COLOUR or OFF_COLOUR,
            onSelect    = function()
                RL_GhostSetOn(not g.on)
                reopen(GHOST)
            end,
        },
        {
            title       = 'Racing against',
            description = MODE_LABEL[g.mode] or g.mode,
            icon        = 'flag-checkered',
            arrow       = true,
            menu        = MODE,
        },
        {
            title       = 'Opacity',
            description = ('%d / 255'):format(g.alpha),
            icon        = 'droplet',
            onSelect    = function()
                local r = lib.inputDialog('Ghost car', {
                    { type = 'slider', label = 'Opacity', min = 20, max = 255,
                      default = g.alpha, step = 5 },
                })
                if r and r[1] then RL_GhostSetAlpha(r[1]) end
                reopen(GHOST)
            end,
        },
        {
            title       = g.blip and 'Map blip: ON' or 'Map blip: OFF',
            description = 'Purple blip on the ghost. Off keeps a sprint honest — no preview of the line ahead.',
            icon        = 'location-dot',
            iconColor   = g.blip and ON_COLOUR or OFF_COLOUR,
            onSelect    = function()
                RL_GhostSetBlip(not g.blip)
                reopen(GHOST)
            end,
        },
        {
            title       = g.spec and 'Rebuild the car: ON' or 'Rebuild the car: OFF',
            description = 'Ghost wears the paint, mods and wheels the lap was set with.',
            icon        = 'palette',
            iconColor   = g.spec and ON_COLOUR or OFF_COLOUR,
            onSelect    = function()
                Config.Ghost.applySpec = not g.spec
                notify('Applies from the next lap', 'inform')
                reopen(GHOST)
            end,
        },
        {
            title       = g.wheels and 'Recorded wheels: ON' or 'Recorded wheels: OFF',
            description = 'Replays the real per-wheel rotation (lockups, wheelspin) instead of faking it from speed.',
            icon        = 'circle-notch',
            iconColor   = g.wheels and ON_COLOUR or OFF_COLOUR,
            onSelect    = function()
                Config.Ghost.applyWheels = not g.wheels
                reopen(GHOST)
            end,
        },
        {
            title       = 'Lap diagnostics',
            description = 'What the loaded lap actually contains — answers "why does the ghost pace flat?"',
            icon        = 'stethoscope',
            onSelect    = function()
                local d = RL_GhostDiagnostics and RL_GhostDiagnostics()
                if not d then
                    notify('No lap loaded for this track in ' .. (MODE_LABEL[RL_GhostGetMode()] or '?') .. ' mode', 'error')
                    return reopen(GHOST)
                end

                lib.alertDialog({
                    header  = 'Ghost lap · ' .. (MODE_LABEL[d.mode] or d.mode),
                    content = table.concat({
                        ('**Lap:** %s%s'):format(fmtMs(d.lapMs), d.holder and (' — ' .. d.holder) or ''),
                        ('**Replay:** %s'):format(d.motion
                            and ('full motion, ' .. d.motion .. ' samples')
                            or 'legacy line only (flat path)'),
                        ('**Points:** %d'):format(d.points),
                        ('**Speed:** min %.0f · avg %.0f · max %.0f km/h'):format(d.minKmh, d.avgKmh, d.maxKmh),
                        ('**Spread:** %.0f km/h%s'):format(d.spread,
                            d.spread < 15 and '  ← near zero means the STORED lap is constant pace, not the replay' or ''),
                    }, '  \n'),
                    centered = true,
                })
                reopen(GHOST)
            end,
        },
    }
end

-- ── Panel root ────────────────────────────────────────────────────────────────

buildMenus = function()
    local s = RL_LineStatus()
    local g = RL_GhostStatus()

    lib.registerContext({
        id      = PANEL,
        title   = 'Raceline',
        options = {
            {
                title       = 'Racing line',
                description = s.visible
                    and (s.points > 0 and ('Shown · %d points%s'):format(s.points, s.track and (' · ' .. s.track) or '')
                                       or 'Shown, but nothing loaded')
                    or 'Hidden',
                icon        = 'route',
                iconColor   = (s.visible and s.points > 0) and ON_COLOUR or OFF_COLOUR,
                arrow       = true,
                menu        = LINE,
            },
            {
                title       = 'Ghost car',
                description = g.on and (MODE_LABEL[g.mode] .. (g.running and ' · running' or '')) or 'Off',
                icon        = 'ghost',
                iconColor   = g.on and ON_COLOUR or OFF_COLOUR,
                arrow       = true,
                menu        = GHOST,
            },
            {
                -- The one thing worth a single press: everything visible off,
                -- for a clean lap or a screenshot.
                title       = 'Hide everything',
                description = 'Line off and ghost off in one press',
                icon        = 'eye-slash',
                disabled    = not (s.visible or g.on),
                onSelect    = function()
                    RL_SetLineVisible(false)
                    RL_GhostSetOn(false)
                    notify('Line and ghost off', 'success')
                    reopen(PANEL)
                end,
            },
        },
    })

    lib.registerContext({ id = LINE,  title = 'Racing line', menu = PANEL, options = lineOptions() })
    lib.registerContext({ id = GHOST, title = 'Ghost car',   menu = PANEL, options = ghostOptions() })
    lib.registerContext({ id = MODE,  title = 'Racing against', menu = GHOST, options = modeOptions() })
end

local function OpenPanel(id)
    buildMenus()
    lib.showContext(id or PANEL)
end

-- ── Radial ────────────────────────────────────────────────────────────────────
--
-- The radial is the in-car surface: four presses that matter while driving, with
-- the full panel one step further in. The submenu is registered once — its items
-- are static ACTIONS, not state readouts, so nothing here goes stale (which is
-- exactly the opposite of the context menus above, and why they are rebuilt).

lib.registerRadial({
    id    = RADIAL,
    items = {
        {
            id    = 'rl_line',
            icon  = 'route',
            label = 'Line',
            onSelect = function()
                local on = not RL_LineVisible()
                RL_SetLineVisible(on)
            end,
        },
        {
            id    = 'rl_ghost',
            icon  = 'ghost',
            label = 'Ghost',
            onSelect = function()
                local on = RL_GhostSetOn(not RL_GhostIsOn())
                notify(on and 'Ghost car ON' or 'Ghost car OFF', on and 'success' or 'inform')
            end,
        },
        {
            id    = 'rl_mode',
            icon  = 'flag-checkered',
            label = 'Ghost Mode',
            onSelect = function()
                -- Cycle rather than open a submenu: at speed this is the press
                -- you want, and there are only three modes.
                local order = { pb = 'record', record = 'pace', pace = 'pb' }
                local nextMode = order[RL_GhostGetMode()] or 'pb'
                RL_GhostSetMode(nextMode)
                notify('Ghost: ' .. MODE_LABEL[nextMode] .. ' (from next lap)', 'success')
            end,
        },
        {
            id    = 'rl_panel',
            icon  = 'sliders',
            label = 'Settings',
            onSelect = function() OpenPanel() end,
        },
    },
})

-- The ROOT entry that opens this ring is added by spz-core's radial (Racing →
-- Raceline), not here. spz-core rebuilds the root on every race-state change
-- with lib.clearRadialItems(), which drops root items belonging to any
-- resource — an entry added here survived only until the next state change,
-- which is why the menu appeared to vanish and leave a bare toggle behind.
-- Submenus are not cleared, so registering the ring above is enough.

-- ── Entry points ──────────────────────────────────────────────────────────────

RegisterCommand('racelinepanel', function() OpenPanel() end, false)
-- F3 — free across every spz resource. Registry: Docs/keybinds.md
RegisterKeyMapping('racelinepanel', 'Raceline: Control panel', 'keyboard', 'F3')

-- `/raceline` with no arguments used to print a usage string. It opens the panel
-- instead: the usage string existed because there was nowhere to look. main.lua
-- owns that command and loads before this file, so it reaches the panel through
-- this global (set at load, read at command time — never nil in practice).
RL_OpenPanel = OpenPanel

exports('OpenPanel', OpenPanel)
