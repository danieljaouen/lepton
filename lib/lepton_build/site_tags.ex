defmodule LeptonBuild.SiteTags do
  @moduledoc """
  Keeps the site-wide `<head>` tags (Google Tag Manager) on every page of
  the website.

  The block lives in one place, `lib/lepton_build/site_head.html`, between
  `<!-- Google Tag Manager -->` and `<!-- End Google Tag Manager -->`.
  `apply/1` puts the current block into every `*.html` file under the
  site: it is inserted after the viewport `<meta>` (or right after
  `<head>`) where missing, and replaced where outdated, so editing the file
  and running `mix lepton.site.tags` updates every page. Generated docs
  pages get it from `head/1` directly.

  It runs from `mix lepton.publish` and `mix lepton.docs`; `mix test` and
  the site repository's GitHub check fail for any page without it.
  """

  @source Path.expand("site_head.html", __DIR__)
  @external_resource @source
  @block @source |> File.read!() |> String.trim_trailing()

  @start "<!-- Google Tag Manager -->"
  @finish "<!-- End Google Tag Manager -->"

  @doc "The block, each line indented by `indent`."
  def head(indent \\ "  "), do: @block |> String.split("\n") |> Enum.map_join("\n", &(indent <> &1))

  @doc "A string every tagged page contains (for checks)."
  def marker, do: Regex.run(~r/gtm\.js\?id=[A-Z0-9-]+/, @block) |> hd()

  @doc "Tag every page under `dir`. Returns the files changed."
  def apply(dir) do
    for {path, _html, tagged} <- untagged(dir) do
      File.write!(path, tagged)
      path
    end
  end

  @doc "Pages under `dir` without the current block."
  def missing(dir), do: for({path, _, _} <- untagged(dir), do: path)

  defp untagged(dir) do
    for path <- pages(dir),
        html = File.read!(path),
        tagged = tag(html),
        tagged != html,
        do: {path, html, tagged}
  end

  defp pages(dir) do
    Path.wildcard(Path.join(dir, "**/*.html"))
    |> Enum.reject(&String.contains?(&1, ["/node_modules/", "/.git/"]))
    |> Enum.sort()
  end

  @doc "Insert or refresh the block in one page's HTML."
  def tag(html) do
    case existing(html) do
      {old, indent} -> String.replace(html, old, head(indent), global: false)
      nil -> insert(html)
    end
  end

  # The current block (with its indentation), or an older unmarked copy of
  # the GTM snippet followed by its inline script.
  defp existing(html) do
    marked = ~r/(?<indent>[ \t]*)#{Regex.escape(@start)}.*?#{Regex.escape(@finish)}/s
    legacy = ~r/(?<indent>[ \t]*)(?:#{Regex.escape(@start)}\s*)?<script async src="https:\/\/www\.googletagmanager\.com\/gtm\.js[^"]*"><\/script>\s*<script>.*?<\/script>/s

    Enum.find_value([marked, legacy], fn re ->
      case Regex.run(re, html, capture: :first, return: :index) do
        [{at, len}] ->
          old = binary_part(html, at, len)
          [_, indent] = Regex.run(~r/^([ \t]*)/, old)
          {old, indent}

        nil ->
          nil
      end
    end)
  end

  defp insert(html) do
    anchor =
      Regex.run(~r/^([ \t]*)<meta name="viewport"[^>]*>[ \t]*\n/m, html, return: :index) ||
        Regex.run(~r/^([ \t]*)<head[^>]*>[ \t]*\n/im, html, return: :index)

    case anchor do
      [{at, len}, {iat, ilen}] ->
        indent = binary_part(html, iat, ilen)
        # Inside <head> the block lines up with the viewport <meta>; after a
        # bare <head> it is indented one step further.
        indent = if binary_part(html, at, len) =~ ~r/<head/i, do: indent <> "  ", else: indent
        binary_part(html, 0, at + len) <> head(indent) <> "\n" <> binary_part(html, at + len, byte_size(html) - at - len)

      nil ->
        raise "cannot tag a page without a <head>: #{String.slice(html, 0, 80)}"
    end
  end
end
