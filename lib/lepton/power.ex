defmodule Lepton.Power do
  @moduledoc """
  Graceful shutdown on the virtual power button.

  When UTM's stop button requests a power-down (or QEMU's
  `system_powerdown`), the firmware raises an ACPI power-button event
  (on QEMU's `virt` machine through the PL061 GPIO controller). With the
  `gpio-pl061` and `button` drivers loaded, the kernel reports it as
  `KEY_POWER` on an input device named "Power Button". This process
  reads that device and runs `shutdown/1`: warn the consoles, flush and
  remount the data partition read-only, then power off via sysrq.
  """

  require Logger

  @ev_key 1
  @key_power 116
  # struct input_event on 64-bit: timeval (16) + type (2) + code (2) + value (4)
  @event_size 24

  def start do
    spawn(fn ->
      for m <- ~w(gpio-pl061 button evdev), do: Lepton.Kmod.modprobe(m)

      case find_button(30) do
        nil -> Logger.warning("power: no power button input device; use `poweroff` to shut down")
        dev -> Logger.info("power: watching #{dev}"); watch(dev)
      end
    end)
  end

  defp find_button(0), do: nil

  defp find_button(tries) do
    found =
      with {:ok, names} <- File.ls("/sys/class/input") do
        names
        |> Enum.filter(&String.starts_with?(&1, "event"))
        |> Enum.find(fn ev ->
          case File.read("/sys/class/input/#{ev}/device/name") do
            {:ok, name} -> String.trim(name) =~ ~r/power button/i
            _ -> false
          end
        end)
      else
        _ -> nil
      end

    if found, do: "/dev/input/" <> found, else: (Process.sleep(100); find_button(tries - 1))
  end

  defp watch(dev) do
    {:ok, fd} = :file.open(dev, [:read, :raw, :binary])
    loop(fd)
  end

  defp loop(fd) do
    case :file.read(fd, @event_size) do
      {:ok, <<_time::binary-size(16), @ev_key::little-16, @key_power::little-16, 1::little-signed-32>>} ->
        shutdown("power button")

      {:ok, _other} ->
        loop(fd)

      error ->
        Logger.warning("power: reading power button failed: #{inspect(error)}")
    end
  end

  @doc "Announce, flush storage and power off."
  def shutdown(reason) do
    broadcast("\r\n\e[1;33mThe system is going down for power-off (#{reason}).\e[0m\r\n")
    Logger.info("power: shutting down (#{reason})")
    Process.sleep(500)
    Lepton.Sys.poweroff()
  end

  defp broadcast(msg) do
    Lepton.Init.say(String.trim(msg))

    Lepton.Proc.list()
    |> Enum.map(& &1.tty)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(fn tty ->
      try do
        Lepton.TTY.write(tty, msg)
      catch
        :exit, _ -> :ok
      end
    end)
  end
end
