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
2. **Guides**: update the relevant `docs/*.md` page (one per topic; front
   matter: `title`, `order`, `summary`). New topic: add a new page; it is
   linked automatically. Use `<!-- commands: a b -->` to embed command
   tables from the registry rather than copying usage text.
3. **Check**: `mix test` (includes `test/docs_test.exs`: links, every
   guide linked, every command documented). `mix lepton.docs` writes
   `site/docs/` for a local preview.
4. **Publish**: `mix lepton.publish` builds and releases the ISO and
   regenerates and pushes the docs (even when the ISO is unchanged).
   `mix lepton.docs --publish` publishes documentation-only fixes.

## Every site page carries the site tags

Every `*.html` page in `site/` must have the Google Tag Manager block
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
  repository, `site/` or `../lepton.iso`.

## Repositories

- this repo: git@github.com:danieljaouen/lepton.git
- `site/` (submodule): danieljaouen.github.io, served at trylepton.app
- `../lepton.iso`: ISO releases (GitHub Releases; never commit the ISO)

Commit or push only when asked. End commit messages with:
`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
