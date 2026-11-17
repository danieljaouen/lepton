defmodule Mix.Tasks.Lepton.Site.Tags do
  @shortdoc "Put the site-wide <head> tags (Google Tag Manager) on every site page"
  @moduledoc """
  Inserts or refreshes the block from `lib/lepton_build/site_head.html` in
  every `*.html` page under `site/` (see `LeptonBuild.SiteTags`).

      mix lepton.site.tags            # tag every page; prints what changed
      mix lepton.site.tags --check    # fail if any page lacks the current block

  `mix lepton.publish` and `mix lepton.docs` run it automatically, so new
  pages are tagged before they are committed.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [check: :boolean, site: :string])
    site = opts[:site] || "site"

    if opts[:check] do
      case LeptonBuild.SiteTags.missing(site) do
        [] -> Mix.shell().info("site tags: every page is tagged")
        pages -> Mix.raise("pages without the current site tags (run mix lepton.site.tags):\n  " <> Enum.join(pages, "\n  "))
      end
    else
      case LeptonBuild.SiteTags.apply(site) do
        [] -> Mix.shell().info("site tags: every page already tagged")
        changed -> Mix.shell().info([:cyan, "==> ", :reset, "tagged #{length(changed)} page(s): " <> Enum.map_join(changed, ", ", &Path.relative_to(&1, site))])
      end
    end
  end
end
