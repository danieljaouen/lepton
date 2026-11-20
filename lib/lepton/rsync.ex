defmodule Lepton.Rsync do
  @moduledoc """
  `rsync`: copy and synchronise files, locally or with another machine
  over SSH, sending only what changed.

  It speaks rsync's own protocol (version 27, which current rsync and
  macOS's openrsync both accept), so it works with the real thing in
  both directions: `rsync -av dir/ me@mac:backup/` runs `rsync --server`
  on the other machine, and a Mac's `rsync -av ~/proj/ me@lepton:proj/`
  runs Lepton's (through `sshd`). A local copy runs both sides here.
  See `Lepton.Rsync.Session` for the transfer itself.
  """

  alias Lepton.{Ctx, IO, Pipe}
  alias Lepton.Rsync.{Session, Wire}

  defmodule Opts do
    @moduledoc false
    defstruct recursive: false, links: false, perms: false, times: false, owner: false, group: false, devices: false,
              dirs: false, delete: false, dry_run: false, verbose: 0, checksum: false, update: false, whole_file: false,
              size_only: false, ignore_times: false, numeric_ids: false, compress: false, excludes: [], rsh: nil,
              rsync_path: "rsync", server: false, sender: false, unsupported: []
  end

  @usage "rsync [-avrlptnczuh] [--delete] [--exclude PATTERN] [-e 'ssh OPTIONS'] SOURCE... DEST"
  def usage, do: @usage

  # -- options -----------------------------------------------------------------------------

  @doc "Parse rsync's options. Returns `{opts, operands}` or `{:error, message}`."
  def parse(args), do: parse(args, %Opts{}, [])

  defp parse([], o, ops), do: {o, Enum.reverse(ops)}
  defp parse(["--" | rest], o, ops), do: {o, Enum.reverse(ops) ++ rest}

  defp parse(["--" <> long | rest], o, ops) do
    {name, value, rest} =
      case String.split(long, "=", parts: 2) do
        [n, v] -> {n, v, rest}
        [n] when n in ~w(exclude rsh rsync-path) -> {n, List.first(rest), Enum.drop(rest, 1)}
        [n] -> {n, nil, rest}
      end

    case long_opt(name, value, o) do
      {:error, _} = e -> e
      o -> parse(rest, o, ops)
    end
  end

  defp parse(["-" <> flags | rest], o, ops) when flags != "" do
    case short(String.graphemes(flags), rest, o) do
      {:error, _} = e -> e
      {o, rest} -> parse(rest, o, ops)
    end
  end

  defp parse([op | rest], o, ops), do: parse(rest, o, [op | ops])

  defp short([], rest, o), do: {o, rest}

  # In a server's flags, `e` starts the client's capability string.
  defp short(["e" | _], rest, %{server: true} = o), do: {o, rest}

  defp short(["e" | more], rest, o) do
    case {more, rest} do
      {[], [v | rest]} -> {%{o | rsh: v}, rest}
      {[], []} -> {:error, "option -e needs a command"}
      {chars, _} -> {%{o | rsh: Enum.join(chars)}, rest}
    end
  end

  defp short([c | more], rest, o) do
    o =
      case c do
        "a" -> %{o | recursive: true, links: true, perms: true, times: true, owner: true, group: true, devices: true}
        "v" -> %{o | verbose: o.verbose + 1}
        "r" -> %{o | recursive: true}
        "l" -> %{o | links: true}
        "p" -> %{o | perms: true}
        "t" -> %{o | times: true}
        "o" -> %{o | owner: true}
        "g" -> %{o | group: true}
        "D" -> %{o | devices: true}
        "n" -> %{o | dry_run: true}
        "c" -> %{o | checksum: true}
        "u" -> %{o | update: true}
        "z" -> %{o | compress: true}
        "d" -> %{o | dirs: true}
        "I" -> %{o | ignore_times: true}
        "W" -> %{o | whole_file: true}
        c when c in ~w(H R) -> %{o | unsupported: o.unsupported ++ ["-" <> c]}
        # -h -P -q -i -x -C -S -L -k -K -b -s and the like change nothing on the wire.
        _ -> o
      end

    short(more, rest, o)
  end

  defp long_opt(name, value, o) do
    case name do
      "server" -> %{o | server: true}
      "sender" -> %{o | sender: true}
      "archive" -> elem(short(["a"], [], o), 0)
      "verbose" -> %{o | verbose: o.verbose + 1}
      "recursive" -> %{o | recursive: true}
      "links" -> %{o | links: true}
      "perms" -> %{o | perms: true}
      "times" -> %{o | times: true}
      "owner" -> %{o | owner: true}
      "group" -> %{o | group: true}
      "devices" -> %{o | devices: true}
      "specials" -> o
      "dirs" -> %{o | dirs: true}
      "delete" -> %{o | delete: true}
      "dry-run" -> %{o | dry_run: true}
      "checksum" -> %{o | checksum: true}
      "update" -> %{o | update: true}
      "compress" -> %{o | compress: true}
      "whole-file" -> %{o | whole_file: true}
      "size-only" -> %{o | size_only: true}
      "ignore-times" -> %{o | ignore_times: true}
      "numeric-ids" -> %{o | numeric_ids: true}
      "exclude" when value != nil -> %{o | excludes: o.excludes ++ [value]}
      "rsh" when value != nil -> %{o | rsh: value}
      "rsync-path" when value != nil -> %{o | rsync_path: value}
      n when n in ~w(hard-links relative) -> %{o | unsupported: o.unsupported ++ ["--" <> n]}
      n when n in ~w(progress partial stats human-readable itemize-changes quiet delete-before delete-during delete-after no-implied-dirs one-file-system) -> o
      n -> {:error, "unknown option --#{n}"}
    end
  end

  # -- the command ---------------------------------------------------------------------------

  @doc """
  Run the command. `open` (for tests) replaces SSH: `fn host, command ->
  {:ok, wire, finish} end`, as `port/2` makes for a local program.
  """
  def run(args, ctx, open \\ nil) do
    Process.put(:rsync_open, open)

    case parse(args) do
      {:error, msg} ->
        IO.err(ctx, "rsync: #{msg}\nusage: #{@usage}")
        1

      {%{server: true} = o, operands} ->
        server(o, operands, ctx)

      {o, operands} when length(operands) < 2 ->
        _ = o
        IO.err(ctx, "usage: #{@usage}")
        1

      {%{unsupported: [_ | _]} = o, _} ->
        IO.err(ctx, "rsync: #{Enum.join(o.unsupported, ", ")}: not supported by Lepton's rsync")
        1

      {o, operands} ->
        client(o, operands, ctx)
    end
  end

  @doc "Where an operand is: `{:local, path}` or `{:remote, user_host, path}`."
  def locate(op) do
    case Regex.run(~r/^((?:[^@:\/\s]+@)?[^:\/\s]+):(.*)$/s, op) do
      [_, host, path] -> {:remote, host, path}
      nil -> {:local, op}
    end
  end

  defp client(o, operands, ctx) do
    {sources, [dest]} = Enum.split(operands, -1)
    places = Enum.map(sources, &locate/1)
    # The wire carries no owners, groups or devices: Lepton's files all
    # belong to its one system user, and these aren't asked for remotely.
    wire_opts = %{o | owner: false, group: false, devices: false}

    case {locate(dest), Enum.uniq(for({:remote, h, _} <- places, do: h))} do
      {{:remote, _, _}, [_ | _]} ->
        IO.err(ctx, "rsync: source and destination cannot both be remote")
        1

      {{:remote, host, path}, []} ->
        local_sources = for {:local, p} <- places, do: {p, Ctx.path(ctx, p)}
        command = server_command(wire_opts, false, [path])
        with_remote(ctx, o, host, command, fn wire -> as_client(wire, wire_opts, ctx, &Session.sender(&1, local_sources)) end)

      {{:local, d}, [host]} ->
        if Enum.any?(places, &match?({:local, _}, &1)) do
          IO.err(ctx, "rsync: all sources must be on the same machine")
          1
        else
          paths = for {:remote, _, p} <- places, do: p
          command = server_command(wire_opts, true, paths)
          with_remote(ctx, o, host, command, fn wire -> as_client(wire, wire_opts, ctx, &Session.receiver(&1, {d, Ctx.path(ctx, d)})) end)
        end

      {{:local, d}, []} ->
        local(wire_opts, Enum.map(sources, &{&1, Ctx.path(ctx, &1)}), {d, Ctx.path(ctx, d)}, ctx)

      {_, _} ->
        IO.err(ctx, "rsync: all sources must be on the same machine")
        1
    end
  end

  @doc "The command line the remote side runs (`rsync --server ...`)."
  def server_command(o, sender?, paths) do
    letters =
      [{o.verbose > 0, "v"}, {o.links, "l"}, {o.perms, "p"}, {o.times, "t"}, {o.recursive, "r"}, {o.dry_run, "n"},
       {o.checksum, "c"}, {o.update, "u"}, {o.ignore_times, "I"}, {o.whole_file, "W"}, {o.dirs, "d"}]
      |> Enum.filter(&elem(&1, 0))
      |> Enum.map_join(&elem(&1, 1))

    long = (if o.delete, do: ["--delete"], else: []) ++ (if o.size_only, do: ["--size-only"], else: [])

    Enum.join(
      [o.rsync_path, "--server"] ++ (if sender?, do: ["--sender"], else: []) ++
        (if letters != "", do: ["-" <> letters], else: []) ++ long ++ ["."] ++ Enum.map(paths, &shell_quote/1),
      " "
    )
  end

  defp shell_quote(""), do: "."

  defp shell_quote(p) do
    if Regex.match?(~r/^[A-Za-z0-9_\/.,:+=@%~-]+$/, p), do: p, else: "'" <> String.replace(p, "'", "'\\''") <> "'"
  end

  defp as_client(wire, o, ctx, role) do
    log = fn
      :info, text -> IO.write(ctx, String.trim_trailing(text, "\n") <> "\n")
      :error, text -> IO.write(ctx.stderr, String.trim_trailing(text, "\n") <> "\n")
    end

    s = Session.start(wire, :client, o, ctx, log)
    {status, size} = role.(s)

    if o.verbose > 0 do
      {read, written} = Wire.counts(wire)
      speedup = if read + written > 0, do: Float.round(size / (read + written), 2), else: 0.0
      IO.puts(ctx, "\nsent #{written} bytes  received #{read} bytes\ntotal size is #{size}  speedup is #{speedup}#{if o.dry_run, do: " (DRY RUN)", else: ""}")
    end

    status
  end

  # Both sides here: this process sends, a server process receives,
  # connected by two pipes.
  defp local(o, sources, dest, ctx) do
    {:ok, up} = Pipe.open()
    {:ok, down} = Pipe.open()
    me = self()

    server =
      spawn(fn ->
        wire = Wire.open(&Elixir.IO.binread(up, &1), fn d -> Elixir.IO.binwrite(down, d) end, fn _, _ -> :ok end)
        status = guard(fn -> elem(Session.receiver(Session.start(wire, :server, o, ctx, fn _, _ -> :ok end), dest), 0) end, ctx, true)
        Pipe.close_write(down)
        send(me, {:rsync_server, status})
      end)

    wire = Wire.open(&Elixir.IO.binread(down, &1), fn d -> Elixir.IO.binwrite(up, d) end, &client_log(ctx, &1, &2))
    status = guard(fn -> as_client(wire, o, ctx, &Session.sender(&1, sources)) end, ctx, false)
    Pipe.close_write(up)

    server_status =
      receive do
        {:rsync_server, st} -> st
      after
        30_000 -> Process.exit(server, :kill); 12
      end

    Wire.close(wire)
    max(status, server_status)
  end

  defp client_log(ctx, :info, text), do: IO.write(ctx, text)
  defp client_log(ctx, :error, text), do: IO.write(ctx.stderr, text)

  defp guard(fun, ctx, quiet?) do
    fun.()
  catch
    {:rsync_error, code, msg} ->
      unless quiet?, do: IO.err(ctx, "rsync: #{msg}")
      code
  end

  # -- remote machines -----------------------------------------------------------------------

  defp with_remote(ctx, o, host, command, fun) do
    opener = Process.get(:rsync_open) || fn host, command -> open_remote(ctx, o, host, command) end

    case opener.(host, command) do
      {:ok, wire, finish} ->
        status = guard(fn -> fun.(wire) end, ctx, false)
        remote_status = finish.()
        Wire.close(wire)
        if status == 0 and remote_status not in [0, nil], do: remote_status, else: status

      {:error, msg} ->
        IO.err(ctx, msg)
        255
    end
  end

  # `-e`: an ssh command line with the options Lepton's ssh takes.
  defp ssh_options(nil), do: {:ok, []}

  defp ssh_options(rsh) do
    case String.split(rsh) do
      [prog | rest] when prog in ["ssh", "/usr/bin/ssh"] -> ssh_args(rest, [])
      _ -> {:error, "rsync: -e must be an ssh command (ssh -p PORT -i KEY -l USER -o OPTION=VALUE)"}
    end
  end

  defp ssh_args([], acc), do: {:ok, acc}
  defp ssh_args(["-p", port | rest], acc), do: ssh_args(rest, [{:port, String.to_integer(port)} | acc])
  defp ssh_args(["-i", key | rest], acc), do: ssh_args(rest, [{:identity, key} | acc])
  defp ssh_args(["-l", user | rest], acc), do: ssh_args(rest, [{:user, user} | acc])
  defp ssh_args(["-o", "StrictHostKeyChecking=" <> v | rest], acc), do: ssh_args(rest, [{:strict, String.downcase(v)} | acc])
  defp ssh_args(["-o", "ProxyJump=" <> v | rest], acc), do: ssh_args(rest, [{:jump, v} | acc])
  defp ssh_args(["-o", "ProxyCommand=" <> v | rest], acc), do: ssh_args(rest, [{:proxy_command, v} | acc])
  defp ssh_args(["-J", v | rest], acc), do: ssh_args(rest, [{:jump, v} | acc])
  defp ssh_args(["-o", _ | rest], acc), do: ssh_args(rest, acc)
  defp ssh_args([flag | rest], acc) when flag in ~w(-T -q -v -4 -6 -x -a -C), do: ssh_args(rest, acc)
  defp ssh_args([other | _], _), do: {:error, "rsync: -e: ssh option #{other} is not supported"}

  defp open_remote(ctx, o, host, command) do
    with {:ok, sopts} <- ssh_options(o.rsh),
         identity = for({:identity, k} <- sopts, do: Ctx.path(ctx, k)),
         {:ok, conn, _cfg} <-
           Lepton.SSH.connect(host,
             home: Ctx.home(ctx),
             port: sopts[:port],
             user: sopts[:user],
             identity: identity,
             strict: sopts[:strict],
             jump: sopts[:jump],
             proxy_command: sopts[:proxy_command],
             env: ctx.env,
             on_unknown: if(ctx.tty, do: &confirm_host(ctx, &1, &2))
           ) do
      channel(conn, command, ctx)
    end
  end

  defp confirm_host(ctx, name, key) do
    IO.write(ctx.stderr, "The authenticity of host '#{name}' can't be established.\n#{Lepton.SSH.kind(key)} key fingerprint is #{Lepton.SSH.fingerprint(key)}.\nAre you sure you want to continue connecting (yes/no)? ")

    case IO.read_line(ctx.stdin) do
      line when is_binary(line) -> String.trim(line) in ["yes", "y"]
      _ -> false
    end
  end

  @doc false
  # A remote command as a byte stream: what it prints goes into a pipe
  # (by a process that owns the channel), what we send goes to its input.
  def channel(conn, command, ctx) do
    {:ok, inbound} = Pipe.open()
    me = self()

    pump =
      spawn(fn ->
        case Lepton.SSH.exec(conn, command) do
          {:ok, ch} ->
            send(me, {:rsync_channel, self(), ch})
            pump(conn, ch, inbound, ctx, nil)

          {:error, msg} ->
            send(me, {:rsync_channel, self(), {:error, msg}})
        end
      end)

    receive do
      {:rsync_channel, ^pump, {:error, msg}} ->
        Lepton.SSH.close(conn)
        {:error, msg}

      {:rsync_channel, ^pump, ch} ->
        wire = Wire.open(&Elixir.IO.binread(inbound, &1), fn d -> :ssh_connection.send(conn, ch, Elixir.IO.iodata_to_binary(d)) end, &client_log(ctx, &1, &2))

        finish = fn ->
          :ssh_connection.send_eof(conn, ch)
          ref = Process.monitor(pump)

          status =
            receive do
              {:DOWN, ^ref, _, _, {:shutdown, {:status, st}}} -> st
              {:DOWN, ^ref, _, _, _} -> nil
            after
              10_000 -> nil
            end

          Lepton.SSH.close(conn)
          status
        end

        {:ok, wire, finish}
    end
  end

  @doc """
  A shell command as the other side (tests: a real `rsync --server`):
  `{:ok, wire, finish}`, finish returning its exit status.
  """
  def port(command, ctx) do
    {:ok, inbound} = Pipe.open()
    me = self()

    pump =
      spawn(fn ->
        port = Port.open({:spawn_executable, "/bin/sh"}, [:binary, :exit_status, args: ["-c", command]])
        send(me, {:rsync_port, self(), port})
        port_pump(port, inbound)
      end)

    port = receive do: ({:rsync_port, ^pump, p} -> p)
    wire = Wire.open(&Elixir.IO.binread(inbound, &1), fn d -> Port.command(port, d); :ok end, &client_log(ctx, &1, &2))

    finish = fn ->
      ref = Process.monitor(pump)

      receive do
        {:DOWN, ^ref, _, _, {:shutdown, {:status, st}}} -> st
        {:DOWN, ^ref, _, _, _} -> nil
      after
        10_000 -> nil
      end
    end

    {:ok, wire, finish}
  end

  defp port_pump(port, inbound) do
    receive do
      {^port, {:data, d}} ->
        Elixir.IO.binwrite(inbound, d)
        port_pump(port, inbound)

      {^port, {:exit_status, st}} ->
        Pipe.close_write(inbound)
        exit({:shutdown, {:status, st}})
    end
  end

  defp pump(conn, ch, inbound, ctx, status) do
    receive do
      {:ssh_cm, ^conn, {:data, ^ch, 0, data}} ->
        Elixir.IO.binwrite(inbound, data)
        :ssh_connection.adjust_window(conn, ch, byte_size(data))
        pump(conn, ch, inbound, ctx, status)

      {:ssh_cm, ^conn, {:data, ^ch, 1, data}} ->
        IO.write(ctx.stderr, data)
        :ssh_connection.adjust_window(conn, ch, byte_size(data))
        pump(conn, ch, inbound, ctx, status)

      {:ssh_cm, ^conn, {:exit_status, ^ch, st}} ->
        pump(conn, ch, inbound, ctx, st)

      {:ssh_cm, ^conn, {:eof, ^ch}} ->
        Pipe.close_write(inbound)
        pump(conn, ch, inbound, ctx, status)

      {:ssh_cm, ^conn, {:closed, ^ch}} ->
        Pipe.close_write(inbound)
        exit({:shutdown, {:status, status}})

      _ ->
        pump(conn, ch, inbound, ctx, status)
    end
  end

  # -- the server (`rsync --server`, run by the other machine's rsync) -----------------------

  defp server(o, operands, ctx) do
    stdin = ctx.stdin
    wire = Wire.open(&Elixir.IO.binread(stdin, &1), fn d -> Elixir.IO.binwrite(ctx.stdout, d) end, fn _, _ -> :ok end)

    status =
      try do
        s = Session.start(wire, :server, o, ctx, fn _, _ -> :ok end)

        cond do
          o.unsupported != [] -> refuse(s, "#{Enum.join(o.unsupported, ", ")} isn't supported by Lepton's rsync")
          true -> serve(s, o, operands, ctx)
        end
      catch
        {:rsync_error, code, msg} ->
          IO.err(ctx, "rsync: #{msg}")
          code
      end

    Wire.close(wire)
    status
  end

  defp refuse(s, msg) do
    Wire.message(s.wire, :error, "rsync: #{msg}\n")
    1
  end

  # rsync [flags] . PATH...: the "." stands for the current directory.
  defp serve(s, o, operands, ctx) do
    paths =
      case operands do
        ["." | rest] when rest != [] -> rest
        other -> other
      end

    paths = Enum.map(paths, fn p -> if p == "", do: ".", else: p end)

    if o.sender do
      elem(Session.sender(s, Enum.map(paths, &{&1, Ctx.path(ctx, &1)})), 0)
    else
      d = List.last(paths) || "."
      elem(Session.receiver(s, {d, Ctx.path(ctx, d)}), 0)
    end
  end
end
