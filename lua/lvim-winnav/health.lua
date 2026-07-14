-- lvim-winnav.health: :checkhealth lvim-winnav.
--
-- The one question this plugin gets asked is "why doesn't the handoff work", and the answer is almost never
-- the Neovim half — it is the MULTIPLEXER's half: its binary is not reachable, its bindings are not
-- installed, or the pane is not marked. So the report answers exactly that, with evidence:
--   • which multiplexer was detected, and from which environment variable
--   • whether its binary is reachable, and the EXACT commands the plugin would run
--   • whether THIS pane is currently marked as running Neovim (`@lvim_nvim`)
--   • whether the RUNNING multiplexer already forwards the keys (and whether those bindings use the mark)
--   • the effective edge behaviour per direction, and which optional integrations are present
-- Read-only: nothing is mutated, nothing is marked, no pane is selected.
--
---@module "lvim-winnav.health"

local config = require("lvim-winnav.config")
local mux = require("lvim-winnav.mux")
local amount = require("lvim-winnav.amount")

local M = {}

---@type LvimWinNavDir[]
local DIRS = { "left", "down", "up", "right" }

--- The environment variable that betrays each multiplexer.
---@type table<string, string>
local ENV = { tmux = "TMUX", wezterm = "WEZTERM_PANE", kitty = "KITTY_LISTEN_ON", zellij = "ZELLIJ" }

--- Report the multiplexer half.
---@param health table
---@return nil
local function check_multiplexer(health)
    local want = config.multiplexer.backend
    if want == false then
        health.info("multiplexer: disabled (`multiplexer.backend = false`) — edges behave as `stop`")
        return
    end

    local backend = mux.get()
    if not backend then
        local seen = {}
        for name, var in pairs(ENV) do
            if (os.getenv(var) or "") ~= "" then
                seen[#seen + 1] = ("%s ($%s)"):format(name, var)
            end
        end
        if #seen == 0 then
            health.info("no multiplexer detected (no $TMUX / $WEZTERM_PANE / $KITTY_LISTEN_ON / $ZELLIJ)")
            health.info("edges configured as `multiplexer` behave as `stop` — this is not an error")
        else
            health.warn(("%s is running, but its binary is not on $PATH"):format(table.concat(seen, ", ")))
        end
        return
    end

    health.ok(("multiplexer: %s (detected via $%s)"):format(backend.name, ENV[backend.name] or "environment"))
    health.ok(("binary reachable: %s"):format(config.multiplexer.commands[backend.name]))

    for what, cmd in pairs(backend.commands()) do
        health.info(("%-6s ➤ %s"):format(what, cmd))
    end

    if config.multiplexer.mark_pane then
        local marked = backend.pane_marked()
        if marked == true then
            health.ok(("this pane is marked: %s = 1"):format(config.multiplexer.pane_option))
        elseif marked == false then
            health.warn(
                ("this pane is NOT marked (%s unset) — call require('lvim-winnav').setup()"):format(
                    config.multiplexer.pane_option
                )
            )
        else
            health.info(
                ("%s does not support pane marking — its side tests the pane's process instead"):format(backend.name)
            )
        end
    else
        health.info("pane marking is off (`multiplexer.mark_pane = false`) — the multiplexer side must guess")
    end

    local bound, marks = backend.has_bindings()
    if bound and marks then
        health.ok("the running multiplexer forwards the keys, testing the pane mark")
    elseif bound then
        health.warn("the multiplexer forwards the keys, but not via the pane mark (a process guess per keypress)")
        health.info("`:LvimWinNav mux-config` prints the mark-based block; the tpm plugin installs it")
    else
        health.warn("the running multiplexer does NOT forward the keys — the handoff cannot reach Neovim")
        health.info("run `:LvimWinNav mux-config` and paste the block, or install the tpm plugin lvim-tech/lvim-winnav")
    end

    if backend.is_zoomed() then
        health.info("this pane is ZOOMED" .. (config.disable_multiplexer_nav_when_zoomed and " — no handoff" or ""))
    end
end

--- Entry point for `:checkhealth lvim-winnav`.
---@return nil
function M.check()
    local health = vim.health
    health.start("lvim-winnav")

    if pcall(require, "lvim-utils.highlight") and pcall(require, "lvim-ui") then
        health.ok("lvim-utils + lvim-ui found (the resize-mode hint bar)")
    else
        health.error("lvim-utils / lvim-ui not found — the resize-mode hint bar is unavailable")
    end

    if pcall(require, "lvim-winmove") then
        health.ok("lvim-winmove found (a directional swap delegates the exchange to it)")
    else
        health.info("lvim-winmove not found — `:LvimWinNav swap` is unavailable (nothing else is affected)")
    end

    local ok_msg, msgarea = pcall(require, "lvim-msgarea")
    if config.dock.enabled and ok_msg and type(msgarea.focus_content) == "function" then
        health.ok("lvim-msgarea found — an edge move DOWN descends into the docked zone first")
    elseif config.dock.enabled then
        health.info("lvim-msgarea not found — there is no dock to descend into (the edge behaviour runs)")
    else
        health.info("dock integration is off (`dock.enabled = false`)")
    end

    -- The effective edge behaviour, per direction (an `at_edge` table is easy to get subtly wrong).
    local nav = require("lvim-winnav.nav")
    local per = {}
    for _, dir in ipairs(DIRS) do
        per[#per + 1] = ("%s=%s"):format(dir, nav.edge_behaviour(dir))
    end
    health.info("at_edge ➤ " .. table.concat(per, "  "))

    local step = config.default_amount
    health.info(
        ("resize step ➤ %s (%d cells horizontally, %d vertically at this size)"):format(
            tostring(step),
            amount.resolve(step, "horizontal"),
            amount.resolve(step, "vertical")
        )
    )

    check_multiplexer(health)
end

return M
