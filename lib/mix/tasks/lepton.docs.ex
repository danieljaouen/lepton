defmodule Mix.Tasks.Lepton.Docs do
  @shortdoc "Generate the documentation (SITE/docs) from docs/*.md and the code"
  @moduledoc """
  Builds `docs/` in the site checkout (`LeptonBuild.Paths.site/0`:
  `../danieljaouen.github.io` for maintainers, else the `site/` submodule)
  with `LeptonBuild.Docs`: the guides in `docs/*.md` plus pages generated
  from the code (command reference, key bindings, tutorial).

      mix lepton.docs              # write SITE/docs (preview: open SITE/docs/index.html)
      mix lepton.docs --check      # fail if the docs have broken links or bad directives
      mix lepton.docs --publish    # write, then commit and push the site

  `mix lepton.publish` runs this for every release, so the published docs
  always describe the downloadable ISO. Use `--publish` for documentation
  fixes between releases.
  """
  use Mix.Task

  alias LeptonBuild.Paths

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [check: :boolean, publish: :boolean])
    Mix.Task.run("app.start")

    rev = System.cmd("git", ["rev-parse", "--short", "HEAD"]) |> elem(0) |> String.trim()
    pages = LeptonBuild.Docs.build(rev: rev)

    case LeptonBuild.Docs.check(pages) do
      [] -> :ok
      problems -> Mix.raise("documentation problems:\n  " <> Enum.join(problems, "\n  "))
    end

    if opts[:check] do
      Mix.shell().info("docs: #{length(pages)} pages, no problems")
    else
      site = Paths.site()
      out = Path.join(site, "docs")
      LeptonBuild.Docs.write(pages, out, rev)
      # Every page of the site, not just the docs, carries the site tags.
      tagged = LeptonBuild.SiteTags.apply(site)
      Mix.shell().info([:cyan, "==> ", :reset, "wrote #{length(pages)} pages to #{out}/" <> if(tagged == [], do: "", else: "; tagged #{length(tagged)} other page(s)")])
      if opts[:publish], do: publish(site, rev, Enum.map(tagged, &Path.relative_to(&1, site)))
    end
  end

  defp publish(site, rev, tagged) do
    git = fn args -> System.cmd("git", ["-C", site | args], stderr_to_stdout: true) end
    git.(["add", "docs", "assets/docs.css" | tagged])

    case git.(["diff", "--cached", "--quiet"]) do
      {_, 0} ->
        Mix.shell().info("docs: already up to date")

      _ ->
        {_, 0} = git.(["commit", "-q", "-m", "Update documentation (lepton@#{rev})\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\n"])
        {out, status} = git.(["pull", "--rebase", "-q"])
        if status != 0, do: Mix.raise("git pull --rebase failed in site:\n#{out}")
        {out, status} = git.(["push", "-q"])
        if status != 0, do: Mix.raise("git push failed in site:\n#{out}")
        Mix.shell().info([:cyan, "==> ", :reset, "published the docs"])
    end
  end
end
