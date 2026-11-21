defmodule Mix.Tasks.Lepton.Version do
  @shortdoc "Print Lepton's version, or bump its minor version"
  @moduledoc """
  Lepton's version lives in `mix.exs` (`@version`) and in
  `rootfs/etc/os-release` (`VERSION_ID`).

      mix lepton.version          # print it
      mix lepton.version --bump   # 1.0.0 -> 1.1.0, in both files

  Every publish gets a minor version bump: run `--bump`, commit, then
  `mix lepton.publish`.
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

      ["--bump"] ->
        next = bump(current)
        replace!(@mix, ~s(@version "#{current}"), ~s(@version "#{next}"))
        replace!(@os_release, ~s(VERSION_ID="#{current}"), ~s(VERSION_ID="#{next}"))
        Mix.shell().info("#{current} -> #{next}")

      _ ->
        Mix.raise("usage: mix lepton.version [--bump]")
    end
  end

  @doc "The version in mix.exs."
  def current do
    case Regex.run(~r/@version "([^"]+)"/, File.read!(@mix)) do
      [_, v] -> v
      _ -> Mix.raise("no @version in #{@mix}")
    end
  end

  @doc "The next minor version: X.Y.Z -> X.(Y+1).0."
  def bump(version) do
    %Version{major: major, minor: minor} = Version.parse!(version)
    "#{major}.#{minor + 1}.0"
  end

  defp replace!(file, from, to) do
    text = File.read!(file)
    unless String.contains?(text, from), do: Mix.raise("#{file} doesn't have #{from}")
    File.write!(file, String.replace(text, from, to))
  end
end
