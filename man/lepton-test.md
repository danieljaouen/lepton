## DESCRIPTION

Run Lepton's own test suite (ExUnit) inside the running system, from
`/usr/share/lepton/test`, or just the test FILEs given. The same tests
run on the development machine with `mix test`.

Some tests are tagged:

- `native`: needs the real Lepton system; skipped elsewhere.
- `network`: needs internet access; included when the network is up.
- `dotfiles`: needs the developer's dotfiles in `$HOME`.

## OPTIONS

- `--only TAG`: run only tests tagged TAG.
- `--include TAG`, `--exclude TAG`: include or exclude tagged tests.
- `--seed N`: the random seed for the test order.
- `-v`: print the name of each test.

## EXIT STATUS

0 if every test passed, 1 otherwise.

## SEE ALSO

mix(1), elixir(1)
