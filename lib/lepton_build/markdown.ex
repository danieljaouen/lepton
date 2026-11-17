defmodule LeptonBuild.Markdown do
  @moduledoc """
  A small Markdown-to-HTML renderer for the documentation (`mix lepton.docs`).

  Supports what the docs use: `#`-`####` headings (with `id`s for
  anchors), paragraphs, `-`/`*`/`1.` lists (nested by indentation, with
  continuation lines), fenced code blocks (```` ```lang ````), GFM pipe
  tables, `>` block quotes, `---` rules, and inline `` `code` ``,
  `**bold**`, `*emphasis*`, `[links](url)`, `<https://autolinks>` and
  `{#id}` (an anchor target, e.g. in a table cell).
  Raw HTML in the source is escaped, never passed through.
  """

  @doc "Render Markdown to HTML. Returns `{html, headings}`, headings as `{level, id, text}`."
  def render(text) do
    lines = text |> String.replace("\r\n", "\n") |> String.split("\n")
    {html, heads} = blocks(lines, [], [])
    {IO.iodata_to_binary(html), Enum.reverse(heads)}
  end

  # -- blocks -------------------------------------------------------------------------

  defp blocks([], acc, heads), do: {Enum.reverse(acc), heads}

  defp blocks([line | rest] = lines, acc, heads) do
    cond do
      String.trim(line) == "" ->
        blocks(rest, acc, heads)

      fence = Regex.run(~r/^\s*```\s*([\w+-]*)\s*$/, line) ->
        {code, rest} = Enum.split_while(rest, &(not String.match?(&1, ~r/^\s*```\s*$/)))
        lang = Enum.at(fence, 1)
        class = if lang != "", do: ~s( class="language-#{lang}"), else: ""
        html = ["<pre><code", class, ">", escape(Enum.join(code, "\n")), "</code></pre>\n"]
        blocks(Enum.drop(rest, 1), [html | acc], heads)

      h = Regex.run(~r/^(\#{1,4})\s+(.*?)\s*#*\s*$/, line) ->
        [_, hashes, title] = h
        level = String.length(hashes)
        id = slug(title)
        html = ["<h#{level} id=\"#{id}\">", inline(title), "<a class=\"anchor\" href=\"##{id}\" aria-label=\"Link to this section\">#</a></h#{level}>\n"]
        blocks(rest, [html | acc], [{level, id, strip_inline(title)} | heads])

      String.match?(line, ~r/^\s*(---|\*\*\*)\s*$/) ->
        blocks(rest, ["<hr>\n" | acc], heads)

      table?(lines) ->
        {rows, rest} = Enum.split_while(lines, &String.match?(&1, ~r/^\s*\|/))
        blocks(rest, [table(rows) | acc], heads)

      String.match?(line, ~r/^\s*>/) ->
        {quoted, rest} = Enum.split_while(lines, &String.match?(&1, ~r/^\s*>/))
        inner = Enum.map(quoted, &String.replace(&1, ~r/^\s*>\s?/, ""))
        {html, heads} = blocks(inner, [], heads)
        blocks(rest, [["<blockquote>\n", html, "</blockquote>\n"] | acc], heads)

      list_marker(line) ->
        {items, rest} = list_items(lines)
        {html, heads} = list(items, heads)
        blocks(rest, [html | acc], heads)

      true ->
        {para, rest} = Enum.split_while(lines, &paragraph_line?/1)
        para = if para == [], do: [line], else: para
        rest = if para == [line] and rest == lines, do: tl(lines), else: rest
        blocks(rest, [["<p>", inline(Enum.map_join(para, " ", &String.trim/1)), "</p>\n"] | acc], heads)
    end
  end

  defp paragraph_line?(line) do
    String.trim(line) != "" and not String.match?(line, ~r/^\s*(```|\#{1,4}\s|>|\|)/) and !list_marker(line)
  end

  # -- lists ----------------------------------------------------------------------------

  defp list_marker(line) do
    case Regex.run(~r/^(\s*)([-*]|\d+\.)\s+(.*)$/, line) do
      [_, indent, marker, text] -> {String.length(indent), if(marker in ["-", "*"], do: :ul, else: :ol), text}
      _ -> nil
    end
  end

  # Items at the first marker's indentation; each keeps its following lines
  # (continuations and nested lists), de-indented.
  defp list_items([first | _] = lines) do
    {base, kind, _} = list_marker(first)
    collect(lines, base, kind, [])
  end

  defp collect([line | rest] = lines, base, kind, items) do
    case list_marker(line) do
      {^base, ^kind, text} ->
        {body, rest} = item_body(rest, base)
        collect(rest, base, kind, [{text, body} | items])

      _ ->
        {{kind, Enum.reverse(items)}, lines}
    end
  end

  defp collect([], _base, kind, items), do: {{kind, Enum.reverse(items)}, []}

  defp item_body(lines, base) do
    {body, rest} =
      Enum.split_while(lines, fn l ->
        cond do
          String.trim(l) == "" -> true
          indent(l) > base -> true
          true -> false
        end
      end)

    # Trailing blank lines belong to whatever follows.
    {trailing, body} = body |> Enum.reverse() |> Enum.split_while(&(String.trim(&1) == ""))
    {Enum.reverse(body), Enum.reverse(trailing) ++ rest}
  end

  defp indent(line), do: String.length(line) - String.length(String.trim_leading(line))

  defp list({kind, items}, heads) do
    {lis, heads} =
      Enum.map_reduce(items, heads, fn {text, body}, heads ->
        {cont, nested} = Enum.split_while(body, &(!list_marker(&1) and not String.match?(&1, ~r/^\s*```/)))
        text = Enum.map_join([text | cont], " ", &String.trim/1) |> String.trim()
        dedented = dedent(nested)
        {inner, heads} = if dedented == [], do: {[], heads}, else: blocks(dedented, [], heads)
        {["<li>", inline(text), inner, "</li>\n"], heads}
      end)

    {["<#{kind}>\n", lis, "</#{kind}>\n"], heads}
  end

  defp dedent([]), do: []

  defp dedent(lines) do
    n = lines |> Enum.reject(&(String.trim(&1) == "")) |> Enum.map(&indent/1) |> Enum.min(fn -> 0 end)
    Enum.map(lines, &String.slice(&1, min(n, indent(&1))..-1//1))
  end

  # -- tables ----------------------------------------------------------------------------

  defp table?([a, b | _]), do: String.match?(a, ~r/^\s*\|/) and String.match?(b, ~r/^\s*\|[\s:|-]+\|?\s*$/) and String.contains?(b, "-")
  defp table?(_), do: false

  defp table([header, _sep | rows]) do
    cells = fn row ->
      row
      |> String.trim()
      |> String.trim_leading("|")
      |> String.trim_trailing("|")
      |> String.split(~r/(?<!\\)\|/)
      |> Enum.map(&(&1 |> String.trim() |> String.replace("\\|", "|")))
    end

    head = Enum.map(cells.(header), &["<th>", inline(&1), "</th>"])
    body = Enum.map(rows, fn r -> ["<tr>", Enum.map(cells.(r), &["<td>", inline(&1), "</td>"]), "</tr>\n"] end)
    ["<div class=\"table-wrap\"><table>\n<thead><tr>", head, "</tr></thead>\n<tbody>\n", body, "</tbody></table></div>\n"]
  end

  # -- inline ------------------------------------------------------------------------------

  @doc false
  def inline(text) do
    # Code spans first, so nothing inside them is interpreted.
    {text, codes} = stash(text, "c", ~r/`([^`]+)`/, fn [_, c] -> "<code>" <> escape(c) <> "</code>" end)
    {text, links} = stash(text, "l", ~r/<(https?:\/\/[^>\s]+)>/, fn [_, url] -> ~s(<a href="#{escape(url)}">#{escape(url)}</a>) end)
    {text, ids} = stash(text, "i", ~r/\{#([A-Za-z0-9_-]+)\}/, fn [_, id] -> ~s(<span class="anchor-target" id="#{id}"></span>) end)

    text
    |> escape()
    |> then(&Regex.replace(~r/\[([^\]]+)\]\(([^)\s]+)\)/, &1, fn _, label, url -> ~s(<a href="#{url}">#{label}</a>) end))
    |> then(&Regex.replace(~r/\*\*(.+?)\*\*/, &1, "<strong>\\1</strong>"))
    |> then(&Regex.replace(~r/(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])/, &1, "<em>\\1</em>"))
    |> unstash("i", ids)
    |> unstash("l", links)
    |> unstash("c", codes)
  end

  # Swap matches for placeholders (tagged, so different kinds can't collide)
  # and render them separately.
  defp stash(text, tag, re, render) do
    parts = Regex.scan(re, text)
    {text, _} = Enum.reduce(parts, {text, 0}, fn [whole | _], {t, i} -> {String.replace(t, whole, "\u0000#{tag}#{i}\u0000", global: false), i + 1} end)
    {text, Enum.map(parts, render)}
  end

  defp unstash(text, tag, values) do
    values |> Enum.with_index() |> Enum.reduce(text, fn {v, i}, t -> String.replace(t, "\u0000#{tag}#{i}\u0000", v) end)
  end

  defp strip_inline(text), do: text |> String.replace(~r/[`*]/, "") |> String.replace(~r/\[([^\]]+)\]\([^)]+\)/, "\\1")

  @doc "A URL fragment for a heading."
  def slug(text) do
    text
    |> strip_inline()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/u, "")
    |> String.trim()
    |> String.replace(~r/[\s-]+/, "-")
  end

  def escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
