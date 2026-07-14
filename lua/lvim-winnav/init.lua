-- lvim-winnav: ONE set of keys that moves the cursor and resizes splits — and, at the edge of the Neovim
-- layout, hands off to the terminal MULTIPLEXER, so the same `<C-h/j/k/l>` walks straight into the tmux pane
-- next door and back.
--
-- It owns the three things its siblings do not: directional NAVIGATION, RESIZING, and the multiplexer
-- HANDOFF. (lvim-winpick picks a window by label; lvim-winmove rearranges windows — a directional swap here
-- delegates to it rather than growing a second implementation.)
--
-- The handoff has TWO halves, and the plugin ships both:
--   • Neovim's half — at an edge, tell the multiplexer to select / resize the pane that way (mux/*.lua).
--   • The multiplexer's half — a key pressed while the pane runs Neovim must be FORWARDED to it instead of
--     moving the pane. `:LvimWinNav mux-config` prints that config, and `lvim-winnav.tmux` (the repo-root
--     script) installs it for tmux users. It tests a pane MARK Neovim sets on itself (`@lvim_nvim`), not a
--     `ps | grep` guess — no shell fork per keypress, and correct under a wrapper / sudo / ssh.
--
--   :LvimWinNav left|down|up|right      -- move the cursor (at the edge: the configured behaviour)
--   :LvimWinNav resize <dir> [amount]   -- move the boundary in <dir> (cells or "5%")
--   :LvimWinNav swap <dir>              -- swap the buffer with the window that way
--   :LvimWinNav resize-mode             -- interactive resize (h/j/k/l until <Esc>)
--   :LvimWinNav mux-config              -- the ready-to-paste config for the detected multiplexer
--
--   require("lvim-winnav").move(dir) / .resize(dir, amount?) / .swap(dir) / .resize_mode()
--
---@module "lvim-winnav"

local api = vim.api
local config = require("lvim-winnav.config")
local nav = require("lvim-winnav.nav")
local resize = require("lvim-winnav.resize")
local swap = require("lvim-winnav.swap")
local mux = require("lvim-winnav.mux")
local highlights = require("lvim-winnav.highlights")
local hl = require("lvim-utils.highlight")
local merge = require("lvim-utils.utils").merge

local M = {}

---@type boolean  one-time registration (highlights, command, pane mark) done
local registered = false

---@type LvimWinNavDir[]  the four directions, in the canonical order
local DIRS = { "left", "down", "up", "right" }

-- ── public API (what a keymap calls) ─────────────────────────────────────────

--- Move the cursor to the window in `dir`; at the edge of the layout, run the configured `at_edge`
--- behaviour (dock / multiplexer / wrap / split / stop).
---@param dir LvimWinNavDir
---@return boolean moved
function M.move(dir)
    return nav.move(dir)
end

--- Move the boundary in `dir` (see lvim-winnav.resize for the semantics). `amount` overrides
--- `config.default_amount` for this call: a number of cells, or a percentage string ("5%").
---@param dir LvimWinNavDir
---@param amount integer|string|nil
---@return boolean resized
function M.resize(dir, amount)
    return resize.resize(dir, amount)
end

--- Swap the current buffer with the one in `dir` (delegates the exchange to lvim-winmove).
---@param dir LvimWinNavDir
---@return boolean swapped
function M.swap(dir)
    return swap.swap(dir)
end

--- Enter the interactive resize mode (plain h/j/k/l resize until a quit key).
---@return nil
function M.resize_mode()
    resize.start()
end

--- Leave the interactive resize mode.
---@return nil
function M.end_resize_mode()
    resize.stop()
end

--- The detected multiplexer's name ("tmux" / "wezterm" / "kitty" / "zellij"), or nil when there is none.
---@return string?
function M.multiplexer()
    return mux.name()
end

--- The ready-to-paste config block for the detected multiplexer, as lines (nil when there is none).
---@return string[]?
function M.mux_config()
    return mux.config_block()
end

-- ── the mux-config viewer ────────────────────────────────────────────────────

