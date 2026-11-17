defmodule Lepton.Shell.Expand do
  @moduledoc """
  Word expansion: tilde, parameters, command substitution, field splitting
  and pathname expansion (globbing), in POSIX order.
  """

  alias Lepton.Ctx

  @doc "Expand a list of words into argv."
  def words(words, shell), do: Enum.flat_map(words, &word(&1, shell))

  @doc "Expand one word into zero or more fields."
  def word(parts, shell) do
    segments = Enum.flat_map(parts, &part(&1, shell))
    fields = split_fields(segments)

    Enum.flat_map(fields, fn segs ->
      text = Enum.map_join(segs, fn {t, _} -> t end)

      if Enum.any?(segs, fn {t, quoted} -> not quoted and String.contains?(t, ["*", "?", "["]) end) do
        case glob(text, shell.ctx) do
          [] -> [text]
          matches -> matches
        end
      else
        [text]
      end
    end)
  end

  @doc "Expand a word to a single string, without splitting or globbing."
  def string(parts, shell) do
    parts
    |> Enum.flat_map(&part(&1, shell))
    |> Enum.map_join(fn
      {:split, t} -> t
      {t, _} -> t
    end)
  end

  # Segments are {text, quoted?}; unquoted expansion results carry a
  # :split marker so field splitting only applies to them.
  defp part({:lit, t}, _shell), do: [{t, false}]
  defp part({:sq, t}, _shell), do: [{t, true}]
  defp part(:tilde, shell), do: [{Ctx.home(shell.ctx), true}]

  defp part({:dq, parts}, shell) do
    text =
      Enum.map_join(parts, fn
        {:lit, t} -> t
        {:var, name} -> var(name, shell, :joined)
        {:cmd, src} -> command_sub(src, shell)
      end)

    [{text, true}]
  end

  defp part({:var, name}, shell), do: [{:split, var(name, shell, :fields)}]
  defp part({:cmd, src}, shell), do: [{:split, command_sub(src, shell)}]

  defp var(name, shell, mode) do
    case name do
      "?" -> to_string(shell.status)
      "$" -> to_string(shell.ctx.pid || Lepton.Proc.current())
      "!" -> to_string(shell.last_bg || "")
      "#" -> to_string(length(shell.positional))
      "0" -> shell.name
      "@" -> joined(shell.positional, mode)
      "*" -> joined(shell.positional, mode)
      "RANDOM" -> to_string(:rand.uniform(32768) - 1)
      "SECONDS" -> to_string(div(System.monotonic_time(:millisecond) - shell.started, 1000))
      "PWD" -> shell.ctx.cwd
      n ->
        case Integer.parse(n) do
          {i, ""} -> Enum.at(shell.positional, i - 1, "")
          _ -> modifier(n, shell)
        end
    end
  end

  defp joined(list, _mode), do: Enum.join(list, " ")

  # ${VAR:-default}, ${VAR:=default}, ${#VAR}
  defp modifier("#" <> name, shell), do: shell.ctx.env |> Map.get(name, "") |> String.length() |> to_string()

  defp modifier(expr, shell) do
    case Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*)(:?[-=+])(.*)$/s, expr) do
      [_, name, op, word] ->
        value = Map.get(shell.ctx.env, name)
        empty? = value == nil or (String.starts_with?(op, ":") and value == "")

        case String.trim_leading(op, ":") do
          "-" -> if empty?, do: word, else: value
          "=" -> if empty?, do: word, else: value
          "+" -> if empty?, do: "", else: word
        end

      nil ->
        Map.get(shell.ctx.env, expr, "")
    end
  end

  def command_sub(src, shell) do
    {out, _status} = Lepton.Shell.capture(src, shell)
    String.trim_trailing(out, "\n")
  end

  # Unquoted expansion results ({:split, text}) are split on whitespace;
  # everything else joins the current field. A field exists once it has
  # content or a quoted (possibly empty) segment, so `""` survives while an
  # empty unquoted `$X` vanishes.
  defp split_fields(segments) do
    {fields, cur, has} =
      Enum.reduce(segments, {[], [], false}, fn
        {:split, text}, acc ->
          [first | rest] = Regex.split(~r/[ \t\n]+/, text)

          Enum.reduce(rest, append(acc, first), fn piece, {fields, cur, has} ->
            fields = if has, do: fields ++ [cur], else: fields
            append({fields, [], false}, piece)
          end)

        {t, quoted}, {fields, cur, has} ->
          {fields, cur ++ [{t, quoted}], has or quoted or t != ""}
      end)

    if has, do: fields ++ [cur], else: fields
  end

  defp append(acc, ""), do: acc
  defp append({fields, cur, _}, piece), do: {fields, cur ++ [{piece, true}], true}

  @doc "Expand a glob pattern relative to the context's cwd."
  def glob(pattern, ctx) do
    absolute? = String.starts_with?(pattern, "/")
    full = if absolute?, do: pattern, else: Path.join(ctx.cwd, pattern)

    full
    |> Path.wildcard()
    |> Enum.map(fn p -> if absolute?, do: p, else: Path.relative_to(p, ctx.cwd) end)
    |> Enum.sort()
  end
end
