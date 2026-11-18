defmodule Lepton.Kmod do
  @moduledoc """
  Kernel module management (`modprobe`, `lsmod`, `rmmod`).

  Dependency resolution reads `modules.dep` the same way kmod does; the final
  `finit_module(2)` goes through `Lepton.Sys.insmod/2`.

  There is no udev: `load_for_hardware/0` matches the `modalias` of every
  USB, SDIO, PCI and platform device against `modules.alias` and loads
  the drivers, which is how Wi-Fi adapters (including ones plugged in
  later), SD card slots and card readers get theirs.
  """

  def modules_dir do
    Path.join("/lib/modules", Lepton.Sys.kernel_release())
  end

  def deps do
    case File.read(Path.join(modules_dir(), "modules.dep")) do
      {:ok, text} ->
        for line <- String.split(text, "\n", trim: true), into: %{} do
          [mod, rest] = String.split(line, ":", parts: 2)
          {mod, String.split(rest)}
        end

      _ ->
        %{}
    end
  end

  def normalize(name), do: name |> Path.basename() |> String.replace(~r/\.ko.*$/, "") |> String.replace("-", "_")

  def loaded do
    case File.read("/proc/modules") do
      {:ok, text} ->
        for line <- String.split(text, "\n", trim: true) do
          [name, size, refs, users | _] = String.split(line) ++ ["", "", ""]
          %{name: name, size: String.to_integer(size), refs: refs, used_by: String.trim(users, ",") |> String.replace("-", "")}
        end

      _ ->
        []
    end
  end

  def loaded?(name), do: Enum.any?(loaded(), &(&1.name == normalize(name)))

  def builtin?(name) do
    case File.read(Path.join(modules_dir(), "modules.builtin")) do
      {:ok, text} -> text |> String.split("\n") |> Enum.any?(&(normalize(&1) == normalize(name)))
      _ -> false
    end
  end

  @doc "Load a module and its dependencies. Returns :ok or {:error, reason}."
  def modprobe(name, params \\ []) do
    deps = deps()
    by_name = Map.new(Map.keys(deps), &{normalize(&1), &1})
    target = normalize(name)

    cond do
      loaded?(target) or builtin?(target) ->
        :ok

      path = by_name[target] ->
        # modules.dep lists dependencies so that the last one must load first.
        order = Enum.reverse(deps[path]) ++ [path]

        Enum.reduce_while(order, :ok, fn mod, :ok ->
          if loaded?(mod) do
            {:cont, :ok}
          else
            args = if mod == path, do: params, else: []

            case Lepton.Sys.insmod(Path.join(modules_dir(), mod), args) do
              :ok -> {:cont, :ok}
              {:error, msg} -> if msg =~ "exists", do: {:cont, :ok}, else: {:halt, {:error, "#{mod}: #{msg}"}}
            end
          end
        end)

      true ->
        {:error, "module #{name} not found in #{modules_dir()}"}
    end
  end

  def rmmod(name) do
    case Lepton.Sys.shim("rmmod", [normalize(name)]) do
      {_, 0} -> :ok
      {out, _} -> {:error, String.trim(out)}
    end
  end

  @hotplug_buses ~w(usb sdio pci platform)
  # Platform devices' aliases are by name or by device tree compatible string.
  @alias_prefixes ~w(usb sdio pci platform of)

  @doc "Load the drivers for USB, SDIO, PCI and platform devices present now. Returns the modules loaded."
  def load_for_hardware do
    table = alias_table()

    device_aliases()
    |> Enum.flat_map(&modules_for(&1, table))
    |> Enum.uniq()
    |> Enum.reject(&loaded?/1)
    |> Enum.filter(&(modprobe(&1) == :ok))
  end

  def device_aliases do
    for bus <- @hotplug_buses,
        file <- Path.wildcard("/sys/bus/#{bus}/devices/*/modalias"),
        {:ok, text} <- [File.read(file)],
        alias = String.trim(text),
        alias != "",
        uniq: true,
        do: alias
  end

  @doc "Modules whose aliases match a device's `modalias`."
  def modules_for(modalias, table) do
    for {re, mod} <- table, Regex.match?(re, modalias), uniq: true, do: mod
  end

  @doc "`modules.alias` as `[{regex, module}]` (cached per kernel)."
  def alias_table do
    key = {__MODULE__, :aliases, modules_dir()}

    case :persistent_term.get(key, nil) do
      nil ->
        table =
          case File.read(Path.join(modules_dir(), "modules.alias")) do
            {:ok, text} -> parse_aliases(text)
            _ -> []
          end

        :persistent_term.put(key, table)
        table

      table ->
        table
    end
  end

  def parse_aliases(text) do
    for line <- String.split(text, "\n"),
        ["alias", pattern, mod] <- [String.split(line)],
        String.starts_with?(pattern, Enum.map(@alias_prefixes, &(&1 <> ":"))),
        do: {glob_regex(pattern), normalize(mod)}
  end

  # fnmatch(3) patterns as used in modules.alias: `*`, `?` and `[...]`.
  defp glob_regex(pattern) do
    body =
      Regex.split(~r/(\*|\?|\[[^\]]*\])/, pattern, include_captures: true, trim: true)
      |> Enum.map_join(fn
        "*" -> ".*"
        "?" -> "."
        "[" <> _ = set -> set
        text -> Regex.escape(text)
      end)

    Regex.compile!("\\A" <> body <> "\\z")
  end
end
