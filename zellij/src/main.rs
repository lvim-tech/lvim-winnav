// lvim-winnav — the ZELLIJ half of the handoff (the counterpart of `lvim-winnav.tmux`).
//
// zellij's own keybinds run in the SERVER: `bind "Ctrl l" { MoveFocus "right"; }` moves the zellij
// pane before the program inside it ever sees the key, so Neovim's internal windows are skipped.
// And zellij has no pane-scoped variable and no conditional keybind, so — unlike tmux — the
// question "does the pane in front of me run Neovim?" cannot be asked from the config at all. This
// plugin asks it instead: the config binds the nav keys to a `MessagePlugin` pipe, the plugin looks
// at the FOCUSED terminal pane of the active tab, and either
//
//   • FORWARDS the key into that pane (`write_chars_to_pane_id`) when it runs Neovim — Neovim then
//     moves a split, or, at the edge of its layout, calls `zellij action move-focus` itself — or
//   • moves / resizes the zellij pane itself when it does not.
//
// "Runs Neovim" is the same MARK contract the tmux half uses, translated to what zellij has:
// Neovim (lvim-winnav's mux/zellij.lua) RENAMES its own pane to the marker on VimEnter and undoes
// the rename on VimLeave, so the plugin tests the focused pane's TITLE — a lookup, not a process
// guess, and correct under a wrapper / sudo / ssh / a renamed binary. As a fallback (Neovim
// without lvim-winnav, or marks disabled) a title or command of `nvim` also counts: zellij titles
// a pane after its running command by default.
//
// LOADING — exactly one instance, on purpose: a `load_plugins` entry in config.kdl with the SAME
// URL the keybinds pipe to. That preloaded background instance is the one every keybind pipe
// reaches (measured on zellij 0.46). Without the entry the plugin still works, less gracefully:
// the first nav keypress's pipe launches its target — into a VISIBLE tiled pane, which is how
// zellij launches a keybind pipe's missing target — and that keypress is stashed here and
// honoured on the first PaneUpdate, milliseconds later. (A `MessageToPlugin` pre-warm from
// another plugin does NOT work as a substitute: it carries a different identity and the keybind
// pipes never reach it.) NEVER place the plugin in a layout: a layout plugin is instantiated once
// per tab, every instance receives every pipe, and N instances would forward N keystrokes.
// Against that misconfiguration each instance locates its own pane in the PaneManifest and, when
// it does live in a tab, acts only while that tab is the active one; the intended background
// instance lives in no tab and always acts.
//
// The plugin only ever reacts to a pipe. It never intercepts the keyboard (no
// `intercept_key_presses`) and it renders nothing, so it can never lock the keyboard.

use std::collections::BTreeMap;
use zellij_tile::prelude::*;

/// The title marker Neovim sets on its own pane (mux/zellij.lua `mark_pane`). Must match
/// lvim-winnav's `multiplexer.pane_option` ("@lvim_nvim" by default).
const MARKER: &str = "@lvim_nvim";

/// What a forwarded key looks like on the pane's STDIN: the legacy control byte (move) or the
/// xterm CSI sequence (resize) that Neovim decodes back into the pressed key.
fn chars_for(action: &str, dir: Direction) -> Option<&'static str> {
    match (action, dir) {
        ("move", Direction::Left) => Some("\u{8}"),  // C-h
        ("move", Direction::Down) => Some("\u{a}"),  // C-j
        ("move", Direction::Up) => Some("\u{b}"),    // C-k
        ("move", Direction::Right) => Some("\u{c}"), // C-l
        ("resize", Direction::Left) => Some("\u{1b}[1;5D"), // C-Left
        ("resize", Direction::Down) => Some("\u{1b}[1;5B"), // C-Down
        ("resize", Direction::Up) => Some("\u{1b}[1;5A"),   // C-Up
        ("resize", Direction::Right) => Some("\u{1b}[1;5C"), // C-Right
        _ => None,
    }
}

/// The first word of `s`, as a bare program name: basename, lowercased.
fn command_word(s: &str) -> Option<String> {
    s.split_whitespace()
        .next()
        .map(|w| w.rsplit('/').next().unwrap_or(w).to_ascii_lowercase())
}

/// Does this pane run Neovim? The explicit mark first (the contract), then the default
/// command-as-title / command panes as a fallback.
fn is_nvim(pane: &PaneInfo) -> bool {
    if pane.is_plugin {
        return false;
    }
    if pane.title.contains(MARKER) {
        return true;
    }
    if command_word(&pane.title).as_deref() == Some("nvim") {
        return true;
    }
    pane.terminal_command.as_deref().and_then(command_word).as_deref() == Some("nvim")
}

/// The pane a `PaneId` names: terminal and plugin panes number separately.
fn pane_by_id(panes: &[PaneInfo], id: PaneId) -> Option<&PaneInfo> {
    let (wanted, plugin) = match id {
        PaneId::Terminal(n) => (n, false),
        PaneId::Plugin(n) => (n, true),
    };
    panes.iter().find(|p| p.id == wanted && p.is_plugin == plugin)
}

#[derive(Default)]
struct State {
    panes: PaneManifest,
    tabs: Vec<TabInfo>,
    own_plugin_id: Option<u32>,
    own_client_id: Option<u16>,
    clients: Vec<ClientInfo>,
    /// A nav key that arrived before the first PaneUpdate. The very first keypress of a session
    /// LAUNCHES this plugin (a `MessagePlugin` pipe launches its target when none is running), and
    /// that pipe is delivered before any state: instead of swallowing the user's key, it is
    /// stashed here and honoured the moment the manifest arrives — milliseconds later.
    pending: Option<(String, Direction)>,
}

