#!/usr/bin/env bash
# cr's checks, each on a real pty via script(1). Run: ./test.sh
cd "$(dirname "$0")"
fail=0
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX

# 1. Which `claude` invocations get a cr session (uses the real claude's subcommand list).
check() {  # check <wrap|pass> <env assignments or -> <claude args...>
  local want=$1 envs=$2 got; shift 2
  [ "$envs" = - ] && envs=
  got=$(env -u TMUX SSH_CONNECTION="1.2.3.4 5 6.7.8.9 22" ${envs:+"$envs"} script -qec "./cr _wants $(printf '%q ' "$@")" /dev/null </dev/null | tr -d '\r')
  [ "$got" = "$want" ] || { echo "FAIL: claude $* ($envs) -> $got, want $want"; fail=1; }
}
check wrap -
check wrap - --model sonnet
check wrap - -c
check wrap - --resume
check wrap - -r abc123
check wrap - "fix the bug"
check wrap - "update the readme"
check wrap - help
check wrap - --remote-control
check wrap - -n "my; session"
check wrap - -- -p
check pass - -p hi
check pass - --print hi
check pass - -cp hi
check pass - -v
check pass - --version
check pass - -h
check pass - --help
check pass - mcp list
check pass - update
check pass - plugins
check pass - kill abc
check pass - --bg
check pass - -w --tmux
check pass - --model sonnet -p hi
check pass SSH_CONNECTION=
check pass TMUX=/tmp/tmux-1000/default,1,0
[ "$(env -u TMUX SSH_CONNECTION=x ./cr _wants </dev/null)" = pass ] || { echo "FAIL: no tty should pass"; fail=1; }

# 2. What claude actually receives, against a fake claude on a private tmux server and state dir.
tmp=$(mktemp -d)
trap 'TMUX_TMPDIR=$tmp tmux -L cr kill-server 2>/dev/null; rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat >"$tmp/bin/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" != --help ] || { printf 'Options:\n  --remote-control [name]\nCommands:\n  mcp\n'; exit; }
{ printf '[%s]' "$@"; echo; echo "probe=${PROBE:-}"; } >"$FAKE_OUT"
[ -z "${FAKE_FAIL:-}" ] || { echo "boom: bad flag" >&2; exit 3; }
EOF
chmod +x "$tmp/bin/claude"
start() {  # start <expected argv> <expected exit> <env assignments or -> <claude args...>
  local want=$1 code=$2 envs=$3 rc; shift 3
  [ "$envs" = - ] && envs=
  rm -f "$tmp/argv"
  env -u TMUX PATH="$tmp/bin:$PATH" XDG_RUNTIME_DIR="$tmp" TMUX_TMPDIR="$tmp" FAKE_OUT="$tmp/argv" \
    SSH_CONNECTION=x ${envs:+"$envs"} script -qec "./cr --auto $(printf '%q ' "$@")" /dev/null </dev/null >"$tmp/screen"
  rc=$?
  [ "$(head -1 "$tmp/argv" 2>/dev/null)" = "$want" ] || { echo "FAIL: claude $* got argv $(head -1 "$tmp/argv" 2>/dev/null), want $want"; fail=1; }
  [ "$rc" = "$code" ] || { echo "FAIL: claude $* exited $rc, want $code"; fail=1; }
}
start '[fix the bug][--remote-control]' 0 - "fix the bug"
start '[--remote-control][--][-p]' 0 - -- -p
start '[--remote-control][myname]' 0 - --remote-control myname
start '[]' 0 ANTHROPIC_BASE_URL=https://example.invalid
start '[a; b][--remote-control]' 0 PROBE='x y;z' "a; b"
grep -qx 'probe=x y;z' "$tmp/argv" || { echo "FAIL: environment didn't reach claude"; fail=1; }
start '[--bogus][--remote-control]' 3 FAKE_FAIL=1 --bogus
grep -q 'boom: bad flag' "$tmp/screen" || { echo "FAIL: instant error not shown"; fail=1; }
[ -z "$(ls "$tmp"/cr/*.env "$tmp"/cr/*.args "$tmp"/cr/*.out 2>/dev/null)" ] || { echo "FAIL: hand-off files left behind"; fail=1; }

[ $fail = 0 ] && echo "all ok"
exit $fail
