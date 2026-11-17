defmodule Lepton.Shell.Parser do
  @moduledoc """
  Lexer and recursive-descent parser for `lsh`, a POSIX-flavoured shell
  language with zsh conveniences.

  Grammar (informal):

      list      := and_or ((';' | '&' | '\\n') and_or)* [';' | '&']
      and_or    := pipeline (('&&' | '||') pipeline)*
      pipeline  := ['!'] command ('|' command)*
      command   := simple | '(' list ')' | '{' list '}' | if | for | while
      simple    := (NAME=word)* word* redirect*

  Words are lists of parts:

      {:lit, text}     unquoted text (subject to globbing)
      {:sq, text}      'single quoted'
      {:dq, parts}     "double quoted" (contains :lit/:var/:cmd parts)
      {:var, name}     $name / ${name} / $? / $$ / $1 ...
      {:cmd, source}   $(command) or `command`
      :tilde           a leading ~
  """

  @keywords ~w(if then elif else fi for in do done while until)

  # -- lexer -------------------------------------------------------------------------

  @doc "Tokenize source text. Returns {:ok, tokens} or {:error, :incomplete | reason}."
  def tokenize(src) do
    lex(String.to_charlist(src), [], [])
  catch
    {:lex_error, reason} -> {:error, reason}
  end

  defp lex([], word, acc), do: {:ok, Enum.reverse(push_word(word, acc))}

  defp lex([?\\, ?\n | rest], word, acc), do: lex(rest, word, acc)

  defp lex([c | rest], word, acc) when c in [?\s, ?\t] do
    lex(rest, [], push_word(word, acc))
  end

  defp lex([?\n | rest], word, acc), do: lex(rest, [], [:newline | push_word(word, acc)])

  defp lex([?# | rest], [], acc) do
    rest = Enum.drop_while(rest, &(&1 != ?\n))
    lex(rest, [], acc)
  end

  defp lex(chars, word, acc) do
    case operator(chars) do
      {op, rest} ->
        acc = push_word(word, acc)

        # `2>`, `2>>`, `2>&1`: a lone digit word directly before a redirect is an fd.
        {acc, op} =
          case {acc, op} do
            {[{:word, [{:lit, <<d>>}]} | prev], {:redir, kind, nil}} when d in ?0..?9 and word != [] ->
              {prev, {:redir, kind, d - ?0}}

            _ ->
              {acc, op}
          end

        lex(rest, [], [op | acc])

      nil ->
        {part, rest} = word_part(chars)
        lex(rest, [part | word], acc)
    end
  end

  defp push_word([], acc), do: acc
  defp push_word(word, acc), do: [{:word, merge(Enum.reverse(word))} | acc]

  # Merge adjacent literal parts.
  defp merge([{:lit, a}, {:lit, b} | rest]), do: merge([{:lit, a <> b} | rest])
  defp merge([p | rest]), do: [p | merge(rest)]
  defp merge([]), do: []

  defp operator(~c"&&" ++ r), do: {:and, r}
  defp operator(~c"||" ++ r), do: {:or, r}
  defp operator(~c";;" ++ r), do: {:semi, r}
  defp operator(~c"&>>" ++ r), do: {{:redir, :append_both, nil}, r}
  defp operator(~c"&>" ++ r), do: {{:redir, :out_both, nil}, r}
  defp operator(~c">&" ++ [d | r]) when d in ?0..?9, do: {{:redir, {:dup, d - ?0}, nil}, r}
  defp operator(~c">>" ++ r), do: {{:redir, :append, nil}, r}
  defp operator(~c"<<<" ++ r), do: {{:redir, :herestring, nil}, r}
  defp operator(~c">|" ++ r), do: {{:redir, :out, nil}, r}
  defp operator([?> | r]), do: {{:redir, :out, nil}, r}
  defp operator([?< | r]), do: {{:redir, :in, nil}, r}
  defp operator([?| | r]), do: {:pipe, r}
  defp operator([?& | r]), do: {:amp, r}
  defp operator([?; | r]), do: {:semi, r}
  defp operator([?( | r]), do: {:lparen, r}
  defp operator([?) | r]), do: {:rparen, r}
  defp operator(_), do: nil

  defp word_part([?' | rest]) do
    case Enum.split_while(rest, &(&1 != ?')) do
      {text, [?' | rest]} -> {{:sq, List.to_string(text)}, rest}
      _ -> throw({:lex_error, :incomplete})
    end
  end

  defp word_part([?" | rest]) do
    {parts, rest} = dquote(rest, [], [])
    {{:dq, parts}, rest}
  end

  defp word_part([?\\, c | rest]), do: {{:sq, <<c::utf8>>}, rest}
  defp word_part([?\\]), do: throw({:lex_error, :incomplete})
  defp word_part([?$ | _] = chars), do: dollar(chars)
  defp word_part([?` | rest]), do: backquote(rest, [])
  defp word_part([?~ | rest]), do: {:tilde, rest}
  defp word_part([c | rest]), do: {{:lit, <<c::utf8>>}, rest}

  defp dquote([?" | rest], buf, parts), do: {finish_dq(buf, parts), rest}
  defp dquote([?\\, c | rest], buf, parts) when c in [?", ?\\, ?$, ?`], do: dquote(rest, [c | buf], parts)
  defp dquote([?\\, ?\n | rest], buf, parts), do: dquote(rest, buf, parts)

  defp dquote([?$ | _] = chars, buf, parts) do
    {part, rest} = dollar(chars)
    dquote(rest, [], [part | flush_buf(buf, parts)])
  end

  defp dquote([?` | rest], buf, parts) do
    {part, rest} = backquote(rest, [])
    dquote(rest, [], [part | flush_buf(buf, parts)])
  end

  defp dquote([c | rest], buf, parts), do: dquote(rest, [c | buf], parts)
  defp dquote([], _, _), do: throw({:lex_error, :incomplete})

  defp flush_buf([], parts), do: parts
  defp flush_buf(buf, parts), do: [{:lit, buf |> Enum.reverse() |> List.to_string()} | parts]
  defp finish_dq(buf, parts), do: buf |> flush_buf(parts) |> Enum.reverse()

  defp backquote([?` | rest], acc), do: {{:cmd, acc |> Enum.reverse() |> List.to_string()}, rest}
  defp backquote([?\\, c | rest], acc), do: backquote(rest, [c | acc])
  defp backquote([c | rest], acc), do: backquote(rest, [c | acc])
  defp backquote([], _), do: throw({:lex_error, :incomplete})

  defp dollar([?$, ?( | rest]) do
    {inner, rest} = balanced(rest, 1, [])
    {{:cmd, inner}, rest}
  end

  defp dollar([?$, ?{ | rest]) do
    case Enum.split_while(rest, &(&1 != ?})) do
      {name, [?} | rest]} -> {{:var, List.to_string(name)}, rest}
      _ -> throw({:lex_error, :incomplete})
    end
  end

  defp dollar([?$, c | rest]) when c in [??, ?$, ?#, ?@, ?*, ?!, ?0] or c in ?1..?9,
    do: {{:var, <<c>>}, rest}

  defp dollar([?$ | rest]) do
    {name, rest} = Enum.split_while(rest, &(&1 in ?a..?z or &1 in ?A..?Z or &1 in ?0..?9 or &1 == ?_))

    case name do
      [] -> {{:lit, "$"}, rest}
      _ -> {{:var, List.to_string(name)}, rest}
    end
  end

  defp balanced([?) | rest], 1, acc), do: {acc |> Enum.reverse() |> List.to_string(), rest}
  defp balanced([?) | rest], n, acc), do: balanced(rest, n - 1, [?) | acc])
  defp balanced([?( | rest], n, acc), do: balanced(rest, n + 1, [?( | acc])

  defp balanced([?' | rest], n, acc) do
    {q, rest} = Enum.split_while(rest, &(&1 != ?'))

    case rest do
      [?' | rest] -> balanced(rest, n, Enum.reverse([?' | q] ++ [?']) ++ acc)
      [] -> throw({:lex_error, :incomplete})
    end
  end

  defp balanced([c | rest], n, acc), do: balanced(rest, n, [c | acc])
  defp balanced([], _, _), do: throw({:lex_error, :incomplete})

  # -- parser ------------------------------------------------------------------------

  @doc """
  Parse source into an AST. `aliases` is a map used for alias expansion of
  the first word of each simple command.
  """
  def parse(src, aliases \\ %{}) do
    with {:ok, tokens} <- tokenize(src) do
      Process.put(:lsh_aliases, aliases)

      try do
        case parse_list(tokens, [:eof]) do
          {list, []} -> {:ok, list}
          {_list, [tok | _]} -> {:error, "syntax error near unexpected token `#{show(tok)}'"}
        end
      catch
        {:parse_error, :incomplete} -> {:error, :incomplete}
        {:parse_error, msg} -> {:error, msg}
      end
    end
  end

  defp show(:rparen), do: ")"
  defp show(:pipe), do: "|"
  defp show(:amp), do: "&"
  defp show(:semi), do: ";"
  defp show(:and), do: "&&"
  defp show(:or), do: "||"
  defp show({:word, parts}), do: literal(parts) || "word"
  defp show(other), do: inspect(other)

  # A list ends at EOF or at one of the given terminators (keywords/rparen).
  defp parse_list(tokens, terminators), do: parse_list(skip_newlines(tokens), terminators, [])

  defp parse_list(tokens, terminators, acc) do
    tokens = skip_newlines(tokens)

    if terminator?(tokens, terminators) do
      {{:list, Enum.reverse(acc)}, tokens}
    else
      {item, rest} = parse_and_or(tokens)

      case rest do
        [:amp | rest] -> parse_list(rest, terminators, [{item, :bg} | acc])
        [:semi | rest] -> parse_list(rest, terminators, [{item, :fg} | acc])
        [:newline | rest] -> parse_list(rest, terminators, [{item, :fg} | acc])
        _ -> {{:list, Enum.reverse([{item, :fg} | acc])}, rest}
      end
    end
  end

  defp terminator?([], terms), do: :eof in terms
  defp terminator?([:rparen | _], terms), do: :rparen in terms
  defp terminator?([{:word, parts} | _], terms), do: (literal(parts) || "") in terms
  defp terminator?(_, _), do: false

  defp skip_newlines([:newline | rest]), do: skip_newlines(rest)
  defp skip_newlines(tokens), do: tokens

  defp parse_and_or(tokens) do
    {first, rest} = parse_pipeline(tokens)
    and_or_tail(rest, first, [])
  end

  defp and_or_tail([op | rest], first, acc) when op in [:and, :or] do
    {next, rest} = parse_pipeline(skip_newlines(rest))
    and_or_tail(rest, first, [{op, next} | acc])
  end

  defp and_or_tail(rest, first, []), do: {first, rest}
  defp and_or_tail(rest, first, acc), do: {{:and_or, first, Enum.reverse(acc)}, rest}

  defp parse_pipeline([{:word, [{:lit, "!"}]} | rest]) do
    {{:pipeline, false, cmds}, rest} = parse_pipeline(rest)
    {{:pipeline, true, cmds}, rest}
  end

  defp parse_pipeline(tokens) do
    {cmd, rest} = parse_command(tokens)
    pipeline_tail(rest, [cmd])
  end

  defp pipeline_tail([:pipe | rest], acc) do
    {cmd, rest} = parse_command(skip_newlines(rest))
    pipeline_tail(rest, [cmd | acc])
  end

  defp pipeline_tail(rest, acc), do: {{:pipeline, false, Enum.reverse(acc)}, rest}

  defp parse_command([]), do: throw({:parse_error, :incomplete})

  defp parse_command([:lparen | rest]) do
    {body, rest} = parse_list(rest, [:rparen])

    case rest do
      [:rparen | rest] ->
        {redirs, rest} = parse_redirs(rest, [])
        {{:subshell, body, redirs}, rest}

      [] ->
        throw({:parse_error, :incomplete})
    end
  end

  defp parse_command([{:word, parts} | rest] = tokens) do
    case literal(parts) do
      "{" -> parse_group(rest)
      "if" -> parse_if(rest)
      "for" -> parse_for(rest)
      "while" -> parse_while(rest, :while)
      "until" -> parse_while(rest, :until)
      kw when kw in @keywords -> throw({:parse_error, "syntax error near unexpected token `#{kw}'"})
      _ -> parse_simple(tokens, [], [], [], MapSet.new())
    end
  end

  defp parse_command([{:redir, _, _} | _] = tokens), do: parse_simple(tokens, [], [], [], MapSet.new())
  defp parse_command([tok | _]), do: throw({:parse_error, "syntax error near unexpected token `#{show(tok)}'"})

  defp parse_group(tokens) do
    {body, rest} = parse_list(tokens, ["}"])

    case rest do
      [{:word, [{:lit, "}"}]} | rest] ->
        {redirs, rest} = parse_redirs(rest, [])
        {{:group, body, redirs}, rest}

      _ ->
        throw({:parse_error, :incomplete})
    end
  end

  defp parse_if(tokens) do
    {cond, rest} = parse_list(tokens, ["then"])
    rest = expect(rest, "then")
    {body, rest} = parse_list(rest, ["elif", "else", "fi"])

    case keyword(rest) do
      {"fi", rest} ->
        {{:if, cond, body, nil}, rest}

      {"else", rest} ->
        {else_body, rest} = parse_list(rest, ["fi"])
        {{:if, cond, body, else_body}, expect(rest, "fi")}

      {"elif", rest} ->
        {nested, rest} = parse_if(rest)
        {{:if, cond, body, {:list, [{nested, :fg}]}}, rest}

      _ ->
        throw({:parse_error, :incomplete})
    end
  end

  defp parse_for([{:word, parts} | rest]) do
    var = literal(parts) || throw({:parse_error, "bad for variable"})
    rest = skip_newlines(rest)

    {words, rest} =
      case keyword(rest) do
        {"in", rest} -> collect_words(rest, [])
        _ -> {[{:word, [{:var, "@"}]}], rest}
      end

    rest = rest |> drop_sep() |> expect("do")
    {body, rest} = parse_list(rest, ["done"])
    {{:for, var, words, body}, expect(rest, "done")}
  end

  defp parse_for([]), do: throw({:parse_error, :incomplete})

  defp parse_while(tokens, kind) do
    {cond, rest} = parse_list(tokens, ["do"])
    rest = expect(rest, "do")
    {body, rest} = parse_list(rest, ["done"])
    {{kind, cond, body}, expect(rest, "done")}
  end

  defp collect_words([{:word, _} = w | rest], acc), do: collect_words(rest, [w | acc])
  defp collect_words(rest, acc), do: {Enum.reverse(acc), rest}

  defp drop_sep([t | rest]) when t in [:semi, :newline], do: drop_sep(rest)
  defp drop_sep(rest), do: rest

  defp keyword([{:word, parts} | rest]) do
    case literal(parts) do
      kw when kw in @keywords -> {kw, rest}
      _ -> nil
    end
  end

  defp keyword(_), do: nil

  defp expect(tokens, kw) do
    case keyword(skip_newlines(tokens)) do
      {^kw, rest} -> rest
      _ when tokens == [] -> throw({:parse_error, :incomplete})
      _ -> throw({:parse_error, "syntax error: expected `#{kw}'"})
    end
  end

  defp parse_simple([{:word, parts} | rest], assigns, words, redirs, used) do
    cond do
      words == [] and assignment?(parts) ->
        {name, value} = split_assignment(parts)
        parse_simple(rest, [{name, value} | assigns], words, redirs, used)

      words == [] and alias_for(parts, used) != nil ->
        {name, text} = alias_for(parts, used)

        case tokenize(text) do
          {:ok, alias_tokens} -> parse_simple(alias_tokens ++ rest, assigns, words, redirs, MapSet.put(used, name))
          _ -> parse_simple(rest, assigns, [parts | words], redirs, used)
        end

      true ->
        parse_simple(rest, assigns, [parts | words], redirs, used)
    end
  end

  defp parse_simple([{:redir, _, _} | _] = tokens, assigns, words, redirs, used) do
    {redirs2, rest} = parse_redirs(tokens, [])
    parse_simple(rest, assigns, words, redirs ++ redirs2, used)
  end

  defp parse_simple(rest, assigns, words, redirs, _used) do
    if assigns == [] and words == [] and redirs == [] do
      throw({:parse_error, if(rest == [], do: :incomplete, else: "syntax error near unexpected token `#{show(hd(rest))}'")})
    end

    {{:simple, Enum.reverse(assigns), Enum.reverse(words), redirs}, rest}
  end

  defp parse_redirs([{:redir, {:dup, target}, fd} | rest], acc) do
    parse_redirs(rest, [{:dup, fd || 1, target} | acc])
  end

  defp parse_redirs([{:redir, kind, fd}, {:word, target} | rest], acc) do
    parse_redirs(rest, [{kind, fd || default_fd(kind), target} | acc])
  end

  defp parse_redirs([{:redir, _, _}], _acc), do: throw({:parse_error, :incomplete})
  defp parse_redirs([{:redir, _, _} | _], _acc), do: throw({:parse_error, "syntax error near redirection"})
  defp parse_redirs(rest, acc), do: {Enum.reverse(acc), rest}

  defp default_fd(k) when k in [:in, :herestring], do: 0
  defp default_fd(_), do: 1

  defp assignment?([{:lit, text} | _]), do: Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=/, text)
  defp assignment?(_), do: false

  defp split_assignment([{:lit, text} | rest]) do
    [name, value] = String.split(text, "=", parts: 2)
    value_parts = if value == "", do: rest, else: [{:lit, value} | rest]
    {name, value_parts}
  end

  defp alias_for(parts, used) do
    aliases = Process.get(:lsh_aliases, %{})

    with name when is_binary(name) <- literal(parts),
         false <- MapSet.member?(used, name),
         {:ok, text} <- Map.fetch(aliases, name) do
      {name, text}
    else
      _ -> nil
    end
  end

  @doc "The text of a word if it is a single unquoted literal."
  def literal([{:lit, text}]), do: text
  def literal(_), do: nil
end
