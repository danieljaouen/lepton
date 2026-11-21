# Working on Lepton

Lepton OS: a Unix-like OS for aarch64 whose userland is Elixir (see
README.md). The user docs are published at https://trylepton.app/docs/.

## Every user-facing change updates the docs

A change is user-facing if it adds, removes or changes a command, an
option, a key binding, a file Lepton reads, a tutorial lesson, or
anything a user would notice. For each one:

1. **Code**: every `defcmd` needs a `usage:` (and a summary). The command
   reference, tutorial page and key bindings page are generated from the
   code, so they update themselves.
2. **Manual page**: every command (and shell builtin) has a page,
   `man/NAME.md` (builtins: `man/builtins.md`), that `man` shows and the
   site publishes. NAME and SYNOPSIS come from the `defcmd`; the page
   has `## DESCRIPTION`, `## OPTIONS`, `## EXAMPLES`, `## SEE ALSO`, ...
   (format: `Lepton.Man`). Update it when options or behaviour change.
3. **Guides**: update the relevant `docs/*.md` page (one per topic; front
   matter: `title`, `order`, `summary`). New topic: add a new page; it is
   linked automatically. Use `<!-- commands: a b -->` to embed command
   tables from the registry rather than copying usage text.
4. **Check**: `mix test` (includes `test/docs_test.exs`: links, every
   guide linked, every command documented; `test/man_test.exs`: every
   command has a manual page). `mix lepton.docs` writes
   `docs/` in the site checkout (below) for a local preview.
5. **Publish**: `mix lepton.publish` builds and releases the ISO and
   regenerates and pushes the docs (even when the ISO is unchanged).
   `mix lepton.docs --publish` publishes documentation-only fixes.

## Every site page carries the site tags

Every `*.html` page of the site must have the Google Tag Manager block
from `lib/lepton_build/site_head.html` (the single source; edit it there
to change or add tags). New pages get it automatically: `mix
lepton.publish` and `mix lepton.docs` run `mix lepton.site.tags`, and the
docs generator includes it. `mix test` (`test/site_tags_test.exs`) and the
site repo's "Site tags" GitHub check fail for any page without it. For a
new hand-written page, run `mix lepton.site.tags` (or just publish).

Keep README.md for the project (overview, build, architecture, testing,
layout); feature documentation lives in `docs/`, not in the README.

## Testing

- `mix test` on the host; `mix lepton.iso && mix lepton.qemu --test` runs
  the same suite inside the VM (`lepton-test`). Report both counts.
- The README "Testing" section and the site's stats quote the counts;
  update them when they change.

## Gotchas learned the hard way

- `and` / `or` / `not` raise on `nil`; option values are often `nil`.
  Use `&&` / `||` / `!` for them.
- No `Access` (`opts[:x]`) inside guards.
- Tests run with `NO_COLOR`; test colour paths too (`sh(..., color: true)`).
- `mix lepton.publish` refuses to run with uncommitted changes in this
  repository, the site checkout or `../lepton.iso`.

## Apps follow an Alpine release

Native apps (Firefox; `Lepton.Apps`) install from one Alpine branch,
`@branch` in `lib/lepton/alpine.ex`. Alpine's community repository, where
Firefox lives, gets updates only until the next stable release (about
every six months), so move `@branch` when one comes out. Check what the
app definition pins and excludes (gdk-pixbuf is pinned to v3.23: newer
builds decode images through glycin's sandboxed helpers), update
docs/apps.md, and test Firefox in a VM before publishing. A scheduled
routine opens a pull request for v3.25 on 2026-12-15.

## Version updates (on request)

`versions.toml` records the kernel (Alpine `linux-lts`), OTP and Elixir
Lepton is built from; the build refuses a Mac whose Erlang or Elixir
differs. Updates run only when the user asks (the daily LaunchAgent was
disabled on 2026-11-21: its plist is kept as
`~/Library/LaunchAgents/app.trylepton.daily-update.plist.disabled`).
`mix lepton.versions --check` says whether anything is newer; then:

1. `brew upgrade erlang elixir` when OTP or Elixir is newer;
   `mix lepton.versions --write`; `mix deps.get`, `mix compile`.
2. Fix whatever the new versions break (warnings too), in code and tests.
3. `mix test`, then `mix lepton.iso && mix lepton.qemu --test`; both pass.
   Update the README's counts and the site's stats if they changed.
4. Commit ("Update to Linux X, OTP Y, Elixir Z" and what was fixed), push,
   and `mix lepton.publish` (when asked to).

## Repositories

- this repo: git@github.com:danieljaouen/lepton.git
- `../danieljaouen.github.io`: the site checkout (SSH clone of
  danieljaouen.github.io, served at trylepton.app). The tooling writes,
  commits and pushes here (`LeptonBuild.Paths.site/0`); edit the site here.
- `site/` (submodule): the same repository over HTTPS, read-only. Don't
  edit it or commit its pointer by hand: the site repo's "Update Lepton's
  site submodule" workflow moves it on every push to the site's main (and
  `mix lepton.publish` does locally). Pull before committing here.
- Dotfiles: not in this repository. Builds and tests use `~/.dotfiles`
  (or `$LEPTON_DOTFILES`).
- `../lepton.iso`: ISO releases (GitHub Releases; never commit the ISO)

Commit or push only when asked. End commit messages with:
`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
