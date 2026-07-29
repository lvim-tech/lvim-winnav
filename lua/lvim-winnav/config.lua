-- lvim-winnav.config: the live configuration table.
-- Holds every default; `setup()` merges the user's options into it IN PLACE (via lvim-utils.utils.merge),
-- so every `require("lvim-winnav.config")` reader sees the effective values. NOTHING the plugin paints,
-- prints, runs or measures is a literal in the code — keys, glyphs, accents, tint ROLES, step amounts,
-- executables and timeouts all live here.
--
-- Colours are palette KEYS (never a hex): `accent` names a colour in `lvim-utils.colors` and `tint` names a
-- ROLE in the shared scale `lvim-utils.config.ui.tint` — so the chrome tracks the live theme and the one
-- global scale.
--
---@module "lvim-winnav.config"

---@alias LvimWinNavDir "left"|"down"|"up"|"right"
---@alias LvimWinNavEdge "multiplexer"|"wrap"|"split"|"dock"|"stop"

---@class LvimWinNavColor
---@field accent string  A palette key in lvim-utils.colors ("blue", "yellow", …) or a literal "#rrggbb"
---@field tint   string  A ROLE name in the shared lvim-utils.config.ui `tint` scale ("badge", "label", …)

---@class LvimWinNavColors
---@field hint_key   LvimWinNavColor  Resize-mode hint bar: the key badge box
---@field hint_label LvimWinNavColor  Resize-mode hint bar: the label box next to a key badge
---@field hint_size  LvimWinNavColor  Resize-mode hint bar: the live window-size cell
---@field hint_sep   LvimWinNavColor  Resize-mode hint bar: the ➤ separator box
---@field hint_fill  LvimWinNavColor  Resize-mode hint bar: the continuous strip under the row

---@class LvimWinNavIcons
---@field mode      string  Leading glyph of the resize-mode hint bar
---@field separator string  The pointer / separator between the hint's key group and the size cell
---@field mux       string  Title glyph of the `mux-config` viewer

---@class LvimWinNavMuxKeys
---@field move   table<LvimWinNavDir, string>  The keys the NEOVIM side is bound to for moving (tmux notation)
---@field resize table<LvimWinNavDir, string>  The keys the NEOVIM side is bound to for resizing

---@class LvimWinNavMuxConfig
---@field backend     "auto"|"tmux"|"wezterm"|"kitty"|"zellij"|false  Which backend to use; auto = detect from the environment
---@field mark_pane   boolean                 Mark the multiplexer pane while Neovim runs in it (tmux: `set-option -p`)
---@field pane_option string                  The pane-scoped user option Neovim marks itself with
---@field no_wrap     boolean                 The GENERATED multiplexer bindings do not wrap around at the outermost pane
---@field timeout     integer                 Milliseconds a multiplexer query may take before it is abandoned
---@field commands    table<string, string>   The executable of each backend (looked up on $PATH)
---@field keys        LvimWinNavMuxKeys       The keys the generated multiplexer config binds

---@class LvimWinNavDock
---@field enabled boolean  At an edge, focus a docked lvim panel in that direction (the message zone / a dock) first

---@class LvimWinNavResizeKeys
---@field left  string    Shrink/grow leftwards while resize mode is active
---@field down  string
---@field up    string
---@field right string
---@field quit  string[]  Keys that leave resize mode

---@class LvimWinNavResizeHooks
---@field on_enter fun()|nil  Called after resize mode is entered
---@field on_leave fun()|nil  Called after resize mode is left

