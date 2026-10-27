-- A step that means the same thing at every screen size, and an edge that does what it is told.
--
-- The resize step is the subtle half. "5%" has to be five percent of something, and the something
-- is the container the boundary actually divides -- the enclosing `row` for a horizontal step, the
-- enclosing `col` for a vertical one. Measuring that container is where nesting bites: a node
-- divides only the axis it splits on, and across its own grain its children OVERLAP rather than
-- stack. Add them up anyway and the answer grows with the nesting depth.

local amount = require("lvim-winnav.amount")
local nav = require("lvim-winnav.nav")
local mux = require("lvim-winnav.mux")
local config = require("lvim-winnav.config")

--- A single window, from a known state.
---@return integer
local function one_window()
    vim.cmd("silent! only")
    return vim.api.nvim_get_current_win()
end

describe("lvim-winnav: a step resolves to cells")

it("a number passes through, floored, and never below one cell", function()
    local win = one_window()
    eq(3, amount.resolve(3, "horizontal", win))
    eq(2, amount.resolve(2.7, "horizontal", win))
    eq(1, amount.resolve(0, "horizontal", win), "a zero step would be a key that does nothing")
    eq(1, amount.resolve(-5, "horizontal", win))
end)

it("a plain numeric string is a number, and nonsense is one cell", function()
    local win = one_window()
    eq(7, amount.resolve("7", "horizontal", win))
    eq(1, amount.resolve("abc", "horizontal", win))
end)

it("a percentage is taken against the editor when nothing is split that way", function()
    local win = one_window()
    eq(vim.o.columns, amount.parent_size(win, "horizontal"))
    eq(vim.o.lines, amount.parent_size(win, "vertical"))
    eq(math.floor(vim.o.columns * 0.1 + 0.5), amount.resolve("10%", "horizontal", win))
end)

it("a small percentage still moves by a cell", function()
    local win = one_window()
    eq(1, amount.resolve("0%", "horizontal", win))
    truthy(amount.resolve("1%", "vertical", win) >= 1)
end)

it("the container is the enclosing row for a horizontal step", function()
    one_window()
    vim.cmd("vsplit")
    local win = vim.api.nvim_get_current_win()
    eq(vim.o.columns, amount.parent_size(win, "horizontal"), "two windows side by side span the screen")
end)

it("the container is the enclosing column for a vertical step", function()
    one_window()
    vim.cmd("split")
    local win = vim.api.nvim_get_current_win()
    local sum = 0
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        sum = sum + vim.api.nvim_win_get_height(w)
    end
    eq(sum, amount.parent_size(win, "vertical"), "the rows the boundary can actually move between")
end)

it("nesting does not inflate the container", function()
    -- row{ col{ leaf, leaf }, leaf }: the window lives in a column, inside a row. Its horizontal
    -- container is that row -- the whole screen -- and NOT the sum of every leaf's width, which is
    -- what adding across the grain produced: 120 columns on an 80-column screen, and a 25% step of
    -- 30 cells instead of 20.
    one_window()
    vim.cmd("vsplit")
    vim.cmd("split")
    local win = vim.api.nvim_get_current_win()
    eq("row", vim.fn.winlayout()[1], "precondition: the outer node is a row")

    eq(vim.o.columns, amount.parent_size(win, "horizontal"))
    eq(
        math.floor(vim.o.columns * 0.25 + 0.5),
        amount.resolve("25%", "horizontal", win),
        "a quarter of the screen, at any nesting depth"
    )

    -- And one level deeper, where a per-level error compounds. Here the nearest `row` ancestor is
    -- an INNER row -- the container really is narrower than the screen, which is the point of
    -- measuring the container at all. What can never happen is a container LARGER than the screen,
    -- and that is exactly what adding across the grain produced.
    vim.cmd("vsplit")
    local deeper = vim.api.nvim_get_current_win()
    local inner = amount.parent_size(deeper, "horizontal")
    truthy(inner <= vim.o.columns, "a container cannot be wider than the screen it is on: got " .. inner)
    -- Its own row holds exactly it and the window it was split from, so the container is those
    -- two widths plus the separator between them. (Measuring "every window at the same screen
    -- row" would wrongly include the full-height window on the far side of the OUTER row -- which
    -- is how this assertion was wrong the first time.)
    local sibling = nav.neighbour(deeper, "right") or nav.neighbour(deeper, "left")
    truthy(sibling, "precondition: the window shares its row with one other")
    eq(
        vim.api.nvim_win_get_width(deeper) + vim.api.nvim_win_get_width(sibling) + 1,
        inner,
        "the container of a boundary is the windows that boundary divides"
    )
end)

