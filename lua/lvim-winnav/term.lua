-- lvim-winnav.term: TERMINAL buffers. A window that runs a terminal program (a Claude Code session, a shell) could
-- not be left with <C-h/j/k/l>: in terminal mode those keys go to the program. So the move keys are bound in
-- terminal mode too — but a program that uses them itself (a finder, lazygit, a nested Neovim) keeps them: the
-- decision is by the NAME of the terminal's foreground process (Linux: /proc), the entries of
-- `config.terminal.passthrough`.
--
---@module "lvim-winnav.term"

local M = {}

--- The terminal foreground process group id out of the text of /proc/<pid>/stat (the comm field may hold
--- spaces and parentheses: the fields count from the LAST parenthesis).
---@param stat string
---@return integer?
function M.tpgid(stat)
    local rest = stat:match("^.*%)%s+(.*)$")
    if not rest then
        return nil
    end
    local f = {}
    for w in rest:gmatch("%S+") do
        f[#f + 1] = w
    end
    return tonumber(f[6]) -- state ppid pgrp session tty_nr TPGID
end

local function read(path)
    local fh = io.open(path, "r")
    if not fh then
        return nil
    end
    local s = fh:read("*a")
    fh:close()
    return s
end

--- The name (`comm`) of the process in the foreground of terminal buffer `buf`, or nil when it cannot be told.
---@param buf integer
---@return string?
function M.foreground(buf)
    local job = vim.b[buf].terminal_job_id
    if not job then
        return nil
    end
    local ok, pid = pcall(vim.fn.jobpid, job)
    if not ok or type(pid) ~= "number" or pid <= 0 then
        return nil
    end
    local stat = read("/proc/" .. pid .. "/stat")
    local fg = stat and M.tpgid(stat)
    if not fg or fg <= 0 then
        return nil
    end
    local name = read("/proc/" .. fg .. "/comm")
    return name and vim.trim(name) or nil
end

--- Is `name` one of `list`? (`comm` is cut at 15 characters, so the entries are compared cut too.)
---@param name string?
---@param list string[]
---@return boolean
function M.matches(name, list)
    if not name or name == "" then
        return false
    end
    name = name:lower():sub(1, 15)
    for _, p in ipairs(list or {}) do
        if p:lower():sub(1, 15) == name then
            return true
        end
    end
    return false
end

--- Does the program in terminal buffer `buf` keep the move keys for itself?
---@param buf integer
---@param list string[]
---@return boolean
function M.passthrough(buf, list)
    return M.matches(M.foreground(buf), list)
end

return M
