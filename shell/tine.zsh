# tine — zsh integration (no pty)
#
# Feeds the edit buffer to the tine app and drives the suggestion panel: arrow
# keys move the selection, Tab accepts. No pseudo-terminal wrapper — nothing can
# leak the way figterm/kiro-cli-term did.
#
# Enable from ~/.zshrc:  source /path/to/tine.zsh

# Fixed default so the app (which doesn't see this env) agrees on the path.
: ${TINE_SOCK:="$HOME/.local/share/tine/tine.sock"}
export TINE_SOCK

_TINE_US=$'\x1f'
_TINE_ACTIVE=0
_TINE_REPLY=""
_TINE_HIST=0   # in shell-history navigation (Up past the top row), like Fig
_TINE_NAV=0    # one-shot: the next redraw came from our own history nav, not typing
_TINE_AROW=1   # prompt-start cursor row (1-based), captured once per prompt
_TINE_ACOL=1   # prompt-start cursor column (1-based)
_TINE_CW=0     # cell width in device pixels (0 = unknown)
_TINE_CH=0     # cell height in device pixels

# Cell pixel size, queried once per prompt while the tty is idle (precmd, before
# the prompt is drawn — position doesn't matter here, only the cell size).
_tine_cellsize() {
  emulate -L zsh
  local saved b tty=${TTY:-/dev/tty}
  saved=$(stty -g <$tty 2>/dev/null) || return
  stty raw -echo <$tty 2>/dev/null
  print -n $'\e[16t' >$tty                # cell size in px -> ESC[6;height;widtht
  read -r -d t -t 0.3 b <$tty
  stty $saved <$tty 2>/dev/null
  b=${b#*$'\e['}; _TINE_CH=${${b#*;}%%;*}; _TINE_CW=${b##*;}
  [[ "$_TINE_CW" == <-> && "$_TINE_CH" == <-> ]] || { _TINE_CW=0; _TINE_CH=0; }
}

# Prompt-start cursor cell, captured at line-init — after the prompt is drawn and
# before the user types, so the cursor sits exactly where the buffer begins. This
# is the anchor the app offsets the buffer against to place the panel in canvas
# terminals (Ghostty). Not a pty — one cursor-position query per prompt on the
# terminal we already own. ZLE has the tty in raw mode, so no stty dance.
_tine_line_init() {
  local reply
  print -n -- $'\e[6n' >/dev/tty
  read -r -d R -t 0.3 reply </dev/tty
  reply=${reply#*$'\e['}
  _TINE_AROW=${reply%%;*}
  _TINE_ACOL=${reply##*;}
  [[ "$_TINE_AROW" == <-> && "$_TINE_ACOL" == <-> ]] || { _TINE_AROW=1; _TINE_ACOL=1; }
}

# Request/response with the app. Sends "<type><US><cursor><US><cwd><US><buffer>"
# and stores the reply line in _TINE_REPLY. Best-effort; never blocks the prompt.
_tine_req() {
  local type=$1
  [[ -n "$TINE_SOCK" ]] || return 1
  zmodload zsh/net/socket 2>/dev/null || return 1
  local fd
  zsocket "$TINE_SOCK" 2>/dev/null || return 1
  fd=$REPLY
  print -u "$fd" -r -- "${type}${_TINE_US}${CURSOR}${_TINE_US}${PWD}${_TINE_US}${_TINE_AROW};${_TINE_ACOL};${COLUMNS};${LINES};${_TINE_CW};${_TINE_CH}${_TINE_US}${BUFFER}"
  _TINE_REPLY=""
  IFS= read -r -u "$fd" _TINE_REPLY
  exec {fd}>&-
  return 0
}

# Fires on every buffer/cursor change: refresh suggestions, track whether the
# panel is showing (reply = suggestion count). A redraw caused by our own history
# navigation keeps the panel hidden and stays in history mode; any other change
# (the user typing) exits history mode and refreshes suggestions.
_tine_feed() {
  if [[ ${_TINE_NAV:-0} -eq 1 ]]; then _TINE_NAV=0; return; fi
  _TINE_HIST=0
  _tine_req update && _TINE_ACTIVE=${_TINE_REPLY:-0}
}
zle -N _tine_feed

# Hide the panel when the line is submitted/abandoned.
_tine_hide() { _tine_req dismiss; _TINE_ACTIVE=0; _TINE_HIST=0; _TINE_NAV=0; }
zle -N _tine_hide

# Hand off to zsh history (Up past the top row, or Down/Up with no panel). Hides
# the panel and enters history mode so subsequent arrows keep navigating history
# — like Fig — until the user types again.
_tine_history() {
  [[ ${_TINE_ACTIVE:-0} -gt 0 ]] && _tine_req dismiss
  _TINE_ACTIVE=0; _TINE_HIST=1; _TINE_NAV=1
  zle "$1"
}

# Arrow keys: move the selection while the panel is up, else navigate history.
# The app replies "PASS" when it can't move (panel not actually visible, or Up at
# the top row) — hand off to history so navigation isn't hijacked. Down only ever
# moves down the list (clamped) or navigates history; it never leaves history mode.
_tine_up() {
  if [[ ${_TINE_HIST:-0} -eq 0 && ${_TINE_ACTIVE:-0} -gt 0 ]] \
     && _tine_req up && [[ "$_TINE_REPLY" != "PASS" ]]; then
    return
  fi
  _tine_history "$_TINE_UP_WIDGET"
}
_tine_down() {
  if [[ ${_TINE_HIST:-0} -eq 0 && ${_TINE_ACTIVE:-0} -gt 0 ]] \
     && _tine_req down && [[ "$_TINE_REPLY" != "PASS" ]]; then
    return
  fi
  _tine_history "$_TINE_DOWN_WIDGET"
}
zle -N _tine_up
zle -N _tine_down

# Accept the selected suggestion (reply = "<newCursor><US><newBuffer>").
# Returns 0 if accepted, 1 if the panel wasn't active.
_tine_do_accept() {
  [[ ${_TINE_ACTIVE:-0} -gt 0 ]] || return 1
  _tine_req accept || return 1
  [[ -n "$_TINE_REPLY" ]] || return 1
  _TINE_ACTIVE=0
  # Fig's auto-execute row: run the line as-is instead of inserting text.
  if [[ "$_TINE_REPLY" == "EXEC" ]]; then
    zle accept-line
    return 0
  fi
  BUFFER=${_TINE_REPLY#*${_TINE_US}}     # set buffer first
  CURSOR=${_TINE_REPLY%%${_TINE_US}*}    # then cursor within it
  zle redisplay
  return 0
}

# Insert the common prefix of the visible suggestions (keeps panel open).
_tine_do_prefix() {
  [[ ${_TINE_ACTIVE:-0} -gt 0 ]] || return 1
  _tine_req prefix || return 1
  [[ -n "$_TINE_REPLY" ]] || return 1
  BUFFER=${_TINE_REPLY#*${_TINE_US}}
  CURSOR=${_TINE_REPLY%%${_TINE_US}*}
  zle redisplay
  return 0
}

# Fig-exact keys:
#   Tab   -> insert common prefix (else normal completion)
#   Enter -> accept selected (else run the line)
#   Esc   -> dismiss the panel (else no-op)
# Tab: while the panel is up, insert the common prefix and consume the key
# (never fall through to zsh/oh-my-zsh completion). Only when the panel is down
# does Tab run normal shell completion.
_tine_tab() {
  if [[ ${_TINE_ACTIVE:-0} -gt 0 ]]; then
    _tine_do_prefix || zle redisplay
  else
    zle expand-or-complete
  fi
}
_tine_enter() { _tine_do_accept || zle accept-line; }
_tine_esc()   { if [[ ${_TINE_ACTIVE:-0} -gt 0 ]]; then _tine_req dismiss; _TINE_ACTIVE=0; zle redisplay; fi; }
# Ctrl+K: toggle the detail pane while the panel is up (else normal kill-line).
_tine_detail() { if [[ ${_TINE_ACTIVE:-0} -gt 0 ]]; then _tine_req toggleDetail; else zle kill-line; fi; }
zle -N _tine_tab
zle -N _tine_enter
zle -N _tine_esc
zle -N _tine_detail

# Send the shell's aliases to the app so the parser can expand them (pc -> plug-cli).
# Once per prompt: cheap, and survives an app restart.
_tine_send_aliases() {
  [[ -n "$TINE_SOCK" ]] || return
  zmodload zsh/net/socket 2>/dev/null || return
  local fd reply dump
  dump="$(alias | tr '\n' "$_TINE_US")"
  zsocket "$TINE_SOCK" 2>/dev/null || return
  fd=$REPLY
  print -u "$fd" -r -- "aliases${_TINE_US}0${_TINE_US}${PWD}${_TINE_US}0;0;0;0;0;0${_TINE_US}${dump}"
  IFS= read -r -u "$fd" reply
  exec {fd}>&-
}
autoload -Uz add-zsh-hook 2>/dev/null
if (( $+functions[add-zsh-hook] )); then
  add-zsh-hook precmd _tine_send_aliases
  add-zsh-hook precmd _tine_cellsize
fi

autoload -Uz add-zle-hook-widget 2>/dev/null
if (( $+functions[add-zle-hook-widget] )); then
  add-zle-hook-widget line-init _tine_line_init
  add-zle-hook-widget line-pre-redraw _tine_feed
  add-zle-hook-widget line-finish _tine_hide

  # Preserve whatever Up/Down were already bound to (oh-my-zsh binds a prefix
  # search, up-line-or-beginning-search) so history navigation keeps that
  # behaviour instead of a plain, unfiltered walk. Capture before rebinding, and
  # skip our own widgets so re-sourcing doesn't capture them and recurse.
  : ${_TINE_UP_WIDGET:=up-line-or-history}
  : ${_TINE_DOWN_WIDGET:=down-line-or-history}
  _tine_capture() {
    local w=${${(s: :)$(bindkey "$1")}[-1]}
    case "$w" in (_tine_up|_tine_down|''|undefined-key) ;; (*) typeset -g "$2"="$w" ;; esac
  }
  _tine_capture '^[[A' _TINE_UP_WIDGET
  _tine_capture '^[[B' _TINE_DOWN_WIDGET

  bindkey '^[[A' _tine_up;   bindkey '^[OA' _tine_up
  bindkey '^[[B' _tine_down; bindkey '^[OB' _tine_down
  bindkey '^[[Z' _tine_up    # shift+tab -> navigate up (Fig)
  bindkey '^I'   _tine_tab
  bindkey '^M'   _tine_enter
  bindkey '^['   _tine_esc
  bindkey '^K'   _tine_detail
fi
