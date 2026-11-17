defmodule LeptonBuild.Docs do
  @moduledoc """
  Builds the documentation (`docs/` in the site checkout, see
  `LeptonBuild.Paths`) from two sources of truth:

    * **guides** - `docs/*.md`, hand-written, one per topic. Front matter
      gives `title`, `order` and `summary`. A line
      `<!-- commands: ip ping curl -->` becomes a table of those commands'
      summaries and usage, read from the command registry (an unknown
      name is an error, so guides can't point at removed commands);
    * **the code** - the command reference (every built-in command and
      shell builtin), the tutorial lessons, and the key bindings Lepton
      loads from the dotfiles (the output of `keys`, `bindkey`, `alias`)
      are generated, so they can't go stale.

  `build/1` returns the pages without writing anything; `write/2` writes
  them and removes pages that no longer exist. Output is deterministic
  apart from the source revision shown in the footer.
  """

  alias LeptonBuild.Markdown

  @repo "https://github.com/danieljaouen/lepton"


  @set_titles %{
    Lepton.Commands.Core => "Files and basics",
    Lepton.Commands.Text => "Text",
    Lepton.Commands.System => "System",
    Lepton.Commands.Network => "Network",
    Lepton.Commands.Dev => "Development",
    Lepton.Commands.Admin => "Administration",
    Lepton.Commands.Services => "Services"
  }

  defmodule Page do
    @moduledoc false
    defstruct [:slug, :title, :summary, :order, :markdown, :source, :html, headings: [], kind: :guide]
  end

  @doc "All pages, rendered. `opts`: `:docs` (guide dir), `:home` (dotfiles home), `:rev`."
  def build(opts \\ []) do
    docs = opts[:docs] || "docs"
    home = opts[:home] || Lepton.TestHelpers.dotfiles_home()

    guides =
      for path <- Path.wildcard(Path.join(docs, "*.md")) do
        {meta, body} = front_matter(File.read!(path), path)

        %Page{
          slug: Path.basename(path, ".md"),
          title: meta["title"] || raise("#{path}: front matter needs a title"),
          summary: meta["summary"],
          order: String.to_integer(meta["order"] || "100"),
          markdown: expand_directives(body, path),
          source: "docs/" <> Path.basename(path)
        }
      end
      |> Enum.sort_by(&{&1.order, &1.slug})

    reference = [commands_page(), keybindings_page(home), tutorial_page(home)]
    pages = guides ++ reference
    index = index_page(guides, reference)

    for page <- [index | pages] do
      {html, headings} = Markdown.render(page.markdown)
      %{page | html: html, headings: headings}
    end
  end

  @doc "Write the pages to `out` (e.g. `../danieljaouen.github.io/docs`). Returns the paths written."
  def write(pages, out, rev) do
    File.mkdir_p!(out)
    nav = Enum.reject(pages, &(&1.slug == "index"))

    written =
      for page <- pages do
        path = Path.join(out, page.slug <> ".html")
        File.write!(path, layout(page, nav, rev))
        path
      end

    # Pages whose guide was removed.
    for stale <- Path.wildcard(Path.join(out, "*.html")), stale not in written, do: File.rm!(stale)
    written
  end

  @doc "Problems that would publish broken docs: bad links and missing anchors."
  def check(pages) do
    anchors = Map.new(pages, fn p -> {p.slug <> ".html", MapSet.new(for [_, id] <- Regex.scan(~r/ id="([^"]+)"/, p.html), do: id)} end)

    for page <- pages,
        [_, href] <- Regex.scan(~r/href="([^"]+)"/, page.html),
        not String.starts_with?(href, ["http://", "https://", "mailto:", "../"]),
        problem = link_problem(href, page, anchors),
        do: "#{page.slug}: #{problem}"
  end

  defp link_problem(href, page, anchors) do
    {file, frag} =
      case String.split(href, "#", parts: 2) do
        ["", frag] -> {page.slug <> ".html", frag}
        [file, frag] -> {file, frag}
        [file] -> {file, nil}
      end

    cond do
      file == "../official.json" -> nil
      not Map.has_key?(anchors, file) -> "link to missing page #{href}"
      frag && not MapSet.member?(anchors[file], frag) -> "link to missing section #{href}"
      true -> nil
    end
  end

  # -- guides --------------------------------------------------------------------------------

  defp front_matter("---\n" <> rest, path) do
    case String.split(rest, "\n---\n", parts: 2) do
      [meta, body] ->
        meta =
          for line <- String.split(meta, "\n", trim: true), [k, v] <- [String.split(line, ":", parts: 2)], into: %{} do
            {String.trim(k), String.trim(v)}
          end

        {meta, body}

      _ ->
        raise "#{path}: unterminated front matter"
    end
  end

  defp front_matter(_text, path), do: raise("#{path}: missing front matter (---\\ntitle: ...\\n---)")

  defp expand_directives(body, path) do
    Regex.replace(~r/^<!-- commands: (.+?) -->$/m, body, fn _, names ->
      rows =
        for name <- String.split(names) do
          case Lepton.Commands.builtin_lookup(name) do
            {:ok, c} -> "| [`#{name}`](commands.html##{anchor(c.name)}) | #{cell(summary(c))} | `#{cell(c.usage)}` |"
            :error -> raise "#{path}: <!-- commands: --> names #{name}, which is not a command"
          end
        end

      "## Commands on this page\n\n| Command | What it does | Usage |\n|---|---|---|\n" <> Enum.join(rows, "\n") <> "\n"
    end)
  end

  # -- generated pages ---------------------------------------------------------------------------

  defp commands_page do
    sections =
      for set <- Lepton.Commands.sets(), Code.ensure_loaded?(set) do
        title = @set_titles[set] || set |> Module.split() |> List.last()

        rows =
          set.__commands__()
          |> Enum.sort_by(& &1.name)
          |> Enum.map_join("\n", fn c ->
            also = if c.aliases == [], do: "", else: " · also " <> Enum.map_join(c.aliases, ", ", &"`#{cell(&1)}`")
            "| {##{anchor(c.name)}}`#{cell(c.name)}`#{also} | #{cell(summary(c))} | `#{cell(c.usage)}` |"
          end)

        "## #{title}\n\n| Command | What it does | Usage |\n|---|---|---|\n#{rows}\n"
      end

    builtins = Lepton.Shell.Builtins.names() |> Enum.map_join(" ", &"`#{&1}`")
    count = Lepton.Commands.builtins() |> Map.values() |> Enum.uniq_by(& &1.name) |> length()

    %Page{
      slug: "commands",
      kind: :reference,
      title: "Command reference",
      order: 1000,
      summary: "Every built-in command, with its usage and aliases.",
      source: :generated,
      markdown: """
      # Command reference

      All #{count} commands that ship with Lepton, generated from the command
      registry. Inside Lepton, `help` lists them and `man COMMAND` shows one.
      Packages can add more ([packages](packages.html#packages-that-add-commands)).

      #{Enum.join(sections, "\n")}
      ## Shell builtins

      These run inside the shell itself ([the shell](shell.html#builtins)):
      #{builtins}.
      """
    }
  end

  defp keybindings_page(home) do
    run = fn cmd ->
      {out, _} = Lepton.Shell.run_capture(cmd <> " 2>&1", env: %{"HOME" => home, "PATH" => "/bin", "NO_COLOR" => "1"}, rc: true)
      String.trim_trailing(out)
    end

    %Page{
      slug: "keybindings",
      kind: :reference,
      title: "Key bindings",
      order: 1001,
      summary: "Everything Lepton loads from the dotfiles: editor, tmux, shell and git.",
      source: :generated,
      markdown: """
      # Key bindings

      Generated from what Lepton actually loads from the
      [dotfiles](dotfiles.html) the published ISO is built with, using the
      same commands you can run inside Lepton (`keys`, `bindkey`, `alias`).
      Built-in Spacemacs and tmux defaults are described on the
      [editor](editor.html) and [tmux](tmux.html) pages.

      ## Editor

      `keys editor`: bindings and settings read from `~/.spacemacs`.

      ```
      #{run.("keys editor")}
      ```

      ## tmux

      `keys tmux`: the key tables from `~/.tmux.conf`.

      ```
      #{run.("keys tmux")}
      ```

      ## Shell line editor

      `bindkey`: the line editor's keys (oh-my-zsh emacs bindings).

      ```
      #{run.("bindkey")}
      ```

      ## Shell aliases

      `alias`: from `~/.zshrc` and the oh-my-zsh git plugin.

      ```
      #{run.("alias")}
      ```

      ## git

      `keys git`: aliases from `~/.gitconfig`.

      ```
      #{run.("keys git")}
      ```
      """
    }
  end

  defp tutorial_page(home) do
    lessons =
      Lepton.Tutorial.lessons(home)
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {{title, text, cmd}, n} ->
        body = text |> String.split("\n") |> Enum.map_join("\n", &String.trim/1) |> String.trim()
        try = if cmd, do: "\n\nTry:\n\n```sh\n#{cmd}\n```\n", else: "\n"
        "## #{n}. #{title}\n\n#{body}#{try}"
      end)

    %Page{
      slug: "tutorial",
      kind: :reference,
      title: "Tutorial",
      order: 1002,
      summary: "The lessons of lepton-tutorial, the interactive tour.",
      source: :generated,
      markdown: """
      # Tutorial

      `lepton-tutorial` is an interactive tour: each lesson explains a topic
      and suggests a command to run for real. It is offered once after
      installation and runs any time. These are its lessons, generated from
      the tutorial itself, with the key bindings from the dotfiles.

      #{lessons}
      """
    }
  end

  defp index_page(guides, reference) do
    list = fn pages -> Enum.map_join(pages, "\n", &"- [#{&1.title}](#{&1.slug}.html): #{&1.summary}") end

    %Page{
      slug: "index",
      kind: :index,
      title: "Documentation",
      order: 0,
      source: :generated,
      markdown: """
      # Lepton documentation

      Everything Lepton OS can do, for the version on the
      [download](../#download) page. New to Lepton? Start with
      [getting started](getting-started.html), then take the
      [tutorial](tutorial.html) inside the OS.

      ## Guides

      #{list.(guides)}

      ## Reference

      #{list.(reference)}
      """
    }
  end

  defp anchor(name), do: "cmd-" <> String.replace(name, ~r/[^A-Za-z0-9_-]/, fn c -> "_#{:binary.first(c)}" end)
  # Commands only root may run say so (see Users and sudo).
  defp summary(%{root: true} = c), do: c.summary <> " (needs [sudo](users.html))"
  defp summary(c), do: c.summary

  defp cell(nil), do: ""
  defp cell(text), do: text |> String.replace("|", "\\|") |> String.replace("\n", " ")

  # -- layout ---------------------------------------------------------------------------------------

  defp layout(page, nav, rev) do
    e = &Markdown.escape/1
    title = if page.slug == "index", do: "Lepton OS documentation", else: "#{page.title} - Lepton OS docs"

    {guides, reference} = Enum.split_with(nav, &(&1.kind == :guide))

    links = fn pages ->
      Enum.map_join(pages, "\n", fn p ->
        current = if p.slug == page.slug, do: ~s( aria-current="page"), else: ""
        ~s(          <li><a href="#{p.slug}.html"#{current}>#{e.(p.title)}</a></li>)
      end)
    end

    toc =
      case for({2, id, text} <- page.headings, do: {id, text}) do
        [] -> ""
        h2s ->
          items = Enum.map_join(h2s, "\n", fn {id, text} -> ~s(          <li><a href="##{id}">#{e.(text)}</a></li>) end)
          ~s(\n      <nav class="docs-toc" aria-label="On this page">\n        <p class="docs-toc-title">On this page</p>\n        <ul>\n#{items}\n        </ul>\n      </nav>)
      end

    source =
      case page.source do
        :generated -> "Generated from the source of lepton@#{rev}."
        file -> ~s(Documents lepton@#{rev}. <a href="#{@repo}/blob/main/#{file}">Edit this page on GitHub</a>.)
      end

    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
    #{LeptonBuild.SiteTags.head()}
      <title>#{e.(title)}</title>
      <meta name="description" content="#{e.(page.summary || "Documentation for Lepton OS, a Unix-like operating system with an Elixir userland.")}">
      <meta name="theme-color" content="#1b1d1e">
      <link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Crect width='64' height='64' rx='14' fill='%2366d9ef'/%3E%3Cpath d='M22 14v32h20' stroke='%231b1d1e' stroke-width='8' fill='none' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E">
      <link rel="stylesheet" href="../assets/style.css">
      <link rel="stylesheet" href="../assets/docs.css">
      <script>try { var t = localStorage.getItem("lepton-theme"); if (t) document.documentElement.dataset.theme = t; } catch (e) {}</script>
    </head>
    <body class="docs">
      <a class="skip" href="#main">Skip to content</a>
      <header class="nav">
        <div class="wrap nav-inner">
          <a class="brand" href="../" aria-label="Lepton OS home"><span class="logo" aria-hidden="true">L</span> Lepton&nbsp;OS</a>
          <nav aria-label="Site">
            <ul class="nav-links">
              <li><a href="index.html" aria-current="#{if page.slug == "index", do: "page", else: "false"}">Docs</a></li>
              <li><a href="../#download">Download</a></li>
            </ul>
          </nav>
          <div class="nav-actions">
            <button class="icon-btn" id="theme-toggle" type="button" aria-label="Toggle light and dark theme">
              <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3a9 9 0 1 0 9 9 7 7 0 0 1-9-9z"/></svg>
            </button>
            <a class="btn btn-small" href="#{@repo}">GitHub</a>
          </div>
        </div>
      </header>
      <div class="wrap docs-grid">
        <nav class="docs-nav" aria-label="Documentation">
          <details open>
            <summary>Contents</summary>
            <p class="docs-nav-title"><a href="index.html">Documentation</a></p>
            <p class="docs-nav-group">Guides</p>
            <ul>
    #{links.(guides)}
            </ul>
            <p class="docs-nav-group">Reference</p>
            <ul>
    #{links.(reference)}
            </ul>
          </details>
        </nav>
        <main id="main" class="docs-main">
          <article class="prose">
    #{page.html}
          </article>
          <footer class="docs-foot">#{source}</footer>
        </main>#{toc}
      </div>
      <script>
        // The contents list starts collapsed on phones.
        if (matchMedia("(max-width: 820px)").matches) document.querySelector(".docs-nav details").open = false;
        document.getElementById("theme-toggle").addEventListener("click", function () {
          var root = document.documentElement;
          var cur = root.dataset.theme || (matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark");
          var next = cur === "light" ? "dark" : "light";
          root.dataset.theme = next;
          try { localStorage.setItem("lepton-theme", next); } catch (e) {}
        });
      </script>
    </body>
    </html>
    """
  end
end
