## DESCRIPTION

Run the Mix TASK, Elixir's build tool, in the project in the current
directory (the one with `mix.exs`), as in `mix compile`, `mix test` or
`mix format`. `mix new NAME` creates a project, and `mix help` lists the
tasks.

Mix runs inside Lepton's own Erlang virtual machine, so one `mix` runs
at a time. Dependencies from Hex need network access.

## EXAMPLES

    mix new hello && cd hello && mix test

## SEE ALSO

elixir(1), iex(1)
