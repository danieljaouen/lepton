defmodule Lepton.Setup do
  @moduledoc """
  First-run setup shown on the consoles before the login shell:

    1. **Wi-Fi** - when the machine has Wi-Fi hardware and no network is
       saved: at every startup of the live ISO, and on an installed system
       until answered (Enter skips; it is skipped automatically after 30
       seconds so headless boots are not blocked). `wifi setup` re-runs it.
    2. **Tutorial** - offered once, on the first boot after installation.

  Each prompt is answered once per boot: when two consoles are attached
  (display and serial), answering on either dismisses it on both.
  """

  alias Lepton.{Persist, TTY, Wifi}

  @timeout_s 30

  def run(ctx) do
    if Lepton.Sys.native?() and ctx.tty do
      # Virtual machines have no Wi-Fi hardware: no prompt there.
      if Wifi.wireless_interfaces() != [], do: wifi(ctx)
      tutorial(ctx)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  defp done?(key), do: :persistent_term.get({__MODULE__, key}, false)
  defp done!(key), do: :persistent_term.put({__MODULE__, key}, true)

  defp wifi(ctx) do
    unless done?(:wifi) or (Persist.installed?() and Wifi.configured?()) do
      # Give DHCP a moment so the summary can show the wired address.
      Process.sleep(1500)
      out(ctx, "\r\n\e[1mNetwork setup\e[0m\r\n" <> Enum.map_join(Wifi.status_lines(), "", &"  #{&1}\r\n"))
      wifi_prompt(ctx)
    end
  end

  @doc "Interactive Wi-Fi credential prompt (also used by `wifi setup`)."
  def wifi_prompt(ctx, timeout? \\ true) do
    case read(ctx, "Wi-Fi network name (SSID), or Enter to skip#{if timeout?, do: " [auto-skips in #{@timeout_s}s]", else: ""}: ", :wifi, timeout?, false) do
      ssid when ssid in [nil, ""] ->
        if Persist.installed?(), do: Persist.set_flag("wifi-skipped")
        done!(:wifi)
        out(ctx, "Skipped. Run `wifi setup` any time.\r\n\r\n")
        :skipped

      ssid ->
        pass = read(ctx, "Passphrase for #{ssid} (Enter for an open network): ", :wifi_pass, false, true) || ""
        Wifi.save(ssid, pass)
        done!(:wifi)

        out(ctx, """
        Saved "#{ssid}" to #{Wifi.conf_path()} (stored as a WPA PSK).\r
        #{if Wifi.wireless_interfaces() == [], do: "No Wi-Fi hardware yet: Lepton connects as soon as an adapter appears.", else: "Connecting in the background; `wifi` shows the status."}\r
        \r
        """)

        :saved
    end
  end

  defp tutorial(ctx) do
    if Persist.installed?() and not Persist.flag?("tutorial-offered") and not done?(:tutorial) do
      done!(:tutorial)
      Persist.set_flag("tutorial-offered")

      case read(ctx, "Welcome to your new Lepton install! Take the tutorial now? [Y/n] ", :tutorial_answer, true, false) do
        answer when answer in [nil, "", "y", "Y", "yes"] -> Lepton.Tutorial.run(ctx)
        _ -> out(ctx, "OK - run `lepton-tutorial` whenever you like.\r\n")
      end
    end
  end

  @doc "Read a line without echoing it (`*` per character); nil if cancelled."
  def read_secret(ctx, prompt), do: read(ctx, prompt, :secret, false, true)

  # Line input with an optional timeout; aborts when another console has
  # already answered `key`.
  defp read(ctx, prompt, key, timeout?, secret) do
    tty = ctx.tty
    TTY.set_mode(tty, :raw)
    out(ctx, prompt)
    deadline = System.monotonic_time(:millisecond) + @timeout_s * 1000

    try do
      read_loop(tty, "", key, if(timeout?, do: deadline), secret)
    after
      TTY.set_mode(tty, :cooked)
      out(ctx, "\r\n")
    end
  end

  defp read_loop(tty, acc, key, deadline, secret) do
    cond do
      done?(key) and key in [:wifi, :tutorial_answer] -> nil
      deadline && System.monotonic_time(:millisecond) > deadline -> nil
      true ->
        case TTY.read_key(tty, 1000) do
          :timeout -> read_loop(tty, acc, key, deadline, secret)
          k when k in ["RET", "C-j"] -> acc
          k when k in ["C-c", "C-g", "ESC"] -> nil
          k when k in ["DEL", "C-h"] ->
            if acc != "", do: TTY.write(tty, "\b \b")
            read_loop(tty, String.slice(acc, 0..-2//1), key, nil, secret)

          k ->
            case Lepton.Keys.text(k) do
              nil -> read_loop(tty, acc, key, deadline, secret)
              t ->
                TTY.write(tty, if(secret, do: "*", else: t))
                # Typing cancels the auto-skip timer.
                read_loop(tty, acc <> t, key, nil, secret)
            end
        end
    end
  end

  defp out(ctx, text), do: TTY.write(ctx.tty, text)
end
