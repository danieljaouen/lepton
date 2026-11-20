## DESCRIPTION

Run Elixir code: the expression CODE given with `-e`, or the script
FILE.exs. ARGS are available as `System.argv()`, and as the variable
`args`. The code runs inside Lepton, with the full standard library.

An executable `*.exs` file can also be run by name, like any command.

## OPTIONS

- `-e CODE`: evaluate CODE.
- `-v`: print the Elixir and Erlang/OTP versions.

## EXIT STATUS

0 on success, 1 if the code raised an error (which is printed).

## EXAMPLES

    elixir -e 'IO.puts(Enum.sum(1..100))'
    elixir script.exs one two

## SEE ALSO

iex(1), mix(1), erl(1)
