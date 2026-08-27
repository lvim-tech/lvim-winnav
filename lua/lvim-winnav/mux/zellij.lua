-- lvim-winnav.mux.zellij: the Zellij backend (`zellij action …`).
--
-- Zellij exposes no QUERY: there is no "is there a pane to my left" and no pane-scoped variable. Its
-- `move-focus` is however edge-safe by design — at the outermost pane it simply does nothing (unlike tmux's
-- select-pane, it never wraps) — so the backend reports "not at the edge" and lets Zellij decide, which
-- yields exactly the behaviour the config asks for without a query. Zoom is not reported, so a zoomed pane
-- cannot be detected (documented in health).
--
-- THE MARK, without a pane option: Zellij's half of the handoff is a WASM plugin (`zellij/` in this repo,
-- shipped built as `zellij/lvim-winnav.wasm`) — Zellij's keybinds run in the server and cannot test the
-- focused pane's process, so the config pipes the nav keys to the plugin and THE PLUGIN decides: forward
-- the key into a Neovim pane, or move/resize the Zellij pane. It recognises Neovim by the pane TITLE:
-- `mark_pane` renames our own pane to `multiplexer.pane_option` ("@lvim_nvim") on VimEnter and undoes the
-- rename on VimLeave — the same mark contract as tmux, expressed in the one pane-scoped thing Zellij has.
-- (The rename targets OUR pane explicitly via $ZELLIJ_PANE_ID, like tmux's `-t $TMUX_PANE`.) The plugin
-- also accepts a plain `nvim` title/command as a fallback, but the mark is what stays correct under a
-- wrapper / sudo / ssh / a renamed binary.
--
---@module "lvim-winnav.mux.zellij"

local config = require("lvim-winnav.config")
local exec = require("lvim-winnav.mux.exec")

local M = {}

M.name = "zellij"

-- direction → Zellij's direction word.
---@type table<LvimWinNavDir, string>
local DIR = { left = "left", down = "down", up = "up", right = "right" }

--- The zellij executable (config).
---@return string
local function exe()
    return config.multiplexer.commands.zellij
end

--- Our own pane, as a `--pane-id` argument (`terminal_<id>`, from the environment Zellij exports into the
--- process it starts) — so the mark is always about the pane Neovim runs in, never "the focused pane".
---@return string?
local function pane_id()
    local id = os.getenv("ZELLIJ_PANE_ID")
    return (id and id ~= "") and ("terminal_" .. id) or nil
end

--- A tmux-notation key ("C-h", "C-Left") as Zellij writes it ("Ctrl h", "Ctrl left").
---@param key string
---@return string
local function zellij_key(key)
    local rest = key:gsub("^C%-", "")
    if #rest > 1 then
        rest = rest:lower() -- named keys (Left → left); single letters are already lowercase
    end
    return "Ctrl " .. rest
end

--- Are we running inside a Zellij session?
---@return boolean
function M.detect()
    local z = os.getenv("ZELLIJ")
    return z ~= nil and z ~= ""
end

--- Is the zellij binary reachable?
---@return boolean
function M.available()
    return exec.has(exe())
end

--- Zellij cannot be asked: UNKNOWN. Its `move-focus` is a no-op at the outermost pane (it never wraps), so
--- letting it try is exactly right.
---@return boolean? at_edge
function M.current_pane_at_edge(_)
    return nil
end

--- Zellij does not report a zoom (fullscreen) state to a client.
---@return boolean
function M.is_zoomed()
    return false
end

--- Move the focus to the pane in `dir` (a no-op at the outermost pane — Zellij never wraps).
---@param dir LvimWinNavDir
---@return boolean moved
function M.next_pane(dir)
    local d = DIR[dir]
    if not d then
        return false
    end
    return (exec.run({ exe(), "action", "move-focus", d }))
end

--- Grow our pane toward `dir`. Zellij resizes by its OWN fixed step, so `cells` is applied by REPEATING the
--- action — the configured amount still scales the gesture.
---@param dir LvimWinNavDir
---@param cells integer
---@return boolean resized
function M.resize_pane(dir, cells)
    local d = DIR[dir]
    if not d then
        return false
    end
    local ok = false
    for _ = 1, math.max(1, cells) do
        ok = (exec.run({ exe(), "action", "resize", "increase", d }))
        if not ok then
            break
        end
    end
    return ok
end

--- Mark (or unmark) our pane: rename it to the configured marker so the lvim-winnav Zellij plugin
--- recognises it as "Neovim runs here". Unmarking undoes the rename, which restores Zellij's automatic
--- title (the running command).
---@param on boolean
---@return boolean ok
function M.mark_pane(on)
    local target = pane_id()
    local argv = { exe(), "action" }
    if on then
        argv[#argv + 1] = "rename-pane"
    else
        argv[#argv + 1] = "undo-rename-pane"
    end
    if target then
        argv[#argv + 1] = "-p"
        argv[#argv + 1] = target
    end
    if on then
        argv[#argv + 1] = config.multiplexer.pane_option
    end
    return (exec.run(argv))
end

--- Zellij has no query for a pane's title, so the mark cannot be read back.
---@return boolean? marked
function M.pane_marked()
    return nil
end

--- The exact commands the backend runs.
---@return table<string, string>
function M.commands()
    return {
        select = exec.show({ exe(), "action", "move-focus", DIR.left }),
        resize = exec.show({ exe(), "action", "resize", "increase", DIR.left }),
        mark = exec.show({
            exe(),
            "action",
            "rename-pane",
            "-p",
            pane_id() or "terminal_$ZELLIJ_PANE_ID",
            config.multiplexer.pane_option,
        }),
    }
end

--- Zellij's keybindings live in its KDL config; there is no query for them.
---@return boolean bound, boolean marks
function M.has_bindings()
    return false, false
end

--- The ready-to-paste KDL blocks: the nav keys are piped to the lvim-winnav Zellij plugin (shipped in this
--- repo as `zellij/lvim-winnav.wasm`), which forwards them INTO a marked Neovim pane and moves/resizes the
--- Zellij pane otherwise. The plugin is PRELOADED once per session — never put it in a layout: a layout
--- instantiates one plugin per tab, and every instance receives every pipe.
---@return string[] lines
function M.config_block()
    local mux = config.multiplexer
    local wasm = "file:" .. (os.getenv("HOME") or "~") .. "/.config/zellij/plugins/lvim-winnav.wasm"
    local L = {
        "// lvim-winnav — the Zellij half of the handoff (generated by :LvimWinNav mux-config)",
        "//",
        "// 1. copy the shipped plugin:  cp <lvim-winnav>/zellij/lvim-winnav.wasm ~/.config/zellij/plugins/",
        "// 2. merge these blocks into ~/.config/zellij/config.kdl (add the lines to existing blocks)",
        "//",
        "// The plugin forwards a nav key INTO the focused pane when it runs Neovim (Neovim marks its own",
        "// pane title with `" .. mux.pane_option .. "` while it runs) and moves/resizes the Zellij pane",
        "// otherwise. Edge-safe: at the outermost pane a move is a no-op — it never wraps or switches tab.",
        "",
        "keybinds {",
        "    normal {",
    }
    local function bind(key, name, dir)
        L[#L + 1] = ('        bind "%s" { MessagePlugin "%s" { name "%s"; payload "%s"; }; }'):format(
            zellij_key(key),
            wasm,
            name,
            DIR[dir]
        )
    end
    for _, dir in ipairs({ "left", "down", "up", "right" }) do
        bind(mux.keys.move[dir], "move", dir)
    end
    -- A resize key applies ZELLIJ'S own fixed step once per press (the plugin cannot scale it).
    for _, dir in ipairs({ "left", "down", "up", "right" }) do
        bind(mux.keys.resize[dir], "resize", dir)
    end
    L[#L + 1] = "    }"
    L[#L + 1] = "}"
    L[#L + 1] = ""
    L[#L + 1] = "// Preload ONE instance per session, so the first nav keypress is not swallowed by a cold"
    L[#L + 1] = "// plugin launch. Never load the plugin from a layout (that would mean one instance per tab)."
    L[#L + 1] = "load_plugins {"
    L[#L + 1] = ('    "%s"'):format(wasm)
    L[#L + 1] = "}"
    return L
end

return M
