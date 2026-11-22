## DESCRIPTION

Run the Mix TASK, Elixir's build tool, as on any other system: in the
project in the current directory (the one with `mix.exs`), as in
`mix compile`, `mix test` or `mix deps.get`. `mix new NAME` creates a
project, and `mix help` lists the tasks.

Mix runs in an Erlang virtual machine of its own (the image's Erlang
and Elixir), not in Lepton's: a project's configuration and dependencies
stay its own, and `mix phx.server` serves a Phoenix app without running
it inside the OS. Hex and archives work as usual: `mix local.hex`,
`mix archive.install hex phx_new`, then `mix phx.new NAME` (they are kept
in `~/.mix` and `~/.hex`). Dependencies from Hex need network access;
ones that compile C code (NIFs with a Makefile) can't be built, as
Lepton has no C compiler.

Git dependencies (a new Phoenix app has one, `heroicons`) and Phoenix's
live reload need programs Mix runs itself: `sudo app install mix-tools`
installs them (Alpine's git, inotifywait, tar, xz and zstd, on Mix's path only; at the
prompt, `git` is still Lepton's). Programs Mix downloads (esbuild,
Tailwind) run as they are.

Mix runs as you, so the files it writes are yours. Lines typed in the
terminal go to it, for Mix's questions. `C-c` stops it, as does stopping
the service it runs in (`svc stop`).

`iex -S mix` isn't available: `iex` and `elixir` evaluate code in
Lepton's own VM.

## EXAMPLES

    mix new hello && cd hello && mix test
    mix archive.install hex phx_new
    mix phx.new myapp && cd myapp && mix ecto.create && mix phx.server

## SEE ALSO

elixir(1), iex(1), postgresql(1), svc(1)