it("a horizontal container counts the separator columns between its windows", function()
    one_window()
    vim.cmd("vsplit")
    local widths = 0
    local wins = vim.api.nvim_tabpage_list_wins(0)
    for _, w in ipairs(wins) do
        widths = widths + vim.api.nvim_win_get_width(w)
    end
    eq(
        widths + (#wins - 1),
        amount.parent_size(wins[1], "horizontal"),
        "Vim draws a separator column between side-by-side windows"
    )
end)

describe("lvim-winnav: moving, and the edge")

it("a neighbour is found in each direction and is nil at the edge", function()
    one_window()
    vim.cmd("vsplit")
    local left = vim.api.nvim_get_current_win()
    local right = vim.api.nvim_tabpage_list_wins(0)[2]

    eq(right, nav.neighbour(left, "right"))
    eq(left, nav.neighbour(right, "left"))
    eq(nil, nav.neighbour(left, "left"))
    eq(true, nav.at_edge(left, "left"))
    eq(false, nav.at_edge(left, "right"))
    eq(nil, nav.neighbour(left, "sideways"), "an unknown direction has no neighbour")
    eq(nil, nav.neighbour(999999, "left"), "neither does a window that is gone")
end)

it("a move to an existing neighbour focuses it", function()
    one_window()
    vim.cmd("vsplit")
    local left = vim.api.nvim_get_current_win()
    local right = vim.api.nvim_tabpage_list_wins(0)[2]
    vim.api.nvim_set_current_win(left)
    eq(true, nav.move("right"))
    eq(right, vim.api.nvim_get_current_win())
end)

it("the edge behaviour may be one value, or one per direction", function()
    local was = config.at_edge
    config.at_edge = "wrap"
    eq("wrap", nav.edge_behaviour("left"))
    eq("wrap", nav.edge_behaviour("down"))

    config.at_edge = { left = "split", right = "wrap" }
    eq("split", nav.edge_behaviour("left"))
    eq("wrap", nav.edge_behaviour("right"))
    eq("stop", nav.edge_behaviour("up"), "a direction nobody configured does nothing")
    config.at_edge = was
end)

it("stop really does nothing", function()
    local was, was_dock = config.at_edge, config.dock.enabled
    config.at_edge = "stop"
    config.dock.enabled = false
    one_window()
    vim.cmd("vsplit")
    local left = vim.api.nvim_get_current_win()
    local before = #vim.api.nvim_tabpage_list_wins(0)

    eq(false, nav.move("left"), "at the left edge")
    eq(left, vim.api.nvim_get_current_win())
    eq(before, #vim.api.nvim_tabpage_list_wins(0), "and no window was opened")
    config.at_edge, config.dock.enabled = was, was_dock
end)

it("wrap crosses to the far window of the row, in one step", function()
    local was, was_dock = config.at_edge, config.dock.enabled
    config.at_edge = "wrap"
    config.dock.enabled = false

    one_window()
    vim.cmd("vsplit")
    vim.cmd("vsplit")
    local wins = vim.api.nvim_tabpage_list_wins(0)
    eq(3, #wins)
    vim.api.nvim_set_current_win(wins[1])

    eq(true, nav.move("left"), "the leftmost window wraps")
    eq(wins[#wins], vim.api.nvim_get_current_win(), "to the far right, not to its immediate neighbour")

    config.at_edge, config.dock.enabled = was, was_dock
end)

it("wrap has nowhere to go with a single window on that axis", function()
    local was, was_dock = config.at_edge, config.dock.enabled
    config.at_edge = "wrap"
    config.dock.enabled = false
    one_window()
    eq(false, nav.move("left"))
    config.at_edge, config.dock.enabled = was, was_dock
end)

it("split opens a window that way", function()
    local was, was_dock = config.at_edge, config.dock.enabled
    config.at_edge = "split"
    config.dock.enabled = false
    one_window()
    eq(true, nav.move("right"))
    eq(2, #vim.api.nvim_tabpage_list_wins(0))
    config.at_edge, config.dock.enabled = was, was_dock
end)

describe("lvim-winnav: handing a move to the multiplexer")

--- Install a fake backend under a name the dispatcher will `require`, and point the config at it.
--- Returns the call log so a case can state what was asked of it.
---@param overrides table
---@return table log
local function fake_backend(overrides)
    local log = { next_pane = 0, resize = {}, marked = nil }
    local backend = vim.tbl_extend("force", {
        name = "spec-fake",
        detect = function()
            return true
        end,
        available = function()
            return true
        end,
        current_pane_at_edge = function()
            return nil
        end,
        next_pane = function()
            log.next_pane = log.next_pane + 1
            return true
        end,
        resize_pane = function(dir, cells)
            log.resize = { dir = dir, cells = cells }
            return true
        end,
        is_zoomed = function()
            return false
        end,
        mark_pane = function(on)
            log.marked = on
            return true
        end,
        pane_marked = function()
            return log.marked
        end,
        has_bindings = function()
            return true, true
        end,
        config_block = function()
            return { "fake" }
        end,
        commands = function()
            return {}
        end,
    }, overrides)
    package.loaded["lvim-winnav.mux.spec-fake"] = backend
    config.multiplexer.backend = "spec-fake"
    mux.reset()
    return log
end

local function restore_mux()
    package.loaded["lvim-winnav.mux.spec-fake"] = nil
    config.multiplexer.backend = "auto"
    mux.reset()
end

it("with the multiplexer off there is never a pane next door", function()
    local was = config.multiplexer.backend
    config.multiplexer.backend = false
    mux.reset()
    eq(nil, mux.get())
    eq(nil, mux.name())
    eq(false, mux.move("left"))
    eq(false, mux.resize("left", 3))
    config.multiplexer.backend = was
    mux.reset()
end)

it("a backend whose binary is missing is not used", function()
    fake_backend({
        available = function()
            return false
        end,
    })
    eq(nil, mux.get())
    eq(false, mux.move("left"))
    restore_mux()
end)

it("the resolved backend is cached until it is reset", function()
    local calls = 0
    fake_backend({
        available = function()
            calls = calls + 1
            return true
        end,
    })
    eq("spec-fake", mux.name())
    local after_first = calls
    mux.name()
    mux.name()
    eq(after_first, calls, "the terminal we run in does not change; asking again is waste")
    mux.reset()
    mux.name()
    truthy(calls > after_first, "reset has to drop the answer")
    restore_mux()
end)

it("a move is handed over when the backend cannot say where its edges are", function()
    local log = fake_backend({})
    eq(true, mux.move("left"), "nil means 'cannot be asked' -- the move itself is the answer")
    eq(1, log.next_pane)
    restore_mux()
end)

it("a move is refused when the backend KNOWS there is no pane that way", function()
    local log = fake_backend({
        current_pane_at_edge = function()
            return true
        end,
    })
    eq(false, mux.move("left"))
    eq(0, log.next_pane, "nothing may be asked of the multiplexer once it has said no")
    restore_mux()
end)

it("a zoomed pane is left alone when that is configured", function()
    local was = config.disable_multiplexer_nav_when_zoomed
    local log = fake_backend({
        is_zoomed = function()
            return true
        end,
    })

    config.disable_multiplexer_nav_when_zoomed = true
    eq(false, mux.move("left"))
    eq(0, log.next_pane)

    config.disable_multiplexer_nav_when_zoomed = false
    eq(true, mux.move("left"))
    eq(1, log.next_pane)

    config.disable_multiplexer_nav_when_zoomed = was
    restore_mux()
end)

it("a resize passes the direction and the cells through untouched", function()
    local log = fake_backend({})
    eq(true, mux.resize("down", 7))
    eq({ dir = "down", cells = 7 }, log.resize)
    restore_mux()
end)

it("marking the pane obeys its own switch", function()
    local was = config.multiplexer.mark_pane
    local log = fake_backend({})

    config.multiplexer.mark_pane = false
    eq(false, mux.mark(true))
    eq(nil, log.marked, "the switch is off; the backend is not even asked")

    config.multiplexer.mark_pane = true
    eq(true, mux.mark(true))
    eq(true, log.marked)

    config.multiplexer.mark_pane = was
    restore_mux()
end)
