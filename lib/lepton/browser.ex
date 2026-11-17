defmodule Lepton.Browser do
  @moduledoc """
  `www` - a text-mode web browser.

  This is the first slice of Lepton's browser: HTTP(S) fetching
  (`:httpc` + `:ssl`), an HTML tokenizer, and a layout pass that turns
  block/inline elements into wrapped text with numbered links. The GUI
  browser on the roadmap will reuse `fetch/1` and `parse/1` and replace
  `layout/2` with a pixel layout drawn to the framebuffer.

  Keys: `j`/`k` scroll, `SPC`/`b` page, `<n> RET` follow link n,
  `g` open URL, `H` back, `q` quit.
  """

  alias Lepton.TTY

  def run(ctx, url) do
    TTY.set_mode(ctx.tty, :raw)
    TTY.write(ctx.tty, "\e[?1049h\e[?25l")

    try do
      st = %{ctx: ctx, history: [], page: nil, top: 0, number: ""}
      loop(open(st, normalize(url)))
    after
      TTY.write(ctx.tty, "\e[?25h\e[?1049l")
      TTY.set_mode(ctx.tty, :cooked)
    end

    0
  end

  defp normalize(url), do: if(String.contains?(url, "://"), do: url, else: "https://" <> url)

  defp open(st, url) do
    {_, cols} = TTY.size(st.ctx.tty)

    page =
      case fetch(url) do
        {:ok, final_url, html} ->
          {lines, links} = html |> parse() |> layout(cols - 1)
          %{url: final_url, lines: lines, links: links, title: title(html) || final_url}

        {:error, reason} ->
          %{url: url, lines: ["Could not load #{url}:", "", "  #{reason}"], links: [], title: "Error"}
      end

    history = if st.page, do: [st.page.url | st.history], else: st.history
    %{st | page: page, top: 0, history: history}
  end

  @doc "Fetch a URL; returns {:ok, url, body} or {:error, reason}."
  def fetch(url) do
    :inets.start()
    :ssl.start()

    case :httpc.request(:get, {String.to_charlist(url), [{~c"user-agent", ~c"Mozilla/5.0 (Lepton; aarch64) lepton-www/0.1"}]}, [ssl: Lepton.Git.Remote.ssl_opts([]), timeout: 30_000, autoredirect: true], body_format: :binary) do
      {:ok, {{_, code, _}, _headers, body}} when code < 400 -> {:ok, url, to_utf8(body)}
      {:ok, {{_, code, reason}, _, _}} -> {:error, "HTTP #{code} #{reason}"}
      {:error, e} -> {:error, inspect(e)}
    end
  end

  defp to_utf8(body), do: if(String.valid?(body), do: body, else: :unicode.characters_to_binary(body, :latin1))

  defp title(html) do
    case Regex.run(~r/<title[^>]*>(.*?)<\/title>/is, html) do
      [_, t] -> t |> entities() |> String.trim()
      nil -> nil
    end
  end

  # -- parsing ----------------------------------------------------------------------------

  @block ~w(p div h1 h2 h3 h4 h5 h6 ul ol li br tr table section article header footer nav main pre blockquote hr dt dd form)

  @doc "Tokenize HTML into [{:text, s} | {:open, tag, attrs} | {:close, tag}]."
  def parse(html) do
    html
    |> String.replace(~r/<!--.*?-->/s, "")
    |> String.replace(~r/<(script|style|noscript|template|svg)\b.*?<\/\1>/is, "")
    |> then(&Regex.scan(~r/<\/?([a-zA-Z0-9]+)([^>]*)>|([^<]+)/s, &1))
    |> Enum.flat_map(fn
      [whole, tag, attrs] ->
        tag = String.downcase(tag)
        if String.starts_with?(whole, "</"), do: [{:close, tag}], else: [{:open, tag, attrs}]

      [_, "", "", text] ->
        [{:text, entities(text)}]

      _ ->
        []
    end)
  end

  defp entities(text) do
    text
    |> String.replace("&nbsp;", " ")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&apos;", "'")
    |> then(&Regex.replace(~r/&#(\d+);/, &1, fn _, n -> <<String.to_integer(n)::utf8>> end))
    |> then(&Regex.replace(~r/&#x([0-9a-fA-F]+);/, &1, fn _, n -> <<String.to_integer(n, 16)::utf8>> end))
    |> String.replace("&amp;", "&")
  end

  @doc "Lay tokens out as wrapped lines; returns {lines, links}."
  def layout(tokens, width) do
    {blocks, links, _} =
      Enum.reduce(tokens, {[""], [], %{href: nil, pre: false, heading: false}}, fn tok, {blocks, links, mode} ->
        case tok do
          {:open, "a", attrs} ->
            href = case Regex.run(~r/href\s*=\s*["']?([^"'\s>]+)/i, attrs) do
              [_, h] -> h
              nil -> nil
            end
            {blocks, links, %{mode | href: href}}

          {:close, "a"} when mode.href != nil ->
            n = length(links) + 1
            {append(blocks, "[#{n}]"), links ++ [mode.href], %{mode | href: nil}}

          {:open, "li", _} -> {blocks ++ ["  • "], links, mode}
          {:open, "pre", _} -> {blocks ++ [""], links, %{mode | pre: true}}
          {:close, "pre"} -> {blocks ++ [""], links, %{mode | pre: false}}
          {:open, "hr", _} -> {blocks ++ [String.duplicate("─", width), ""], links, mode}
          {:open, h, _} when h in ~w(h1 h2 h3) -> {blocks ++ ["", "\e[1m"], links, %{mode | heading: true}}
          {:close, h} when h in ~w(h1 h2 h3) -> {append(blocks, "\e[0m") ++ [""], links, %{mode | heading: false}}
          {:open, t, _} when t in @block -> {blocks ++ [""], links, mode}
          {:close, t} when t in @block -> {blocks ++ [""], links, mode}
          {:text, text} -> {append(blocks, if(mode.pre, do: text, else: String.replace(text, ~r/\s+/, " "))), links, mode}
          _ -> {blocks, links, mode}
        end
      end)

    lines =
      blocks
      |> Enum.flat_map(&String.split(&1, "\n"))
      |> Enum.map(&String.trim_trailing/1)
      |> Enum.chunk_by(&(&1 == ""))
      |> Enum.flat_map(fn chunk -> if hd(chunk) == "", do: [""], else: chunk end)
      |> Enum.flat_map(&wrap(&1, width))

    {lines, links}
  end

  defp append(blocks, text), do: List.update_at(blocks, -1, &(&1 <> text))

  defp wrap(line, width) do
    if Lepton.Style.width(line) <= width do
      [line]
    else
      line
      |> String.split(" ")
      |> Enum.reduce([""], fn word, [cur | rest] ->
        if Lepton.Style.width(cur) + String.length(word) + 1 > width and cur != "",
          do: [word, cur | rest],
          else: [String.trim_leading(cur <> " " <> word) | rest]
      end)
      |> Enum.reverse()
    end
  end

  # -- UI ----------------------------------------------------------------------------------------

  defp loop(st) do
    {rows, cols} = TTY.size(st.ctx.tty)
    h = rows - 2
    page = st.page
    visible = Enum.slice(page.lines, st.top, h)
    head = "\e[1;1H\e[48;5;24;38;5;231;1m" <> String.pad_trailing(" " <> String.slice(page.title, 0, cols - 2), cols) <> "\e[0m"
    body = for i <- 0..(h - 1), do: ["\e[#{i + 2};1H\e[2K", Enum.at(visible, i) || ""]
    foot = "\e[#{rows};1H\e[2K\e[7m" <> String.pad_trailing(" #{String.slice(page.url, 0, cols - 40)}  #{if st.number != "", do: "link " <> st.number, else: "q quit · g go · H back · N RET follow"}", cols) <> "\e[0m"
    TTY.write(st.ctx.tty, [head, body, foot])
    max_top = max(length(page.lines) - h, 0)

    case TTY.read_key(st.ctx.tty) do
      k when k in ["q", "C-c"] -> :ok
      k when k in ["j", "<down>", "C-n"] -> loop(%{st | top: min(st.top + 1, max_top)})
      k when k in ["k", "<up>", "C-p"] -> loop(%{st | top: max(st.top - 1, 0)})
      k when k in ["SPC", "C-f", "<next>"] -> loop(%{st | top: min(st.top + h, max_top)})
      k when k in ["b", "C-b", "<prior>"] -> loop(%{st | top: max(st.top - h, 0)})
      d when d in ~w(0 1 2 3 4 5 6 7 8 9) -> loop(%{st | number: st.number <> d})
      "RET" when st.number != "" ->
        n = String.to_integer(st.number)

        case Enum.at(page.links, n - 1) do
          nil -> loop(%{st | number: ""})
          href -> loop(open(%{st | number: ""}, resolve(page.url, href)))
        end

      "H" ->
        case st.history do
          [prev | rest] -> loop(%{open(%{st | page: nil}, prev) | history: rest})
          [] -> loop(st)
        end

      "g" ->
        TTY.write(st.ctx.tty, "\e[#{rows};1H\e[2KURL: \e[?25h")
        url = read_line(st.ctx.tty, "")
        TTY.write(st.ctx.tty, "\e[?25l")
        if url in [nil, ""], do: loop(st), else: loop(open(st, normalize(url)))

      _ ->
        loop(%{st | number: ""})
    end
  end

  defp resolve(base, href), do: base |> URI.merge(href) |> to_string()

  defp read_line(tty, acc) do
    case TTY.read_key(tty) do
      "RET" -> acc
      k when k in ["ESC", "C-c", "C-g"] -> nil
      k when k in ["DEL", "C-h"] -> TTY.write(tty, "\b \b"); read_line(tty, String.slice(acc, 0..-2//1))
      k ->
        case Lepton.Keys.text(k) do
          nil -> read_line(tty, acc)
          t -> TTY.write(tty, t); read_line(tty, acc <> t)
        end
    end
  end
end
