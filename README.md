# lvim-winnav

One set of keys that **moves the cursor**, **resizes splits** — and, at the edge of the Neovim layout, hands
off to the **terminal multiplexer**, so the same `<C-h/j/k/l>` walks straight into the tmux pane next door and
back.

It owns the three things its siblings do not: directional **navigation**, **resizing**, and the multiplexer
**handoff**. (`lvim-winpick` picks a window by label; `lvim-winmove` rearranges windows — a directional swap
here delegates the exchange to it rather than growing a second implementation.)

## The handoff has two halves — the plugin ships both

- **Neovim's half** — at an edge, tell the multiplexer to select (or resize) the pane that way.
- **The multiplexer's half** — a key pressed while the pane runs Neovim must be _forwarded_ to it instead of
  moving the pane. `:LvimWinNav mux-config` prints that config for the detected multiplexer, and
  `lvim-winnav.tmux` (a script at the repo root) installs it for tmux users: `set -g @plugin
  'lvim-tech/lvim-winnav'` **is** the whole tmux configuration.

The tmux half tests a **pane mark**, not a process guess: while Neovim runs it sets the pane-scoped option
`@lvim_nvim`, so the tmux binding evaluates `#{==:#{@lvim_nvim},1}` — a variable lookup inside tmux. The usual
`is_vim="ps -o state= -o comm= -t '#{pane_tty}' | grep -iqE …"` idiom forks a shell on **every keypress** and
lies under a wrapper, `sudo`, an `ssh` session or a renamed binary. (Existing `is_vim` bindings keep working —
nothing here requires the plugin's own tmux half.)

## Features

- **Directional navigation** — `move("left"|"down"|"up"|"right")`. At the edge of the layout, `at_edge`
  decides: `multiplexer` · `wrap` · `split` · `dock` · `stop` — one value, or **one per direction**.
- **Dock-aware edges** — before an edge behaviour runs, a docked lvim panel in that direction (the message
  zone) is focused instead of leaving Neovim. That is what `<C-j>` should do, as a config value.
- **Resizing with the right semantics** — the boundary in the pressed direction moves in that direction, from
  any window in the pair. At the outermost edge the boundary belongs to the multiplexer, so the same key
  resizes the **pane**.
- **Layout-aware amounts** — `default_amount = "5%"` is a percentage of the parent container, so the same key
  means the same step on an 80-column and a 200-column screen.
- **Interactive resize mode** — enter once, then plain `h/j/k/l` resize until `<Esc>`; a themed hint bar above
  the statusline shows the live keys and the window's size.
- **Directional buffer swap** — `swap("left")` exchanges the buffer with the window that way (through
  `lvim-winmove`), optionally taking the cursor along.
- **Four multiplexer backends** — tmux · WezTerm · kitty · Zellij, auto-detected. No multiplexer degrades to
  `stop`: never an error.
- **`:checkhealth lvim-winnav`** answers the only question this plugin ever gets asked — _why doesn't the
  handoff work_: the detected multiplexer, whether its binary is reachable, the exact commands it runs,
  whether this pane is marked, and whether the running multiplexer already forwards the keys.

## Install

With the lvim-tech installer:

```lua
require("lvim-installer").install({ "lvim-tech/lvim-winnav" })
```

Or with Neovim's native package manager:

```lua
vim.pack.add({ "https://github.com/lvim-tech/lvim-winnav" })
```

Then, in tmux (the other half):

```tmux
set -g @plugin 'lvim-tech/lvim-winnav'
```

## Usage

The plugin binds nothing — the keys are yours:

```lua
local winnav = require("lvim-winnav")

vim.keymap.set("n", "<C-h>", function()
    winnav.move("left")
end, { desc = "Window left" })
vim.keymap.set("n", "<C-j>", function()
    winnav.move("down")
end, { desc = "Window down" })
vim.keymap.set("n", "<C-k>", function()
    winnav.move("up")
end, { desc = "Window up" })
vim.keymap.set("n", "<C-l>", function()
    winnav.move("right")
end, { desc = "Window right" })

vim.keymap.set("n", "<C-Left>", function()
    winnav.resize("left")
end, { desc = "Resize left" })
vim.keymap.set("n", "<C-Down>", function()
    winnav.resize("down")
end, { desc = "Resize down" })
vim.keymap.set("n", "<C-Up>", function()
    winnav.resize("up")
end, { desc = "Resize up" })
vim.keymap.set("n", "<C-Right>", function()
    winnav.resize("right")
end, { desc = "Resize right" })
```

Whatever keys you choose, tell the plugin (`multiplexer.keys`) — that is what the generated multiplexer
config binds on the other side.

### Commands

| Command                            | What it does                                                     |
| ---------------------------------- | ---------------------------------------------------------------- |
| `:LvimWinNav left\|down\|up\|right` | Move the cursor; at the edge, run the `at_edge` behaviour         |
| `:LvimWinNav resize <dir> [amount]` | Move the boundary in `<dir>` (cells, or a percentage like `10%`)  |
| `:LvimWinNav swap <dir>`            | Swap the buffer with the window that way                          |
| `:LvimWinNav resize-mode`           | Interactive resize (`h/j/k/l`, `<Esc>` to leave)                  |
| `:LvimWinNav mux-config`            | Show the ready-to-paste config for the detected multiplexer (`y` copies it) |

### API

```lua
require("lvim-winnav").move(dir) -- "left" | "down" | "up" | "right"
require("lvim-winnav").resize(dir, amount) -- amount: cells | "5%" | nil (config default)
require("lvim-winnav").swap(dir)
require("lvim-winnav").resize_mode()
require("lvim-winnav").end_resize_mode()
require("lvim-winnav").multiplexer() -- "tmux" | "wezterm" | "kitty" | "zellij" | nil
require("lvim-winnav").mux_config() -- the generated config block, as lines
```

## The tmux side

`lvim-winnav.tmux` is a POSIX shell script tmux runs on start (via tpm). It installs the root-table bindings
that forward the keys into Neovim when the pane is marked, and move / resize the pane when it is not. Every
binding is `-n` (root table): **none of them uses, or can collide with, your prefix key.**

```tmux
set -g @plugin 'lvim-tech/lvim-winnav'
```

Its options (set them before the tpm `run` line):

| tmux option                     | Default      | Meaning                                              |
| ------------------------------- | ------------ | ---------------------------------------------------- |
| `@lvim-winnav_move_left_key`    | `C-h`        | The key that moves left                              |
| `@lvim-winnav_move_down_key`    | `C-j`        | The key that moves down                              |
| `@lvim-winnav_move_up_key`      | `C-k`        | The key that moves up                                |
| `@lvim-winnav_move_right_key`   | `C-l`        | The key that moves right                             |
| `@lvim-winnav_resize_left_key`  | `C-Left`     | The key that resizes left                            |
| `@lvim-winnav_resize_down_key`  | `C-Down`     | The key that resizes down                            |
| `@lvim-winnav_resize_up_key`    | `C-Up`       | The key that resizes up                              |
| `@lvim-winnav_resize_right_key` | `C-Right`    | The key that resizes right                           |
| `@lvim-winnav_resize_step_size` | `3`          | Cells a resize key moves the pane border             |
| `@lvim-winnav_no_wrap`          | `on`         | Stop at the outermost pane instead of wrapping around |
| `@lvim-winnav_pane_option`      | `@lvim_nvim` | The pane option Neovim marks itself with (must match `multiplexer.pane_option`) |
| `@lvim-winnav_copy_mode`        | `on`         | Bind the same move keys in `copy-mode-vi`            |

Not using tpm? `:LvimWinNav mux-config` prints exactly the same bindings, ready to paste into `tmux.conf`
(and the same for WezTerm, kitty and Zellij).

## Default configuration

The complete option set, every value at its default:

```lua
require("lvim-winnav").setup({
    -- What a move does when there is no Neovim window in that direction. One value for every direction, or a
    -- per-direction table — e.g. `{ left = "multiplexer", right = "multiplexer", up = "multiplexer",
    -- down = "dock" }` so the bottom key descends into the message zone instead of leaving Neovim.
    --   multiplexer — select the tmux/wezterm/kitty/zellij pane that way (no multiplexer ⇒ stop)
    --   wrap        — wrap around to the window at the opposite edge
    --   split       — open a new split that way
    --   dock        — focus the docked lvim panel that way (the message zone / the dock stack)
    --   stop        — do nothing
    at_edge = "multiplexer",

    -- The resize step: a number of CELLS, or a percentage STRING of the parent container's size ("5%").
    -- The plugin's OWN normal-mode maps, bound at setup(). `false` binds nothing (map the API
    -- yourself); a direction left out of a table is simply not bound.
    keys = {
        move = { left = "<C-h>", down = "<C-j>", up = "<C-k>", right = "<C-l>" },
        resize = { left = "<C-Left>", down = "<C-Down>", up = "<C-Up>", right = "<C-Right>" },
    },
    default_amount = 3,

    -- A directional swap moves the buffer; `true` moves the cursor with it.
    move_cursor_with_buffer = false,

    -- A zoomed multiplexer pane stays zoomed: no handoff out of it.
    disable_multiplexer_nav_when_zoomed = true,

    multiplexer = {
        -- auto = detect from the environment ($TMUX, $WEZTERM_PANE, $KITTY_LISTEN_ON, $ZELLIJ);
        -- a backend name forces it; `false` disables the handoff (edges then behave as "stop").
        backend = "auto",

        -- Neovim marks its own pane while it runs, so the multiplexer side tests a variable instead of
        -- guessing the process name. `false` = never mark.
        mark_pane = true,
        pane_option = "@lvim_nvim",

        -- The generated multiplexer bindings stop at the outermost pane instead of wrapping around.
        no_wrap = true,

        -- How long a multiplexer query may take (milliseconds) before it is abandoned.
        timeout = 1000,

        -- The executable of each backend (resolved on $PATH).
        commands = { tmux = "tmux", wezterm = "wezterm", kitty = "kitty", zellij = "zellij" },

        -- The keys YOUR Neovim keymaps use. The plugin binds nothing itself — these are declared so
        -- `:LvimWinNav mux-config` and `lvim-winnav.tmux` generate the mirror bindings for exactly them.
        keys = {
            move = { left = "C-h", down = "C-j", up = "C-k", right = "C-l" },
            resize = { left = "C-Left", down = "C-Down", up = "C-Up", right = "C-Right" },
        },
    },

    dock = {
        -- Before an edge behaviour runs, focus a docked lvim panel in that direction (the message zone)
        -- instead of leaving Neovim. `false` = never.
        enabled = true,
    },

    resize_mode = {
        -- Plain keys while the mode owns the keyboard (a getcharstr loop — no keymaps are installed).
        keys = { left = "h", down = "j", up = "k", right = "l", quit = { "<Esc>", "q" } },
        hooks = { on_enter = nil, on_leave = nil },
        -- The hint bar above the statusline: the live keys + the current window's size.
        show_footer = true,
        title = "RESIZE",
        labels = { left = "left", down = "down", up = "up", right = "right", quit = "quit" },
        size_format = "%d x %d",
    },

    -- Windows that must never be resized.
    ignored_filetypes = {},
    ignored_buftypes = {},

    -- Nerd Font glyphs (single width) + the canonical `➤` pointer.
    icons = {
        mode = "󰩨",
        separator = "➤",
        mux = "󰆍",
    },

    -- Every colour: an accent (a palette KEY, never a hex) + a tint ROLE from the shared lvim-utils scale.
    colors = {
        hint_key = { accent = "blue", tint = "badge" },
        hint_label = { accent = "yellow", tint = "label" },
        hint_size = { accent = "green", tint = "strong" },
        hint_sep = { accent = "red", tint = "deep" },
        hint_fill = { accent = "yellow", tint = "bar_fill" },
    },
})
```

## How resizing decides

One invariant: **the boundary in the pressed direction moves in that direction.**

- With `A│B` and the cursor in `A`, `resize left` moves the shared boundary left — `A` shrinks.
- With the cursor in `B`, the same key moves the same boundary left — `B` grows.
- At the outermost edge of the layout there is no Neovim boundary that way, so the boundary in that direction
  is the multiplexer's pane border: the key resizes the **pane** (when `at_edge` is `multiplexer`).

Percentages are measured against the **parent container** (the enclosing row / column of the window layout),
not the screen — so `"10%"` is the same visual step at any nesting depth and any terminal size.

## What each backend can do

| Backend | Move | Resize | Edge query        | Zoom guard | Pane mark |
| ------- | ---- | ------ | ----------------- | ---------- | --------- |
| tmux    | yes  | yes    | yes (`pane_at_*`) | yes        | yes       |
| WezTerm | yes  | yes    | yes (`get-pane-direction`) | yes | not needed |
| kitty   | yes  | yes    | the move answers (kitty has no query) | n/a | not needed |
| Zellij  | yes  | yes    | the move answers (Zellij has no query) | n/a | not needed |

A backend that cannot be asked never guesses: the move itself is the answer (it fails, or no-ops, when there
is nothing that way).

## Health

`:checkhealth lvim-winnav` reports the detected multiplexer and how it was detected, whether its binary is
reachable, **the exact commands** the plugin runs, whether this pane is marked, whether the running
multiplexer forwards the keys (and whether those bindings use the mark), the effective `at_edge` per
direction, and the resize step in cells at the current size.

## License

BSD-3-Clause
