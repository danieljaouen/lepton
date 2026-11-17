defmodule LeptonBuild.Paths do
  @moduledoc """
  Where the build tooling finds the website and the dotfiles.

    * **Site**: the checkout the tooling writes, commits and pushes
      (`mix lepton.docs`, `lepton.site.tags`, `lepton.official`,
      `lepton.publish`). `LEPTON_SITE`, else a maintainer's SSH clone at
      `../danieljaouen.github.io`, else the `site/` submodule (an HTTPS
      mirror: fine for previews, not for pushing).
    * **Dotfiles**: the repository installed into `/root` by `mix
      lepton.iso`. `LEPTON_DOTFILES`, else `~/.dotfiles`, else none.
  """

  @submodule "site"
  @maintainer_site "../danieljaouen.github.io"

  def submodule, do: @submodule

  def site do
    cond do
      dir = System.get_env("LEPTON_SITE") -> dir
      git_dir?(@maintainer_site) -> @maintainer_site
      true -> @submodule
    end
  end

  @doc "Is the site checkout separate from the `site/` submodule?"
  def separate_site?(site \\ site()), do: Path.expand(site) != Path.expand(@submodule)

  def dotfiles do
    dir = System.get_env("LEPTON_DOTFILES") || Path.expand("~/.dotfiles")
    if File.dir?(dir), do: dir
  end

  defp git_dir?(dir), do: File.exists?(Path.join(dir, ".git"))
end
