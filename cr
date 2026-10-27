#!/usr/bin/env bash
# cr: Claude Code in a tmux session that survives SSH drops, with Remote Control on.
set -euo pipefail

IDLE_LIMIT=${CR_IDLE_LIMIT:-7200}  # seconds a detached session may sit idle before `cr reap` kills it
PREFIX=cr-
SELF=$(readlink -f "$0")
T=(tmux -L cr -f "${SELF%/*}/tmux.conf")  # own tmux server and config, apart from any tmux you use yourself
STATE=${XDG_RUNTIME_DIR:-$HOME/.cache}/cr  # hand-off files between a terminal and its session

usage() { cat <<'EOF'
cr: Claude Code sessions that survive SSH disconnects (lid closed) and stay reachable from your phone.

  cr [claude args...]   start claude (with --remote-control) in a new tmux session, attached
  cr a [session]        reattach, taking it over from any other terminal still on it
                        (no name: the most recent session, detached ones first)
  cr ls                 list sessions: Claude status, how long in it, attached / commands running
  cr reap [-n]          kill sessions that are detached, not working and idle for >= CR_IDLE_LIMIT
                        seconds (default 7200 = 2h); -n only prints what it would kill
  cr install            install + start the systemd user timer that runs `cr reap` every 10 min
  cr --auto [args...]   what the `claude` shell function calls: cr session for interactive chats
                        typed into an SSH login, plain claude for everything else (-p, mcp, ...)
  cr login              for your shell rc at SSH login: mentions detached sessions and points
                        their SSH agent at this connection
  cr -h | --help        this help

In a session: Ctrl-Z drops back to your shell (the session keeps running), so does closing the
terminal or the lid. Scrolling works; hold Shift while dragging to select text.
Claude's own Ctrl-B shortcut needs Ctrl-B twice. `command claude` skips cr.
A reaped conversation comes back with `claude --resume`.
EOF
}

# The terminal must be one this machine's terminfo knows (e.g. xterm-ghostty often isn't), or tmux won't draw.
term_ok() { infocmp "${TERM:-dumb}" >/dev/null 2>&1 || export TERM=xterm-256color; }

# Should this `claude` call get a cr session? Only interactive chats typed into an SSH login.
wants_cr() {
  [ -n "${SSH_CONNECTION:-}" ] && [ -z "${TMUX:-}" ] && [ -t 0 ] && [ -t 1 ] || return 1
  [ "${TERM:-dumb}" != dumb ] || return 1  # tmux can't draw on a dumb terminal (Emacs shells, some IDEs)
  local a
  for a in "$@"; do
    case $a in
      --) break ;;
      -p|--print|-v|--version|-h|--help|--bg|--background|--desktop|--cloud|--cloud=*|--tmux|--tmux=*) return 1 ;;
      -[!-]*[pvh]*) return 1 ;;  # short-flag bundle such as -cp
    esac
  done
  [ $# = 0 ] || [[ $1 == -* ]] || ! subcommand "$1"
}

# `claude --help`, cached per installed binary since it changes with updates. Empty if it can't be read.
help_text() {
  local bin c tmp
  bin=$(command -v claude) || return 0
  c=$STATE/help.$(stat -Lc %i.%Y.%s "$bin")
  if [ ! -s "$c" ]; then
    mkdir -p -m 700 "$STATE"
    tmp=$(mktemp "$STATE/.help.XXXXXX")
    claude --help >"$tmp" 2>/dev/null || true
    [ -s "$tmp" ] || { rm -f "$tmp"; return 0; }  # don't cache a failure
    rm -f "$STATE"/help.*
    mv "$tmp" "$c"
  fi
  cat "$c"
}

# Is $1 one of claude's subcommands (mcp, update, ...)?
subcommand() {
  local cmds
  cmds=$(help_text | sed -n '/^Commands:/,$p' | grep -oE '^  [a-z][a-z|-]*' | tr -d ' ' | tr '|' '\n') || true
  [ -n "$cmds" ] || return 0  # couldn't read the list: treat it as a subcommand and leave claude alone
  grep -qxF -- "$1" <<<"$cmds"
}

# Remote Control needs a claude.ai login (not an API key or other provider) and a claude that still has the flag.
remote_ok() {
  [ -z "${ANTHROPIC_BASE_URL:-}${ANTHROPIC_AUTH_TOKEN:-}${ANTHROPIC_API_KEY:-}${CLAUDE_CODE_USE_BEDROCK:-}${CLAUDE_CODE_USE_VERTEX:-}" ] &&
    [[ $(help_text) == *--remote-control* ]]
}

