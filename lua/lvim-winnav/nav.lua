-- lvim-winnav.nav: directional navigation, and what happens at the EDGE.
--
-- Adjacency is Vim's OWN (`winnr("h"/"j"/"k"/"l")` evaluated in the window's context) — the same relation
-- CTRL-W h/j/k/l uses, so a move never disagrees with the editor's idea of "the window to my left". When
-- there is no window that way, the window is at the EDGE of the Neovim layout and `at_edge` decides:
--
--   dock        focus the docked lvim panel that way (the message zone below the editor / the dock stack)
--   multiplexer select the tmux / wezterm / kitty / zellij pane that way (none ⇒ nothing happens)
--   wrap        jump to the window at the OPPOSITE edge of the same row/column
--   split       open a new split that way
--   stop        do nothing
--
-- The DOCK is asked FIRST regardless of the configured behaviour (unless `dock.enabled = false`): a docked
-- panel in that direction is INSIDE Neovim, so leaving for a tmux pane while the message zone sits right
-- there is never what the user meant. That is the config value replacing the hand-written `<C-j>` wrapper
-- ("descend into the message zone, else navigate").
--
---@module "lvim-winnav.nav"

local api = vim.api
local fn = vim.fn
local config = require("lvim-winnav.config")
local mux = require("lvim-winnav.mux")

local M = {}

-- direction → the `wincmd` motion letter (adjacency AND the move itself).
---@type table<LvimWinNavDir, string>
local MOTION = { left = "h", down = "j", up = "k", right = "l" }

-- direction → its opposite (used to wrap, and to find the far window of a row/column).
---@type table<LvimWinNavDir, LvimWinNavDir>
local OPPOSITE = { left = "right", down = "up", up = "down", right = "left" }

-- direction → how a new split that way is opened.
---@type table<LvimWinNavDir, string>
local SPLIT = {
    left = "aboveleft vsplit",
    right = "belowright vsplit",
    up = "aboveleft split",
    down = "belowright split",
}

--- The window immediately in `dir` of `win`, or nil when `win` is at that edge of the layout.
---@param win integer
---@param dir LvimWinNavDir
---@return integer? neighbour
function M.neighbour(win, dir)
    local motion = MOTION[dir]
    if not motion or not api.nvim_win_is_valid(win) then
        return nil
    end
    local nr = api.nvim_win_call(win, function()
        return fn.winnr(motion)
    end)
    local nb = fn.win_getid(nr)
    if nb == 0 or nb == win then
        return nil -- winnr(<motion>) answers with the current window when there is nothing that way
    end
    return nb
end

--- Is `win` at the `dir` edge of the Neovim layout (no window that way)?
---@param win integer
---@param dir LvimWinNavDir
---@return boolean
function M.at_edge(win, dir)
    return M.neighbour(win, dir) == nil
end

--- The configured edge behaviour for `dir` (`at_edge` is one value for every direction, or a per-direction
--- table — an unlisted direction falls back to "stop").
---@param dir LvimWinNavDir
---@return LvimWinNavEdge
function M.edge_behaviour(dir)
    local at = config.at_edge
    if type(at) == "table" then
        return at[dir] or "stop"
    end
    return at
end

--- Focus the docked lvim panel in `dir`, if there is one. Only DOWN has a dock today: the message zone (and,
--- through its registered descend fallback, a bottom/float dock consumer) sits below the editor. This is the
--- ONE seam — `lvim-msgarea.focus_content()` — the zone itself publishes for exactly this key; the dock stack
--- registers its own descend INTO it, so a single call covers both. Absent plugins ⇒ false (no dock).
---@param dir LvimWinNavDir
---@return boolean focused
function M.focus_dock(dir)
    if dir ~= "down" then
        return false
    end
    local ok, msgarea = pcall(require, "lvim-msgarea")
    if not ok or type(msgarea.focus_content) ~= "function" then
        return false
    end
    local focused, res = pcall(msgarea.focus_content)
    return focused and res == true
end

--- Wrap to the far window at the OPPOSITE edge, by walking back as far as the layout goes — the window the
--- user would reach by holding the opposite key.
---@param dir LvimWinNavDir
---@return boolean moved
local function wrap(dir)
    local back = OPPOSITE[dir]
    local cur = api.nvim_get_current_win()
    local far = M.neighbour(cur, back)
    if not far then
        return false -- a single window on that axis: there is nothing to wrap to
    end
    while far do
        api.nvim_set_current_win(far)
        far = M.neighbour(far, back)
    end
    return true
end

--- Run the edge behaviour for `dir`. When `dock.enabled` the DOCK is offered FIRST, whatever the behaviour
--- is (a docked panel that way is still inside Neovim — see the module header).
---@param dir LvimWinNavDir
---@return boolean acted
function M.at_edge_action(dir)
    local docks = config.dock.enabled
    if docks and M.focus_dock(dir) then
        return true
    end
    local behaviour = M.edge_behaviour(dir)
    if behaviour == "multiplexer" then
        return mux.move(dir)
    elseif behaviour == "wrap" then
        return wrap(dir)
    elseif behaviour == "split" then
        vim.cmd(SPLIT[dir])
        return true
    elseif behaviour == "dock" then
        -- The dock, and nothing else. Already offered above when `dock.enabled`; otherwise this explicit
        -- behaviour still asks for it (the value names the target, the flag only drives the pre-check).
        return (not docks) and M.focus_dock(dir) or false
    end
    return false -- "stop"
end

--- Move the cursor to the window in `dir`; at the edge, run the configured edge behaviour.
---@param dir LvimWinNavDir
---@return boolean moved
function M.move(dir)
    if not MOTION[dir] then
        return false
    end
    local cur = api.nvim_get_current_win()
    local nb = M.neighbour(cur, dir)
    if nb then
        api.nvim_set_current_win(nb)
        return true
    end
    return M.at_edge_action(dir)
end

return M
