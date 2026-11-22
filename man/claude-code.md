## DESCRIPTION

Install, update or remove Claude Code, Anthropic's coding agent, which
`claude` runs. With no argument (or `status`), say whether it is
installed and which version.

Claude Code isn't open source and isn't part of Lepton. `install`
downloads Anthropic's `linux-arm64-musl` build of the latest release from
Anthropic's download server (about 365 MB), checks its SHA-256 checksum
against the release's manifest, and keeps it in
`/var/lib/lepton/claude-code`. First, it installs the `claude-code` app:
what Claude Code needs from Alpine (bash, git, ripgrep, util-linux; about
14 MB). Using Claude Code is subject to Anthropic's terms.

`install`, `update` and `remove` are for root.

## COMMANDS

- `status`: installed or not, and the version (the default).
- `install`: install it (and the programs it needs).
- `update`: download the latest release if it is newer.
- `remove`: remove it and its programs; `~/.claude` is kept.

## EXAMPLES

    sudo claude-code install
    claude-code
    sudo claude-code update

## SEE ALSO

claude(1), app(1), https://trylepton.app/docs/claude-code.html
