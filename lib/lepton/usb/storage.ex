defmodule Lepton.USB.Storage do
  @moduledoc """
  USB drives in a virtual machine: usb-storage rather than UAS.

  Fast USB 3 drives (a Samsung T7, most SSDs) speak UAS, USB Attached
  SCSI, which needs USB 3 "streams". Passed through to a QEMU virtual
  machine (UTM's) they don't survive it: the first command fails, the
  device resets, and the host takes it back ("rejected by host"). The
  same drives also speak the older Bulk-Only protocol, which works.

  So in QEMU (`Lepton.Sys.qemu?/0`) the `uas` driver isn't loaded
  (`Lepton.Init`, `Lepton.Kmod`), and usb-storage, which leaves a drive
  that could do UAS to it, finds such drives unclaimed. Here each one gets
  usb-storage's "ignore UAS" quirk (`VID:PID:u`) and is probed again; it
  then works as a USB stick does. On real hardware nothing changes.
  """

  require Logger

  @quirks "/sys/module/usb_storage/parameters/quirks"
  @probe "/sys/bus/usb/drivers_probe"
  # usb-storage's quirks parameter is a string of at most 128 characters.
  @quirks_max 127

  @doc """
  Mass-storage interfaces (class 08) that no driver has: `[{interface,
  vendor, product}]`, read from `root` (`/sys/bus/usb/devices`).
  """
  def unclaimed(root \\ "/sys/bus/usb/devices") do
    case File.ls(root) do
      {:ok, names} ->
        for name <- Enum.sort(names),
            String.contains?(name, ":"),
            dir = Path.join(root, name),
            read(dir, "bInterfaceClass") == "08",
            not File.exists?(Path.join(dir, "driver")),
            device = Path.join(root, name |> String.split(":") |> hd()),
            vid = read(device, "idVendor"),
            pid = read(device, "idProduct"),
            vid != nil and pid != nil,
            do: {name, vid, pid}

      _ ->
        []
    end
  end

  @doc "usb-storage's quirks with `VID:PID:u` for each of `ids` (kept short enough; the newest last)."
  def with_quirks(existing, ids) do
    entries = existing |> String.trim() |> String.split(",", trim: true)
    entries = Enum.reduce(ids, entries, fn {vid, pid}, acc -> Enum.reject(acc, &String.starts_with?(&1, "#{vid}:#{pid}:")) ++ ["#{vid}:#{pid}:u"] end)
    trim_to(entries, @quirks_max)
  end

  defp trim_to(entries, max) do
    s = Enum.join(entries, ",")
    if String.length(s) > max and length(entries) > 1, do: trim_to(tl(entries), max), else: s
  end

  @doc """
  In QEMU, give every unclaimed mass-storage interface to usb-storage
  (`:root`, `:quirks`, `:probe` and `:vm` are for tests). Returns the
  interfaces handed over.
  """
  def fallback(opts \\ []) do
    if Keyword.get_lazy(opts, :vm, &Lepton.Sys.qemu?/0) do
      root = opts[:root] || "/sys/bus/usb/devices"
      quirks = opts[:quirks] || @quirks
      probe = opts[:probe] || @probe

      case unclaimed(root) do
        [] ->
          []

        found ->
          ids = found |> Enum.map(fn {_, vid, pid} -> {vid, pid} end) |> Enum.uniq()

          existing = case File.read(quirks) do
            {:ok, s} -> s
            _ -> ""
          end

          File.write(quirks, with_quirks(existing, ids))

          for {iface, vid, pid} <- found do
            File.write(probe, iface)
            Logger.info("usb: #{iface} (#{vid}:#{pid}) uses usb-storage, not UAS, in this virtual machine")
            iface
          end
      end
    else
      []
    end
  end

  defp read(dir, attr) do
    case File.read(Path.join(dir, attr)) do
      {:ok, v} -> String.trim(v)
      _ -> nil
    end
  end
end
