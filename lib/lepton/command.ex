defmodule Lepton.Command do
  @moduledoc """
  DSL for defining userland programs.

      defmodule Lepton.Commands.Example do
        use Lepton.Command

        defcmd "hello", "print a greeting", usage: "hello [NAME]" do
          Lepton.IO.puts(ctx, "hello " <> Enum.join(args, " "))
          0
        end
      end

  Inside the body `args` (argv without the program name) and `ctx` (a
  `Lepton.Ctx`) are bound; the body returns the exit status.
  """

  defmacro __using__(_opts) do
    quote do
      import Lepton.Command, only: [defcmd: 3, defcmd: 4]
      import Lepton.Args, only: [getopt: 2]
      alias Lepton.{Ctx, IO, Args}
      Module.register_attribute(__MODULE__, :lepton_commands, accumulate: true)
      @before_compile Lepton.Command
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def __commands__, do: Enum.reverse(@lepton_commands)
    end
  end

  # `do:` may come as its own argument (`defcmd "x", "s", usage: "u" do ... end`)
  # or inside the options (`defcmd "x", "s", usage: "u", do: 0`).
  defmacro defcmd(name, summary, opts \\ [], block \\ nil) do
    {block, opts} =
      case block do
        [do: body] -> {body, opts}
        nil -> Keyword.pop!(opts, :do)
      end

    fun = String.to_atom("cmd_" <> String.replace(name, ~r/[^A-Za-z0-9_]/, "_"))

    quote do
      @lepton_commands %{
        name: unquote(name),
        summary: unquote(summary),
        usage: unquote(opts[:usage]),
        aliases: unquote(opts[:aliases] || []),
        root: unquote(opts[:root] == true),
        fun: {__MODULE__, unquote(fun)}
      }
      def unquote(fun)(var!(args), var!(ctx)) do
        _ = var!(args)
        _ = var!(ctx)

        # `root: true`: only root (or `sudo`) may run it.
        if unquote(opts[:root] == true) and not Lepton.Users.root?(var!(ctx)) do
          Lepton.Users.denied(var!(ctx), unquote(name))
        else
          unquote(block)
        end
      end
    end
  end
end

defmodule Lepton.Args do
  @moduledoc """
  POSIX `getopt`-style argument parsing.

      getopt(["-la", "-n", "5", "file"], "lan:")
      #=> {%{"l" => true, "a" => true, "n" => "5"}, ["file"]}

  Long options (`--name`, `--name=value`) are returned under their name.
  Parsing stops at `--` or the first non-option argument.
  """

  def getopt(args, spec) do
    takes_value = for [c, ":"] <- Regex.scan(~r/(.)(:?)/, spec, capture: :all_but_first), into: MapSet.new(), do: c
    loop(args, takes_value, %{}, [])
  end

  defp loop([], _tv, opts, rest), do: {opts, Enum.reverse(rest)}
  defp loop(["--" | args], _tv, opts, rest), do: {opts, Enum.reverse(rest) ++ args}

  defp loop(["--" <> long | args], tv, opts, rest) do
    case String.split(long, "=", parts: 2) do
      [k, v] -> loop(args, tv, Map.put(opts, k, v), rest)
      [k] -> loop(args, tv, Map.put(opts, k, true), rest)
    end
  end

  defp loop(["-" <> flags = arg | args], tv, opts, rest) when flags != "" do
    if Regex.match?(~r/^-?\d+$/, flags) and not MapSet.member?(tv, "0") do
      # `head -5` style numeric shorthand
      loop(args, tv, Map.put(opts, "#", String.trim_leading(flags, "-")), rest)
    else
      shorts(String.graphemes(flags), args, tv, opts, rest, arg)
    end
  end

  # Options may follow operands (GNU-style permutation).
  defp loop([arg | args], tv, opts, rest), do: loop(args, tv, opts, [arg | rest])

  defp shorts([], args, tv, opts, rest, _arg), do: loop(args, tv, opts, rest)

  defp shorts([c | more], args, tv, opts, rest, arg) do
    if MapSet.member?(tv, c) do
      case {more, args} do
        {[], [v | args]} -> loop(args, tv, Map.put(opts, c, v), rest)
        {[], []} -> loop([], tv, Map.put(opts, c, ""), rest)
        {chars, _} -> loop(args, tv, Map.put(opts, c, Enum.join(chars)), rest)
      end
    else
      shorts(more, args, tv, Map.update(opts, c, true, &count/1), rest, arg)
    end
  end

  defp count(true), do: 2
  defp count(n) when is_integer(n), do: n + 1
  defp count(v), do: v

  def int(opts, key, default) do
    case Map.get(opts, key) do
      nil -> default
      v -> case Integer.parse(to_string(v)) do
          {i, _} -> i
          :error -> default
        end
    end
  end
