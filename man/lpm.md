## DESCRIPTION

The Lepton package manager. It installs Elixir and Erlang packages from
hex.pm: it resolves versions and dependencies, verifies each download
against the registry's SHA-256 checksum, compiles the sources inside
Lepton, and loads installed packages at every boot. A package can add
shell commands (modules that `use Lepton.Command`).

Installing, removing and upgrading take `sudo`; looking does not.

## COMMANDS

- `search QUERY`: search hex.pm.
- `info NAME`: describe a package.
- `install NAME[@REQUIREMENT]...`: install packages and their
  dependencies (`jason`, `jason@~>1.4`).
- `install ./DIR`: install a local Mix project.
- `list`, `ls`: the installed packages.
- `remove NAME...`, `uninstall`, `rm`: remove packages.
- `update`: reinstall the packages you installed at their latest
  versions.
- `official`: the official updates for built-in commands, from the
  signed list at https://trylepton.app/official.json.
- `upgrade [APP...]`: install or refresh official updates (all of them
  with no APP).
- `revert APP...`: go back to the built-in version of APP.

## SECURITY

A package's commands may not take the name of a built-in command, and
it may not define `Lepton.*` or other system modules; only code compiled
from its sources is used. Only an official update, pinned by version and
checksum in a list signed with the Lepton key, may stand in for a
built-in, and `builtin APP` always runs the original. Installing a
package still runs its code, so install only packages you trust.

## EXAMPLES

    lpm search json
    sudo lpm install jason
    elixir -e 'IO.puts Jason.encode!(%{hello: "lepton"})'
    sudo lpm upgrade grep

## SEE ALSO

app(1), builtin(1), mix(1), https://trylepton.app/docs/packages.html
