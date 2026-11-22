## DESCRIPTION

Run Claude Code, Anthropic's coding agent, in the current directory:
ask it in plain words to explain, change or test your code. The first
time, it asks you to log in (a Claude account or an Anthropic Console
account; or set `ANTHROPIC_API_KEY`).

Claude Code isn't part of Lepton: install it first with
`sudo claude-code install`, which downloads Anthropic's build. Its
options are Claude Code's own (`claude --help`); `-p PROMPT` answers one
prompt and exits, reading more input from a pipe.

The commands it runs go to Alpine's bash, with git, ripgrep, util-linux,
busybox's programs, and `mix` and `elixir` (the image's, in a VM of their
own). Lepton's own commands aren't available to it. It runs as you.

On a terminal it runs under `script`, which gives it a pseudo-terminal;
window size changes reach it. With its output on a pipe, it runs on
pipes.

`claude update` doesn't apply: use `sudo claude-code update`.

## EXAMPLES

    claude
    claude -p "explain lib/myapp/repo.ex"
    git diff | claude -p "review this change"

## FILES

- `~/.claude`, `~/.claude.json`: your login, settings and sessions.
- `/var/lib/lepton/claude-code`: Claude Code itself.

## SEE ALSO

claude-code(1), mix(1), https://trylepton.app/docs/claude-code.html
