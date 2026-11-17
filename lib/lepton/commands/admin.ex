defmodule Lepton.Commands.Admin do
  @moduledoc "Installation, setup, packages and credits."

  use Lepton.Command

  defcmd "lepton-install", "install Lepton from the ISO onto a disk", usage: "lepton-install [-y] [/dev/DISK]" do
    Lepton.Installer.run(args, ctx)
  end

  defcmd "lepton-tutorial", "an interactive tour of Lepton", usage: "lepton-tutorial", aliases: ["tutorial"] do
    Lepton.Tutorial.run(ctx)
  end

  defcmd "lpm", "Lepton package manager (packages from hex.pm)", usage: "lpm search|info|install|list|remove|update|official|upgrade|revert ..." do
    Lepton.Pkg.cli(args, ctx)
  end

  defcmd "wifi", "Wi-Fi status and credential setup", usage: "wifi [status | setup | forget]" do
    case args do
      ["setup" | _] ->
        if ctx.tty, do: Lepton.Setup.wifi_prompt(ctx, false)
        0

      ["forget" | _] ->
        File.rm(Lepton.Wifi.conf_path())
        File.rm(Lepton.Persist.state_path("wifi-skipped"))
        IO.puts(ctx, "Forgot saved Wi-Fi networks.")
        0

      _ ->
        for line <- Lepton.Wifi.status_lines(), do: IO.puts(ctx, line)
        0
    end
  end

  defcmd "credits", "who made Lepton", usage: "credits" do
    IO.puts(ctx, Lepton.credits())
    0
  end
end
