defmodule Lepton.Shell.Zshrc do
  @moduledoc """
  Imports the parts of a `~/.zshrc` that make sense on Lepton.

  zsh syntax is a superset of what `lsh` parses, and a real `.zshrc` mostly
  configures plugins and paths for another machine, so instead of executing
  it this module *reads* it:

    * `alias name='value'` lines become aliases
    * `export NAME=literal` sets variables (values containing `$` or
      command substitutions are skipped, as are `PATH`, `TERM`, `SHELL`)
    * `setopt`/`unsetopt` set shell options
    * `if [[ ... OSX/Darwin ... ]]` / `else` / `fi` blocks are followed as
      zsh would on Linux, so macOS-only aliases are skipped and the
      `else` (Linux) branch is used

  `EDITOR`/`VISUAL` are kept pointing at Lepton's editor but the user's
  choice (vim, nvim, emacsclient...) is aliased to it.
  """

  alias Lepton.Shell

  @skip_exports ~w(PATH TERM SHELL HOME USER EDITOR VISUAL)

  def import(shell, path) do
    case File.read(path) do
      {:ok, text} -> apply_entries(shell, parse(text))
      _ -> shell
    end
  end

  @doc "Returns a list of `{:alias, k, v} | {:export, k, v} | {:setopt, opt, bool}`."
  def parse(text) do
    {entries, _stack} =
      text
      |> String.split("\n")
      |> Enum.reduce({[], []}, fn line, {acc, stack} ->
        line = String.trim(line)

        cond do
          Regex.match?(~r/^if\s/, line) ->
            {acc, [condition_active?(line) | stack]}

          Regex.match?(~r/^elif\s/, line) ->
            {acc, [condition_active?(line) and not hd_or(stack, false) | tl_or(stack)]}

          line == "else" ->
            {acc, [not hd_or(stack, true) | tl_or(stack)]}

          line == "fi" ->
            {acc, tl_or(stack)}

          not Enum.all?(stack, & &1) ->
            {acc, stack}

          entry = entry(line) ->
            {[entry | acc], stack}

          true ->
            {acc, stack}
        end
      end)

    Enum.reverse(entries)
  end

  # Conditions mentioning macOS are false on Lepton; Linux ones are true;
  # anything else (feature tests we cannot evaluate) counts as true.
  defp condition_active?(line) do
    cond do
      line =~ ~r/OSX|Darwin|darwin/ -> false
      line =~ ~r/LINUX|Linux|linux/ -> true
      true -> true
    end
  end

  defp hd_or([h | _], _), do: h
  defp hd_or([], d), do: d
  defp tl_or([_ | t]), do: t
  defp tl_or([]), do: []

  defp entry("#" <> _), do: nil

  defp entry(line) do
    cond do
      m = Regex.run(~r/^alias\s+([^=\s]+)=(.*)$/, line) ->
        [_, name, value] = m
        {:alias, name, unquote_value(value)}

      m = Regex.run(~r/^export\s+([A-Za-z_][A-Za-z0-9_]*)=(.*)$/, line) ->
        [_, name, value] = m
        value = unquote_value(value)

        if name in @skip_exports or String.contains?(value, ["$", "`"]),
          do: editor_alias(name, value),
          else: {:export, name, value}

      m = Regex.run(~r/^(setopt|unsetopt)\s+(\S+)/, line) ->
        [_, kind, opt] = m
        {:setopt, String.downcase(opt), kind == "setopt"}

      true ->
        nil
    end
  end

  defp editor_alias(name, value) when name in ["EDITOR", "VISUAL"] do
    if value in ["le", ""], do: nil, else: {:alias, value, "le"}
  end

  defp editor_alias(_, _), do: nil

  defp unquote_value(v) do
    v = String.trim(v)

    cond do
      String.starts_with?(v, "'") and String.ends_with?(v, "'") and byte_size(v) >= 2 -> String.slice(v, 1..-2//1)
      String.starts_with?(v, "\"") and String.ends_with?(v, "\"") and byte_size(v) >= 2 -> String.slice(v, 1..-2//1)
      true -> v |> String.split(~r/\s+#/) |> hd()
    end
  end

  defp apply_entries(shell, entries) do
    Enum.reduce(entries, shell, fn
      {:alias, k, v}, shell -> %{shell | aliases: Map.put(shell.aliases, k, v)}
      {:export, k, v}, shell -> put_in(shell.ctx.env[k], v)
      {:setopt, k, v}, shell -> %{shell | options: Map.put(shell.options, k, v)}
    end)
    |> then(fn %Shell{} = s -> s end)
  end
end
