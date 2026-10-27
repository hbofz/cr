# cr

Keep Claude Code alive when your SSH connection drops, and reachable from your phone.

You SSH into a machine, start `claude`, close your laptop lid, and the session dies with the connection. With `cr`, `claude` over SSH runs inside its own tmux session with Remote Control turned on. The lid can close, the agent keeps working, and you can carry on from the Claude app on your phone. Sessions you forget about get cleaned up after two idle hours.

## Install

Needs Linux, bash, tmux, jq, and Claude Code logged in with a claude.ai account. Remote Control doesn't work with API keys or other providers; cr still keeps those sessions alive, just without the phone link.

```sh
git clone https://github.com/hbofz/cr ~/.local/share/cr
ln -s ~/.local/share/cr/cr ~/.local/bin/cr   # any directory on your PATH
cr install                                   # cleanup timer (systemd user unit)
```

Then add this to `~/.bashrc` on the server, after your PATH setup:

```bash
if [ -n "${SSH_CONNECTION:-}" ] && command -v cr >/dev/null; then
  claude() { cr --auto "$@"; }
  if shopt -q login_shell; then cr login; fi
fi
```

(zsh: use `[[ -o login ]]` in place of `shopt -q login_shell`.) For the cleanup to run while you're logged out: `sudo loginctl enable-linger $USER`.

## Use

Keep typing `claude`. Over SSH, interactive sessions (`claude`, `claude -c`, `claude --resume`, `claude "a prompt"`, ...) open in a cr session. Everything else (`-p`, `mcp`, `update`, pipes, scripts) runs exactly as before, and nothing changes when you're not on SSH.

| | |
|---|---|
| Ctrl-Z | back to your shell, the session keeps running |
| `cr a` | reattach (takes it over from a stale terminal) |
| `cr ls` | list sessions with their status |
| `command claude` | plain claude, no cr |

When you SSH in and sessions are waiting, you get one line saying so. `cr --help` has the rest.

## What it takes care of

- **Your environment comes along.** Venvs, exported variables, wrapper functions that point Claude at another provider. It's handed over through private files, never through command-line arguments other users could read in `ps`.
- **Errors aren't lost.** When Claude exits, its last screen (an error, the resume command) and its exit code come back to your terminal.
- **SSH agent forwarding keeps working** after you reconnect: sessions use a socket link that each new login re-aims.
- **Its own tmux server** (`tmux -L cr`) with its own config, so your tmux setup neither matters nor gets touched.

## Cleanup rules

Every 10 minutes `cr reap` kills a session only when all of these hold:

- no terminal is attached
- Claude has been idle, or waiting on a prompt, for 2 hours (busy, running a background command, or any status cr doesn't know keeps it alive)
- none of its Bash commands are still running
- the screen hasn't changed for 2 hours

The conversation is saved, so `claude --resume` brings it back. To change the limit, `systemctl --user edit cr-reap.service`:

```ini
[Service]
Environment=CR_IDLE_LIMIT=3600
```

## Claude Code updates

cr reads a few things Claude Code doesn't document, and each one degrades safely if an update changes it:

- **Session status files** (`~/.claude/sessions/<pid>.json`): without them cr judges by the screen, and a status it doesn't recognize is never reaped.
- **`claude --help`**: re-read after every update, for the subcommand list and to check `--remote-control` still exists. If the flag is gone, sessions start without it rather than failing.

Sessions already running keep the version they started with.

## Tips

- **Ghostty:** servers often lack the `xterm-ghostty` terminfo, which breaks `clear` and tmux. cr falls back to `xterm-256color`. To fix it everywhere, add `shell-integration-features = ssh-terminfo` to your Ghostty config.
- **Dead connections can look attached.** Without keepalives, a sleeping laptop's SSH connection can count as attached for about two hours until TCP gives up, which also delays cleanup. `ClientAliveInterval 60` in the server's `sshd_config` drops them within minutes. `cr a` takes the session over either way.
- **Wrappers like `env VAR=... claude`** skip the shell function. Use a subshell with `export` instead: `myclaude() ( export VAR=...; claude "$@" )`.
- Claude's own Ctrl-B shortcut needs Ctrl-B twice inside cr (it's the tmux prefix).

## Tests

`./test.sh` checks which invocations get wrapped, then runs cr against a fake `claude` on a private tmux server to check the arguments, environment and exit code it really gets.

Tested on Debian 13 with tmux 3.5a and Claude Code 2.1.311.
