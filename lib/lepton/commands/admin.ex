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

  defcmd "wifi", "Wi-Fi: status, scan, connect and saved networks",
    usage: "wifi [status] | scan [IFACE] | connect SSID [PASSPHRASE] | forget [SSID] | setup" do
    wifi(args, ctx)
  end

  defp wifi(["scan" | rest], ctx) do
    case List.first(rest) || List.first(Lepton.Wifi.wireless_interfaces()) do
      nil ->
        IO.err(ctx, "wifi: no Wi-Fi hardware (UTM/QEMU have none; pass a USB Wi-Fi adapter through to the VM)")
        1

      iface ->
        IO.puts(ctx, "Scanning on #{iface}...")

        case Lepton.Wifi.scan(iface) do
          {:ok, []} ->
            IO.puts(ctx, "No networks found.")
            0

          {:ok, nets} ->
            IO.puts(ctx, String.pad_trailing("SSID", 32) <> " SIGNAL    SECURITY   BAND")

            for n <- nets do
              band = if n.frequency >= 5000, do: "5 GHz", else: "2.4 GHz"
              IO.puts(ctx, "#{String.pad_trailing(n.ssid, 32)} #{String.pad_trailing("#{n.signal} dBm", 9)} #{String.pad_trailing(n.security, 10)} #{band}")
            end

            0

          {:error, e} ->
            IO.err(ctx, "wifi: scan failed on #{iface}: #{inspect(e)}")
            1
        end
    end
  end

  defp wifi(["connect", ssid | rest], ctx) do
    pass =
      case rest do
        [p | _] -> p
        [] -> if ctx.tty, do: Lepton.Setup.read_secret(ctx, "Passphrase for #{ssid} (Enter for an open network): "), else: ""
      end

    if pass == nil do
      IO.err(ctx, "wifi: cancelled")
      1
    else
      Lepton.Wifi.save(ssid, pass)

      case Lepton.Wifi.wireless_interfaces() do
        [] ->
          IO.puts(ctx, "Saved \"#{ssid}\". No Wi-Fi hardware yet: Lepton connects as soon as an adapter appears.")
          0

        [iface | _] ->
          IO.puts(ctx, "Saved \"#{ssid}\". Connecting on #{iface}...")

          with {:ok, st} <- Lepton.Wifi.await_associated(iface, 30_000),
               _ = IO.puts(ctx, "Associated with #{st["ssid"]}; asking for an address (DHCP)..."),
               {:ok, l} <- Lepton.Wifi.await_lease(iface, 20_000) do
            IO.puts(ctx, "Connected: #{iface} #{Lepton.Net.format_ip(l.ip)}/#{l.prefix}")
            0
          else
            {:error, :timeout} ->
              IO.err(ctx, "wifi: associated, but no DHCP address yet. Lepton keeps trying; `wifi` shows the status.")
              1

            {:error, state} ->
              IO.err(ctx, "wifi: not connected yet (#{state}). Lepton keeps trying; `wifi` shows the status.")
              1
          end
      end
    end
  end

  defp wifi(["forget" | rest], ctx) do
    case Lepton.Wifi.forget(List.first(rest)) do
      :ok ->
        IO.puts(ctx, if(rest == [], do: "Forgot all saved Wi-Fi networks.", else: "Forgot \"#{hd(rest)}\"."))
        0

      {:error, :not_found} ->
        IO.err(ctx, "wifi: \"#{hd(rest)}\" is not a saved network")
        1
    end
  end

  defp wifi(["setup" | _], ctx) do
    if ctx.tty, do: Lepton.Setup.wifi_prompt(ctx, false)
    0
  end

  defp wifi(args, ctx) when args in [[], ["status"]] do
    for line <- Lepton.Wifi.status_lines(), do: IO.puts(ctx, line)
    0
  end

  defp wifi(_, ctx) do
    IO.err(ctx, "usage: wifi [status] | scan [IFACE] | connect SSID [PASSPHRASE] | forget [SSID] | setup")
    2
  end

  defcmd "credits", "who made Lepton", usage: "credits" do
    IO.puts(ctx, Lepton.credits())
    0
  end
end
