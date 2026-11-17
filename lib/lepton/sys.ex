defmodule Lepton.Sys do
  @moduledoc """
  The syscall boundary.

  The BEAM can open/read/write files, sockets and device nodes on its own,
  which covers almost everything an OS userland does. A handful of
  operations need system calls ERTS does not expose (`mount(2)`,
  `finit_module(2)` and the termios/winsize `ioctl(2)`s). For exactly those
  Lepton invokes the static busybox binary shipped in the image as an opaque
  syscall shim - it is never exposed as a userland command. Everything else
  here is plain Elixir talking to procfs/sysfs.
  """

  @busybox "/bin/busybox"

  def native?, do: File.exists?(@busybox) and os() == :linux

  def os do
    case :os.type() do
      {:unix, :linux} -> :linux
      {:unix, :darwin} -> :darwin
      {_, other} -> other
    end
  end

  def pid1?, do: System.pid() == "1"

  @doc "Runs a busybox applet: returns {output, exit_status}."
  def shim(applet, args) do
    if File.exists?(@busybox) do
      port =
        Port.open({:spawn_executable, @busybox}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [applet | args]
        ])

      collect(port, [])
    else
      {"#{applet}: not available on this host\n", 127}
    end
  end

  defp collect(port, acc) do
    receive do
      {^port, {:data, data}} -> collect(port, [acc, data])
      {^port, {:exit_status, status}} -> {IO.iodata_to_binary(acc), status}
    after
      30_000 ->
        Port.close(port)
        {IO.iodata_to_binary(acc), 124}
    end
  end

  # -- mount(2) ----------------------------------------------------------------

  def mount(type, source, target, opts \\ nil) do
    File.mkdir_p(target)
    args = ["-t", type] ++ if(opts, do: ["-o", opts], else: []) ++ [source, target]

    case shim("mount", args) do
      {_, 0} -> :ok
      {out, _} -> {:error, String.trim(out)}
    end
  end

  def umount(target) do
    case shim("umount", [target]) do
      {_, 0} -> :ok
      {out, _} -> {:error, String.trim(out)}
    end
  end

  def mounts do
    case File.read("/proc/mounts") do
      {:ok, text} ->
        for line <- String.split(text, "\n", trim: true),
            [dev, dir, type, opts | _] <- [String.split(line)] do
          %{device: dev, dir: dir, type: type, options: opts}
        end

      _ ->
        []
    end
  end

  # -- finit_module(2) ---------------------------------------------------------

  def insmod(path, params \\ []) do
    case shim("insmod", [path | params]) do
      {_, 0} -> :ok
      {out, _} -> {:error, String.trim(out)}
    end
  end

  # -- termios / winsize ioctls -----------------------------------------------

  # Port programs run as session leaders (ERTS calls setsid). A session
  # leader that opens a tty without O_NOCTTY makes it its controlling
  # terminal, and its exit then hangs the line up, turning every other open
  # descriptor into EIO. So stty runs as a *child* of the shim shell, which
  # never opens the device itself (the trailing `:` stops it exec'ing stty).
  defp stty(device, args) do
    # (Applets are invoked through the busybox binary: there are no applet
    # symlinks on PATH, by design.)
    shim("sh", ["-c", ~s(#{@busybox} stty -F "$0" "$@"; s=$?; :; exit $s), device | args])
  end

  def tty_raw(device) do
    case stty(device, ["raw", "-echo", "-ixon", "-icrnl", "-opost"]) do
      {_, 0} -> :ok
      {out, _} -> {:error, String.trim(out)}
    end
  end

  def tty_size(device) do
    with {out, 0} <- stty(device, ["size"]),
         [rows, cols] <- out |> String.trim() |> String.split(),
         {rows, ""} when rows > 0 <- Integer.parse(rows),
         {cols, ""} when cols > 0 <- Integer.parse(cols) do
      {:ok, {rows, cols}}
    else
      _ -> :error
    end
  end

  def set_tty_size(device, {rows, cols}) do
    stty(device, ["rows", to_string(rows), "cols", to_string(cols)])
    :ok
  end

  # -- procfs / sysfs ----------------------------------------------------------

  def hostname do
    case File.read("/proc/sys/kernel/hostname") do
      {:ok, name} -> String.trim(name)
      _ -> :inet.gethostname() |> elem(1) |> to_string()
    end
  end

  def set_hostname(name) do
    if native?(), do: File.write("/proc/sys/kernel/hostname", name), else: {:error, :eperm}
  end

  def cmdline do
    case File.read("/proc/cmdline") do
      {:ok, text} -> String.trim(text)
      _ -> ""
    end
  end

  def cmdline_flag?(flag), do: flag in String.split(cmdline())

  def kernel_release do
    case File.read("/proc/sys/kernel/osrelease") do
      {:ok, v} -> String.trim(v)
      _ -> :os.version() |> Tuple.to_list() |> Enum.join(".")
    end
  end

  def uptime_seconds do
    case File.read("/proc/uptime") do
      {:ok, text} -> text |> String.split() |> hd() |> String.to_float()
      _ -> :erlang.statistics(:wall_clock) |> elem(0) |> Kernel./(1000)
    end
  end

  def meminfo do
    case File.read("/proc/meminfo") do
      {:ok, text} ->
        for line <- String.split(text, "\n", trim: true),
            [k, v | _] <- [String.split(line, [":", " "], trim: true)],
            into: %{} do
          {k, String.to_integer(v) * 1024}
        end

      _ ->
        total = :erlang.memory(:total)
        %{"MemTotal" => total, "MemFree" => 0, "MemAvailable" => 0}
    end
  end

  def loadavg do
    case File.read("/proc/loadavg") do
      {:ok, text} -> text |> String.split() |> Enum.take(3) |> Enum.join(" ")
      _ -> "0.00 0.00 0.00"
    end
  end

  # -- power -------------------------------------------------------------------

  def sync, do: sysrq("s")

  def poweroff do
    Lepton.Persist.shutdown()
    sync()
    sysrq("o")
  end

  def reboot do
    Lepton.Persist.shutdown()
    sync()
    sysrq("b")
  end

  defp sysrq(key) do
    if native?() do
      File.write("/proc/sys/kernel/sysrq", "1")
      File.write("/proc/sysrq-trigger", key)
    else
      {:error, :not_native}
    end
  end
end
