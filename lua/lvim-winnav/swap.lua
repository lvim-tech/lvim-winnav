-- lvim-winnav.swap: swap the current buffer with the one in a direction.
--
-- This is the ONE place where lvim-winnav overlaps its sibling lvim-winmove, which already owns "exchange
-- two windows' content" (buffer + view, each window keeping its own position and options). So it is not
-- reimplemented here: this module resolves the DIRECTIONAL target (lvim-winnav's job — adjacency) and calls
-- `lvim-winmove.swap_with(target)` (lvim-winmove's job — the exchange). Without lvim-winmove installed there
-- is no swap, and the caller is told so once — never a second implementation.
--
-- `move_cursor_with_buffer` decides where you end up: with it, the cursor FOLLOWS the buffer into the window
-- it was moved to; without it, the cursor stays where it is and now shows the buffer that came the other way.
--
---@module "lvim-winnav.swap"

local api = vim.api
local config = require("lvim-winnav.config")
local nav = require("lvim-winnav.nav")

local M = {}

--- Swap the current window's buffer with the window in `dir`. No-op at the edge (there is nothing to swap
--- with) — an edge behaviour would be meaningless for a swap.
---@param dir LvimWinNavDir
---@return boolean swapped
function M.swap(dir)
    local cur = api.nvim_get_current_win()
    local target = nav.neighbour(cur, dir)
    if not target then
        return false
    end

    local ok, winmove = pcall(require, "lvim-winmove")
    if not ok or type(winmove.swap_with) ~= "function" then
        vim.notify("lvim-winnav: a directional swap needs lvim-winmove", vim.log.levels.WARN)
        return false
    end

    if not winmove.swap_with(target) then
        return false
    end
    if config.move_cursor_with_buffer then
        api.nvim_set_current_win(target) -- follow the buffer into its new window
    end
    return true
end

return M
