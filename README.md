# claude-statusline

A custom status line for [Claude Code](https://code.claude.com) — shows context usage,
subscription rate limits (5h/7d) with countdown to reset, cost, and session duration. Fully
local: it only reads stdin, makes no network calls, reads no credentials, and has no
third-party dependencies (other than `jq`).

## What it shows

Adaptive layout based on terminal width:

- **Left:** model · 💰 cost · ⏱ session duration
- **Center:** 🧠 free context · ⚡ 5h limit · 📅 7d limit (with bars and countdown to reset)
- **Right:** 🌿 git branch

On a wide terminal it's a single line with three zones; on a narrow one it wraps to two lines
automatically; on a very narrow one the branch name is truncated. Bar colors shift as you
approach the limit (green → yellow → red).

The limits (`rate_limits.five_hour` / `.seven_day`) arrive on stdin from Claude Code v2.1.x+
for Pro/Max subscribers and appear after the first API response in a session.

## Install

```bash
git clone <repo-url> claude-statusline
cd claude-statusline
./install.sh
```

`install.sh` copies `statusline.sh` into `~/.claude/` and adds the `statusLine` key to
`~/.claude/settings.json` (it creates a backup and leaves the rest of your config untouched).
Then restart Claude Code and accept the trust dialog.

## Requirements

`bash`, `git`, and `jq`. Works on macOS and Linux. On Windows, run it under WSL or Git Bash.

| OS | Install jq |
|----|------------|
| macOS | `brew install jq` |
| Debian/Ubuntu | `sudo apt install jq` |
| Fedora/RHEL | `sudo dnf install jq` |
| Arch | `sudo pacman -S jq` |

## Test

```bash
echo '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":42,"remaining_percentage":58},"cost":{"total_cost_usd":0.23,"total_duration_ms":125000},"rate_limits":{"five_hour":{"used_percentage":24,"resets_at":9999999999},"seven_day":{"used_percentage":91,"resets_at":9999999999}}}' | ./statusline.sh
```

## Uninstall

Remove the `statusLine` key from `~/.claude/settings.json` (or run `/statusline delete` in
Claude Code) and delete `~/.claude/statusline.sh`.

## Security

The script makes no network calls and reads no secrets or credentials — it only parses the
JSON that Claude Code passes locally on stdin. `settings.json` is not part of the repository.
