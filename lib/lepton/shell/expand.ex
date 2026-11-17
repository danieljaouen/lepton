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
        {:arith, src} -> arith(src, shell)
      end)

    [{text, true}]
  end

  defp part({:var, name}, shell), do: [{:split, var(name, shell, :fields)}]
  defp part({:cmd, src}, shell), do: [{:split, command_sub(src, shell)}]
  defp part({:arith, src}, shell), do: [{:split, arith(src, shell)}]

  # -- $(( arithmetic )) -------------------------------------------------------------
  # Integer arithmetic with C precedence. Bare names and $NAME are variables
  # (unset or non-numeric = 0).

  @doc false
  def arith(src, shell) do
    tokens = arith_tokens(String.to_charlist(src), [])

    case arith_expr(tokens, 0, shell) do
      {value, []} -> Integer.to_string(value)
      _ -> raise ArgumentError, "bad arithmetic expression: #{String.trim(src)}"
    end
  end

  defp arith_tokens([], acc), do: Enum.reverse(acc)
  defp arith_tokens([c | rest], acc) when c in [?\s, ?\t, ?\n], do: arith_tokens(rest, acc)

  defp arith_tokens([c | _] = chars, acc) when c in ?0..?9 do
    {digits, rest} = Enum.split_while(chars, &(&1 in ?0..?9))
    arith_tokens(rest, [{:num, List.to_integer(digits)} | acc])
  end

  defp arith_tokens([c | _] = chars, acc) when c in ?a..?z or c in ?A..?Z or c == ?_ or c == ?$ do
    chars = if c == ?$, do: tl(chars), else: chars
    {name, rest} = Enum.split_while(chars, &(&1 in ?a..?z or &1 in ?A..?Z or &1 in ?0..?9 or &1 == ?_))
    arith_tokens(rest, [{:name, List.to_string(name)} | acc])
  end

  defp arith_tokens([a, b | rest], acc) when [a, b] in [~c"<=", ~c">=", ~c"==", ~c"!=", ~c"&&", ~c"||"],
    do: arith_tokens(rest, [List.to_string([a, b]) | acc])

  defp arith_tokens([c | rest], acc) when c in ~c"+-*/%()<>!", do: arith_tokens(rest, [<<c>> | acc])
  defp arith_tokens([c | _], _), do: raise(ArgumentError, "bad character in arithmetic: #{<<c::utf8>>}")

  @arith_ops %{"||" => 1, "&&" => 2, "==" => 3, "!=" => 3, "<" => 4, ">" => 4, "<=" => 4, ">=" => 4, "+" => 5, "-" => 5, "*" => 6, "/" => 6, "%" => 6}

  # Precedence climbing: parse operators binding tighter than `min`.
  defp arith_expr(tokens, min, shell) do
    {lhs, rest} = arith_unary(tokens, shell)
    arith_rhs(lhs, rest, min, shell)
  end

  defp arith_rhs(lhs, [op | rest] = tokens, min, shell) when is_binary(op) do
    case @arith_ops[op] do
      prec when is_integer(prec) and prec > min ->
        {rhs, rest} = arith_expr(rest, prec, shell)
        arith_rhs(arith_apply(op, lhs, rhs), rest, min, shell)

      _ ->
        {lhs, tokens}
    end
  end

  defp arith_rhs(lhs, tokens, _min, _shell), do: {lhs, tokens}

  defp arith_unary(["-" | rest], shell), do: arith_unary(rest, shell) |> then(fn {v, r} -> {-v, r} end)
  defp arith_unary(["+" | rest], shell), do: arith_unary(rest, shell)
  defp arith_unary(["!" | rest], shell), do: arith_unary(rest, shell) |> then(fn {v, r} -> {if(v == 0, do: 1, else: 0), r} end)
  defp arith_unary([{:num, n} | rest], _shell), do: {n, rest}

  defp arith_unary([{:name, name} | rest], shell) do
    value =
      case Integer.parse(String.trim(var(name, shell, :joined))) do
        {n, ""} -> n
        _ -> 0
      end

    {value, rest}
  end

  defp arith_unary(["(" | rest], shell) do
    case arith_expr(rest, 0, shell) do
      {v, [")" | rest]} -> {v, rest}
      _ -> raise ArgumentError, "missing ) in arithmetic"
    end
  end

  defp arith_unary(_, _), do: raise(ArgumentError, "bad arithmetic expression")

  defp arith_apply(op, _a, 0) when op in ["/", "%"], do: raise(ArgumentError, "division by zero")
  defp arith_apply("+", a, b), do: a + b
  defp arith_apply("-", a, b), do: a - b
  defp arith_apply("*", a, b), do: a * b
  defp arith_apply("/", a, b), do: div(a, b)
  defp arith_apply("%", a, b), do: rem(a, b)
  defp arith_apply(op, a, b) when op in ["&&", "||"], do: bool(if(op == "&&", do: a != 0 and b != 0, else: a != 0 or b != 0))
  defp arith_apply("==", a, b), do: bool(a == b)
  defp arith_apply("!=", a, b), do: bool(a != b)
  defp arith_apply("<", a, b), do: bool(a < b)
  defp arith_apply(">", a, b), do: bool(a > b)
  defp arith_apply("<=", a, b), do: bool(a <= b)
  defp arith_apply(">=", a, b), do: bool(a >= b)
  defp bool(true), do: 1
  defp bool(false), do: 0

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
