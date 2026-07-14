-- lvim-winnav.mux: the multiplexer BACKEND interface + detection.
--
-- One small interface, four implementations (tmux · wezterm · kitty · zellij) — adding a multiplexer is a
-- FILE, not a refactor:
--
--   detect()                  the environment says we run inside it
--   available()               its binary is reachable
--   current_pane_at_edge(dir) our pane has no neighbour that way — or nil: this multiplexer cannot be ASKED
--                             (kitty / zellij expose no edge query), in which case the MOVE answers instead:
--                             it fails / no-ops when there is nothing that way. Never a guess.
--   next_pane(dir)            select the pane that way (its success IS "there was one")
--   resize_pane(dir, cells)   move our pane's border that way
--   is_zoomed()               our pane is blown up over the others
--   mark_pane(on)             mark/unmark our pane as "Neovim runs here"
--   pane_marked()             is it marked right now?
--   has_bindings()            does the RUNNING multiplexer already forward our keys?
--   config_block()            the ready-to-paste config for its own side
--   commands()                the exact argv lists it runs (for :checkhealth)
--
-- Detection is the ENVIRONMENT, in preference order, and it degrades: no multiplexer, a disabled backend or
-- a missing binary is not an error — it simply means there is no pane next door, so an edge behaviour of
-- "multiplexer" behaves as "stop". Resolution is cached (the terminal we run in does not change) and can be
-- dropped with `M.reset()` after a `setup()` that changes the backend.
--
---@module "lvim-winnav.mux"

local config = require("lvim-winnav.config")

local M = {}

---@class LvimWinNavMuxBackend
---@field name                 string
---@field detect               fun(): boolean
---@field available            fun(): boolean
---@field current_pane_at_edge fun(dir: LvimWinNavDir): boolean?
---@field next_pane            fun(dir: LvimWinNavDir): boolean
---@field resize_pane          fun(dir: LvimWinNavDir, cells: integer): boolean
---@field is_zoomed            fun(): boolean
---@field mark_pane            fun(on: boolean): boolean
---@field pane_marked          fun(): boolean?
---@field has_bindings         fun(): boolean, boolean
---@field config_block         fun(): string[]
---@field commands             fun(): table<string, string>

-- The backends, in DETECTION order: the innermost multiplexer wins (tmux running inside WezTerm owns the
-- panes Neovim sees).
---@type string[]
local ORDER = { "tmux", "wezterm", "kitty", "zellij" }

---@type LvimWinNavMuxBackend|false|nil  nil = not resolved yet, false = none
local cached = nil

--- Load a backend module by name.
---@param name string
---@return LvimWinNavMuxBackend?
local function load(name)
    local ok, backend = pcall(require, "lvim-winnav.mux." .. name)
    return ok and backend or nil
end

--- Drop the cached resolution (after `setup()` changed `multiplexer.backend`).
---@return nil
function M.reset()
    cached = nil
end

--- The active backend, or nil when there is none: the multiplexer is disabled (`backend = false`), the
--- environment shows none, or its binary is not reachable. Never throws.
---@return LvimWinNavMuxBackend?
function M.get()
    if cached ~= nil then
        return cached or nil
    end
    cached = false

    local want = config.multiplexer.backend
    if want == false or want == nil then
        return nil
    end

    if want ~= "auto" then
        local backend = load(want)
        if backend and backend.available() then
            cached = backend
        end
        return cached or nil
    end

    for _, name in ipairs(ORDER) do
        local backend = load(name)
        if backend and backend.detect() and backend.available() then
            cached = backend
            break
        end
    end
    return cached or nil
end

--- The RESOLVED backend name, or nil.
---@return string?
function M.name()
    local backend = M.get()
    return backend and backend.name or nil
end

--- Hand the move off to the multiplexer: select the pane in `dir`. Returns whether focus actually left
--- Neovim. Refuses while the pane is ZOOMED (when configured to), and when the backend KNOWS there is no
--- pane that way; when it cannot be asked (nil), the move itself is the answer.
---@param dir LvimWinNavDir
---@return boolean handed_off
function M.move(dir)
    local backend = M.get()
    if not backend then
        return false
    end
    if config.disable_multiplexer_nav_when_zoomed and backend.is_zoomed() then
        return false
    end
    if backend.current_pane_at_edge(dir) == true then
        return false
    end
    return backend.next_pane(dir)
end

--- Resize the multiplexer PANE: move its border in `dir` by `cells`.
---@param dir LvimWinNavDir
---@param cells integer
---@return boolean resized
function M.resize(dir, cells)
    local backend = M.get()
    if not backend then
        return false
    end
    return backend.resize_pane(dir, cells)
end

--- Mark (or unmark) our pane as "Neovim runs here", so the multiplexer's own bindings can test a variable
--- instead of guessing the process name. A backend without pane options ignores it.
---@param on boolean
---@return boolean ok
function M.mark(on)
    if not config.multiplexer.mark_pane then
        return false
    end
    local backend = M.get()
    if not backend then
        return false
    end
    return backend.mark_pane(on)
end

--- The ready-to-paste config block for the DETECTED multiplexer (nil when there is none).
---@return string[]? lines
function M.config_block()
    local backend = M.get()
    return backend and backend.config_block() or nil
end

return M
