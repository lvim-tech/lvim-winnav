-- lvim-winnav.term: the move keys in terminal mode, and the programs that keep them.

local term = require("lvim-winnav.term")

describe("lvim-winnav.term: the foreground process of a terminal")

it("the foreground group is read from the stat line, spaces and parentheses in the name included", function()
    eq(4242, term.tpgid("1 (some (odd) name) S 1 100 100 34816 4242 4194304 0"))
    eq(nil, term.tpgid("garbage"))
end)

it("a name matches the passthrough list, cut as comm is cut", function()
    local list = { "lvim-fuzzy", "lfz", "nvim", "a-very-long-program-name" }
    eq(true, term.matches("lvim-fuzzy", list))
    eq(true, term.matches("NVIM", list))
    eq(true, term.matches("a-very-long-pro", list)) -- comm is cut at 15
    eq(false, term.matches("claude", list))
    eq(false, term.matches(nil, list))
    eq(false, term.matches("", list))
end)

it("the real foreground process of a terminal buffer is found by its name", function()
    if vim.fn.filereadable("/proc/self/stat") == 0 then
        return
    end
    local buf = vim.api.nvim_create_buf(false, true)
    local name
    vim.api.nvim_buf_call(buf, function()
        vim.fn.jobstart({ "sleep", "5" }, { term = true })
    end)
    vim.wait(2000, function()
        name = term.foreground(buf)
        return name ~= nil
    end, 20)
    eq("sleep", name)
    eq(false, term.passthrough(buf, { "lvim-fuzzy", "lfz" }))
    eq(true, term.passthrough(buf, { "lvim-fuzzy", "sleep" }))
end)

describe("lvim-winnav: the keys in terminal mode")

it("the move keys are bound in terminal mode, unless that is switched off", function()
    local config = require("lvim-winnav.config")
    local nav = require("lvim-winnav")
    config.terminal.enabled = true
    nav.setup({})
    local maps = {}
    for _, m in ipairs(vim.api.nvim_get_keymap("t")) do
        maps[m.lhs] = true
    end
    for _, k in ipairs({ "<C-H>", "<C-J>", "<C-K>", "<C-L>" }) do
        eq(true, maps[k] or maps[k:lower()] or false, k)
    end
end)
