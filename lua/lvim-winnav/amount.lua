-- lvim-winnav.amount: the resize STEP, resolved to cells.
--
-- A step in columns is meaningless across screens — 3 columns is a nudge on an 80-column terminal and
-- invisible on a 200-column one. So a step may be a PERCENTAGE STRING ("5%"), resolved against the size of
-- the window's PARENT container on that axis: the enclosing `row` node of the window layout for a horizontal
-- step, the enclosing `col` node for a vertical one (`vim.fn.winlayout()` — the same tree Vim splits with).
-- The parent is what the boundary actually divides, so the same percentage means the same visual step at any
-- terminal size and at any nesting depth. A window with no such parent (a single split axis) falls back to
-- the editor's own size.
--
---@module "lvim-winnav.amount"

local fn = vim.fn

local M = {}

--- The total size of the layout NODE `node` on `axis` (its windows plus the separator columns/rows between
--- them). A leaf is one window; a `row`/`col` is the sum of its children (plus one separator per gap for a
--- row — Vim draws a vertical separator column between side-by-side windows).
---@param node table  a `vim.fn.winlayout()` node: { "leaf", winid } | { "row"|"col", children }
---@param axis "horizontal"|"vertical"
---@return integer
local function node_size(node, axis)
    local kind = node[1]
    if kind == "leaf" then
        local win = node[2] --[[@as integer]]
        return axis == "horizontal" and fn.winwidth(win) or fn.winheight(win)
    end
    local total, children = 0, node[2] --[[@as table[] ]]
    for _, child in ipairs(children) do
        total = total + node_size(child, axis)
    end
    -- A `row` stacks its children side by side with a 1-column separator between them; a `col` stacks them
    -- vertically, and the statusline that divides them is already counted OUTSIDE winheight().
    if kind == "row" and axis == "horizontal" then
        total = total + math.max(0, #children - 1)
    end
    return total
end

--- The nearest ancestor of `win` whose split ORIENTATION matches `axis` ("row" for a horizontal step, "col"
--- for a vertical one) — the container the boundary being moved actually divides. nil when the window is not
--- inside such a node (nothing is split on that axis).
---@param win integer
---@param axis "horizontal"|"vertical"
---@return table? node
local function parent_node(win, axis)
    local want = (axis == "horizontal") and "row" or "col"
    local found = nil

    ---@param node table
    ---@param nearest table?  the closest matching ancestor seen on the way down
    ---@return boolean  the subtree contains `win`
    local function walk(node, nearest)
        if node[1] == "leaf" then
            if node[2] == win then
                found = nearest
                return true
            end
            return false
        end
        local next_nearest = (node[1] == want) and node or nearest
        for _, child in ipairs(node[2]) do
            if walk(child, next_nearest) then
                return true
            end
        end
        return false
    end

    walk(fn.winlayout(), nil)
    return found
end

--- The size (in cells) of the container a step on `axis` is measured against: the window's parent `row`/`col`
--- node, else the editor itself.
---@param win integer
---@param axis "horizontal"|"vertical"
---@return integer
function M.parent_size(win, axis)
    local node = parent_node(win, axis)
    if node then
        return node_size(node, axis)
    end
    return axis == "horizontal" and vim.o.columns or vim.o.lines
end

--- Resolve a step to whole CELLS: a number passes through; a "N%" string is that percentage of the parent
--- container's size on `axis` (never less than 1 cell, so a small percentage on a small screen still moves).
---@param value integer|string
---@param axis "horizontal"|"vertical"
---@param win integer?  the window the step applies to (defaults to the current one)
---@return integer cells
function M.resolve(value, axis, win)
    if type(value) == "number" then
        return math.max(1, math.floor(value))
    end
    local pct = tostring(value):match("^%s*(%d+%.?%d*)%s*%%%s*$")
    if not pct then
        return math.max(1, math.floor(tonumber(value) or 1))
    end
    local parent = M.parent_size(win or vim.api.nvim_get_current_win(), axis)
    return math.max(1, math.floor(parent * tonumber(pct) / 100 + 0.5))
end

return M
