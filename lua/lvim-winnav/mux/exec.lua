-- lvim-winnav.mux.exec: the ONE way this plugin talks to a multiplexer.
--
-- Every call is `vim.system` with an ARGV LIST — never a shell string. A pane title, a session name or a
-- user option that contains a space, a quote or a `$(…)` therefore cannot break the command, and cannot
-- inject into it: nothing is ever parsed by a shell. The call is SYNCHRONOUS (a navigation keypress must
-- know the answer before it decides), bounded by `config.multiplexer.timeout` so a hung multiplexer can
-- never hang the editor, and it NEVER throws: a missing binary or a non-zero exit is reported as a plain
-- `false`, which the caller degrades on.
--
---@module "lvim-winnav.mux.exec"

local config = require("lvim-winnav.config")

local M = {}

--- Run `argv` and wait for it. Returns success (exit code 0) and the trimmed stdout.
---@param argv string[]
---@return boolean ok, string stdout
function M.run(argv)
    local ok, res = pcall(function()
        return vim.system(argv, { text = true }):wait(config.multiplexer.timeout)
    end)
    if not ok or type(res) ~= "table" then
        return false, ""
    end
    local out = vim.trim(res.stdout or "")
    return res.code == 0, out
end

--- Is `exe` an executable on $PATH?
---@param exe string
---@return boolean
function M.has(exe)
    return vim.fn.executable(exe) == 1
end

--- Render an argv list the way a user would type it — for `:checkhealth` ("the exact command it runs").
---@param argv string[]
---@return string
function M.show(argv)
    return table.concat(argv, " ")
end

return M
