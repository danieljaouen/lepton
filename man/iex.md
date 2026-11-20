## DESCRIPTION

Interactive Elixir: type Elixir expressions and see their values. It
runs inside Lepton itself, so you can call Lepton's own modules (for
example `Lepton.Proc.list()`). `~/.iex.exs` is loaded first, so your
helpers are available; `System.shell/2` runs commands in `lsh`.

Type `exit` or press Ctrl-D to leave.

## FILES

- `~/.iex.exs`: evaluated at startup.

## SEE ALSO

elixir(1), mix(1), erl(1)