--- Show the generated multiplexer config in the canonical read-only viewer, with a key that copies it to
--- the clipboard (it exists to be pasted). No multiplexer ⇒ a plain notification, not an empty window.
---@return nil
local function show_mux_config()
    local lines = mux.config_block()
    local name = mux.name()
    if not lines or not name then
        vim.notify("lvim-winnav: no multiplexer detected — nothing to configure", vim.log.levels.WARN)
        return
    end
    local ui = require("lvim-ui")
    ui.info(lines, {
        title = { icon = config.icons.mux, text = ("%s config"):format(name) },
        hide_cursor = true,
        footer_items = {
            {
                key = "y",
                name = "copy",
                run = function()
                    vim.fn.setreg("+", table.concat(lines, "\n"))
                    vim.notify(("lvim-winnav: %s config copied"):format(name), vim.log.levels.INFO)
                end,
            },
        },
    })
end

-- ── the pane mark ────────────────────────────────────────────────────────────

--- Mark this multiplexer pane as "Neovim runs here" while it does: set on entry / resume, cleared on exit /
--- suspend. The multiplexer's own bindings then test that variable instead of inspecting the pane's process.
--- The autocmds are the ONLY ones the plugin owns — every action is a direct call from a keymap.
---@return nil
local function register_pane_mark()
    if not config.multiplexer.mark_pane then
        return
    end
    local group = api.nvim_create_augroup("LvimWinNavPaneMark", { clear = true })
    api.nvim_create_autocmd({ "VimEnter", "VimResume" }, {
        group = group,
        callback = function()
            mux.mark(true)
        end,
    })
    api.nvim_create_autocmd({ "VimLeavePre", "VimSuspend" }, {
        group = group,
        callback = function()
            mux.mark(false)
        end,
    })
    -- setup() may run long after VimEnter (a lazily loaded plugin): mark right now as well.
    if vim.v.vim_did_enter == 1 then
        mux.mark(true)
    end
end

-- ── the command ──────────────────────────────────────────────────────────────

--- Run one `:LvimWinNav` invocation.
---@param args string[]
---@return nil
local function dispatch(args)
    local sub = args[1]
    if not sub or sub == "" then
        vim.notify("lvim-winnav: a subcommand is required", vim.log.levels.WARN)
        return
    end
    if vim.tbl_contains(DIRS, sub) then
        M.move(sub)
    elseif sub == "resize" then
        M.resize(args[2], args[3])
    elseif sub == "swap" then
        M.swap(args[2])
    elseif sub == "resize-mode" then
        M.resize_mode()
    elseif sub == "mux-config" then
        show_mux_config()
    else
        vim.notify("lvim-winnav: unknown subcommand " .. sub, vim.log.levels.WARN)
    end
end

--- Completion for `:LvimWinNav`: the subcommands, then the directions of the ones that take a direction.
---@param _lead string
---@param line string
---@return string[]
local function complete(_lead, line)
    local args = vim.split(vim.trim(line), "%s+")
    -- args[1] is the command name itself; a trailing space means the NEXT argument is being completed.
    local typing_second = #args == 2 and not line:match("%s$")
    if #args <= 1 or typing_second then
        local subs = vim.deepcopy(DIRS)
        vim.list_extend(subs, { "resize", "swap", "resize-mode", "mux-config" })
        return subs
    end
    if args[2] == "resize" or args[2] == "swap" then
        return DIRS
    end
    return {}
end

--- Merge user options into the live config, bind the highlights, register `:LvimWinNav` and the pane mark.
--- Optional — the defaults work without it, but the pane mark (the tmux side's variable) needs it.
---@param opts LvimWinNavConfig?
---@return nil
function M.setup(opts)
    if opts then
        merge(config, opts)
        mux.reset() -- the backend may have changed
    end
    if registered then
        return
    end
    registered = true

    hl.setup()
    hl.bind(highlights.build)

    api.nvim_create_user_command("LvimWinNav", function(cmd)
        dispatch(cmd.fargs)
    end, {
        nargs = "*",
        desc = "lvim-winnav: move / resize / swap / resize-mode / mux-config",
        complete = complete,
    })

    register_pane_mark()
end

return M
