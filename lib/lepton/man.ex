defmodule Lepton.Man do
  @moduledoc """
  The manual pages `man` shows (and the site publishes, `mix lepton.docs`).

  Each command has a page, `man/NAME.md` in the source tree, compiled into
  this module. A page holds only what the code can't say: its sections
  (`## DESCRIPTION`, `## OPTIONS`, `## EXAMPLES`, `## SEE ALSO`, ...). The
  NAME line and SYNOPSIS come from the command's `defcmd` summary and
  usage. Pages are a small Markdown subset:

    * paragraphs, and `## SECTION` headings;
    * `- item` lists; an item starting with `` `code` `` and a colon
      (`` - `-l`: long format ``) is a tagged paragraph, as `.TP` in roff;
    * code blocks indented by four spaces;
    * `` `code` `` (bold), `[text](url)` and cross references `ls(1)`.

  `man/builtins.md` describes the shell builtins; `man cd` shows the
  part about `cd`.
  """

  alias Lepton.Style

  @dir Path.expand("../../man", __DIR__)
  @files @dir |> Path.join("*.md") |> Path.wildcard() |> Enum.sort()
  for f <- @files, do: @external_resource(f)
  @sources Map.new(@files, &{Path.basename(&1, ".md"), File.read!(&1)})

  @names Enum.map(@files, &Path.basename/1)

  # A page added or removed recompiles this module. (Mix asks from the
  # project's root; file names only, so no absolute path of the build
  # machine is compiled in.)
  def __mix_recompile__?, do: Path.wildcard("man/*.md") |> Enum.map(&Path.basename/1) |> Enum.sort() != @names

  @indent 7

  @doc "The Markdown source of page NAME (a command's own name, or `builtins`)."
  def source(name), do: Map.get(@sources, name)

  @doc "Every page: the commands, the shell builtins and `builtins`, sorted."
  def names do
    commands = for {_, c} <- Lepton.Commands.builtins(), uniq: true, do: c.name
    Enum.sort(commands ++ Lepton.Shell.Builtins.names() ++ ["builtins"]) |> Enum.uniq()
  end

  @doc """
  The page for NAME: a command (by any of its names), a shell builtin or
  `builtins`. Returns `%{name, names, summary, synopsis, body}` or nil.
  Commands added by packages, which have no page here, get one made from
  their summary and usage.
  """
  def page(name) do
    cond do
      name == "builtins" ->
        %{name: "builtins", names: ["builtins"], summary: "the shell's builtin commands", synopsis: [], body: source("builtins")}

      Lepton.Shell.Builtins.builtin?(name) ->
        builtin_page(name)

      true ->
        # A package's command without a page gets one from its summary.
        case Lepton.Commands.lookup(name) do
          {:ok, c} ->
            body = source(c.name) || "## DESCRIPTION\n\n#{capitalize(c.summary)}.\n"
            %{name: c.name, names: [c.name | c.aliases], summary: c.summary, synopsis: List.wrap(c.usage), body: body}

          :error ->
            nil
        end
    end
  end

  # The builtin's item in builtins.md's BUILTINS list, as a page of its own.
  defp builtin_page(name) do
    with {tags, text} <- Enum.find(builtin_items(), fn {tags, _} -> Enum.any?(tags, &(hd(String.split(&1)) == name)) end) do
      summary = text |> String.replace("`", "") |> String.split(~r/[,.;:] /, parts: 2) |> hd() |> String.trim_trailing(".")

      %{
        name: name,
        names: Enum.map(tags, &hd(String.split(&1))),
        summary: summary <> " (shell builtin)",
        synopsis: tags,
        body: "## DESCRIPTION\n\n#{capitalize(text)}\n\n## SEE ALSO\n\nbuiltins(1), lsh(1)\n"
      }
    end
  end

  defp capitalize(<<c::utf8, rest::binary>>), do: String.upcase(<<c::utf8>>) <> rest

  defp builtin_items do
    [_, list] = String.split(source("builtins"), "## BUILTINS\n", parts: 2)
    list = list |> String.split("\n## ") |> hd()

    for {:item, text} <- blocks(list), {:tagged, tags, desc} <- [tagged(text)] do
      {Enum.map(tags, &String.trim(&1, "`")), desc}
    end
  end

  @doc """
  Pages whose name or summary contains `keyword` (`man -k`, `apropos`),
  as `{name, summary}`; `keywords` may be a list (any of them matches).

  Options: `all: true`, every keyword must match; `text: true`, the
  pages' text is searched as well, and a page found only there comes as
  `{name, summary, line}` with the first line that matches.
  """
  def apropos(keywords, opts \\ []) do
    ks = keywords |> List.wrap() |> Enum.map(&normalize/1)
    match? = fn hay -> if opts[:all], do: Enum.all?(ks, &String.contains?(hay, &1)), else: Enum.any?(ks, &String.contains?(hay, &1)) end

    for name <- names(), p = page(name), p.name == name, hit = found(p, ks, match?, opts[:text]), do: hit
  end

  defp found(p, ks, match?, text?) do
    cond do
      match?.(normalize(Enum.join(p.names, " ") <> " " <> p.summary)) ->
        {p.name, p.summary}

      text? && match?.(normalize(plain(p.body || ""))) ->
        {p.name, p.summary, context(p.body, ks)}

      true ->
        nil
    end
  end

  # The text around the first keyword in the page, as one line: from a
  # few words before it ("…" when that isn't the start of a paragraph).
  defp context(body, ks) do
    # Paragraphs, and an example block's lines one by one.
    paras = for p <- body |> plain() |> String.split(~r/\n\s*\n/), l <- if(p =~ ~r/\A(    .*(\n|\z))+\z/, do: String.split(p, "\n"), else: [p]), do: l
    para = Enum.find(paras, "", &Enum.any?(ks, fn k -> String.contains?(normalize(&1), k) end))
    line = para |> String.replace(~r/\s+/u, " ") |> String.trim()
    at = ks |> Enum.map(&:binary.match(String.downcase(line), &1)) |> Enum.reject(&(&1 == :nomatch)) |> Enum.map(&elem(&1, 0)) |> Enum.min(fn -> 0 end)
    before = binary_part(line, 0, at) |> String.split(" ")

    if length(before) > 6,
      do: "…" <> (before |> Enum.take(-6) |> Enum.join(" ")) <> binary_part(line, at, byte_size(line) - at),
      else: line
  end

  # Lower case, one space between words, without Markdown's backquotes and stars.
  defp normalize(text), do: text |> String.downcase() |> String.replace(~r/\s+/u, " ") |> String.trim()
  defp plain(text), do: text |> String.replace(~r/^#+ .*$/m, "") |> String.replace(~r/[`*]/, "")

  # -- terminal rendering -----------------------------------------------------------------------

  @doc """
  Lay out `page` for a terminal `width` columns wide; with `color?`,
  headings and code are bold.
  """
  def render(page, width, color?) do
    title = "#{String.upcase(page.name)}(1)"
    middle = "Lepton Manual"
    gap = max(width - 2 * String.length(title) - String.length(middle), 2)
    header = title <> String.duplicate(" ", div(gap, 2)) <> middle <> String.duplicate(" ", gap - div(gap, 2)) <> title

    name = wrap("#{Enum.join(page.names, ", ")} - #{page.summary}", @indent, width, color?)
    synopsis = Enum.map(page.synopsis, &wrap(&1, @indent, width, false))

    # A blank line between paragraphs, none after a heading.
    {body, _} =
      Enum.flat_map_reduce(blocks(page.body), :heading, fn block, prev ->
        gap = if prev == :heading, do: [], else: [""]

        case block do
          {:heading, h} -> {gap ++ [heading(h, color?)], :heading}
          {:para, text} -> {gap ++ [wrap(text, @indent, width, color?)], :text}
          {:code, lines} -> {gap ++ Enum.map(lines, &(String.duplicate(" ", @indent + 4) <> &1)), :text}
          {:item, text} -> {gap ++ [item(text, width, color?)], :text}
        end
      end)

    head = [header, "", heading("NAME", color?), name, ""]
    head = if synopsis == [], do: head, else: head ++ [heading("SYNOPSIS", color?) | synopsis] ++ [""]
    Enum.join(head ++ body, "\n") <> "\n"
  end

  defp heading(text, true), do: "\e[1m#{text}\e[22m"
  defp heading(text, false), do: text

  defp item(text, width, color?) do
    case tagged(text) do
      {:tagged, tags, desc} ->
        tag = inline(Enum.join(tags, ", "), color?)
        tag_width = String.length(Style.strip(tag))
        body_indent = @indent + 7

        if tag_width < 7 do
          [first | rest] = wrap(desc, body_indent, width, color?) |> String.split("\n")
          line = String.duplicate(" ", @indent) <> tag <> String.duplicate(" ", 7 - tag_width) <> String.trim_leading(first)
          Enum.join([line | rest], "\n")
        else
          wrap(Enum.join(tags, ", "), @indent, width, color?) <> "\n" <> wrap(desc, body_indent, width, color?)
        end

      :plain ->
        wrapped = wrap(text, @indent + 2, width, color?)
        String.duplicate(" ", @indent) <> "•" <> String.slice(wrapped, (@indent + 1)..-1//1)
    end
  end

  # `code`, `code`: text  ->  {:tagged, ["`code`", "`code`"], "text"}
  defp tagged(text) do
    case Regex.run(~r/^((?:`[^`]+`(?:, )?)+):\s+(.*)$/s, text) do
      [_, tags, desc] -> {:tagged, Regex.scan(~r/`[^`]+`/, tags) |> Enum.map(&hd/1), desc}
      nil -> :plain
    end
  end

  # Fill `text` to `width`, every line indented by `indent`. Code spans
  # are never broken across lines.
  defp wrap(text, indent, width, color?) do
    room = max(width - indent, 20)

    words =
      for [w] <- Regex.scan(~r/(?:`[^`]*`|[^\s`]|`)+/, text), part <- split_long(w, room), do: inline(part, color?)

    pad = String.duplicate(" ", indent)

    words
    |> Enum.reduce([], fn word, lines ->
      w = String.length(Style.strip(word))

      case lines do
        [line | rest] when elem(line, 1) + 1 + w <= room -> [{elem(line, 0) <> " " <> word, elem(line, 1) + 1 + w} | rest]
        _ -> [{word, w} | lines]
      end
    end)
    |> Enum.reverse()
    |> Enum.map_join("\n", fn {line, _} -> pad <> line end)
  end

  # A code span wider than the line is broken at its spaces after all.
  defp split_long(word, room) do
    if String.length(word) <= room, do: [word], else: Regex.replace(~r/`([^`]*)`/, word, fn _, c -> c |> String.split(" ") |> Enum.map_join(" ", &"`#{&1}`") end) |> String.split(" ")
  end

  defp inline(text, color?) do
    text = Regex.replace(~r/\[([^\]]+)\]\([^)\s]+\)/, text, "\\1")

    Regex.replace(~r/`([^`]*)`/, text, fn _, code ->
      if color?, do: "\e[1m#{code}\e[22m", else: code
    end)
  end

  # -- parsing ------------------------------------------------------------------------------------

  @doc false
  def blocks(text) do
    text |> String.split("\n") |> parse([])
  end

  defp parse([], acc), do: Enum.reverse(acc)

  defp parse([line | rest] = lines, acc) do
    cond do
      String.trim(line) == "" ->
        parse(rest, acc)

      h = Regex.run(~r/^##\s+(.*)$/, line) ->
        parse(rest, [{:heading, Enum.at(h, 1)} | acc])

      String.starts_with?(line, "    ") ->
        {code, rest} = Enum.split_while(lines, &(String.starts_with?(&1, "    ") or String.trim(&1) == ""))
        code = code |> Enum.map(&String.replace_prefix(&1, "    ", "")) |> drop_trailing_blank()
        parse(rest, [{:code, code} | acc])

      String.starts_with?(line, "- ") ->
        {cont, rest} = Enum.split_while(rest, &String.starts_with?(&1, "  "))
        text = Enum.map_join([String.replace_prefix(line, "- ", "") | cont], " ", &String.trim/1)
        parse(rest, [{:item, text} | acc])

      true ->
        {para, rest} = Enum.split_while(lines, &(String.trim(&1) != "" and not String.starts_with?(&1, ["## ", "- ", "    "])))
        parse(rest, [{:para, Enum.map_join(para, " ", &String.trim/1)} | acc])
    end
  end

  defp drop_trailing_blank(lines), do: lines |> Enum.reverse() |> Enum.drop_while(&(String.trim(&1) == "")) |> Enum.reverse()

  # -- the site --------------------------------------------------------------------------------------

  @doc """
  Page NAME as Markdown for the site: the NAME and SYNOPSIS sections
  added, code blocks fenced, and cross references `ls(1)` linked to
  `man-ls.html`.
  """
  def markdown(page) do
    # Consecutive items make one list.
    body =
      page.body
      |> blocks()
      |> Enum.chunk_by(&(elem(&1, 0) == :item))
      |> Enum.map(fn chunk ->
        Enum.map_join(chunk, if(match?([{:item, _} | _], chunk), do: "\n", else: "\n\n"), fn
          {:heading, h} -> "## #{h}"
          {:para, text} -> site_inline(text)
          {:code, lines} -> "```sh\n" <> Enum.join(lines, "\n") <> "\n```"
          {:item, text} -> "- " <> site_inline(text)
        end)
      end)

    synopsis = if page.synopsis == [], do: "", else: "## SYNOPSIS\n\n```\n#{Enum.join(page.synopsis, "\n")}\n```\n\n"

    """
    # #{page.name}(1)

    ## NAME

    #{Enum.map_join(page.names, ", ", &"`#{&1}`")} - #{page.summary}

    #{synopsis}#{Enum.join(body, "\n\n")}
    """
  end

  defp site_inline(text) do
    {text, codes} = stash(text)
    pages = MapSet.new(names())

    text
    |> then(&Regex.replace(~r/(?<![\w(\/])(https:\/\/[^\s,)]+[^\s,).])/, &1, "<\\1>"))
    |> then(&Regex.replace(~r/\b([a-z][\w.-]*)\(1\)/, &1, fn whole, name -> if name in pages, do: "[#{name}(1)](man-#{name}.html)", else: whole end))
    |> unstash(codes)
  end

  defp stash(text) do
    codes = Regex.scan(~r/`[^`]*`/, text) |> Enum.map(&hd/1)
    {text, _} = Enum.reduce(codes, {text, 0}, fn c, {t, i} -> {String.replace(t, c, "\u0000#{i}\u0000", global: false), i + 1} end)
    {text, codes}
  end

  defp unstash(text, codes), do: codes |> Enum.with_index() |> Enum.reduce(text, fn {c, i}, t -> String.replace(t, "\u0000#{i}\u0000", c) end)
end
