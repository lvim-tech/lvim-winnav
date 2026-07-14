-- lvim-winnav.mux.tmux: the tmux backend.
--
-- Everything is one `tmux` invocation with an ARGV list, always targeting OUR pane explicitly (`-t
-- $TMUX_PANE`) rather than "the active pane" — Neovim may act while another pane has focus (a `send-keys`
-- from a script, a hook), and the answer must still be about the pane Neovim runs in.
--
-- The edge query is a SINGLE `display-message` that returns every flag the decision needs (the four
-- `pane_at_*` flags and the zoom flag) in one line: a move key must not fork four processes.
--
-- PANE MARKING is the plugin's answer to the `is_vim="ps -o state= -o comm= … | grep -iqE …"` idiom the
-- tmux side conventionally uses: Neovim SETS a pane-scoped user option (`@lvim_nvim`) on entry and clears it
-- on exit, so the tmux bindings test `#{@lvim_nvim}` — a variable lookup instead of a process guess that
-- forks a shell on every keypress and lies under a wrapper / sudo / ssh / a renamed binary.
--
---@module "lvim-winnav.mux.tmux"

local config = require("lvim-winnav.config")
local exec = require("lvim-winnav.mux.exec")
local amount = require("lvim-winnav.amount")

local M = {}

M.name = "tmux"

-- direction → the tmux pane-selection flag, and the `#{pane_at_*}` format that says "no pane that way".
---@type table<LvimWinNavDir, { flag: string, at: string }>
local DIR = {
    left = { flag = "-L", at = "pane_at_left" },
    down = { flag = "-D", at = "pane_at_bottom" },
    up = { flag = "-U", at = "pane_at_top" },
    right = { flag = "-R", at = "pane_at_right" },
}

-- The order the single edge/zoom query returns its flags in.
---@type string[]
local QUERY = { "pane_at_left", "pane_at_bottom", "pane_at_top", "pane_at_right", "window_zoomed_flag" }

--- The tmux executable (config).
---@return string
local function exe()
    return config.multiplexer.commands.tmux
end

--- Our own pane id, from the environment tmux exports into the process it starts.
---@return string?
local function pane()
    local p = os.getenv("TMUX_PANE")
    return (p and p ~= "") and p or nil
end

