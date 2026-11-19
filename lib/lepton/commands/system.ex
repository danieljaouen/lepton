defmodule Lepton.Commands.System do
  @moduledoc "Process, kernel and system utilities."

  use Lepton.Command
  alias Lepton.{Proc, Sys}

  defcmd "ps", "report a snapshot of the current processes", usage: "ps [-e] [aux]" do
    {opts, rest} = getopt(args, "efA")
    all = opts["e"] || opts["A"] || "aux" in rest
    IO.puts(ctx, "  PID  PPID TTY          STAT   TIME CMD")
    now = System.monotonic_time(:millisecond)

    for p <- Proc.list() do
      tty = if p.tty, do: tty_name(p.tty), else: "?"
      stat = if p.state == :stopped, do: "T", else: "S"
      secs = div(now - p.started, 1000)
      time = "#{div(secs, 60)}:#{String.pad_leading(to_string(rem(secs, 60)), 2, "0")}"
      IO.puts(ctx, Enum.join([pad(p.pid, 5), pad(p.ppid, 5), String.pad_trailing(tty, 12), String.pad_trailing(stat, 4), pad(time, 6), p.cmd], " "))
    end

    if all, do: kernel_procs(ctx)
    0
  end

  defp tty_name(tty) do
    Lepton.TTY.name(tty) |> String.replace_prefix("/dev/", "")
  catch
    :exit, _ -> "?"
  end

  # With -e, also show the Linux processes underneath (beam, kernel threads).
  defp kernel_procs(ctx) do
    case File.ls("/proc") do
      {:ok, entries} ->
        pids = entries |> Enum.filter(&Regex.match?(~r/^\d+$/, &1)) |> Enum.sort_by(&String.to_integer/1)

        for e <- pids do
          name = case File.read("/proc/#{e}/comm") do
            {:ok, n} -> String.trim(n)
            _ -> "?"
          end

          IO.puts(ctx, "#{pad("k" <> e, 5)}     -  ?            S         - [#{name}]")
        end

      _ ->
        :ok
    end
  end

  defp pad(v, n), do: String.pad_leading(to_string(v), n)

  defcmd "kill", "send a signal to a process", usage: "kill [-9|-STOP|-CONT|-TERM] PID..." do
    {sig, pids} =
      case args do
        ["-l" | _] ->
          IO.puts(ctx, "TERM KILL STOP CONT INT")
          {:list, []}

        ["-" <> s | rest] -> {signal(s), rest}
        rest -> {:term, rest}
      end

    Enum.reduce(pids, 0, fn p, status ->
      with {pid, ""} <- Integer.parse(String.trim_leading(p, "%")),
           :ok <- Proc.signal(pid, sig) do
        status
      else
        {:error, :eperm} -> IO.err(ctx, "kill: (#{p}) - Operation not permitted"); 1
        _ -> IO.err(ctx, "kill: (#{p}) - No such process"); 1
      end
    end)
  end

  defp signal(s) when s in ["9", "KILL", "SIGKILL"], do: :kill
  defp signal(s) when s in ["19", "STOP", "SIGSTOP", "20", "TSTP"], do: :stop
  defp signal(s) when s in ["18", "CONT", "SIGCONT"], do: :cont
  defp signal(_), do: :term

  defcmd "pgrep", "look up processes by name", usage: "pgrep PATTERN" do
    pattern = List.first(args) || ""
    matches = for p <- Proc.list(), String.contains?(p.cmd, pattern), do: p
    Enum.each(matches, &IO.puts(ctx, to_string(&1.pid)))
    if matches == [], do: 1, else: 0
  end

  defcmd "pkill", "signal processes by name", usage: "pkill PATTERN" do
    pattern = List.first(args) || ""
    killed = for p <- Proc.list(), p.pid != 1, String.contains?(p.cmd, pattern), p.beam != self(), do: Proc.signal(p.pid, :term)
    if killed == [], do: 1, else: 0
  end

  defcmd "top", "display Lepton processes (q to quit)", usage: "top" do
    Lepton.Top.run(ctx)
  end

  defcmd "free", "display amount of free and used memory", usage: "free [-h] [-m]" do
    {opts, _} = getopt(args, "hmk")
    m = Sys.meminfo()
    fmt = fn n -> cond do
      opts["h"] -> Lepton.Commands.Core.human(n)
      opts["m"] -> to_string(div(n, 1024 * 1024))
      true -> to_string(div(n, 1024))
    end end

    total = m["MemTotal"] || 0
    free = m["MemFree"] || 0
    avail = m["MemAvailable"] || free
    shared = m["Shmem"] || 0
    cache = (m["Cached"] || 0) + (m["Buffers"] || 0)
    used = total - avail
    IO.puts(ctx, "               total        used        free      shared  buff/cache   available")
    IO.puts(ctx, "Mem:    " <> Enum.map_join([total, used, free, shared, cache, avail], "", &String.pad_leading(fmt.(&1), 12)))
    beam = :erlang.memory()
    IO.puts(ctx, "BEAM:   " <> Enum.map_join([beam[:total], beam[:processes], beam[:binary], beam[:code], beam[:ets]], "", &String.pad_leading(fmt.(&1), 12)) <> "   (total processes binary code ets)")
    0
  end

  defcmd "uptime", "tell how long the system has been running", usage: "uptime" do
    secs = trunc(Sys.uptime_seconds())
    days = div(secs, 86_400)
    hm = "#{div(rem(secs, 86_400), 3600)}:#{String.pad_leading(to_string(div(rem(secs, 3600), 60)), 2, "0")}"
    up = if days > 0, do: "#{days} days, #{hm}", else: hm
    users = Proc.list() |> Enum.count(&(&1.cmd == "-lsh"))
    IO.puts(ctx, " #{clock()} up #{up},  #{users} user#{if users == 1, do: "", else: "s"},  load average: #{Sys.loadavg() |> String.replace(" ", ", ")}")
    0
  end

  defp clock do
    {_, {h, m, s}} = :calendar.local_time()
    Enum.map_join([h, m, s], ":", &String.pad_leading(to_string(&1), 2, "0"))
  end

  defcmd "uname", "print system information", usage: "uname [-asnrmo]" do
    {opts, _} = getopt(args, "asnrvmo")
    all = opts["a"]
    arch = :erlang.system_info(:system_architecture) |> to_string() |> String.split("-") |> hd()

    parts =
      [
        {"s", "Linux"},
        {"n", Sys.hostname()},
        {"r", Sys.kernel_release()},
        {"v", "Lepton #{Lepton.Init.version()} (Elixir #{System.version()}, OTP #{System.otp_release()})"},
        {"m", arch},
        {"o", "Lepton"}
      ]
      |> Enum.filter(fn {k, _} -> all || opts[k] end)
      |> Enum.map(&elem(&1, 1))

    IO.puts(ctx, Enum.join(if(parts == [], do: ["Linux"], else: parts), " "))
    0
  end

  defcmd "hostname", "show or set the system's host name", usage: "hostname [NAME]" do
    case args do
      [] -> IO.puts(ctx, Sys.hostname()); 0
      [_ | _] when ctx.user != "root" -> Lepton.Users.denied(ctx, "hostname")
      [name | _] ->
        case Sys.set_hostname(name) do
          :ok -> 0
          _ -> IO.err(ctx, "hostname: you must be root to change the host name"); 1
        end
    end
  end

  defcmd "whoami", "print effective user name", usage: "whoami" do
    IO.puts(ctx, ctx.user)
    0
  end

  defcmd "id", "print user and group information", usage: "id [USER]" do
    name = List.first(args) || ctx.user

    case Lepton.Users.get(name) do
      nil ->
        IO.err(ctx, "id: '#{name}': no such user")
        1

      u ->
        groups = [{u.name, u.gid} | Lepton.Users.groups_of(u.name)] |> Enum.uniq_by(&elem(&1, 1))
        groups = if u.name == "root", do: [{"root", 0}], else: groups
        IO.puts(ctx, "uid=#{u.uid}(#{u.name}) gid=#{u.gid}(#{u.name}) groups=" <> Enum.map_join(groups, ",", fn {g, gid} -> "#{gid}(#{g})" end))
        0
    end
  end

  defcmd "date", "print the system date and time", usage: "date [+FORMAT] [-u]" do
    {opts, rest} = getopt(args, "uI")
    now = DateTime.utc_now()

    text =
      case {rest, opts["I"]} do
        {["+" <> fmt | _], _} -> strftime(now, fmt)
        {_, true} -> Date.to_iso8601(now)
        _ -> strftime(now, "%a %b %e %H:%M:%S UTC %Y")
      end

    IO.puts(ctx, text)
    0
  end

  @days ~w(Mon Tue Wed Thu Fri Sat Sun)
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  def strftime(dt, fmt) do
    Regex.replace(~r/%([a-zA-Z%])/, fmt, fn _, c ->
      p2 = &String.pad_leading(to_string(&1), 2, "0")

      case c do
        "Y" -> to_string(dt.year)
        "y" -> p2.(rem(dt.year, 100))
        "Z" -> "UTC"
        "A" -> Enum.at(~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday), Date.day_of_week(dt) - 1)
        "B" -> Enum.at(~w(January February March April May June July August September October November December), dt.month - 1)
        "I" -> p2.(rem(dt.hour + 11, 12) + 1)
        "p" -> if dt.hour < 12, do: "AM", else: "PM"
        "m" -> p2.(dt.month)
        "d" -> p2.(dt.day)
        "e" -> String.pad_leading(to_string(dt.day), 2)
        "H" -> p2.(dt.hour)
        "M" -> p2.(dt.minute)
        "S" -> p2.(dt.second)
        "a" -> Enum.at(@days, Date.day_of_week(dt) - 1)
        "b" -> Enum.at(@months, dt.month - 1)
        "s" -> to_string(DateTime.to_unix(dt))
        "F" -> Date.to_iso8601(dt)
        "T" -> "#{p2.(dt.hour)}:#{p2.(dt.minute)}:#{p2.(dt.second)}"
        "j" -> dt |> Date.day_of_year() |> to_string() |> String.pad_leading(3, "0")
        "%" -> "%"
        other -> "%" <> other
      end
    end)
  end

  defcmd "cal", "display a calendar", usage: "cal" do
    today = Date.utc_today()
    first = Date.new!(today.year, today.month, 1)
    IO.puts(ctx, String.pad_leading("#{Enum.at(~w(January February March April May June July August September October November December), today.month - 1)} #{today.year}", 15))
    IO.puts(ctx, "Su Mo Tu We Th Fr Sa")
    offset = rem(Date.day_of_week(first), 7)
    days = for d <- 1..Date.days_in_month(first), do: if(d == today.day and Lepton.Style.color?(ctx), do: "\e[7m#{String.pad_leading(to_string(d), 2)}\e[0m", else: String.pad_leading(to_string(d), 2))

    (List.duplicate("  ", offset) ++ days)
    |> Enum.chunk_every(7)
    |> Enum.each(&IO.puts(ctx, Enum.join(&1, " ")))

    0
  end

  defcmd "sleep", "delay for a specified amount of time", usage: "sleep SECONDS" do
    secs = args |> List.first("1") |> Float.parse() |> then(fn {f, _} -> f; :error -> 1.0 end)
    Process.sleep(trunc(secs * 1000))
    0
  end

  defcmd "env", "print the environment, or run a command in a modified one", usage: "env [NAME=VALUE...] [COMMAND [ARG...]]" do
    {assigns, cmd} = Enum.split_while(args, &String.contains?(&1, "="))
    env = Enum.reduce(assigns, ctx.env, fn a, env -> [k, v] = String.split(a, "=", parts: 2); Map.put(env, k, v) end)

    case cmd do
      [] ->
        for {k, v} <- Enum.sort(env), do: IO.puts(ctx, "#{k}=#{v}")
        0

      [name | rest] ->
        shell = %Lepton.Shell{ctx: %{ctx | env: env}}
        Lepton.Shell.Exec.exec(name, rest, shell)
    end
  end

  defcmd "printenv", "print environment variables", usage: "printenv [NAME...]" do
    case args do
      [] -> for {k, v} <- Enum.sort(ctx.env), do: IO.puts(ctx, "#{k}=#{v}")
      names -> for n <- names, v = ctx.env[n], do: IO.puts(ctx, v)
    end

    0
  end

  defcmd "time", "run a command and report how long it took", usage: "time COMMAND [ARG...]" do
    case args do
      [] -> 0
      [name | rest] ->
        t0 = System.monotonic_time(:microsecond)
        status = Lepton.Shell.Exec.exec(name, rest, %Lepton.Shell{ctx: ctx})
        us = System.monotonic_time(:microsecond) - t0
        IO.write(ctx.stderr, "\nreal\t#{:erlang.float_to_binary(us / 1_000_000, decimals: 3)}s\n")
        status
    end
  end

  defcmd "watch", "execute a program periodically, showing output fullscreen", usage: "watch [-n SECS] COMMAND" do
    {opts, cmd} = getopt(args, "n:")
    interval = Lepton.Args.int(opts, "n", 2)
    src = Enum.join(cmd, " ")
    Lepton.TTY.set_mode(ctx.tty, :raw)

    try do
      Stream.repeatedly(fn ->
        {out, _} = Lepton.Shell.run_capture(src, cwd: ctx.cwd, env: ctx.env, user: ctx.user)
        IO.write(ctx, "\e[H\e[2JEvery #{interval}s: #{src}\n\n" <> out)
        Lepton.TTY.read_key(ctx.tty, interval * 1000)
      end)
      |> Enum.find(&(&1 in ["q", "C-c"]))
    after
      Lepton.TTY.set_mode(ctx.tty, :cooked)
    end

    0
  end

  # -- kernel & devices --------------------------------------------------------------------

  defcmd "mount", "mount a filesystem / list mounts", usage: "mount [-t TYPE] [-o OPTS] SOURCE DIR" do
    {opts, operands} = getopt(args, "t:o:")

    case operands do
      [] ->
        for m <- Sys.mounts(), do: IO.puts(ctx, "#{m.device} on #{m.dir} type #{m.type} (#{m.options})")
        0

      [_src, _dir] when ctx.user != "root" ->
        Lepton.Users.denied(ctx, "mount")

      [src, dir] ->
        case Sys.mount(opts["t"] || "auto", src, Ctx.path(ctx, dir), opts["o"]) do
          :ok -> 0
          {:error, msg} -> IO.err(ctx, "mount: #{msg}"); 32
        end

      _ ->
        IO.err(ctx, "usage: mount [-t TYPE] SOURCE DIR")
        1
    end
  end

  defcmd "lsblk", "disks, USB drives and SD cards: partitions, filesystems and where they're mounted", usage: "lsblk" do
    mounts = Map.new(Sys.mounts(), &{String.replace_prefix(&1.device, "/dev/", ""), &1.dir})
    IO.puts(ctx, "NAME          SIZE  BUS  FSTYPE   LABEL             MOUNTPOINT")

    for d <- Lepton.Media.block_devices(), d.size > 0 do
      {type, label} = Lepton.Media.FS.probe("/dev/" <> d.name)
      name = if d.partition?, do: "  " <> d.name, else: d.name

      IO.puts(
        ctx,
        String.pad_trailing(name, 11) <> String.pad_leading(Lepton.Install.Disk.human(d.size), 7) <> "  " <>
          String.pad_trailing(to_string(d.bus || ""), 5) <> String.pad_trailing(type || "", 9) <>
          String.pad_trailing(label || "", 18) <> (mounts[d.name] || "")
      )
    end

    0
  end

  defcmd "eject", "unmount a USB drive or SD card so it's safe to remove", usage: "eject [DEVICE|DIR]" do
    target =
      case {args, Lepton.Media.mounted()} do
        {[t], _} -> t
        {[], [only]} -> only.device
        {[], []} -> {:error, "no USB drive or SD card is mounted"}
        {[], many} -> {:error, "which one? " <> Enum.map_join(many, ", ", & &1.dir)}
        _ -> {:error, "usage: eject [DEVICE|DIR]"}
      end

    # A mount point (or a directory in one), else a device name (sdb1, /dev/sdb).
    dir = fn t -> if File.dir?(Ctx.path(ctx, t)), do: Ctx.path(ctx, t), else: t end

    with t when is_binary(t) <- target, {:ok, dirs} <- Lepton.Media.eject(dir.(t)) do
      IO.puts(ctx, "Ejected #{Enum.join(dirs, ", ")}: it's safe to remove.")
      0
    else
      {:error, msg} ->
        IO.err(ctx, "eject: #{msg}")
        1
    end
  end

  defcmd "umount", "unmount a filesystem", usage: "umount DIR...", root: true do
    Enum.reduce(args, 0, fn dir, st ->
      case Sys.umount(Ctx.path(ctx, dir)) do
        :ok -> st
        {:error, msg} -> IO.err(ctx, "umount: #{msg}"); 32
      end
    end)
  end

  defcmd "dmesg", "print the kernel ring buffer", usage: "dmesg" do
    # busybox's dmesg reads it with syslog(2); Erlang's reads of /dev/kmsg
    # fail (EINVAL) on some kernels.
    with true <- File.exists?("/bin/busybox"), {out, 0} when out != "" <- Lepton.Sys.shim("dmesg", []) do
      IO.write(ctx, out)
      0
    else
      _ -> kmsg_dmesg(ctx)
    end
  end

  defp kmsg_dmesg(ctx) do
    case File.open("/dev/kmsg", [:read, :binary, :raw]) do
      {:ok, _fd} ->
        # /dev/kmsg reads block at the end; read the snapshot via a helper process.
        lines = kmsg_snapshot()
        for l <- lines, do: IO.puts(ctx, l)
        0

      _ ->
        IO.err(ctx, "dmesg: kernel log not available")
        1
    end
  end

  defp kmsg_snapshot do
    parent = self()

    reader =
      spawn(fn ->
        {:ok, fd} = :file.open("/dev/kmsg", [:read, :binary, :raw])
        loop_kmsg(fd, parent)
      end)

    collect_kmsg(reader, [])
  end

  defp loop_kmsg(fd, parent) do
    case :file.read(fd, 8192) do
      {:ok, data} -> send(parent, {:kmsg, self(), data}); loop_kmsg(fd, parent)
      # The oldest messages were overwritten while we read: carry on from the next.
      {:error, :epipe} -> loop_kmsg(fd, parent)
      _ -> send(parent, {:kmsg_done, self()})
    end
  end

  defp collect_kmsg(reader, acc) do
    receive do
      {:kmsg, ^reader, data} ->
        line =
          case String.split(data, ";", parts: 2) do
            [meta, msg] ->
              ts = meta |> String.split(",") |> Enum.at(2, "0") |> String.to_integer()
              "[#{String.pad_leading(:erlang.float_to_binary(ts / 1_000_000, decimals: 6), 12)}] #{String.trim_trailing(msg) |> String.split("\n") |> hd()}"

            _ ->
              String.trim(data)
          end

        collect_kmsg(reader, [line | acc])

      {:kmsg_done, ^reader} ->
        Enum.reverse(acc)
    after
      200 ->
        Process.exit(reader, :kill)
        Enum.reverse(acc)
    end
  end

  defcmd "usb", "USB devices as a tree: hubs, their ports and what is plugged in", usage: "usb", aliases: ["lsusb"] do
    case {args, Lepton.USB.devices()} do
      {[_ | _], _} ->
        IO.err(ctx, "usage: usb")
        2

      {[], []} ->
        IO.puts(ctx, "No USB controllers (the VM has none, or its driver isn't loaded).")
        0

      {[], devices} ->
        Enum.each(Lepton.USB.describe(devices), &IO.puts(ctx, &1))
        0
    end
  end

  defcmd "input", "keyboards, mice, touchpads and tablets: the input devices and what each is", usage: "input" do
    case Lepton.Photon.Input.all() do
      [] ->
        IO.puts(ctx, "No input devices.")

      devices ->
        for d <- devices do
          where = if d.usb, do: "  (USB #{d.usb})", else: ""
          IO.puts(ctx, String.pad_trailing(Path.basename(d.path), 9) <> String.pad_trailing(to_string(d.kind || "other"), 10) <> (d.name || "?") <> where)
        end
    end

    0
  end

  defcmd "lsmod", "show the status of modules in the Linux kernel", usage: "lsmod" do
    IO.puts(ctx, "Module                  Size  Used by")

    for m <- Lepton.Kmod.loaded() do
      IO.puts(ctx, String.pad_trailing(m.name, 20) <> String.pad_leading(to_string(m.size), 8) <> "  " <> m.refs <> " " <> m.used_by)
    end

    0
  end

  defcmd "modprobe", "add a module (and its dependencies) to the kernel", usage: "modprobe MODULE [PARAM=VALUE...]", root: true do
    case args do
      ["-r", mod] -> rmmod(ctx, mod)
      [mod | params] ->
        case Lepton.Kmod.modprobe(mod, params) do
          :ok -> 0
          {:error, msg} -> IO.err(ctx, "modprobe: #{msg}"); 1
        end

      [] ->
        IO.err(ctx, "usage: modprobe MODULE")
        1
    end
  end

  defcmd "rmmod", "remove a module from the kernel", usage: "rmmod MODULE...", root: true do
    Enum.reduce(args, 0, fn m, st -> max(st, rmmod(ctx, m)) end)
  end

  defp rmmod(ctx, mod) do
    case Lepton.Kmod.rmmod(mod) do
      :ok -> 0
      {:error, msg} -> IO.err(ctx, "rmmod: #{msg}"); 1
    end
  end

  defcmd "sync", "flush filesystem buffers", usage: "sync" do
    Sys.sync()
    0
  end

  defcmd "poweroff", "power off the machine (flushes the disk first)", usage: "poweroff", aliases: ["halt", "shutdown"], root: true do
    if Sys.native?() do
      # Same path as the power button: announce, flush, remount read-only, off.
      Lepton.Power.shutdown("poweroff")
      Process.sleep(:infinity)
    else
      IO.err(ctx, "poweroff: not running as the system init")
      1
    end
  end

  defcmd "reboot", "reboot the machine", usage: "reboot", root: true do
    IO.puts(ctx, "Rebooting...")
    Process.sleep(200)

    case Sys.reboot() do
      :ok -> Process.sleep(:infinity)
      _ -> IO.err(ctx, "reboot: not running as the system init"); 1
    end
  end

  # -- terminal -------------------------------------------------------------------------------

  defcmd "clear", "clear the terminal screen", usage: "clear", aliases: ["cls"] do
    IO.write(ctx, "\e[H\e[2J\e[3J")
    0
  end

  defcmd "reset", "reset the terminal", usage: "reset" do
    IO.write(ctx, "\ec\e[?25h\e[0m")
    0
  end

  defcmd "resize", "set the terminal size from the terminal emulator's window", usage: "resize" do
    if ctx.tty do
      case Lepton.TTY.probe_size(ctx.tty, 500) do
        {:ok, {rows, cols}} ->
          IO.puts(ctx, "COLUMNS=#{cols};\nLINES=#{rows};")
          0

        :error ->
          IO.err(ctx, "resize: terminal did not answer")
          1
      end
    else
      1
    end
  end

  defcmd "stty", "show terminal settings (size)", usage: "stty [size | rows N cols M]" do
    case {args, ctx.tty} do
      {_, nil} -> 1
      {["rows", r, "cols", c], tty} -> Lepton.TTY.set_size(tty, {String.to_integer(r), String.to_integer(c)}); 0
      {_, tty} ->
        {r, c} = Lepton.TTY.size(tty)
        IO.puts(ctx, "#{r} #{c}")
        0
    end
  end

  defcmd "tty", "print the file name of the terminal", usage: "tty" do
    if ctx.tty, do: (IO.puts(ctx, Lepton.TTY.name(ctx.tty)); 0), else: (IO.puts(ctx, "not a tty"); 1)
  end

  # -- clipboard (pbcopy/pbpaste on macOS, xclip on Linux - both from the dotfiles) ------------

  defcmd "pbcopy", "copy standard input to the clipboard", usage: "pbcopy [-o]", aliases: ["xclip", "xsel", "wl-copy"] do
    if "-o" in args do
      IO.write(ctx, Lepton.Clipboard.get())
    else
      text = IO.read_all(ctx.stdin)
      Lepton.Clipboard.put(text)
      # Also hand it to the host terminal (OSC 52), e.g. iTerm2 over serial.
      if ctx.tty, do: Lepton.TTY.write(ctx.tty, Lepton.Clipboard.osc52(text))
    end

    0
  end

  defcmd "pbpaste", "paste the clipboard to standard output", usage: "pbpaste", aliases: ["wl-paste"] do
    IO.write(ctx, Lepton.Clipboard.get())
    0
  end

  # -- help ------------------------------------------------------------------------------------

  defcmd "help", "list available commands", usage: "help [COMMAND]" do
    case args do
      [name | _] -> man(ctx, name)
      [] ->
        IO.puts(ctx, "Lepton OS #{Lepton.Init.version()} - commands (`help CMD` or `man CMD` for details)\n")
        cmds = Lepton.Commands.all() |> Map.values() |> Enum.uniq_by(& &1.name) |> Enum.sort_by(& &1.name)
        for c <- cmds, do: IO.puts(ctx, "  " <> String.pad_trailing(c.name, 14) <> c.summary)
        IO.puts(ctx, "\nShell builtins: " <> Enum.join(Lepton.Shell.Builtins.names(), " "))
        IO.puts(ctx, "Keybindings: `keys` shows the bindings loaded from your dotfiles.")
        IO.puts(ctx, "Documentation: https://trylepton.app/docs/")
        0
    end
  end

  defcmd "man", "show the manual for a command", usage: "man COMMAND" do
    case args do
      [name | _] -> man(ctx, name)
      [] -> IO.err(ctx, "What manual page do you want?"); 1
    end
  end

  defp man(ctx, name) do
    case Lepton.Commands.lookup(name) do
      {:ok, c} ->
        IO.puts(ctx, "#{String.upcase(c.name)}(1)\n\nNAME\n    #{c.name} - #{c.summary}\n")
        if c.usage, do: IO.puts(ctx, "SYNOPSIS\n    #{c.usage}\n")
        if c.aliases != [], do: IO.puts(ctx, "ALIASES\n    #{Enum.join(c.aliases, ", ")}\n")

        case c.fun do
          {mod, _} -> IO.puts(ctx, "IMPLEMENTATION\n    #{inspect(mod)} (Elixir)")
          _ -> :ok
        end

        0

      :error ->
        if Lepton.Shell.Builtins.builtin?(name), do: (IO.puts(ctx, "#{name}: shell builtin (see `help`)"); 0), else: (IO.err(ctx, "No manual entry for #{name}"); 16)
    end
  end

  defcmd "keys", "show keybindings loaded from the dotfiles", usage: "keys [editor|tmux|shell|git]" do
    Lepton.Dotfiles.describe(ctx, List.first(args))
  end

  defcmd "neofetch", "show system information", usage: "neofetch", aliases: ["fetch", "about"] do
    mem = Sys.meminfo()
    logo = [
      "    __     ",
      "   / /     ",
      "  / /      ",
      " / /___    ",
      "/_____/    ",
      "           ",
      "           "
    ]

    info = [
      "root@#{Sys.hostname()}",
      "OS: Lepton #{Lepton.Init.version()} aarch64",
      "Kernel: Linux #{Sys.kernel_release()}",
      "Runtime: Elixir #{System.version()} / OTP #{System.otp_release()} (ERTS #{:erlang.system_info(:version)})",
      "Uptime: #{trunc(Sys.uptime_seconds())}s   Processes: #{length(Proc.list())} lepton, #{:erlang.system_info(:process_count)} beam",
      "Memory: #{div((mem["MemTotal"] || 0) - (mem["MemAvailable"] || 0), 1_048_576)}MiB / #{div(mem["MemTotal"] || 0, 1_048_576)}MiB   #{if Lepton.Persist.installed?(), do: "installed", else: "live"}",
      "Written by Claude (Anthropic) - see `credits`"
    ]

    color = Lepton.Style.color?(ctx)

    for {l, i} <- Enum.zip(logo, info) do
      IO.puts(ctx, (if color, do: "\e[1;36m#{l}\e[0m", else: l) <> i)
    end

    0
  end

  # -- running foreign (ELF) programs --------------------------------------------------------------

  @doc "Run a native Linux executable through an Erlang port (stdin/stdout piped)."
  def run_native(path, args, ctx) do
    port = Port.open({:spawn_executable, path}, [:binary, :exit_status, :stderr_to_stdout, :use_stdio, args: args, cd: ctx.cwd, env: Enum.map(ctx.env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)])
    native_loop(port, ctx)
  end

  defp native_loop(port, ctx) do
    receive do
      {^port, {:data, d}} -> IO.write(ctx, d); native_loop(port, ctx)
      {^port, {:exit_status, s}} -> s
    end
  end
end
