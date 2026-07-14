-- lvim-winnav.resize: resizing with the semantics a key press actually means.
--
-- ONE invariant, everywhere: **the boundary in the pressed direction moves in that direction.** With two
-- vertical splits `A│B`, `resize left` moves the shared boundary left — so A (whose boundary that is on its
-- right) SHRINKS and B (whose boundary that is on its left) GROWS. The same key, the same visible effect, in
-- every window; `:vertical resize +N` alone cannot express that, because whether a window grows or shrinks
-- depends on which side of the boundary it sits on.
--
-- The resolution is therefore a BOUNDARY, not a window:
--   • the boundary in `dir` — the one between the window and its neighbour that way — when there is one;
--   • else (the window is at that edge of the layout) the boundary on the OPPOSITE side, which is the only
--     one it has: pushing it in `dir` shrinks / grows the window instead. That is the parity behaviour;
--   • else (no boundary on that axis at all — a single row/column) the boundary in `dir` belongs to the
--     MULTIPLEXER: it is the tmux pane border. So at the OUTERMOST edge the same key resizes the PANE
--     (`at_edge = "multiplexer"`), which is exactly the same invariant one level up.
--
-- The move itself is executed from the LEFT/UPPER window of the pair, because that is where Vim's own
-- `:resize` is unambiguous: growing a window takes the cells from the neighbour BELOW/RIGHT of it, shrinking
-- gives them back — i.e. it always moves the boundary the pair shares.
--
-- Interactive RESIZE MODE is a modal `getcharstr` loop (no keymaps are installed, nothing to clean up): the
-- keys resize the REAL window while it stays current, and the live keys + the window's size are announced on
-- the non-focusable `lvim-ui.hint` bar above the statusline.
--
---@module "lvim-winnav.resize"

local api = vim.api
local fn = vim.fn
local config = require("lvim-winnav.config")
local guard = require("lvim-winnav.guard")
local nav = require("lvim-winnav.nav")
local mux = require("lvim-winnav.mux")
local amount = require("lvim-winnav.amount")

local M = {}

-- direction → the axis it resizes on, and which member of the boundary pair the window is.
---@type table<LvimWinNavDir, { axis: "horizontal"|"vertical", grow: boolean }>
local AXIS = {
    left = { axis = "horizontal", grow = false }, -- the boundary moves LEFT  ⇒ the pair's left window shrinks
    right = { axis = "horizontal", grow = true }, -- the boundary moves RIGHT ⇒ the pair's left window grows
    up = { axis = "vertical", grow = false },
    down = { axis = "vertical", grow = true },
}

---@type boolean  resize mode owns the keyboard
local in_mode = false

---@type LvimUiHintHandle?  the hint bar of the active resize mode
local hint = nil

--- Apply a size delta to `win` on `axis` (Vim's own resize, run in that window's context).
---@param win integer
---@param axis "horizontal"|"vertical"
---@param delta integer
---@return nil
local function apply(win, axis, delta)
    api.nvim_win_call(win, function()
        if axis == "horizontal" then
            vim.cmd(("vertical resize %+d"):format(delta))
        else
            vim.cmd(("resize %+d"):format(delta))
        end
    end)
end