--- An argv list for a tmux subcommand targeted at OUR pane: `tmux <cmd> -t <pane> <args…>`.
---@param cmd string
---@param args string[]?
---@return string[]
local function argv(cmd, args)
    local a = { exe(), cmd, "-t", pane() or "" }
    for _, v in ipairs(args or {}) do
        a[#a + 1] = v
    end
    return a
end

--- One query for every flag a navigation decision needs (edges + zoom), as `name → "0"|"1"`.
--- An empty table when the query fails (tmux gone) — the caller then treats nothing as known.
---@return table<string, string>
local function flags()
    local fmt = {}
    for i, name in ipairs(QUERY) do
        fmt[i] = "#{" .. name .. "}"
    end
    local ok, out = exec.run(argv("display-message", { "-p", table.concat(fmt, ",") }))
    if not ok then
        return {}
    end
    local values, i = {}, 1
    for value in (out .. ","):gmatch("([^,]*),") do
        values[QUERY[i]] = value
        i = i + 1
    end
    return values
end

--- Does the environment say we are running inside tmux?
---@return boolean
function M.detect()
    local t = os.getenv("TMUX")
    return t ~= nil and t ~= "" and pane() ~= nil
end

--- Is the tmux binary reachable?
---@return boolean
function M.available()
    return exec.has(exe())
end

--- Has OUR pane no neighbour in `dir` (is it at that edge of the tmux window)?
---@param dir LvimWinNavDir
---@return boolean
function M.current_pane_at_edge(dir)
    local d = DIR[dir]
    if not d then
        return true
    end
    local f = flags()
    return f[d.at] ~= "0" -- unknown (a failed query) is treated as "at the edge": never hand off blindly
end

--- Is our pane's window zoomed (one pane blown up over the others)?
---@return boolean
function M.is_zoomed()
    return flags().window_zoomed_flag == "1"
end

--- Select the tmux pane in `dir`.
---@param dir LvimWinNavDir
---@return boolean moved
function M.next_pane(dir)
    local d = DIR[dir]
    if not d then
        return false
    end
    return (exec.run(argv("select-pane", { d.flag })))
end

--- Move OUR pane's border in `dir` by `cells`.
---@param dir LvimWinNavDir
---@param cells integer
---@return boolean resized
function M.resize_pane(dir, cells)
    local d = DIR[dir]
    if not d then
        return false
    end
    return (exec.run(argv("resize-pane", { d.flag, tostring(cells) })))
end

--- Mark (or unmark) our pane with the configured pane option, so the tmux bindings can test `#{@…}`
--- instead of inspecting the pane's process.
---@param on boolean
---@return boolean ok
function M.mark_pane(on)
    local option = config.multiplexer.pane_option
    if on then
        return (exec.run(argv("set-option", { "-p", option, "1" })))
    end
    return (exec.run(argv("set-option", { "-p", "-u", option })))
end

--- Is our pane currently marked? (nil = the query failed.)
---@return boolean? marked
function M.pane_marked()
    local ok, out = exec.run(argv("display-message", { "-p", "#{" .. config.multiplexer.pane_option .. "}" }))
    if not ok then
        return nil
    end
    return out == "1"
end

--- The exact commands the backend runs, keyed by what they do — printed by `:checkhealth`.
---@return table<string, string>
function M.commands()
    return {
        edges = exec.show(argv("display-message", { "-p", "#{pane_at_left},…,#{window_zoomed_flag}" })),
        select = exec.show(argv("select-pane", { DIR.left.flag })),
        resize = exec.show(argv("resize-pane", { DIR.left.flag, tostring(config.default_amount) })),
        mark = exec.show(argv("set-option", { "-p", config.multiplexer.pane_option, "1" })),
    }
end

--- Do the RUNNING tmux's root-table bindings already forward our keys? Returns whether every move key is
--- bound in the root table, and whether those bindings test our PANE OPTION (the modern half) — so health
--- can tell "not bound at all" from "bound the old process-guessing way, which still works".
---@return boolean bound, boolean marks
function M.has_bindings()
    local ok, out = exec.run({ exe(), "list-keys", "-T", "root" })
    if not ok then
        return false, false
    end
    local bound = true
    for _, key in pairs(config.multiplexer.keys.move) do
        -- tmux prints the key as it parsed it (`C-h`); a binding line for it starts with `bind-key -T root C-h`.
        if not out:find("root%s+" .. vim.pesc(key) .. "%s") then
            bound = false
        end
    end
    return bound, out:find(vim.pesc(config.multiplexer.pane_option), 1, true) ~= nil
end

--- The ready-to-paste tmux config block for the CURRENT settings: the mirror bindings that FORWARD our keys
--- into Neovim when the pane is marked, and move / resize the tmux pane when it is not. Nothing here uses the
--- tmux prefix (they are root-table `-n` bindings), so no prefix key can collide with them.
---@return string[] lines
function M.config_block()
    local mux = config.multiplexer
    local step = amount.resolve(config.default_amount, "horizontal")
    -- The whole test: "this pane is marked as running Neovim". A tmux FORMAT (`if-shell -F`) — evaluated
    -- inside tmux, with no shell involved at all (the process-guessing idiom forks `ps | grep` per keypress).
    local guard = ("#{==:#{%s},1}"):format(mux.pane_option)
    local L = {
        "# lvim-winnav — the tmux half of the handoff (generated by :LvimWinNav mux-config)",
        "#",
        "# Neovim MARKS its own pane while it runs (" .. mux.pane_option .. "), so these bindings test a",
        "# tmux VARIABLE instead of guessing the process name with `ps | grep` on every keypress.",
        "# All bindings are root-table (-n): they never use, and never collide with, your prefix key.",
        "",
    }

    ---@param key string
    ---@param fallback string  what tmux does when the pane is NOT running Neovim
    local function bind(key, fallback)
        L[#L + 1] = ("bind-key -n '%s' if-shell -F \"%s\" 'send-keys %s' \"%s\""):format(key, guard, key, fallback)
    end

    for _, dir in ipairs({ "left", "down", "up", "right" }) do
        local d = DIR[dir]
        local select = ("select-pane %s"):format(d.flag)
        if mux.no_wrap then
            -- tmux's own select-pane WRAPS around at the outermost pane; the guard makes it stop there.
            select = ("if-shell -F '#{%s}' '' 'select-pane %s'"):format(d.at, d.flag)
        end
        bind(mux.keys.move[dir], select)
    end
    for _, dir in ipairs({ "left", "down", "up", "right" }) do
        bind(mux.keys.resize[dir], ("resize-pane %s %d"):format(DIR[dir].flag, step))
    end

    L[#L + 1] = ""
    L[#L + 1] = "# The same moves from tmux's copy mode (no Neovim there — always move the pane)."
    for _, dir in ipairs({ "left", "down", "up", "right" }) do
        L[#L + 1] = ("bind-key -T copy-mode-vi '%s' select-pane %s"):format(mux.keys.move[dir], DIR[dir].flag)
    end
    return L
end

return M