# Sessions outlive the SSH connection whose agent socket they started with, so they get a link that
# every new connection re-aims, and git/ssh inside keep working after you reconnect.
agent_link() {
  [ -S "${SSH_AUTH_SOCK:-}" ] && [ "$SSH_AUTH_SOCK" != "$STATE/agent.sock" ] || return 0
  mkdir -p -m 700 "$STATE"
  ln -sfn "$SSH_AUTH_SOCK" "$STATE/agent.sock"
}

start() {
  local name f a args=() rc=1
  term_ok
  name=$PREFIX$(printf %s "${PWD##*/}" | tr -c 'A-Za-z0-9_-' _)-$RANDOM
  for a in "$@"; do [[ $a == --remote-control || $a == --remote-control=* ]] && rc=0; done
  remote_ok || rc=0
  # The flag takes an optional name, so it goes after the user's args (before any --) where it can't swallow a prompt.
  for a in "$@"; do
    if [ $rc = 1 ] && [ "$a" = -- ]; then args+=(--remote-control); rc=0; fi
    args+=("$a")
  done
  [ $rc = 0 ] || args+=(--remote-control)
  mkdir -p -m 700 "$STATE"
  f=$STATE/$name
  agent_link
  # Environment and args go through private files: tmux -e / argv would show secrets in `ps`,
  # and tmux treats an argument ending in ';' as a command separator.
  (
    umask 077
    [ ! -e "$STATE/agent.sock" ] || [ -z "${SSH_AUTH_SOCK:-}" ] || export SSH_AUTH_SOCK=$STATE/agent.sock
    env -0 >"$f.env"
    printf '%s\0' "$PWD" "${args[@]}" >"$f.args"
  )
  # Created attached in one step, so even a claude that dies instantly has a terminal to report to.
  TMUX= "${T[@]}" new-session -s "$name" "$SELF" _run "$f" || { rm -f "$f.env" "$f.args"; return 1; }
  finish "$name"
}

# Inside the pane: become the caller's exact environment, run claude, then hand its last screen back.
run() {
  local f=$1 v kv env a rc=0
  mapfile -d '' -t env <"$f.env"
  mapfile -d '' -t a <"$f.args"
  rm -f "$f.env" "$f.args"
  for v in $(compgen -e); do
    case $v in TERM|TMUX|TMUX_PANE) ;; *) unset "$v" 2>/dev/null || true ;; esac
  done
  for kv in "${env[@]}"; do
    case ${kv%%=*} in TERM|TMUX|TMUX_PANE|COLUMNS|LINES) ;; *) export "$kv" 2>/dev/null || true ;; esac
  done
  trap : INT QUIT  # a stray Ctrl-C must not kill this wrapper; claude still gets it (handlers reset on exec)
  if cd "${a[0]}"; then claude "${a[@]:1}" || rc=$?; else rc=1; fi
  # Whoever is attached gets the screen claude left (errors, the resume command) in their own terminal.
  [ "$(tmux display -p -t "$TMUX_PANE" '#{session_attached}')" != 0 ] || return 0
  { echo "$rc"; tmux capture-pane -p -J -t "$TMUX_PANE" -S -60; } >"$f.out"
}

# After a terminal leaves session $1: print what claude left if it exited (and return its exit code),
# or say how to get back in if it's still running.
finish() {
  local out=$STATE/$1.out rc=0
  if [ -e "$out" ]; then
    { read -r rc; awk 'NF {for (; n; n--) print ""; print; next} {n++}'; } <"$out"
    rm -f "$out"
    return "$rc"
  fi
  if "${T[@]}" has-session -t "=$1" 2>/dev/null; then echo "cr: $1 is still running. Back in with: cr a"; fi
}

attach() {
  local t
  t=$("${T[@]}" ls -F '#{session_attached} #{session_activity} #{session_name}' 2>/dev/null |
      sort -k1,1n -k2,2nr | awk -v q="${1:-}" 'q == "" || $3 == q {print $3; exit}') || true
  [ -n "$t" ] || { echo "cr: ${1:+no session named }${1:-no sessions}" >&2; return 1; }
  term_ok
  agent_link
  # -d: take it over. A terminal from a closed lid can look attached for hours until its TCP connection times out.
  TMUX= "${T[@]}" attach -d -t "=$t" || return
  finish "$t"
}