--- The window whose resize MOVES the boundary in `dir`: the LEFT/UPPER member of the pair that boundary
--- divides (see the module header), plus whether that window must grow or shrink. nil when the current
--- window has no boundary on that axis (the multiplexer's border is the only one there).
---@param win integer
---@param dir LvimWinNavDir
---@return integer? anchor, boolean grow
local function boundary(win, dir)
    local spec = AXIS[dir]
    local ahead = nav.neighbour(win, dir)
    if ahead then
        -- The boundary in `dir` exists. Its left/upper member is `win` for right/down, the neighbour for
        -- left/up.
        local anchor = (dir == "right" or dir == "down") and win or ahead
        return anchor, spec.grow
    end
    -- At the `dir` edge: fall back to the boundary on the other side (the only one this window has).
    local behind = nav.neighbour(win, ({ left = "right", right = "left", up = "down", down = "up" })[dir])
    if behind then
        local anchor = (dir == "right" or dir == "down") and behind or win
        return anchor, spec.grow
    end
    return nil, spec.grow
end

--- Resize by moving the boundary in `dir` (see the module header). `step` overrides `config.default_amount`
--- for this call; a percentage string is resolved against the parent container.
---@param dir LvimWinNavDir
---@param step integer|string|nil
---@return boolean resized
function M.resize(dir, step)
    local spec = AXIS[dir]
    if not spec then
        return false
    end
    local win = api.nvim_get_current_win()
    if not guard.resizable(win, spec.axis) then
        return false
    end
    local cells = amount.resolve(step or config.default_amount, spec.axis, win)

    local anchor, grow = boundary(win, dir)
    if anchor then
        if not guard.resizable(anchor, spec.axis) then
            return false
        end
        apply(anchor, spec.axis, grow and cells or -cells)
        return true
    end

    -- No boundary inside Neovim on this axis: the border in `dir` is the multiplexer's pane border. The same
    -- invariant, one level up — but only when the edge is configured to reach for the multiplexer.
    if nav.edge_behaviour(dir) == "multiplexer" then
        return mux.resize(dir, cells)
    end
    return false
end

-- ── interactive resize mode ──────────────────────────────────────────────────

--- The hint-bar records for the mode: a key badge per direction, the `➤` pointer, the live window size.
---@return table[] items
local function hint_items()
    local rm = config.resize_mode
    local icons = config.icons
    local key_hl = { icon = { normal = "LvimWinNavHintKey" }, text = { normal = "LvimWinNavHintLabel" } }
    local items = {
        {
            name = rm.title,
            icon = icons.mode,
            style = "tab",
            hl = { icon = { normal = "LvimWinNavHintKey" }, text = { normal = "LvimWinNavHintLabel" } },
        },
    }
    for _, dir in ipairs({ "left", "down", "up", "right" }) do
        items[#items + 1] = { key = rm.keys[dir], name = rm.labels[dir], hl = key_hl }
    end
    items[#items + 1] = { key = rm.keys.quit[1], name = rm.labels.quit, hl = key_hl }
    items[#items + 1] = {
        type = "separator",
        text = icons.separator,
        style = { padding = { 1, 1 }, hl = "LvimWinNavHintSep" },
    }
    local win = api.nvim_get_current_win()
    items[#items + 1] = {
        name = rm.size_format:format(api.nvim_win_get_width(win), api.nvim_win_get_height(win)),
        style = "plain",
        hl = { text = { normal = "LvimWinNavHintSize" } },
    }
    return items
end

--- Is resize mode active?
---@return boolean
function M.active()
    return in_mode
end

--- Leave resize mode (closing the hint bar and firing the leave hook). Safe to call when not in it.
---@return nil
function M.stop()
    if not in_mode then
        return
    end
    in_mode = false
    if hint then
        hint:close()
        hint = nil
    end
    local hooks = config.resize_mode.hooks
    if type(hooks.on_leave) == "function" then
        hooks.on_leave()
    end
    vim.cmd("redraw")
end

--- Enter resize mode: plain h/j/k/l (the configured keys) resize the CURRENT window until a quit key. A
--- modal `getcharstr` loop — no keymaps are installed and nothing is left behind if it is interrupted.
---@return nil
function M.start()
    if in_mode then
        return
    end
    in_mode = true

    local rm = config.resize_mode
    local hooks = rm.hooks
    if type(hooks.on_enter) == "function" then
        hooks.on_enter()
    end

    -- raw keystroke → the direction it resizes / the quit action.
    local km = {}
    local function tc(key)
        return api.nvim_replace_termcodes(key, true, false, true)
    end
    for _, dir in ipairs({ "left", "down", "up", "right" }) do
        km[tc(rm.keys[dir])] = dir
    end
    for _, key in ipairs(rm.keys.quit or {}) do
        km[tc(key)] = "quit"
    end

    if rm.show_footer then
        hint = require("lvim-ui").hint({ fill_hl = "LvimWinNavHintFill" })
        hint:show(hint_items())
    end

    while in_mode do
        vim.cmd("redraw")
        local ok, ch = pcall(fn.getcharstr)
        if not ok then
            break
        end
        local action = km[ch]
        if action == "quit" then
            break
        elseif action then
            M.resize(action)
            if hint then
                hint:update(hint_items()) -- the size cell follows the window it just resized
            end
        end
        -- an unmapped key is ignored: the mode is left with a quit key
    end

    M.stop()
end

--- Toggle the mode.
---@return nil
function M.toggle()
    if in_mode then
        M.stop()
    else
        M.start()
    end
end

--- The size of the current window, for a consumer that wants the same reading the hint bar shows.
---@return integer width, integer height
function M.size()
    local win = api.nvim_get_current_win()
    return api.nvim_win_get_width(win), api.nvim_win_get_height(win)
end

return M
