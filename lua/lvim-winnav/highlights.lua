-- lvim-winnav.highlights: every group the resize-mode hint bar paints with, derived from the LIVE
-- lvim-utils palette and the plugin's `config.colors` roles. `build()` is registered through
-- `lvim-utils.highlight.bind` in setup(), so the groups re-derive on ColorScheme / palette sync.
--
-- Accents are palette KEYS (never a hex in code); tint strengths are ROLE NAMES resolved against the shared
-- `lvim-utils.config.ui` scale — the plugin owns no numeric scale of its own.
--
---@module "lvim-winnav.highlights"

local c = require("lvim-utils.colors")
local hl = require("lvim-utils.highlight")
local config = require("lvim-winnav.config")

local M = {}

--- The shared tint scale (`lvim-utils.config.ui` `tint`), read LIVE so a retuned scale reaches us.
---@return table<string, number>
local function shared_tints()
    local ok, ui = pcall(require, "lvim-utils.config.ui")
    return (ok and type(ui) == "table" and ui.tint) or {}
end

--- Resolve a config accent: a palette key (tracks the live theme) or a literal "#rrggbb".
---@param key string
---@return string
local function accent(key)
    local v = c[key]
    return type(v) == "string" and v or key
end

--- Resolve a tint ROLE against the shared scale (a raw factor passes through).
---@param t string|number|nil
---@param tints table<string, number>
---@return number
local function tint_of(t, tints)
    if type(t) == "number" then
        return t
    end
    return (type(t) == "string" and tints[t]) or 0
end

--- A box group: the accent as the foreground on its own tint of the editor background (the shared "mtint").
---@param role LvimWinNavColor
---@param tints table<string, number>
---@param bold boolean?
---@return table
local function box(role, tints, bold)
    local a = accent(role.accent)
    return { fg = a, bg = hl.blend(a, c.bg, tint_of(role.tint, tints)), bold = bold or nil }
end

--- The lvim-winnav highlight groups from the live palette + `config.colors`.
---@return table<string, table>
function M.build()
    local col = config.colors
    local tints = shared_tints()

    return {
        LvimWinNavHintKey = box(col.hint_key, tints, true), -- the ` h ` key badge
        LvimWinNavHintLabel = box(col.hint_label, tints), -- its ` left ` label box
        LvimWinNavHintSize = box(col.hint_size, tints, true), -- the live `80 x 24` cell
        LvimWinNavHintSep = box(col.hint_sep, tints), -- the ➤ separator box
        LvimWinNavHintFill = box(col.hint_fill, tints), -- the strip under the whole row
    }
end

return M
