defmodule LeptonBuild.Paths do
  @moduledoc """
  Where the build tooling finds the website and the dotfiles.

    * **Site**: the checkout the tooling writes, commits and pushes
      (`mix lepton.docs`, `lepton.site.tags`, `lepton.official`,
      `lepton.publish`). `LEPTON_SITE`, else a maintainer's SSH clone at
      `../danieljaouen.github.io`, else the `site/` submodule (an HTTPS
      mirror: fine for previews, not for pushing).
    * **Dotfiles**: the repository installed into `/root` by `mix
      lepton.iso`, and read by `mix lepton.docs` (the keybindings page).
      `LEPTON_DOTFILES` (a local checkout, for a build of your own),
      else the repository on GitHub (`LEPTON_DOTFILES_URL`, else
      danieljaouen/dotfiles), cloned into `_build/lepton/dotfiles` and
      brought up to date at each build: what is published comes from what
      is pushed, the same on a Mac and inside Lepton, whatever is checked
      out locally.
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

  @dotfiles_url "https://github.com/danieljaouen/dotfiles.git"

  def dotfiles_url, do: System.get_env("LEPTON_DOTFILES_URL") || @dotfiles_url

  @doc "The dotfiles to build with (see above): a directory, or nil for Lepton's built-in defaults."
  def dotfiles do
    case System.get_env("LEPTON_DOTFILES") do
      nil -> github_dotfiles()
      dir -> if File.dir?(dir), do: dir
    end
  end

  @doc """
  The dotfiles repository from GitHub, in `_build/lepton/dotfiles`: cloned
  the first time, then brought to the remote's latest commit (once per
  run: the ISO and the docs share it). Offline, the copy from last time,
  with a warning; nil without one.
  """
  def github_dotfiles(dir \\ Path.join([File.cwd!(), "_build", "lepton", "dotfiles"]), url \\ dotfiles_url()) do
    key = {__MODULE__, :dotfiles, dir}

    case :persistent_term.get(key, nil) do
      nil ->
        result = fetch_dotfiles(dir, url)
        :persistent_term.put(key, result)
        result

      done ->
        done
    end
  end

  defp fetch_dotfiles(dir, url) do
    synced =
      if git_dir?(dir) do
        # The build's own copy: brought exactly to the remote's head.
        git(dir, ["remote", "set-url", "origin", url]) == :ok and
          git(dir, ["fetch", "-q", "--depth", "1", "origin", "HEAD"]) == :ok and
          git(dir, ["reset", "-q", "--hard", "FETCH_HEAD"]) == :ok
      else
        File.rm_rf(dir)
        File.mkdir_p!(Path.dirname(dir))
        git(Path.dirname(dir), ["clone", "-q", "--depth", "1", url, dir]) == :ok
      end

    cond do
      synced ->
        Mix.shell().info("  dotfiles #{url} at #{commit(dir)}")
        dir

      git_dir?(dir) ->
        Mix.shell().info("  (couldn't fetch #{url}: using the copy fetched before, at #{commit(dir)})")
        dir

      true ->
        Mix.shell().info("  (couldn't fetch #{url}, and no copy from before: no dotfiles)")
        nil
    end
  end

  @doc "Where dotfiles in `dir` came from: `URL at COMMIT` for a git checkout, else the path."
  def dotfiles_source(dir) do
    case {System.cmd("git", ["-C", dir, "remote", "get-url", "origin"], stderr_to_stdout: true), commit(dir)} do
      {{url, 0}, sha} when sha != nil -> "#{String.trim(url)} at #{sha}"
      _ -> Path.expand(dir)
    end
  rescue
    _ -> Path.expand(dir)
  end

  defp commit(dir) do
    case System.cmd("git", ["-C", dir, "rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp git(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, out}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp git_dir?(dir), do: File.exists?(Path.join(dir, ".git"))
end
