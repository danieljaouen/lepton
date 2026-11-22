defmodule Mix.Tasks.Lepton.Version do
  @shortdoc "Print Lepton's version, or bump it for a release"
  @moduledoc """
  Lepton's version lives in `mix.exs` (`@version`) and in
  `rootfs/etc/os-release` (`VERSION_ID`).

      mix lepton.version            # print it
      mix lepton.version --patch    # bug fixes:           1.4.2 -> 1.4.3
      mix lepton.version --minor    # new features:        1.4.2 -> 1.5.0
      mix lepton.version --major    # a complete overhaul: 1.4.2 -> 2.0.0

  Every publish gets one bump, by the biggest change it releases: a
  release with a feature is `--minor` even if it fixes bugs too. Bump,
  commit, then `mix lepton.publish`.
  """
  use Mix.Task

  @mix "mix.exs"
  @os_release "rootfs/etc/os-release"
  @parts %{"--patch" => :patch, "--minor" => :minor, "--major" => :major}

  @impl true
  def run(args) do
    current = current()

    case args do
      [] ->
        Mix.shell().info(current)

      [flag] when is_map_key(@parts, flag) ->
        next = bump(current, @parts[flag])
        replace!(@mix, ~s(@version "#{current}"), ~s(@version "#{next}"))
        replace!(@os_release, ~s(VERSION_ID="#{current}"), ~s(VERSION_ID="#{next}"))
        # This task compiled the project when it started, perhaps within
        # the same second: Mix might not see mix.exs as changed and keep
        # the old version in lepton.app. Without it, the next build writes it.
        Enum.each(Path.wildcard("_build/*/lib/lepton/ebin/lepton.app"), &File.rm/1)
        Mix.shell().info("#{current} -> #{next}")

      _ ->
        Mix.raise("usage: mix lepton.version [--patch | --minor | --major]")
    end
  end

  @doc "The version in mix.exs."
  def current do
    case Regex.run(~r/@version "([^"]+)"/, File.read!(@mix)) do
      [_, v] -> v
      _ -> Mix.raise("no @version in #{@mix}")
    end
  end

  @doc """
  The next version: `:patch` (bug fixes, X.Y.Z -> X.Y.Z+1), `:minor`
  (features, X.Y+1.0) or `:major` (an overhaul, X+1.0.0).
  """
  def bump(version, part) do
    %Version{major: major, minor: minor, patch: patch} = Version.parse!(version)

    case part do
      :patch -> "#{major}.#{minor}.#{patch + 1}"
      :minor -> "#{major}.#{minor + 1}.0"
      :major -> "#{major + 1}.0.0"
    end
  end

  defp replace!(file, from, to) do
    text = File.read!(file)
    unless String.contains?(text, from), do: Mix.raise("#{file} doesn't have #{from}")
    File.write!(file, String.replace(text, from, to))
  end
end
