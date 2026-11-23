defmodule Lepton.Keyboard.Console do
  @moduledoc """
  The Linux console's own keymap, for the keys Lepton changes on the text
  console (`/dev/tty1`, a real keyboard on bare metal or in a VM): Caps
  Lock as another Ctrl (`keyboard caps ctrl`).

  The kernel turns key presses into the bytes the console reads, so the
  change is made there, as `loadkeys` would: `KDSKBENT` sets key 58 (Caps
  Lock) to Control in every keymap table the kernel has (plain, Shift,
  AltGr, Ctrl, ...). Photon reads the keyboard itself and changes the key
  on its own (`Lepton.Photon`).
  """

  import Bitwise

  # linux/kd.h
  @kdgkbent 0x4B46
  @kdskbent 0x4B47
  @max_tables 256

  @caps_key 58
  # K(KT_SPEC, 7) and K(KT_SHIFT, KG_CTRL); K(KT_SPEC, 127)
  @k_caps 0x0207
  @k_ctrl 0x0702
  @k_nosuchmap 0x027F

  @consoles ["/dev/tty1", "/dev/tty0", "/dev/console"]

  @doc "What Caps Lock types for a setting (`:ctrl` or `:lock`), as a kernel keysym."
  def keysym(:ctrl), do: @k_ctrl
  def keysym(_), do: @k_caps

  @doc """
  Make Caps Lock `:ctrl` or `:lock` (`:ok`, or `{:error, reason}`); only
  on a Lepton machine with a console (elsewhere: `{:error, :no_console}`).
  """
  def set_caps(caps, devices \\ @consoles) do
    with {:ok, f} <- open(devices) do
      try do
        tables = for t <- 0..(@max_tables - 1), get(f, t, 0) not in [nil, @k_nosuchmap], do: t
        results = for t <- tables, do: set(f, t, @caps_key, keysym(caps))
        Enum.find(results, :ok, &(&1 != :ok))
      after
        :file.close(f)
      end
    end
  end

  @doc "What Caps Lock types now in the plain table: `:ctrl`, `:lock`, `{:other, keysym}`, or nil."
  def caps(devices \\ @consoles) do
    with {:ok, f} <- open(devices) do
      try do
        case get(f, 0, @caps_key) do
          @k_ctrl -> :ctrl
          @k_caps -> :lock
          nil -> nil
          v -> {:other, v}
        end
      after
        :file.close(f)
      end
    else
      _ -> nil
    end
  end

  defp open(devices) do
    Enum.find_value(devices, {:error, :no_console}, fn d ->
      if Lepton.Sys.native?() and File.exists?(d) do
        case :file.open(String.to_charlist(d), [:raw, :binary, :read]) do
          {:ok, f} -> {:ok, f}
          _ -> nil
        end
      end
    end)
  end

  # struct kbentry { u8 kb_table; u8 kb_index; u16 kb_value; }
  defp get(f, table, index) do
    case Lepton.FD.ioctl(f, @kdgkbent, <<table, index, 0::native-16>>) do
      {:ok, _, <<_, _, v::native-16>>} -> band(v, 0xFFFF)
      _ -> nil
    end
  end

  defp set(f, table, index, value) do
    case Lepton.FD.ioctl(f, @kdskbent, <<table, index, value::native-16>>) do
      {:ok, _, _} -> :ok
      {:error, e} -> {:error, e}
    end
  end
end
