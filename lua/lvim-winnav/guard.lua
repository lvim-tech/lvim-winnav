-- lvim-winnav.guard: which windows the plugin may TOUCH.
-- A resize must never fight a window that owns its own size: Neovim's own 'winfixwidth'/'winfixheight'
-- windows (a side panel that pinned itself), a FLOAT (it is not part of the split layout at all — resizing
-- it through `wincmd` would silently resize the window underneath), and the user's `ignored_filetypes` /
-- `ignored_buftypes`. Navigation is never guarded: you may always MOVE into any window; only changing a
-- window's geometry is.
--
---@module "lvim-winnav.guard"

local api = vim.api
local config = require("lvim-winnav.config")

local M = {}

--- Is `win` a FLOAT (not part of the split layout)?
---@param win integer
---@return boolean
function M.is_float(win)
    return api.nvim_win_is_valid(win) and api.nvim_win_get_config(win).relative ~= ""
end

--- Is `win` excluded from resizing by the user's ignore lists?
---@param win integer
---@return boolean
function M.is_ignored(win)
    if not api.nvim_win_is_valid(win) then
        return true
    end
    local buf = api.nvim_win_get_buf(win)
    for _, ft in ipairs(config.ignored_filetypes or {}) do
        if vim.bo[buf].filetype == ft then
            return true
        end
    end
    for _, bt in ipairs(config.ignored_buftypes or {}) do
        if vim.bo[buf].buftype == bt then
            return true
        end
    end
    return false
end

--- May `win`'s size be changed along `axis`? ("horizontal" = its width, "vertical" = its height.)
--- False for a float, an ignored window, or one that fixed its own size on that axis.
---@param win integer
---@param axis "horizontal"|"vertical"
---@return boolean
function M.resizable(win, axis)
    if not api.nvim_win_is_valid(win) or M.is_float(win) or M.is_ignored(win) then
        return false
    end
    if axis == "horizontal" then
        return not vim.wo[win].winfixwidth
    end
    return not vim.wo[win].winfixheight
end

return M
