defmodule Lepton.USB do
  @moduledoc """
  USB devices, hubs and hotplug.

  The kernel's USB core does the protocol work: host controllers (`xhci`,
  `ehci`, `ohci`), hubs (part of the USB core: a hub's ports are
  enumerated like the root hub's, to any depth) and the device drivers.
  Lepton has no udev, so this module does the two things udev would:

    * **Hotplug** (this GenServer, started at boot): it looks at
      `/sys/bus/usb/devices` every second and, when devices come or go,
      loads the drivers for new ones by hardware ID
      (`Lepton.Kmod.load_for_hardware/0`): keyboards and mice, disks,
      Wi-Fi and Ethernet adapters (a dock's network port, which it then
      configures with DHCP), and USB display adapters (`udl` for
      DisplayLink, `gud`). Photon picks up new input
      devices and displays itself (`Lepton.Photon.Input`,
      `Lepton.Photon.Screen`).
    * **The device tree** (`tree/1`, the `usb` command): every device by
      its port path (`1-2.3` is port 3 of the hub on port 2 of bus 1),
      with what it is, its driver, and what it became (`event2`, `fb1`,
      `eth1`, `sda`).
  """

  use GenServer
  require Logger

  @sysfs "/sys/bus/usb/devices"
  @tick 1_000

  defstruct [:name, :bus, :parent, :vendor, :product_id, :manufacturer, :product, :class, :speed, :ports, interfaces: [], drivers: [], nodes: []]

  # USB class codes (device or interface).
  @classes %{
    "01" => "audio",
    "02" => "communications",
    "03" => "HID",
    "06" => "imaging",
    "07" => "printer",
    "08" => "storage",
    "09" => "hub",
    "0a" => "CDC data",
    "0b" => "smart card",
    "0e" => "video",
    "10" => "audio/video",
    "11" => "billboard",
    "dc" => "diagnostic",
    "e0" => "wireless",
    "ef" => "miscellaneous",
    "fe" => "application",
    "ff" => "vendor-specific"
  }

  # -- the device tree -------------------------------------------------------------------------------

  @doc "Every USB device (root hubs included), from `root` (sysfs)."
  def devices(root \\ @sysfs) do
    case File.ls(root) do
      {:ok, names} ->
        names
        |> Enum.filter(&device_name?/1)
        |> Enum.map(&device(root, &1, names))
        |> Enum.sort_by(&sort_key/1)

      _ ->
        []
    end
  end

  defp device_name?(name), do: name =~ ~r/^(usb\d+|\d+-\d+(\.\d+)*)$/

  defp device(root, name, all) do
    dir = Path.join(root, name)
    read = &attr(dir, &1)

    interfaces =
      for i <- all, String.starts_with?(i, name <> ":") do
        idir = Path.join(root, i)
        %{name: i, class: attr(idir, "bInterfaceClass"), driver: driver(idir), nodes: nodes(idir)}
      end

    %__MODULE__{
      name: name,
      bus: read.("busnum") && String.to_integer(read.("busnum")),
      parent: parent(name),
      vendor: read.("idVendor"),
      product_id: read.("idProduct"),
      manufacturer: read.("manufacturer"),
      product: read.("product"),
      class: read.("bDeviceClass"),
      speed: read.("speed"),
      ports: case read.("maxchild") do
        nil -> 0
        n -> String.to_integer(n)
      end,
      interfaces: interfaces,
      drivers: interfaces |> Enum.map(& &1.driver) |> Enum.reject(&(&1 in [nil, "hub"])) |> Enum.uniq(),
      nodes: interfaces |> Enum.flat_map(& &1.nodes) |> Enum.uniq()
    }
  end

  @doc "The device a port path hangs off: `1-2.3` -> `1-2`, `1-2` -> `usb1`, `usb1` -> nil."
  def parent("usb" <> _), do: nil

  def parent(name) do
    [bus, path] = String.split(name, "-", parts: 2)

    case String.split(path, ".") do
      [_port] -> "usb" <> bus
      ports -> bus <> "-" <> Enum.join(Enum.drop(ports, -1), ".")
    end
  end

  # Root hubs first, then by port numbers (so 1-10 comes after 1-9).
  defp sort_key(%{name: "usb" <> n}), do: {String.to_integer(n), []}

  defp sort_key(%{name: name, bus: bus}) do
    [_, path] = String.split(name, "-", parts: 2)
    {bus, Enum.map(String.split(path, "."), &String.to_integer/1)}
  end

  defp attr(dir, name) do
    case File.read(Path.join(dir, name)) do
      {:ok, v} -> case String.trim(v) do
          "" -> nil
          v -> v
        end

      _ ->
        nil
    end
  end

  defp driver(dir) do
    case File.read_link(Path.join(dir, "driver")) do
      {:ok, link} -> Path.basename(link)
      _ -> nil
    end
  end

  # What an interface became: input event devices, framebuffers, network
  # interfaces and disks, found below it in sysfs (real directories only:
  # sysfs links back up the tree).
  @node ~r/^(event\d+|fb\d+|sd[a-z]+)$/

  defp nodes(dir, depth \\ 0) do
    case File.ls(dir) do
      {:ok, names} when depth < 8 ->
        Enum.flat_map(names, fn n ->
          path = Path.join(dir, n)

          cond do
            not dir?(path) -> []
            Path.basename(dir) == "net" -> [n]
            n =~ @node -> [n]
            true -> nodes(path, depth + 1)
          end
        end)

      _ ->
        []
    end
  end

  defp dir?(path), do: match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))

  @doc "What a device is, in a word or two: its class, or its interfaces' (a hub, a keyboard's HID)."
  def kind(%__MODULE__{name: "usb" <> _}), do: "root hub"

  def kind(%__MODULE__{} = d) do
    cond do
      Enum.any?(d.drivers, &(&1 in ["udl", "gud"])) or Enum.any?(d.nodes, &String.starts_with?(&1, "fb")) -> "display"
      d.class == "09" -> "hub"
      d.class not in [nil, "00", "ef"] -> @classes[d.class] || "class #{d.class}"
      true -> d.interfaces |> Enum.map(&@classes[&1.class]) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.join(", ") |> blank("device")
    end
  end

  defp blank("", default), do: default
  defp blank(s, _), do: s

  @doc "A device's name: its product string, else `vendor:product`."
  def label(%__MODULE__{name: "usb" <> _} = d), do: "#{d.product || "root hub"}"
  def label(%__MODULE__{} = d), do: d.product || "#{d.vendor}:#{d.product_id}"

  @doc "The speed as people say it: `480 Mbit/s`, `5 Gbit/s`."
  def speed(nil), do: nil

  def speed(mbps) do
    case Float.parse(mbps) do
      {v, _} when v >= 1000 -> "#{format(v / 1000)} Gbit/s"
      {v, _} -> "#{format(v)} Mbit/s"
      :error -> mbps
    end
  end

  defp format(v) when v == trunc(v), do: Integer.to_string(trunc(v))
  defp format(v), do: :erlang.float_to_binary(v, decimals: 1)

  @doc """
  The devices as an indented tree under each root hub: `[{depth, device}]`.
  A device whose parent isn't there (unplugged mid-read) hangs off the
  top level.
  """
  def tree(devices) do
    names = MapSet.new(devices, & &1.name)
    children = Enum.group_by(devices, &if(MapSet.member?(names, &1.parent || ""), do: &1.parent, else: nil))
    walk(children, nil, 0)
  end

  defp walk(children, parent, depth) do
    Enum.flat_map(Map.get(children, parent, []), fn d -> [{depth, d} | walk(children, d.name, depth + 1)] end)
  end

  @doc "The tree as lines of text (the `usb` command)."
  def describe(devices) do
    for {depth, d} <- tree(devices) do
      indent = String.duplicate("  ", depth)
      id = if d.vendor && !String.starts_with?(d.name, "usb"), do: " #{d.vendor}:#{d.product_id}", else: ""
      ports = if d.ports > 0, do: ", #{d.ports} ports", else: ""
      extra = Enum.join(Enum.reject([speed(d.speed) | [Enum.join(d.drivers, ", ") |> blank(nil)]], &is_nil/1), "; ")
      nodes = if d.nodes != [], do: " -> " <> Enum.join(d.nodes, " "), else: ""
      "#{indent}#{d.name}#{id}  #{label(d)} (#{kind(d)}#{ports}) [#{extra}]#{nodes}"
    end
  end

  # -- hotplug ------------------------------------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # Only on a booted Lepton (not `mix test` on a Mac).
    if Lepton.Sys.native?(), do: send(self(), :tick)
    {:ok, %{seen: nil, ethernet: []}}
  end

  @impl true
  def handle_info(:tick, st) do
    Process.send_after(self(), :tick, @tick)
    names = present()
    st = ethernet(st)

    cond do
      st.seen == nil ->
        {:noreply, %{st | seen: names}}

      names == st.seen ->
        {:noreply, st}

      true ->
        added = MapSet.difference(names, st.seen)
        removed = MapSet.difference(st.seen, names)
        for d <- devices(), MapSet.member?(added, d.name), do: Logger.info("usb: #{d.name} connected: #{label(d)} (#{kind(d)})")
        for n <- removed, do: Logger.info("usb: #{n} disconnected")
        # Drivers for what was plugged in (hubs need none: the USB core enumerates their ports).
        loaded = Lepton.Kmod.load_for_hardware()
        if loaded != [], do: Logger.info("usb: loaded #{Enum.join(loaded, ", ")}")
        {:noreply, %{st | seen: names}}
    end
  end

  def handle_info(_msg, st), do: {:noreply, st}

  # An Ethernet port that appears later (a dock's, a USB adapter's) is
  # configured with DHCP, as the ones there at boot are (`Lepton.Net`).
  defp ethernet(%{seen: nil} = st), do: %{st | ethernet: Lepton.Net.ethernet_interfaces()}

  defp ethernet(st) do
    now = Lepton.Net.ethernet_interfaces()

    for iface <- now -- st.ethernet do
      spawn(fn ->
        case Lepton.Net.configure(iface) do
          {:ok, lease} -> Logger.info("usb: #{iface} configured: #{Lepton.Net.format_ip(lease.ip)}/#{lease.prefix}")
          {:error, reason} -> Logger.warning("usb: #{iface}: #{inspect(reason)}")
        end
      end)
    end

    %{st | ethernet: now}
  end

  defp present do
    case File.ls(@sysfs) do
      {:ok, names} -> names |> Enum.filter(&device_name?/1) |> MapSet.new()
      _ -> MapSet.new()
    end
  end
end
