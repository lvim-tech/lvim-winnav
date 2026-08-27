#!/usr/bin/env sh
#
# lvim-winnav — the TMUX half of the handoff.
#
# tpm runs this on tmux start:  set -g @plugin 'lvim-tech/lvim-winnav'
# Installing the plugin IS the tmux configuration — there is nothing to paste.
#
# It installs root-table bindings for the move / resize keys. Each one asks ONE question: does the pane in
# front of me run Neovim? Neovim answers it itself — while it runs it MARKS its pane with a pane-scoped user
# option (`@lvim_nvim`, set by lvim-winnav on VimEnter and cleared on VimLeave). So the binding tests a tmux
# FORMAT (`#{==:#{@lvim_nvim},1}`) — a variable lookup inside tmux:
#
#   • no `ps -o comm= -t #{pane_tty} | grep -iqE …` process guess, which forks a shell on EVERY keypress
#   • and no false answer under a wrapper, `sudo`, an `ssh` session or a renamed binary
#
# When the pane runs Neovim the key is SENT to it (lvim-winnav decides: move a split, or hand back to tmux at
# the edge). Otherwise tmux moves / resizes the pane itself.
#
# Every binding is root-table (`-n`): none of them uses — or can collide with — your prefix key.
#
# Options (set before the `run` line, e.g. in ~/.tmux.conf):
#
#   @lvim-winnav_move_left_key      default C-h
#   @lvim-winnav_move_down_key      default C-j
#   @lvim-winnav_move_up_key        default C-k
#   @lvim-winnav_move_right_key     default C-l
#   @lvim-winnav_resize_left_key    default C-Left
#   @lvim-winnav_resize_down_key    default C-Down
#   @lvim-winnav_resize_up_key      default C-Up
#   @lvim-winnav_resize_right_key   default C-Right
#   @lvim-winnav_resize_step_size   default 3      cells a resize key moves the pane border
#   @lvim-winnav_no_wrap            default on     stop at the outermost pane instead of wrapping around
#   @lvim-winnav_pane_option        default @lvim_nvim   the pane option Neovim marks itself with
#                                                        (must match `multiplexer.pane_option`)
#   @lvim-winnav_copy_mode          default on     bind the same move keys in copy-mode-vi
#
set -eu

# The value of a tmux user option, or the given default when it is unset/empty.
tmux_option() {
    value=$(tmux show-option -gqv "$1" 2>/dev/null || true)
    if [ -n "$value" ]; then
        printf '%s' "$value"
    else
        printf '%s' "$2"
    fi
}

move_left=$(tmux_option "@lvim-winnav_move_left_key" "C-h")
move_down=$(tmux_option "@lvim-winnav_move_down_key" "C-j")
move_up=$(tmux_option "@lvim-winnav_move_up_key" "C-k")
move_right=$(tmux_option "@lvim-winnav_move_right_key" "C-l")

resize_left=$(tmux_option "@lvim-winnav_resize_left_key" "C-Left")
resize_down=$(tmux_option "@lvim-winnav_resize_down_key" "C-Down")
resize_up=$(tmux_option "@lvim-winnav_resize_up_key" "C-Up")
resize_right=$(tmux_option "@lvim-winnav_resize_right_key" "C-Right")

step=$(tmux_option "@lvim-winnav_resize_step_size" "3")
no_wrap=$(tmux_option "@lvim-winnav_no_wrap" "on")
pane_option=$(tmux_option "@lvim-winnav_pane_option" "@lvim_nvim")
copy_mode=$(tmux_option "@lvim-winnav_copy_mode" "on")

# "This pane runs Neovim" — the mark lvim-winnav sets on itself.
is_nvim="#{==:#{$pane_option},1}"

# select-pane in a direction; with no_wrap, guarded by the matching `#{pane_at_*}` flag so tmux stops at the
# outermost pane instead of wrapping around to the far side.
select_pane() {
    flag=$1
    at=$2
    if [ "$no_wrap" = "on" ]; then
        printf "if-shell -F '#{%s}' '' 'select-pane %s'" "$at" "$flag"
    else
        printf "select-pane %s" "$flag"
    fi
}

# Bind KEY in the root table: forward it to Neovim when the pane is marked, else run the tmux command.
bind_key() {
    key=$1
    fallback=$2
    tmux bind-key -n "$key" if-shell -F "$is_nvim" "send-keys $key" "$fallback"
}

bind_key "$move_left" "$(select_pane -L pane_at_left)"
bind_key "$move_down" "$(select_pane -D pane_at_bottom)"
bind_key "$move_up" "$(select_pane -U pane_at_top)"
bind_key "$move_right" "$(select_pane -R pane_at_right)"

bind_key "$resize_left" "resize-pane -L $step"
bind_key "$resize_down" "resize-pane -D $step"
bind_key "$resize_up" "resize-pane -U $step"
bind_key "$resize_right" "resize-pane -R $step"

# tmux's copy mode is not Neovim: the same keys always move the pane there.
if [ "$copy_mode" = "on" ]; then
    tmux bind-key -T copy-mode-vi "$move_left" select-pane -L
    tmux bind-key -T copy-mode-vi "$move_down" select-pane -D
    tmux bind-key -T copy-mode-vi "$move_up" select-pane -U
    tmux bind-key -T copy-mode-vi "$move_right" select-pane -R
fi
