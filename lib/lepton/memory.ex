defmodule Lepton.Memory do
  @moduledoc """
  Keeping the system responsive when memory runs out.

  Lepton has no swap. When the apps (Firefox's tabs) fill the memory,
  Linux doesn't kill anything until nearly every page is gone: first it
  throws away the code of the programs that are running and reads it back
  from the disk, again and again, and the whole system freezes, for
  minutes or for good.

  This GenServer (started at boot) reads `/proc/meminfo` twice a second.
  When the memory available falls below `threshold/1` (5% of it, and at
  least 160 MiB), it stops the largest app process: one of Firefox's tabs
  if it can (Firefox then shows that tab as crashed, and reloading it
  brings it back), else the largest app program, and says so in the
  kernel's log (`dmesg`). Then it waits five seconds for the memory to
  come back before looking again. Lepton's own processes are never
  stopped.

  Firefox unloads background tabs by itself before this happens (see
  `Lepton.Apps.firefox_policies/1`): this is for when that isn't enough.
  """

  use GenServer
  require Logger

  @tick 500
  @cooldown 5_000

  @doc "`%{total, available}` in kB from `/proc/meminfo` text (nil if they aren't there)."
  def parse(text) do
    fields = for [k, v] <- Regex.scan(~r/^(MemTotal|MemAvailable):\s+(\d+) kB/m, text, capture: :all_but_first), into: %{}, do: {k, String.to_integer(v)}

    case fields do
      %{"MemTotal" => total, "MemAvailable" => available} -> %{total: total, available: available}
      _ -> nil
    end
  end

  @doc "Below how many kB of available memory an app is stopped: 5% of `total_kb`, at least 160 MiB."
  def threshold(total_kb), do: max(div(total_kb, 20), 160 * 1024)

  @doc "Is memory short (`parse/1`'s result)?"
  def low?(%{total: total, available: available}), do: available < threshold(total)
  def low?(nil), do: false

  @doc """
  Which process to stop, from `[%{pid, rss, cmdline}]` (the apps'
  processes): the largest of Firefox's tab processes, else the largest.
  nil if there are none.
  """
  def victim([]), do: nil

  def victim(procs) do
    tabs = Enum.filter(procs, &(&1.cmdline =~ "-contentproc" and &1.cmdline =~ "-isForBrowser"))
    Enum.max_by(if(tabs == [], do: procs, else: tabs), & &1.rss)
  end

  @doc "The apps' processes, from `/proc`: `[%{pid, rss (kB), cmdline}]`."
  def app_processes(root \\ Lepton.Apps.root()) do
    prefix = root <> "/"

    for entry <- Path.wildcard("/proc/[0-9]*"),
        {:ok, exe} <- [File.read_link(Path.join(entry, "exe"))],
        String.starts_with?(exe, prefix),
        {:ok, status} <- [File.read(Path.join(entry, "status"))],
        [_, rss] <- [Regex.run(~r/^VmRSS:\s+(\d+)/m, status)],
        {:ok, cmdline} <- [File.read(Path.join(entry, "cmdline"))],
        do: %{pid: String.to_integer(Path.basename(entry)), rss: String.to_integer(rss), cmdline: String.replace(cmdline, <<0>>, " ")}
  end

  # -- the guard ---------------------------------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if Lepton.Sys.native?(), do: send(self(), :tick)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, st) do
    mem = with {:ok, text} <- File.read("/proc/meminfo"), do: parse(text), else: (_ -> nil)

    delay =
      with true <- low?(mem), %{} = p <- victim(app_processes()) do
        msg = "memory: #{div(mem.available, 1024)} MiB available of #{div(mem.total, 1024)} MiB; stopping process #{p.pid} (#{div(p.rss, 1024)} MiB): #{String.slice(p.cmdline, 0, 80)}"
        Logger.warning(msg)
        # In the kernel's log too, for dmesg.
        File.write("/dev/kmsg", "lepton: " <> msg <> "\n")
        Lepton.Sys.shim("kill", ["-9", to_string(p.pid)])
        @cooldown
      else
        _ -> @tick
      end

    Process.send_after(self(), :tick, delay)
    {:noreply, st}
  end

  def handle_info(_msg, st), do: {:noreply, st}
end