---@class LvimWinNavResizeMode
---@field keys        LvimWinNavResizeKeys
---@field hooks       LvimWinNavResizeHooks
---@field show_footer boolean  Show the lvim-ui hint bar (live keys + the window's size) while the mode is active
---@field title       string   The bar's leading label
---@field labels      table<string, string>  The label of each hint button
---@field size_format string   How the live window size is rendered (width, height)

---@class LvimWinNavConfig
---@field keys                               { move: table<LvimWinNavDir, string>?, resize: table<LvimWinNavDir, string>? }|false
---   The plugin's own normal-mode maps, bound at setup(): `move` focuses the window in that
---   direction (with the edge behaviour `at_edge` describes) and `resize` grows/shrinks by
---   `default_amount`. `false` binds nothing — for a host that maps the API itself
---@field at_edge                            LvimWinNavEdge|table<LvimWinNavDir, LvimWinNavEdge>
---@field default_amount                     integer|string  Resize step: cells, or a percentage of the parent ("5%")
---@field move_cursor_with_buffer            boolean         A swap takes the cursor along into the moved buffer
---@field disable_multiplexer_nav_when_zoomed boolean        A zoomed multiplexer pane never hands off
---@field multiplexer                        LvimWinNavMuxConfig
---@field dock                               LvimWinNavDock
---@field resize_mode                        LvimWinNavResizeMode
---@field ignored_filetypes                  string[]        Windows with these filetypes are never resized
---@field ignored_buftypes                   string[]        Windows with these buftypes are never resized
---@field icons                              LvimWinNavIcons
---@field colors                             LvimWinNavColors

---@type LvimWinNavConfig
return {
    -- What a move does when there is no Neovim window in that direction. One value for every direction, or a
    -- per-direction table — e.g. `{ left = "multiplexer", right = "multiplexer", up = "multiplexer",
    -- down = "dock" }` so the bottom key descends into the message zone instead of leaving Neovim.
    --   multiplexer — select the tmux/wezterm/kitty/zellij pane in that direction (no multiplexer ⇒ stop)
    --   wrap        — wrap around to the window at the opposite edge
    --   split       — open a new split in that direction
    --   dock        — focus the docked lvim panel in that direction (the message zone / the dock stack)
    --   stop        — do nothing
    at_edge = "multiplexer",

    -- The resize step: a number of CELLS, or a percentage STRING of the parent container's size ("5%") — the
    -- same key then means the same thing on an 80-column and a 200-column screen.
    default_amount = 3,

    -- THE PLUGIN'S OWN KEYS. `false` binds nothing at all (the host maps `move`/`resize` itself); a
    -- table binds exactly what it lists, and a direction left out is simply not bound. These are
    -- normal-mode maps set at setup(), the same moment every other part of this plugin is wired.
    --
    -- Named as the actions they perform, not as a flat key list, so a rebind cannot silently point a
    -- "move" key at a resize: the direction is the KEY of the entry and the keystroke is its value.
    keys = {
        move = { left = "<C-h>", down = "<C-j>", up = "<C-k>", right = "<C-l>" },
        resize = { left = "<C-Left>", down = "<C-Down>", up = "<C-Up>", right = "<C-Right>" },
    },

    -- A directional swap moves the buffer; `true` moves the cursor with it (you follow your buffer).
    move_cursor_with_buffer = false,

    -- A zoomed multiplexer pane stays zoomed: no handoff out of it (the move simply stops at the edge).
    disable_multiplexer_nav_when_zoomed = true,

    multiplexer = {
        -- auto = detect from the environment ($TMUX, $WEZTERM_PANE, $KITTY_LISTEN_ON, $ZELLIJ);
        -- a backend name forces it; `false` disables the handoff entirely (edges then behave as "stop").
        backend = "auto",

        -- Neovim MARKS its own pane while it runs (`tmux set-option -p @lvim_nvim 1`, cleared on exit), so the
        -- multiplexer side tests a VARIABLE (`#{@lvim_nvim}`) instead of guessing the process name with
        -- `ps | grep` — no fork per keypress, and correct under a wrapper / sudo / ssh / a renamed binary.
        -- `false` = never mark (for a user who keeps the old process-check bindings; they keep working).
        mark_pane = true,
        pane_option = "@lvim_nvim",

        -- The GENERATED multiplexer bindings stop at the outermost pane instead of wrapping around.
        no_wrap = true,

        -- How long a multiplexer query may take (milliseconds) before it is abandoned — a hung multiplexer
        -- must never hang the keypress.
        timeout = 1000,

        -- The executable of each backend (resolved on $PATH).
        commands = { tmux = "tmux", wezterm = "wezterm", kitty = "kitty", zellij = "zellij" },

        -- The keys the NEOVIM side is bound to. The plugin never binds them itself (the user's keymaps call
        -- the API) — they are declared here so `:LvimWinNav mux-config` and the shipped `lvim-winnav.tmux`
        -- generate the MIRROR bindings for exactly those keys.
        keys = {
            move = { left = "C-h", down = "C-j", up = "C-k", right = "C-l" },
            resize = { left = "C-Left", down = "C-Down", up = "C-Up", right = "C-Right" },
        },
    },

    dock = {
        -- Before an edge behaviour runs, ask the set's docks: when a docked lvim panel sits in that direction
        -- (the message zone below the editor, a bottom/float dock consumer), focus IT instead of leaving
        -- Neovim. `false` = never (the edge behaviour runs unconditionally).
        enabled = true,
    },

    resize_mode = {
        -- Plain keys while the mode owns the keyboard (a getcharstr loop — no keymaps are installed).
        keys = { left = "h", down = "j", up = "k", right = "l", quit = { "<Esc>", "q" } },
        hooks = { on_enter = nil, on_leave = nil },
        -- The lvim-ui hint bar above the statusline: the live keys + the current window's size.
        show_footer = true,
        title = "RESIZE",
        labels = { left = "left", down = "down", up = "up", right = "right", quit = "quit" },
        size_format = "%d x %d",
    },

    -- Windows that must never be resized (their filetype / buftype). Chrome windows are excluded by
    -- construction elsewhere; these are the user's own exceptions.
    ignored_filetypes = {},
    ignored_buftypes = {},

    -- Nerd Font glyphs (single width) + the canonical `➤` pointer.
    icons = {
        mode = "󰩨",
        separator = "➤",
        mux = "󰆍",
    },

    -- Every colour the plugin paints with: an accent (a palette KEY) + a tint ROLE from the shared scale.
    colors = {
        hint_key = { accent = "blue", tint = "badge" },
        hint_label = { accent = "yellow", tint = "label" },
        hint_size = { accent = "green", tint = "strong" },
        hint_sep = { accent = "red", tint = "deep" },
        hint_fill = { accent = "yellow", tint = "bar_fill" },
    },
}
