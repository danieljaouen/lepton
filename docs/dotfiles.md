---
title: Your dotfiles, applied
order: 13
summary: How Lepton reads Spacemacs, tmux, zsh, starship and git configuration.
---

# Your dotfiles, applied

Lepton is configured by a dotfiles repository, read at runtime from the
files themselves rather than re-typed. The published ISO is built with
[Daniel Jaouen's dotfiles](https://github.com/danieljaouen/dotfiles);
build your own image with `mix lepton.iso --dotfiles PATH`.

The build installs the repository into `/root` following its own
`locations/` convention (`*.symlink` → `~/.name`, `*.directory.symlink` →
directories). Each program then reads its native file:

| File | Read by | What it gives you |
|---|---|---|
| `~/.spacemacs`, `~/.spacemacs.d/*.el` | `le` | key bindings, settings, theme ([editor](editor.html)) |
| `~/.tmux.conf` (+ `.tmux.linux.conf`) | `tmux` | prefix, key tables, options ([tmux](tmux.html)) |
| `~/.zshrc` | `lsh` | aliases, exports, options ([shell](shell.html#your-zshrc)) |
| `~/.config/starship.toml` | `lsh` | the prompt ([shell](shell.html#the-prompt)) |
| `~/.gitconfig` | `git` | identity, aliases, settings ([git](git.html)) |
| `~/.iex.exs` | `iex` | your IEx helpers ([system](system.html#elixir-and-erlang)) |

`keys` (or `keys editor|tmux|git|shell`) prints exactly what was loaded.
The [key bindings page](keybindings.html) is generated from the same
output.

Anything Lepton reads but can't apply is reported, never silently
dropped: unsupported editor commands show as "not supported" in `keys`.