end

defmodule Lepton.Commands do
  @moduledoc """
  The command registry - Lepton's `$PATH`.

  Built-in programs come from modules using `Lepton.Command`. More can be
  registered at runtime, e.g. from `~/.lshrc.exs`:

      Lepton.Commands.register("greet", fn args, ctx ->
        Lepton.IO.puts(ctx, "hi " <> Enum.join(args, " ")); 0
      end)

  Executable files are also commands: `*.exs` files run as Elixir scripts
  and files starting with `#!` naming `lsh`/`sh` run as shell scripts.

  Packages cannot take over built-in names: `register_module/2` skips them
  unless the package is an official update allowed to replace them (see
  `Lepton.Official`). Even then the built-in stays available through
  `builtin_lookup/1` (the shell's `builtin NAME`).
  """

  @sets [
    Lepton.Commands.Core,
    Lepton.Commands.Text,
    Lepton.Commands.System,
    Lepton.Commands.Network,
    Lepton.Commands.Dev,
    Lepton.Commands.Admin,
    Lepton.Commands.Services,
    Lepton.Commands.VM,
    Lepton.Commands.Printing,
    Lepton.Commands.Desktop
  ]

  def all, do: Map.merge(builtins(), runtime())

  @doc "The modules that define the built-in commands, in display order."
  def sets, do: @sets

  @doc "The commands shipped with the OS image, by name."
  def builtins do
    for set <- @sets, Code.ensure_loaded?(set), cmd <- set.__commands__(), name <- [cmd.name | cmd.aliases], into: %{} do
      {name, cmd}
    end
  end

  @doc "Look up the OS image's own command, ignoring packages."
  def builtin_lookup(name), do: Map.fetch(builtins(), name)

  def names, do: all() |> Map.keys() |> Enum.sort()

  def lookup(name) do
    case :persistent_term.get({__MODULE__, :cache}, nil) do
      nil ->
        cache = all()
        :persistent_term.put({__MODULE__, :cache}, cache)
        Map.fetch(cache, name)

      cache ->
        Map.fetch(cache, name)
    end
  end

  def register(name, fun, summary \\ "user command") when is_function(fun, 2) do
    :persistent_term.put({__MODULE__, :runtime}, Map.put(runtime(), name, %{name: name, summary: summary, usage: nil, aliases: [], fun: fun}))
    :persistent_term.erase({__MODULE__, :cache})
    :ok
  end

  @doc """
  Register the commands of a package module that `use Lepton.Command`.
  Names of built-in commands are skipped unless listed in `replaces`
  (official updates). Returns the skipped names.
  """
  def register_module(mod, replaces \\ []) do
    builtin = builtins()
    named = for cmd <- mod.__commands__(), name <- [cmd.name | cmd.aliases], do: {name, cmd}
    {allowed, skipped} = Enum.split_with(named, fn {name, _} -> not Map.has_key?(builtin, name) or name in replaces end)
    :persistent_term.put({__MODULE__, :runtime}, Map.merge(runtime(), Map.new(allowed)))
    :persistent_term.erase({__MODULE__, :cache})
    for {name, _} <- skipped, do: name
  end

  @doc "Remove the commands a package module registered (when it is uninstalled)."
  def unregister_module(mod) do
    kept = Map.reject(runtime(), fn {_name, cmd} -> match?(%{fun: {^mod, _}}, cmd) end)
    :persistent_term.put({__MODULE__, :runtime}, kept)
    :persistent_term.erase({__MODULE__, :cache})
    :ok
  end

  defp runtime, do: :persistent_term.get({__MODULE__, :runtime}, %{})

  def invoke(%{fun: {mod, fun}}, args, ctx), do: apply(mod, fun, [args, ctx])
  def invoke(%{fun: fun}, args, ctx) when is_function(fun, 2), do: fun.(args, ctx)
end
