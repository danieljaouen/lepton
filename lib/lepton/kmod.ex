defmodule Lepton.Kmod do
  @moduledoc """
  Kernel module management (`modprobe`, `lsmod`, `rmmod`).

  Dependency resolution reads `modules.dep` the same way kmod does; the final
  `finit_module(2)` goes through `Lepton.Sys.insmod/2`.
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
end