# One line per session: <name> <attached clients> <claude status> <secs in it> <secs since screen changed> <commands running>
sessions() {
  local now name att pane act pid cfg st at tools
  now=$(date +%s)
  { "${T[@]}" ls -F '#{session_name} #{session_attached} #{pane_pid} #{window_activity}' 2>/dev/null || true; } |
    while read -r name att pane act; do
      pid=$(pgrep -P "$pane" | head -1) || true  # claude runs under the `cr _run` wrapper
      st= at= tools=0
      if [ -n "$pid" ]; then
        cfg=$(tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null | sed -n 's/^CLAUDE_CONFIG_DIR=//p') || true
        IFS=$'\t' read -r st at < <(jq -r '[(.status // ""), ((.statusUpdatedAt // 0) / 1000 | floor)] | @tsv' \
          "${cfg:-$HOME/.claude}/sessions/$pid.json" 2>/dev/null) || true
        tools=$(pgrep -c -P "$pid" -f shell-snapshots) || true  # Bash tool commands, background ones included
      fi
      # No status from Claude (still starting, trust prompt, older version): go by the screen instead.
      if [ -z "$st" ] || [ "${at:-0}" -le 0 ]; then st=unknown at=$act; fi
      echo "$name $att $st $((now - at)) $((now - act)) ${tools:-0}"
    done
}

list() {
  local name att st secs quiet tools note
  printf '%-32s %-8s %-6s %s\n' SESSION STATUS FOR NOTE
  sessions | while read -r name att st secs quiet tools; do
    note=()
    [ "$att" = 0 ] || note+=(attached)
    [ "$tools" = 0 ] || note+=("$tools command(s) running")
    printf '%-32s %-8s %-6s %s\n' "$name" "$st" "$((secs / 60))m" "$(printf '%s, ' "${note[@]}" | sed 's/, $//')"
  done
}

reap() {
  local name att st secs quiet tools
  sessions | while read -r name att st secs quiet tools; do
    # Kill only if nobody's on it, the agent isn't working or running a command, and both Claude
    # and the screen have been still for the whole limit. Waiting on a prompt that long = abandoned.
    # Statuses are allowlisted: busy, shell (background command) or anything new keeps it alive.
    [ "$att" = 0 ] && [[ $st == idle || $st == waiting || $st == unknown ]] && [ "$tools" = 0 ] &&
      [ "$secs" -ge "$IDLE_LIMIT" ] && [ "$quiet" -ge "$IDLE_LIMIT" ] || continue
    echo "reaping $name ($st for $((secs / 60))m)"
    [ "${1:-}" = -n ] || "${T[@]}" kill-session -t "=$name" || true
  done
  # Last screens nobody came back for (a session exited under a plain `tmux attach`).
  find "$STATE" -maxdepth 1 -name '*.out' -mmin +60 -delete 2>/dev/null || true
}

login() {
  local n
  agent_link
  n=$("${T[@]}" ls -F '#{session_attached}' 2>/dev/null | grep -cx 0) || true
  [ "${n:-0}" = 0 ] || echo "cr: $n detached Claude session(s). cr a reattaches, cr ls lists them."
}

install_timer() {
  local d=~/.config/systemd/user
  mkdir -p "$d"
  cat >"$d/cr-reap.service" <<EOF
[Unit]
Description=Kill cr Claude sessions left detached and idle

[Service]
Type=oneshot
ExecStart=$SELF reap
EOF
  cat >"$d/cr-reap.timer" <<'EOF'
[Timer]
OnCalendar=*:0/10

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now cr-reap.timer
  loginctl show-user "$USER" -p Linger | grep -q yes ||
    echo "cr: run 'sudo loginctl enable-linger $USER' so the timer runs while you're logged out" >&2
}

case ${1:-} in
  -h|--help) usage ;;
  a) shift; attach "$@" ;;
  ls) list ;;
  reap) shift; reap "$@" ;;
  login) login ;;
  install) install_timer ;;
  _run) run "$2"; exit ;;  # exit before bash reads further: the script may have been edited since
  _wants) shift; if wants_cr "$@"; then echo wrap; else echo pass; fi ;;
  --auto) shift; if wants_cr "$@"; then start "$@"; else exec claude "$@"; fi ;;
  *) start "$@" ;;
esac
