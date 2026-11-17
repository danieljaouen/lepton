---
title: git and GitHub
order: 5
summary: A format-compatible git, your gitconfig aliases, and a gh CLI.
---

# git and GitHub

## git

Lepton's `git` is format-compatible with upstream git: loose and packed
objects, index v2, refs, packed-refs and `.gitignore`. It speaks smart
HTTP to GitHub (side-band-64k packs, OFS/REF deltas).

Supported subcommands: `init clone fetch pull push status add rm restore
reset commit log show diff branch checkout switch merge stash tag remote
config rev-parse ls-files ls-remote cat-file hash-object version`.

`~/.gitconfig` is honoured: `[include] path = .gitconfig.local`, all your
aliases (`gl`, `gll` with `--pretty=format:` placeholders, `st`, `ci`,
`co`, `br`, `df`, `dc`, `lg`, …), `user.name` / `user.email`,
`core.pager = cat`, `core.excludesfile` and `http.sslVerify`. The aliases
are listed on the [key bindings page](keybindings.html#git).

Limits: merges are fast-forward only (no three-way merge), there is no
rebase, and remotes use HTTPS (no SSH transport).

## gh

`gh auth login` stores a token in the same `~/.config/gh/hosts.yml`
format GitHub's own `gh` uses (or set `GH_TOKEN`), and `git push` uses it.

```sh
gh auth login
gh repo view | list | clone OWNER/REPO | create NAME
gh issue list | view N | create
gh pr list | view N
gh browse
gh api /user
```

## From the editor

In `le`, `SPC g s` opens a magit-style status buffer, where `P p` pushes
and `F p` pulls. See [the editor](editor.html#git-from-the-editor).

<!-- commands: git gh -->
