defmodule Lepton.DocsTest do
  use ExUnit.Case

  # Guards the documentation: `mix lepton.docs` must build every page with
  # working links, every command must document itself, and guides can only
  # name commands that exist. (Host only: docs/ isn't in the image.)
  @moduletag :docs

  import Lepton.TestHelpers
  alias LeptonBuild.{Docs, Markdown}

  setup_all do
    %{pages: Docs.build(rev: "test")}
  end

  test "every page builds and every internal link resolves", %{pages: pages} do
    assert Docs.check(pages) == []
  end

  test "every guide in docs/ is a page, linked from the index", %{pages: pages} do
    slugs = MapSet.new(pages, & &1.slug)
    index = Enum.find(pages, &(&1.slug == "index"))

    for path <- Path.wildcard("docs/*.md"), slug = Path.basename(path, ".md") do
      assert MapSet.member?(slugs, slug)
      assert index.html =~ ~s(href="#{slug}.html"), "the index doesn't link #{slug}"
    end
  end

  test "every command documents itself and is in the reference", %{pages: pages} do
    reference = Enum.find(pages, &(&1.slug == "commands"))

    for c <- Lepton.Commands.builtins() |> Map.values() |> Enum.uniq_by(& &1.name) do
      assert c.summary not in [nil, ""], "#{c.name} has no summary"
      assert c.usage not in [nil, ""], "#{c.name} has no usage line (defcmd ..., usage: \"...\")"
      assert reference.html =~ ~s(>#{Markdown.escape(c.name)}</code>), "#{c.name} is missing from the command reference"
    end
  end

  test "the tutorial and key binding pages come from the code", %{pages: pages} do
    tutorial = Enum.find(pages, &(&1.slug == "lepton-tutorial"))
    for {title, _, _} <- Lepton.Tutorial.lessons(Lepton.TestHelpers.dotfiles_home()), do: assert(tutorial.html =~ Markdown.escape(title))
    keys = Enum.find(pages, &(&1.slug == "keybindings"))
    assert keys.html =~ "evil-ex"
  end

  test "every guide is in a section, and the contents show each as a drop-down" do
    pages = Docs.build(rev: "test")
    known = Enum.map(Docs.sections(), &elem(&1, 0))
    for p <- pages, p.kind == :guide, do: assert(p.section in known, "#{p.slug}: section #{inspect(p.section)}")

    dir = tmp_dir("docsout")
    Docs.write(pages, dir, "test")
    web = File.read!(Path.join(dir, "web.html"))
    assert web =~ ~s(<details class="docs-sec" open>\n          <summary>Networking and the web</summary>)
    assert web =~ ~s(<details class="docs-sec">\n          <summary>Hardware</summary>)
    index = File.read!(Path.join(dir, "index.html"))
    for {_, title} <- Docs.sections(), do: assert(index =~ Markdown.escape(title))

    bad = tmp_dir("docsbad")
    File.write!(Path.join(bad, "y.md"), "---\ntitle: Y\nsection: nowhere\n---\n# Y\n")
    assert_raise RuntimeError, ~r/unknown section nowhere/, fn -> Docs.build(docs: bad, rev: "test") end
  end

  test "a guide naming an unknown command fails the build" do
    dir = Lepton.TestHelpers.tmp_dir("docs")
    File.write!(Path.join(dir, "x.md"), "---\ntitle: X\nsection: shell\n---\n# X\n\n<!-- commands: ls frobnicate -->\n")
    assert_raise RuntimeError, ~r/frobnicate, which is not a command/, fn -> Docs.build(docs: dir, rev: "test") end
  end

  test "broken links are reported" do
    # struct/2, not %Docs.Page{}: this file must compile inside Lepton too,
    # where the generator isn't present.
    pages = [struct(Docs.Page, slug: "a", html: ~s(<h2 id="x">X</h2><a href="b.html">b</a><a href="#y">y</a><a href="#x">x</a>), headings: [])]
    assert Docs.check(pages) == ["a: link to missing page b.html", "a: link to missing section #y"]
  end

  describe "Markdown" do
    test "inline markup, escaping and anchors" do
      {html, [{1, "title-x", "Title x"}]} = Markdown.render("# Title `x`\n\nUse `a<b>` and **bold**, *em*, [l](u.html), <https://x.y/>, {#here}<b>.\n")
      assert html =~ "<code>a&lt;b&gt;</code>"
      assert html =~ "<strong>bold</strong>, <em>em</em>"
      assert html =~ ~s(<a href="u.html">l</a>)
      assert html =~ ~s(<a href="https://x.y/">https://x.y/</a>)
      assert html =~ ~s(<span class="anchor-target" id="here"></span>&lt;b&gt;.)
    end

    test "lists, tables, code and quotes" do
      {html, _} = Markdown.render("- a\n  more\n  - nested\n- b\n\n1. one\n\n| A | B |\n|---|---|\n| `x\\|y` | z |\n\n```sh\necho <hi>\n```\n\n> quoted\n")
      assert html =~ "<li>a more<ul>\n<li>nested</li>"
      assert html =~ "<ol>\n<li>one</li>"
      assert html =~ "<td><code>x|y</code></td>"
      assert html =~ ~s(<pre><code class="language-sh">echo &lt;hi&gt;</code></pre>)
      assert html =~ "<blockquote>\n<p>quoted</p>"
    end
  end
end