register_plugin!(State);

impl ZellijPlugin for State {
    fn load(&mut self, _configuration: BTreeMap<String, String>) {
        request_permission(&[
            PermissionType::ReadApplicationState,   // PaneUpdate / TabUpdate
            PermissionType::ChangeApplicationState, // move_focus / resize
            PermissionType::WriteToStdin,           // forward the key into Neovim's pane
        ]);
        subscribe(&[EventType::PaneUpdate, EventType::TabUpdate, EventType::ListClients]);
        let ids = get_plugin_ids();
        self.own_plugin_id = Some(ids.plugin_id);
        self.own_client_id = Some(ids.client_id);
        list_clients();
    }

    fn update(&mut self, event: Event) -> bool {
        match event {
            Event::PaneUpdate(manifest) => {
                self.panes = manifest;
                list_clients(); // a client attaching or leaving shows up as a pane update
            }
            Event::TabUpdate(tabs) => {
                self.tabs = tabs;
                list_clients();
            }
            Event::ListClients(clients) => self.clients = clients,
            _ => {}
        }
        // The keypress that launched this instance, replayed now that the state exists.
        if self.pending.is_some() && self.ready() {
            if let Some((action, dir)) = self.pending.take() {
                self.act(&action, dir);
            }
        }
        false // nothing to render, ever
    }

    fn pipe(&mut self, message: PipeMessage) -> bool {
        let action = message.name.as_str();
        if action != "move" && action != "resize" {
            return false;
        }
        let dir = message
            .payload
            .as_deref()
            .and_then(|p| p.parse::<Direction>().ok());
        if let Some(dir) = dir {
            if !self.ready() {
                // Cold start: this very pipe launched the plugin. Keep the key for the state.
                self.pending = Some((action.to_string(), dir));
            } else {
                self.act(action, dir);
            }
        }
        false
    }
}

impl State {
    /// Everything `act` reads has arrived.
    fn ready(&self) -> bool {
        !self.panes.panes.is_empty() && !self.tabs.is_empty() && !self.clients.is_empty()
    }

    /// Zellij runs one instance per attached client and pipes every keypress to each of them,
    /// without saying which client pressed. Two terminals on one session therefore forwarded each
    /// key twice (measured: two `\n` 1.3 ms apart), so one `<C-j>` moved two steps. Only the
    /// instance of the lowest client id answers.
    fn is_responder(&self) -> bool {
        let lowest = self.clients.iter().map(|c| c.client_id).min();
        lowest.is_none() || lowest == self.own_client_id
    }

    /// The tab this instance is EMBEDDED in as a tiled layout pane — None for the intended
    /// BACKGROUND instance. (A background plugin still appears in the manifest — `load_plugins`
    /// lists it as suppressed, a pipe-launch as floating — so "in no tab" alone is not the test:
    /// embedded means a TILED, non-suppressed plugin pane, the way a layout instantiates it.)
    fn own_tab(&self) -> Option<usize> {
        let own_id = self.own_plugin_id?;
        for (tab_position, panes) in &self.panes.panes {
            if panes
                .iter()
                .any(|p| p.is_plugin && p.id == own_id && !p.is_floating && !p.is_suppressed)
            {
                return Some(*tab_position);
            }
        }
        None
    }

    /// The focused pane of the ACTIVE tab. Zellij is asked outright, because the manifest's
    /// `is_focused` can hold for several panes of one tab: with a Neovim pane below a shell, the
    /// shell could still be flagged, it came first, and the key moved the zellij focus instead of
    /// reaching Neovim. The flag is only the fallback, in the layer the user actually sees (a
    /// visible floating layer covers the tiled one).
    fn focused_pane(&self) -> Option<(&TabInfo, &PaneInfo)> {
        let tab = self.tabs.iter().find(|t| t.active)?;
        let panes = self.panes.panes.get(&tab.position)?;
        if let Ok((_, id)) = get_focused_pane_info() {
            if let Some(pane) = pane_by_id(panes, id) {
                return Some((tab, pane));
            }
        }
        let floating = tab.are_floating_panes_visible;
        let pane = panes
            .iter()
            .find(|p| p.is_focused && !p.is_suppressed && p.is_floating == floating)?;
        Some((tab, pane))
    }

    /// One nav keypress: forward it into Neovim's pane, or move / resize the zellij pane.
    fn act(&self, action: &str, dir: Direction) {
        if !self.is_responder() {
            return;
        }
        let Some((tab, pane)) = self.focused_pane() else {
            return;
        };
        // The multi-instance guard: an instance that lives in a tab (someone put the plugin in a
        // layout) acts only while ITS tab is the active one — a pipe reaches every instance, and
        // only one of them may answer it.
        if let Some(own) = self.own_tab() {
            if own != tab.position {
                return;
            }
        }
        if is_nvim(pane) {
            if let Some(chars) = chars_for(action, dir) {
                write_chars_to_pane_id(chars, PaneId::Terminal(pane.id));
            }
            return;
        }
        match action {
            // move_focus is edge-safe by design: at the outermost pane it is a no-op — it never
            // wraps and never switches the tab (lvim-winnav's `no_wrap` behaviour).
            "move" => move_focus(dir),
            "resize" => resize_focused_pane_with_direction(Resize::Increase, dir),
            _ => {}
        }
    }
}
