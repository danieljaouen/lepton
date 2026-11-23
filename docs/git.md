---
title: git and GitHub
order: 5
section: shell
summary: A format-compatible git, your gitconfig aliases, and a gh CLI.
---

# git and GitHub

## git

Lepton's `git` is format-compatible with upstream git: loose and packed
objects, index v2, refs, packed-refs and `.gitignore`. It talks to GitHub
and other servers over HTTPS ("smart HTTP") and [SSH](#ssh-remotes)
(side-band-64k packs, OFS/REF deltas).

Supported subcommands: `init clone fetch pull push status add rm restore
reset commit log show diff branch checkout switch merge stash tag remote
config rev-parse ls-files ls-remote cat-file hash-object version`.

`~/.gitconfig` is honoured: `[include] path = .gitconfig.local`, all your
aliases (`gl`, `gll` with `--pretty=format:` placeholders, `st`, `ci`,
`co`, `br`, `df`, `dc`, `lg`, …), `user.name` / `user.email`,
`core.pager = cat`, `core.excludesfile`, `http.sslVerify` and
`url.<base>.insteadOf` / `pushInsteadOf`. The aliases
are listed on the [key bindings page](keybindings.html#git).

Limits: merges are fast-forward only (no three-way merge) and there is no
rebase.

## SSH remotes

Private repositories are easiest over SSH: create a key once and every
clone, fetch and push uses it, with no token to paste. See
[SSH](ssh.html) for the details.

```sh
ssh-keygen && gh ssh-key add          # once (or add the .pub on github.com)
git clone git@github.com:you/private-repo.git
cd private-repo && git push
```

Remote URLs can be scp-like (`git@github.com:OWNER/REPO.git`),
`ssh://[user@]host[:port]/path`, or an alias from `~/.ssh/config`
(`gh:OWNER/REPO.git`). An existing HTTPS clone switches with `git remote
set-url origin git@github.com:OWNER/REPO.git`. To use SSH for every GitHub
URL, including ones you paste, add this to `~/.gitconfig`:

```ini
[url "git@github.com:"]
	insteadOf = https://github.com/
```

GitHub's host key is built in. For other servers, connect once with `ssh
HOST` to check and accept their key (git can't ask).

## gh

`gh auth login` stores a token in the same `~/.config/gh/hosts.yml`
format GitHub's own `gh` uses (or set `GH_TOKEN`), and `git push` over
HTTPS uses it. Scopes: `repo` and `read:org`, plus `admin:public_key` for
`gh ssh-key`.

```sh
gh auth login
gh repo view | list | clone OWNER/REPO | create NAME
gh ssh-key list | add [~/.ssh/id_ed25519.pub] [-t TITLE]
gh config set git_protocol ssh     # gh repo clone uses git@github.com: URLs
gh issue list | view N | create
gh pr list | view N
gh browse
gh api /user
```

## From the editor

In `le`, `SPC g s` opens a magit-style status buffer: `s` stages, `c c`
opens the commit message (finish with `, c` or `C-c C-c`, cancel with
`, k` or `C-c C-k`), `P p` pushes and `F p` pulls. See [the editor](editor.html#git-from-the-editor).

<!-- commands: git gh -->
