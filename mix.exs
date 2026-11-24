defmodule Lepton.MixProject do
  use Mix.Project

  @version "1.19.1"

  def project do
    [
      app: :lepton,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: false,
      deps: [],
      test_paths: ["test"],
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :public_key, :ssl, :ssh, :inets, :parsetools],
      mod: {Lepton.Application, []}
    ]
  end

  defp aliases do
    [
      iso: ["compile", "lepton.iso"],
      boot: ["lepton.qemu"]
    ]
  end
end
