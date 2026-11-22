defmodule Lepton.Commands.VM do
  @moduledoc "Virtual machines (`vm`): QEMU guests, as UTM runs them on a Mac (`Lepton.VM`)."

  use Lepton.Command

  alias Lepton.{Ctx, IO, Keys, TTY, VM}
  alias Lepton.VM.Server

  @usage """
  vm                                list your machines
  vm create NAME [OPTIONS]          make one: -m MB memory (2048), -c CPUS (2),
                                    -s SIZE disk (16G), -i ISO a CD to boot,
                                    -f HOST:GUEST a port to forward
  vm start NAME [-c]                start it (-c: and attach its console)
  vm stop NAME [-f]                 shut it down (-f: at once, like pulling the plug)
  vm console NAME                   its serial console (C-] detaches)
  vm log NAME                       what its console printed lately
  vm info NAME                      its settings and state
  vm set NAME KEY=VALUE...          memory, cpus, iso, forward
  vm delete NAME                    remove it and its disk\
  """

  defcmd "vm", "virtual machines: create, start, stop and attach to QEMU guests (like UTM)",
    usage: "vm [list|create|start|stop|console|log|info|set|delete] [NAME] ..." do
    vm(args, ctx)
  end

  defp vm(args, ctx) do
    home = Ctx.home(ctx)

    case args do
      [] -> list(ctx, home)
      ["list"] -> list(ctx, home)
      ["create", name | rest] -> create(ctx, home, name, rest)
      ["start", name | rest] -> start(ctx, home, name, rest)
      ["stop", name | rest] -> stop(ctx, home, name, rest)
      ["console", name] -> console(ctx, home, name)
      ["log", name] -> log(ctx, home, name)
      ["info", name] -> info(ctx, home, name)
      ["set", name | kvs] when kvs != [] -> set(ctx, home, name, kvs)
      ["delete", name] -> result(ctx, VM.delete(home, name), "Deleted #{name}.")
      [h | _] when h in ["-h", "--help", "help"] -> IO.puts(ctx, @usage); 0
      _ -> IO.err(ctx, @usage); 2
    end
  end

  defp list(ctx, home) do
    case VM.statuses(home) do
      [] ->
        IO.puts(ctx, "No machines yet. Make one with: vm create NAME -i ISO")
        unless VM.installed?(), do: IO.puts(ctx, "(QEMU isn't installed: sudo app install qemu)")
        0

      vms ->
        IO.puts(ctx, String.pad_trailing("NAME", 20) <> String.pad_trailing("STATE", 10) <> String.pad_trailing("MEMORY", 9) <> String.pad_trailing("CPUS", 6) <> "CD")

        for v <- vms do
          IO.puts(ctx, String.pad_trailing(v["name"], 20) <> String.pad_trailing(if(v["running"], do: "running", else: "stopped"), 10) <> String.pad_trailing("#{v["memory"]} MB", 9) <> String.pad_trailing(to_string(v["cpus"]), 6) <> if(v["iso"] == "", do: "-", else: Path.basename(v["iso"])))
        end

        0
    end
  end

  defp create(ctx, home, name, rest) do
    {opts, extra} = Lepton.Args.getopt(rest, "m:c:s:i:f")
    size = VM.parse_size(opts["s"] || "16G")
    iso = if opts["i"], do: Ctx.path(ctx, opts["i"]), else: ""

    assignments =
      [{"memory", opts["m"]}, {"cpus", opts["c"]}, {"forward", opts["f"]}]
      |> Enum.filter(&elem(&1, 1))
      |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)

    with [] <- extra,
         size when size != nil <- size,
         {:ok, cfg} <- VM.update(%{"iso" => iso}, assignments),
         :ok <- if(iso != "" and not File.exists?(iso), do: {:error, "no such file: #{iso}"}, else: :ok),
         :ok <- VM.create(home, name, cfg, size, Lepton.Users.get(ctx.user)) do
      IO.puts(ctx, "Made #{name} (#{Ctx.tildify(ctx, VM.dir(home, name))}). Start it with: vm start #{name} -c")
      0
    else
      nil -> fail(ctx, "vm: the disk size is a number with K, M, G or T, like 16G")
      [_ | _] = extra -> fail(ctx, "vm: unexpected #{Enum.join(extra, " ")}")
      {:error, msg} -> fail(ctx, "vm: " <> msg)
    end
  end

  defp start(ctx, home, name, rest) do
    {opts, _} = Lepton.Args.getopt(rest, "c")

    case VM.start(home, name, Lepton.Users.get(ctx.user)) do
      {:ok, _} ->
        accel = if VM.kvm?(), do: "KVM", else: "emulated: no KVM, so it is slow"
        IO.puts(ctx, "Started #{name} (#{accel}).")
        if opts["c"], do: console(ctx, home, name), else: (IO.puts(ctx, "Its console: vm console #{name}"); 0)

      {:error, msg} ->
        fail(ctx, "vm: " <> msg)
    end
  end

  defp stop(ctx, home, name, rest) do
    {opts, _} = Lepton.Args.getopt(rest, "f")
    force? = opts["f"] == true

    case VM.stop(home, name, force: force?) do
      :ok ->
        IO.puts(ctx, if(force?, do: "Stopped #{name}.", else: "Asked #{name} to shut down (vm stop -f #{name} if it doesn't)."))
        0

      {:error, msg} ->
        fail(ctx, "vm: " <> msg)
    end
  end

  defp log(ctx, home, name) do
    case Server.whereis(home, name) do
      nil -> fail(ctx, "vm: #{name} isn't running")
      pid -> IO.write(ctx, Server.log(pid)); 0
    end
  end

  defp info(ctx, home, name) do
    if VM.exists?(home, name) do
      cfg = VM.config(home, name)
      running? = VM.running?(home, name)
      IO.puts(ctx, "#{name}: #{if running?, do: "running", else: "stopped"}")
      IO.puts(ctx, "  memory:  #{cfg["memory"]} MB, #{cfg["cpus"]} CPUs")
      IO.puts(ctx, "  disk:    #{Ctx.tildify(ctx, VM.disk(home, name))}")
      IO.puts(ctx, "  CD:      #{if cfg["iso"] == "", do: "(none)", else: cfg["iso"]}")
      IO.puts(ctx, "  ports:   #{if cfg["forward"] == [], do: "(none)", else: Enum.map_join(cfg["forward"], ", ", &("127.0.0.1:" <> String.replace(&1, ":", " -> guest "))) }")
      IO.puts(ctx, "  speed:   #{if VM.kvm?(), do: "KVM", else: "emulated (no /dev/kvm: boot Lepton with nested virtualization)"}")
      0
    else
      fail(ctx, "vm: no machine called #{name}")
    end
  end

  defp set(ctx, home, name, kvs) do
    if VM.exists?(home, name) do
      case VM.update(VM.config(home, name), kvs) do
        {:ok, cfg} ->
          VM.write_config(home, name, cfg)
          IO.puts(ctx, "Changed #{name}#{if VM.running?(home, name), do: " (from its next start)", else: ""}.")
          0

        {:error, msg} ->
          fail(ctx, "vm: " <> msg)
      end
    else
      fail(ctx, "vm: no machine called #{name}")
    end
  end

  # -- the console ------------------------------------------------------------------------

  defp console(ctx, home, name) do
    cond do
      Server.whereis(home, name) == nil -> fail(ctx, "vm: #{name} isn't running (vm start #{name})")
      ctx.tty == nil -> fail(ctx, "vm: the console needs a terminal (vm log #{name} shows its output)")
      true -> attach(ctx, Server.whereis(home, name), name)
    end
  end

  defp attach(ctx, pid, name) do
    tty = ctx.tty
    IO.puts(ctx, "Connected to #{name}'s console. C-] detaches (the machine keeps running).")
    seen = Server.attach(pid)
    TTY.set_mode(tty, :raw)
    # The latest output, so the screen isn't blank: the guest's prompt is in it.
    tail = if byte_size(seen) > 8192, do: binary_part(seen, byte_size(seen) - 8192, 8192), else: seen
    TTY.write(tty, tail)
    me = self()
    reader = spawn_link(fn -> read_keys(tty, me) end)
    ref = Process.monitor(pid)

    try do
      relay(tty, pid, ref)
    after
      send(reader, :stop)
      Server.detach(pid)
      TTY.set_mode(tty, :cooked)
    end
    |> case do
      :detached -> IO.puts(ctx, "\r\nDetached from #{name}; it keeps running."); 0
      {:exited, s} -> IO.puts(ctx, "\r\n#{name} has stopped#{if s != 0, do: " (QEMU exited with #{s})", else: ""}."); 0
    end
  end

  defp read_keys(tty, owner) do
    receive do
      :stop -> :ok
    after
      0 ->
        case TTY.read_key(tty, 200) do
          :timeout -> :ok
          key -> send(owner, {:vm_key, key})
        end

        read_keys(tty, owner)
    end
  end

  defp relay(tty, pid, ref) do
    receive do
      {:vm_serial, data} -> TTY.write(tty, data); relay(tty, pid, ref)
      {:vm_exit, s, _log} -> {:exited, s}
      {:DOWN, ^ref, _, _, _} -> {:exited, 0}
      {:vm_key, "C-]"} -> :detached
      {:vm_key, key} when is_binary(key) -> Server.input(pid, Keys.encode(key)); relay(tty, pid, ref)
      {:vm_key, _} -> relay(tty, pid, ref)
    end
  end

  defp result(ctx, :ok, msg), do: (IO.puts(ctx, msg); 0)
  defp result(ctx, {:error, msg}, _), do: fail(ctx, "vm: " <> msg)

  defp fail(ctx, msg), do: (IO.err(ctx, msg); 1)
end
