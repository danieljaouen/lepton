defmodule Lepton.SiteTagsTest do
  use ExUnit.Case

  # The site-wide <head> tags (Google Tag Manager) must be on every page of
  # the website, including pages added later. (Host only, like the docs.)
  @moduletag :docs

  alias LeptonBuild.SiteTags

  test "every page of the site carries the current tags" do
    assert SiteTags.missing("site") == [], "run `mix lepton.site.tags` to tag these pages"
  end

  test "a new page gets the block after its viewport meta, aligned with it" do
    page = "<!doctype html>\n<html>\n<head>\n  <meta charset=\"utf-8\">\n  <meta name=\"viewport\" content=\"width=device-width\">\n  <title>New</title>\n</head>\n<body></body>\n</html>\n"
    tagged = SiteTags.tag(page)
    assert tagged =~ "  <meta name=\"viewport\" content=\"width=device-width\">\n" <> SiteTags.head("  ") <> "\n  <title>New</title>"
    assert SiteTags.tag(tagged) == tagged
  end

  test "a page without a viewport meta gets it right after <head>" do
    tagged = SiteTags.tag("<html>\n<head>\n<title>x</title>\n</head>\n</html>\n")
    assert tagged =~ "<head>\n" <> SiteTags.head("  ") <> "\n<title>x</title>"
  end

  test "older copies are replaced: the unmarked snippet and outdated blocks" do
    legacy = """
    <head>
      <!-- Google Tag Manager -->
      <script async src="https://www.googletagmanager.com/gtm.js?id=GTM-NXNK6NF7"></script>
      <script>
        gtag('js', new Date());
      </script>
      <title>x</title>
    """

    assert SiteTags.tag(legacy) == "<head>\n" <> SiteTags.head("  ") <> "\n  <title>x</title>\n"

    outdated = "<head>\n    <!-- Google Tag Manager -->\n    <script>old()</script>\n    <!-- End Google Tag Manager -->\n</head>\n"
    assert SiteTags.tag(outdated) == "<head>\n" <> SiteTags.head("    ") <> "\n</head>\n"
  end

  test "apply/1 tags only what needs it; a page without <head> is an error" do
    dir = Lepton.TestHelpers.tmp_dir("site")
    File.mkdir_p!(Path.join(dir, "blog"))
    File.write!(Path.join(dir, "blog/post.html"), "<html>\n<head>\n</head>\n</html>\n")
    File.write!(Path.join(dir, "done.html"), SiteTags.tag("<html>\n<head>\n</head>\n</html>\n"))

    assert SiteTags.apply(dir) == [Path.join(dir, "blog/post.html")]
    assert SiteTags.missing(dir) == []
    assert SiteTags.apply(dir) == []

    File.write!(Path.join(dir, "fragment.html"), "<p>no head</p>")
    assert_raise RuntimeError, ~r/without a <head>/, fn -> SiteTags.apply(dir) end
  end
end
