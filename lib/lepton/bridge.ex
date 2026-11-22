defmodule Lepton.Bridge do
  @moduledoc """
  Lepton's commands for native programs.

  Lepton's commands (`svc`, `app`, `vm`, Lepton's `git`, ...) are
  functions in Lepton's Erlang VM, so a native program (Claude Code's
  bash, a script run by it) can't run them as it runs a file. The bridge
  lets it: `lepton COMMAND [ARGS...]` (`/usr/bin/lepton`, an escript)
  connects to a Unix socket, and Lepton runs the command line in `lsh`,
  as the user the socket belongs to, sending back its output and exit
  status.

  Each user has a socket of their own, `/run/lepton/bridge/UID/socket`,
  in a directory only that user (and root) can open: whoever reaches the
  socket is that user, as with `ssh`. A command gets no terminal; its
  standard input is empty unless the client sends its own (`lepton -i`).

  The protocol: Erlang terms (`term_to_binary`), each in a frame with a
  4-byte length. The client sends `{:run, command_line, cwd, stdin?}`,
  then `{:stdin, data}`... and `:eof` when it sends input; Lepton answers
  with `{:out, 1 | 2, data}`... and `{:exit, status}`.
  """

  use GenServer

  alias Lepton.{Ctx, Pipe, Proc, Shell, Users}

  @root "/run/lepton/bridge"

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The socket of the user with `uid`."
  def socket(uid), do: Path.join([@root, to_string(uid), "socket"])

  @doc """
  Make sure `user` (a `Lepton.Users` user) has a socket, and return its
  path (nil off a native system).
  """
  def ensure(user) do
    if Process.whereis(__MODULE__) && Lepton.Sys.native?(), do: GenServer.call(__MODULE__, {:ensure, user}), else: nil
  end

  # -- server ---------------------------------------------------------------------------

  @impl true
  def init(nil) do
    if Lepton.Sys.native?(), do: send(self(), :start_all)
    {:ok, %{listeners: %{}}}
  end

  @impl true
  def handle_info(:start_all, st) do
    st = Enum.reduce(Users.list(), st, fn u, st -> elem(listen(st, u), 1) end)
    {:noreply, st}
  end

  def handle_info(_, st), do: {:noreply, st}

  @impl true
  def handle_call({:ensure, user}, _from, st) do
    {path, st} = listen(st, user)
    {:reply, path, st}
  end

  defp listen(st, user) do
    path = socket(user.uid)

    if Map.has_key?(st.listeners, user.uid) and File.exists?(path) do
      {path, st}
    else
      case listen_at(path, user) do
        {:ok, acceptor} -> {path, %{st | listeners: Map.put(st.listeners, user.uid, acceptor)}}
        {:error, _} -> {nil, st}
      end
    end
  end

  @doc "Serve `user` on a socket at `path` (tests; `ensure/1` for the real ones)."
  def listen_at(path, user) do
    with {:ok, lsock} <- open(path, user) do
      acceptor = spawn(fn -> accept(lsock, user.name) end)
      :gen_tcp.controlling_process(lsock, acceptor)
      {:ok, acceptor}
    end
  end

  # The directory: the user's alone (0700), so the socket in it is too.
  @doc false
  def open(path, user) do
    dir = Path.dirname(path)
    File.mkdir_p!(Path.dirname(dir))
    File.chmod(Path.dirname(dir), 0o755)
    File.rm_rf(dir)
    File.mkdir_p!(dir)
    File.chown(dir, user.uid)
    File.chgrp(dir, user.gid)
    File.chmod(dir, 0o700)

    with {:ok, lsock} <- :gen_tcp.listen(0, [:binary, ifaddr: {:local, String.to_charlist(path)}, packet: 4, active: false, reuseaddr: true]) do
      File.chown(path, user.uid)
      File.chmod(path, 0o600)
      {:ok, lsock}
    end
  end

  defp accept(lsock, name) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        pid = spawn(fn -> receive(do: (:go -> serve(sock, name))) end)
        :gen_tcp.controlling_process(sock, pid)
        send(pid, :go)
        accept(lsock, name)

      {:error, _} ->
        :ok
    end
  end

  # One request: run it, relay its input and output, report its status.
  @doc false
  def serve(sock, name) do
    with {:ok, frame} <- :gen_tcp.recv(sock, 0, 10_000),
         {:run, line, cwd, stdin?} when is_binary(line) and is_binary(cwd) <- decode(frame),
         %{} = user <- Users.get(name) do
      {:ok, stdin} = Pipe.open()
      outs = [out(sock, 1), out(sock, 2)]
      cwd = if File.dir?(cwd), do: cwd, else: user.home
      ctx = Users.as(%Ctx{cwd: cwd, env: env(user)}, user)
      parent = self()

      {_pid, beam, ref} =
        Proc.spawn(line, [monitor: true], fn _ ->
          Pipe.set_reader(stdin, self())
          send(parent, :started)
          status = Shell.run_string(line, cwd: ctx.cwd, env: ctx.env, stdin: stdin, stdout: hd(outs), stderr: List.last(outs), rc: true, user: user.name)
          exit({:shutdown, {:status, status}})
        end)

      receive(do: (:started -> :ok))
      if stdin?, do: :inet.setopts(sock, active: :once), else: Pipe.close_write(stdin)
      status = relay(sock, stdin, beam, ref)
      :gen_tcp.send(sock, :erlang.term_to_binary({:exit, status}))
      Enum.each(outs, &send(&1, :stop))
      :gen_tcp.close(sock)
    else
      _ -> :gen_tcp.close(sock)
    end
  end

  defp relay(sock, stdin, beam, ref) do
    receive do
      {:tcp, ^sock, frame} ->
        case decode(frame) do
          {:stdin, data} when is_binary(data) -> IO.binwrite(stdin, data)
          :eof -> Pipe.close_write(stdin)
          _ -> :ok
        end

        :inet.setopts(sock, active: :once)
        relay(sock, stdin, beam, ref)

      # The client went away (C-c): so does the command.
      {:tcp_closed, ^sock} ->
        Process.exit(beam, :kill)
        relay(sock, stdin, beam, ref)

      {:DOWN, ^ref, :process, ^beam, {:shutdown, {:status, status}}} -> status
      {:DOWN, ^ref, :process, ^beam, _} -> 255
    end
  end

  defp decode(frame) do
    :erlang.binary_to_term(frame, [:safe])
  rescue
    _ -> nil
  end

  # The user's environment, as `sshd` gives a command: no terminal.
  defp env(user) do
    %{
      "HOME" => user.home,
      "USER" => user.name,
      "LOGNAME" => user.name,
      "SHELL" => user.shell,
      "PATH" => "/usr/local/bin:/usr/bin:/bin",
      "TERM" => "dumb",
      "LANG" => "C.UTF-8",
      "HOSTNAME" => Lepton.Sys.hostname()
    }
  end

  # An output stream (1 stdout, 2 stderr) as an I/O server, sending frames.
  defp out(sock, n), do: spawn(fn -> out_loop(sock, n) end)

  defp out_loop(sock, n) do
    receive do
      {:io_request, from, reply_as, req} ->
        send(from, {:io_reply, reply_as, out_request(sock, n, req)})
        out_loop(sock, n)

      :stop ->
        :ok
    end
  end

  defp out_request(sock, n, {:put_chars, enc, chars}) do
    data = if enc == :latin1, do: :erlang.iolist_to_binary(chars), else: :unicode.characters_to_binary(chars)

    case :gen_tcp.send(sock, :erlang.term_to_binary({:out, n, data})) do
      :ok -> :ok
      _ -> {:error, :epipe}
    end
  end

  defp out_request(sock, n, {:put_chars, enc, m, f, a}), do: out_request(sock, n, {:put_chars, enc, apply(m, f, a)})
  defp out_request(sock, n, {:requests, reqs}), do: Enum.reduce_while(reqs, :ok, fn r, _ -> case out_request(sock, n, r) do :ok -> {:cont, :ok}; e -> {:halt, e} end end)
  defp out_request(_, _, :getopts), do: [binary: true, encoding: :unicode]
  defp out_request(_, _, {:setopts, _}), do: :ok
  defp out_request(_, _, _), do: {:error, :enotsup}
end
