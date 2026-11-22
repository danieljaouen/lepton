defmodule Mix.Tasks.Lepton.Version do
  @shortdoc "Print Lepton's version, or bump it"
  @moduledoc """
  Lepton's version lives in `mix.exs` (`@version`) and in
  `rootfs/etc/os-release` (`VERSION_ID`).

      mix lepton.version          # print it
      mix lepton.version --bump   # 1.0.0 -> 1.1.0, in both files
      mix lepton.version --patch  # 1.0.0 -> 1.0.1: the build number

  Every publish gets a version bump: the minor version unless the
  build number is asked for. Bump, commit, then `mix lepton.publish`.
  """
  use Mix.Task

  @mix "mix.exs"
  @os_release "rootfs/etc/os-release"

  @impl true
  def run(args) do
    current = current()

    case args do
      [] ->
        Mix.shell().info(current)

      [flag] when flag in ["--bump", "--patch"] ->
        next = if flag == "--patch", do: bump(current, :patch), else: bump(current)
        replace!(@mix, ~s(@version "#{current}"), ~s(@version "#{next}"))
        replace!(@os_release, ~s(VERSION_ID="#{current}"), ~s(VERSION_ID="#{next}"))
        # This task compiled the project when it started, perhaps within
        # the same second: Mix might not see mix.exs as changed and keep
        # the old version in lepton.app. Without it, the next build writes it.
        Enum.each(Path.wildcard("_build/*/lib/lepton/ebin/lepton.app"), &File.rm/1)
        Mix.shell().info("#{current} -> #{next}")

      _ ->
        Mix.raise("usage: mix lepton.version [--bump | --patch]")
    end
  end

  @doc "The version in mix.exs."
  def current do
    case Regex.run(~r/@version "([^"]+)"/, File.read!(@mix)) do
      [_, v] -> v
      _ -> Mix.raise("no @version in #{@mix}")
    end
  end

  @doc "The next minor version, X.Y.Z -> X.(Y+1).0, or build number, X.Y.Z -> X.Y.(Z+1)."
  def bump(version, part \\ :minor) do
    %Version{major: major, minor: minor, patch: patch} = Version.parse!(version)
    if part == :patch, do: "#{major}.#{minor}.#{patch + 1}", else: "#{major}.#{minor + 1}.0"
  end

  defp replace!(file, from, to) do
    text = File.read!(file)
    unless String.contains?(text, from), do: Mix.raise("#{file} doesn't have #{from}")
    File.write!(file, String.replace(text, from, to))
  end
end
