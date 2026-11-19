defmodule Lepton.KernelLog do
  @moduledoc """
  The kernel's messages in Lepton's log (`/var/log/messages`), so that on
  an installed system, where the log is kept on the data partition, what
  the kernel said before a crash (a driver's error, the OOM killer) is
  still there after the restart.

  This GenServer (started at boot) reads the kernel's log (`dmesg`, as the
  `dmesg` command does) every five seconds and logs the lines it hasn't
  logged yet, as `kernel: ...`. Lines Lepton wrote itself (`lepton: ...`)
  are in the log already.
  """

  use GenServer
  require Logger

  @tick 5_000

  @doc """
  The lines of `dmesg` output after the timestamp `since` (seconds since
  boot): `{[text], last_timestamp}`. Lepton's own lines are left out.
  """
  def new_lines(text, since) do
    {lines, last} =
      for line <- String.split(text, "\n"),
          [_, t, msg] <- [Regex.run(~r/^\[\s*(\d+\.\d+)\]\s?(.*)$/, line)],
          String.to_float(t) > since,
          reduce: {[], since} do
        {acc, _} -> {if(String.starts_with?(msg, "lepton: "), do: acc, else: [msg | acc]), String.to_float(t)}
      end

    {Enum.reverse(lines), last}
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if Lepton.Sys.native?() and File.exists?("/bin/busybox"), do: send(self(), :tick)
    {:ok, %{since: -1.0}}
  end

  @impl true
  def handle_info(:tick, st) do
    Process.send_after(self(), :tick, @tick)

    case Lepton.Sys.shim("dmesg", []) do
      {out, 0} ->
        {lines, since} = new_lines(out, st.since)
        for l <- lines, do: Logger.info("kernel: " <> l)
        {:noreply, %{st | since: since}}

      _ ->
        {:noreply, st}
    end
  end

  def handle_info(_msg, st), do: {:noreply, st}
end
