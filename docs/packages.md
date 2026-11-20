---
title: Packages (lpm)
order: 10
summary: Install Elixir and Erlang packages from hex.pm, and official updates for built-in apps.
---

# Packages: lpm

`lpm` installs Elixir and Erlang packages directly from
[hex.pm](https://hex.pm). It resolves version requirements and
dependencies through the Hex API, downloads the tarballs, verifies them
against the registry's SHA-256 checksum, and compiles them *inside
Lepton* with the compilers in the image. Installed packages are loaded at
every boot.

Packages are system-wide, so installing, removing and upgrading them takes
[sudo](users.html); searching and listing don't.

```sh
lpm search json
lpm info jason
sudo lpm install jason      # or jason@~>1.4, several at once
elixir -e 'IO.puts Jason.encode!(%{hello: "lepton"})'
sudo lpm install ./my_tool  # a local Mix project
lpm list
sudo lpm remove jason
sudo lpm update             # reinstall the packages at their latest version
```

## Packages that add commands

A package can add shell commands: any module that does
`use Lepton.Command` and defines `defcmd`s becomes a command when the
package loads, so a Lepton tool can be published to hex.pm like any other
library.

```elixir
defmodule LeptonCowsay do
  use Lepton.Command

  defcmd "cowsay", "a talking cow", usage: "cowsay TEXT..." do
    IO.puts(ctx, "< " <> Enum.join(args, " ") <> " >")
    0
  end
end
```

Packages built on Mix-specific features (compile-time config, application
callbacks in `mix.exs`, NIFs) are not supported yet.

## Packages can't hijack the system

Anyone can publish to hex.pm, so `lpm` never lets a package silently take
over part of the OS:

- a package command named like a built-in (`grep`, `git`, `poweroff`, …)
  is skipped, and the built-in keeps working;
- a package may not define `Lepton.*` modules or any module the system
  already has (Elixir, OTP, Lepton). This is checked before compiling and
  again after, and package code goes *after* the system's on the code
  path;
- only code compiled from the package's sources runs; prebuilt `.beam`
  files are discarded.

Installing a package still runs its code, so only install packages you
trust.

## Official updates for built-in apps

Built-in apps can be updated from hex.pm without a new ISO, but only by
**official updates**.

```sh
lpm official               # what's available, and what's installed
sudo lpm upgrade grep      # install the official update for grep
sudo lpm upgrade           # refresh all of them (withdrawn ones are reverted)
sudo lpm revert grep       # back to the built-in grep
builtin grep ...      # always runs the built-in, even when replaced
```

The project publishes a signed list, <https://trylepton.app/official.json>
(Ed25519; the signature is in `official.json.sig`). Each entry names the
exact hex package, version and tarball SHA-256, the built-in commands it
may stand in for, and every pinned dependency. The public key is compiled
into the OS, with a copy at `/etc/lepton/official-key.pub`.

- A look-alike package isn't in the list.
- A new release pushed from a compromised hex.pm account doesn't match
  the pinned checksum.
- A tampered list fails the signature, and an *older* list (a lower
  `serial`) is refused, so a withdrawn update can't come back.
- The built-in is never deleted: "replacing" only puts the update first
  in line. The last verified list is cached for offline use.

Official updates are maintained by the
[`lepton` organization on hex.pm](https://hex.pm/orgs/lepton), which the
signed list names and `lpm official` shows.

### For maintainers: publishing an official update

Making a package official takes two things: every hex.pm owner of the
package must be the `lepton` organization or one of its members, *and*
the list must be signed with the Lepton key. After the first publish,
hand the package to the organization with
`mix hex.owner transfer PACKAGE lepton`.

```sh
mix hex.user auth        # once; the owner check reads the org's members
mix lepton.official add lepton_grep 1.2.0 --replaces grep,egrep [--dep NAME@VERSION ...]
cd site && git commit -am "Official: lepton_grep 1.2.0" && git push
```

`add` pins the checksums from hex.pm and refuses unless the whole
dependency closure is pinned; `list`, `remove` and `sign` manage the
list. The signing key and the organization's API key live in the macOS
Keychain (`lepton-official-signing-key` and `hex-lepton`), never in a
repository.

<!-- commands: lpm -->
