defmodule Mix.Tasks.Lepton.Iso do
  @shortdoc "Build the bootable Lepton OS ISO (out/lepton.iso)"
  @moduledoc """
  Builds `out/lepton.iso`.

      mix lepton.iso [--dotfiles PATH] [--out DIR]

  The dotfiles repository (default `./dotfiles`) is installed into `/root`
  following its `locations/` convention.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [dotfiles: :string, out: :string])
    Mix.Task.run("compile")
    Mix.Task.run("app.config")
    Application.load(:lepton)
    LeptonBuild.Image.build!(dotfiles: opts[:dotfiles], out_dir: opts[:out])
  end
end
