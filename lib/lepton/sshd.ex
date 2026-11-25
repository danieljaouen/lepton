defmodule Lepton.SSHD do
  @moduledoc """
  `sshd`: log in to Lepton over SSH, built on OTP's SSH daemon.

  Keys only: the daemon offers no password or keyboard-interactive
  login, so the only way in is a key listed in the account's
  `~/.ssh/authorized_keys` (root's is `/root/.ssh/authorized_keys`).
  Lepton's own accounts are SSH's users.

  It is off until enabled: the shipped `sshd` service runs the `sshd`
  command (`sudo svc enable --now sshd`). The host key, an ed25519 key,
  is made on the first start in `/var/lib/lepton/ssh`, which an installed
  system keeps, so clients see the same key after a restart.

  A session with a terminal (`ssh lepton`, `ssh -t lepton top`) gets a
  `Lepton.TTY` whose backend is the SSH channel: the line discipline,
  C-c, full-screen programs and window resizes work as on the console. A
  command without one (`ssh lepton ls`) runs with pipes for standard
  input and output, and its exit status goes back to the client. Tunnels
  out are allowed (Lepton can be a jump host: `ssh -J`), and SFTP is
  offered (sftp, scp, sshfs), each account confined to its home (root to
  the whole system). Remote forwarding is not.
  """

  require Logger
  alias Lepton.{Persist, SSH, Users}

  @default_port 22

  def default_port, do: @default_port
  def host_key_path, do: Persist.state_path("ssh/ssh_host_ed25519_key")

  @doc "The host key, made (with its `.pub`) the first time. Returns `{:ok, key}`."
  def host_key(path \\ host_key_path()) do
    case SSH.load_key(path) do
      {:ok, key} ->
        {:ok, key}

      {:error, :enoent} ->
        key = SSH.generate()
        File.mkdir_p!(Path.dirname(path))
        File.chmod(Path.dirname(path), 0o700)
        File.write!(path, SSH.encode_private(key, "root@" <> Lepton.Sys.hostname()))
        File.chmod!(path, 0o600)
        File.write!(path <> ".pub", SSH.public_line(SSH.public(key), "root@" <> Lepton.Sys.hostname()) <> "\n")
        {:ok, key}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Start the daemon on `port`. Options: `:host_key` (path), `:log` (a pid
  sent `{:sshd_log, line}` for logins and failures), `:home` (a function
  from an account to its home directory, for tests).
  Returns `{:ok, daemon_ref}`.
  """
  def start(port \\ @default_port, opts \\ []) do
    :ssh.start()
    # Loaded now: on first use OTP loses a tunnel's first data while it loads them.
    for m <- [:ssh_tcpip_forward_srv, :ssh_tcpip_forward_client], do: Code.ensure_loaded(m)

    with {:ok, key} <- host_key(opts[:host_key] || host_key_path()) do
      log = opts[:log]
      say = fn line -> Logger.info("sshd: " <> line); if log, do: send(log, {:sshd_log, line}) end

      :ssh.daemon(port,
        key_cb: {Lepton.SSHD.Keys, host_key: key, home: opts[:home], say: say},
        # Public keys only: no password, no keyboard-interactive.
        auth_methods: ~c"publickey",
        ssh_cli: {Lepton.SSHD.Channel, [home: opts[:home]]},
        # SFTP (sftp, scp, sshfs), each account in its own home.
        subsystems: [{~c"sftp", {Lepton.SSHD.SFTP, [home: opts[:home]]}}],
        # Tunnels from here to other hosts (direct-tcpip: ssh -J, -W and -L
        # through Lepton), as OpenSSH allows them; OTP calls these "in".
        # No listening for the client (-R: "out").
        tcpip_tunnel_in: true,
        tcpip_tunnel_out: false,
        id_string: ~c"Lepton_sshd",
        parallel_login: true,
        max_sessions: 16,
        connectfun: fn user, {ip, _port}, method -> say.("accepted #{method} for #{user} from #{:inet.ntoa(ip)}") end,
        failfun: fn user, {ip, _port}, _reason -> say.("refused #{user} from #{:inet.ntoa(ip)}") end,
        disconnectfun: fn _reason -> :ok end
      )
    end
  end

  def stop(daemon), do: :ssh.stop_daemon(daemon)

  @doc """
  Stop `daemon` when `owner` ends, however it ends. OTP's daemon isn't
  linked to whoever started it: the sshd service's process, killed
  rather than asked to stop (its tree killed when the process it ran in
  ended first), left the daemon listening, and every start after it then
  found port 22 taken (`eaddrinuse`) until Lepton restarted.
  """
  def bind_to(daemon, owner \\ self()) do
    spawn(fn ->
      ref = Process.monitor(owner)

      receive do
        {:DOWN, ^ref, :process, _, _} -> :ssh.stop_daemon(daemon)
      end
    end)

    daemon
  end

  @doc "The account `user` may log in as, if any."
  def account(user) when is_list(user), do: account(to_string(user))
  def account(user), do: Users.get(user)

  @doc """
  Is `key` in `user`'s `~/.ssh/authorized_keys`? The file must not be
  writable by group or others (OpenSSH's StrictModes).
  """
  def authorized?(user, key, home_fun \\ nil) do
    with %Users{} = account <- account(user),
         home = if(home_fun, do: home_fun.(account), else: account.home),
         path = Path.join(home, ".ssh/authorized_keys"),
         {:ok, %{mode: mode}} <- File.stat(path),
         true <- Bitwise.band(mode, 0o022) == 0,
         {:ok, text} <- File.read(path) do
      blob = SSH.blob(key)
      Enum.any?(authorized_keys(text), &(SSH.blob(&1) == blob))
    else
      _ -> false
    end
  end

  @doc "The keys of an `authorized_keys` file (lines it can't read are skipped)."
  def authorized_keys(text) do
    for line <- String.split(text, "\n"), line = String.trim(line), line != "", not String.starts_with?(line, "#"), key <- decode(line), do: key
  end

  # A line may start with options (from="...",no-pty ...): find the key type.
  defp decode(line) do
    case Regex.run(~r/((?:ssh|ecdsa-sha2|sk-ssh|sk-ecdsa)-\S+\s+[A-Za-z0-9+\/=]+)/, line) do
      [_, key] ->
        try do
          case :ssh_file.decode(key, :auth_keys) do
            [{k, _} | _] -> [k]
            _ -> []
          end
        catch
          _, _ -> []
        end

      nil ->
        []
    end
  end
end

defmodule Lepton.SSHD.SFTP do
  @moduledoc false
  # OTP's SFTP server, rooted at the account's home (root: everything).
  # Which account is known only once the channel is up, so the real
  # server is started then and every message passed on to it.
  @behaviour :ssh_server_channel

  @impl true
  def init(opts), do: {:ok, %{opts: opts, inner: nil}}

  @impl true
  def handle_msg({:ssh_channel_up, _ch, conn} = msg, st) do
    [user: user] = :ssh.connection_info(conn, [:user])
    account = Lepton.SSHD.account(user)
    home = if st.opts[:home], do: st.opts[:home].(account), else: account.home
    root = if account.name == "root" and st.opts[:home] == nil, do: "/", else: home
    {:ok, inner} = :ssh_sftpd.init(root: String.to_charlist(root), cwd: ~c"/", file_handler: Lepton.SSHD.SFTPFile)
    wrap(:ssh_sftpd.handle_msg(msg, inner), st)
  end

  def handle_msg(msg, %{inner: inner} = st) when inner != nil, do: wrap(:ssh_sftpd.handle_msg(msg, inner), st)
  def handle_msg(_msg, st), do: {:ok, st}

  @impl true
  def handle_ssh_msg(msg, %{inner: inner} = st) when inner != nil, do: wrap(:ssh_sftpd.handle_ssh_msg(msg, inner), st)
  def handle_ssh_msg(_msg, st), do: {:ok, st}

  @impl true
  def terminate(reason, %{inner: inner}) when inner != nil, do: :ssh_sftpd.terminate(reason, inner)
  def terminate(_reason, _st), do: :ok

  defp wrap({:ok, inner}, st), do: {:ok, %{st | inner: inner}}
  defp wrap({:stop, ch, inner}, st), do: {:stop, ch, %{st | inner: inner}}
end

defmodule Lepton.SSHD.SFTPFile do
  @moduledoc false
  # SFTP's file operations, raw: OTP's default handler goes through the
  # VM's file server, which every non-raw file operation in Lepton
  # shares. One that waits (on an sshfs mount, say) would hold up the
  # SFTP server, and so whoever waits on it: a deadlock.
  @behaviour :ssh_sftpd_file_api

  @impl true
  def close(dev, st), do: {:file.close(dev), st}
  @impl true
  def delete(path, st), do: {:prim_file.delete(path), st}
  @impl true
  def del_dir(path, st), do: {:prim_file.del_dir(path), st}
  @impl true
  def get_cwd(st), do: {:prim_file.get_cwd(), st}
  @impl true
  def is_dir(path, st), do: {match?({:ok, {:file_info, _, :directory, _, _, _, _, _, _, _, _, _, _, _}}, :prim_file.read_file_info(path)), st}
  @impl true
  def list_dir(path, st), do: {:prim_file.list_dir(path), st}
  @impl true
  def make_dir(path, st), do: {:prim_file.make_dir(path), st}
  @impl true
  def make_symlink(target, path, st), do: {:prim_file.make_symlink(target, path), st}
  @impl true
  def open(path, flags, st), do: {:file.open(path, [:raw | flags]), st}
  @impl true
  def position(dev, offs, st), do: {:file.position(dev, offs), st}
  @impl true
  def read(dev, len, st), do: {:file.read(dev, len), st}
  @impl true
  def read_link(path, st), do: {:prim_file.read_link(path), st}
  @impl true
  def read_link_info(path, st), do: {:prim_file.read_link_info(path), st}
  @impl true
  def read_file_info(path, st), do: {:prim_file.read_file_info(path), st}
  @impl true
  def rename(from, to, st), do: {:prim_file.rename(from, to), st}
  @impl true
  def write(dev, data, st), do: {:file.write(dev, data), st}
  @impl true
  def write_file_info(path, info, st), do: {:prim_file.write_file_info(path, info), st}
end

defmodule Lepton.SSHD.Keys do
  @moduledoc false
  # The daemon's key callback: its host key, and each account's
  # authorized_keys.
  @behaviour :ssh_server_key_api

  @impl true
  def host_key(alg, opts) do
    key = opts[:key_cb_private][:host_key]
    if alg == :"ssh-ed25519", do: {:ok, key}, else: {:error, :no_key}
  end

  @impl true
  def is_auth_key(key, user, opts) do
    o = opts[:key_cb_private]

    if Lepton.SSHD.authorized?(user, key, o[:home]) do
      true
    else
      o[:say].("refused key #{Lepton.SSH.fingerprint(key)} for #{user}: not in their authorized_keys")
      false
    end
  end
end

defmodule Lepton.SSHD.Channel do
  @moduledoc false
  # One session channel: a shell or command for the logged-in account.
  @behaviour :ssh_server_channel

  alias Lepton.{Ctx, Pipe, Proc, Shell, TTY, Users}

  defmodule Backend do
    @moduledoc false
    # A TTY whose terminal is the SSH client.
    def open({conn, ch, size}, _tty), do: {:ok, {conn, ch, size}}
    def size({_, _, size}), do: size
    def write({conn, ch, _}, data), do: :ssh_connection.send(conn, ch, data)
  end

  @impl true
  def init(opts), do: {:ok, %{opts: opts, conn: nil, ch: nil, pty: nil, env: %{}, tty: nil, stdin: nil, outs: [], session: nil}}

  @impl true
  def handle_msg({:ssh_channel_up, ch, conn}, st), do: {:ok, %{st | ch: ch, conn: conn}}

  def handle_msg({:session_done, status}, st) do
    :ssh_connection.exit_status(st.conn, st.ch, status)
    :ssh_connection.send_eof(st.conn, st.ch)
    {:stop, st.ch, st}
  end

  def handle_msg(_msg, st), do: {:ok, st}

  @impl true
  def handle_ssh_msg({:ssh_cm, conn, {:pty, ch, want, {term, cols, rows, _, _, _}}}, st) do
    reply(conn, want, :success, ch)
    {:ok, %{st | pty: {to_string(term), size(rows, cols)}}}
  end

  # The client's LANG and LC_* (as OpenSSH's AcceptEnv); nothing else.
  def handle_ssh_msg({:ssh_cm, conn, {:env, ch, want, var, value}}, st) do
    var = to_string(var)

    if var == "LANG" or String.starts_with?(var, "LC_") do
      reply(conn, want, :success, ch)
      {:ok, %{st | env: Map.put(st.env, var, to_string(value))}}
    else
      reply(conn, want, :failure, ch)
      {:ok, st}
    end
  end

  def handle_ssh_msg({:ssh_cm, conn, {:shell, ch, want}}, st), do: start(st, conn, ch, want, nil)
  def handle_ssh_msg({:ssh_cm, conn, {:exec, ch, want, cmd}}, st), do: start(st, conn, ch, want, to_string(cmd))

  def handle_ssh_msg({:ssh_cm, conn, {:data, ch, 0, data}}, st) do
    :ssh_connection.adjust_window(conn, ch, byte_size(data))

    cond do
      st.tty -> TTY.input(st.tty, data)
      st.stdin -> IO.binwrite(st.stdin, data)
      true -> :ok
    end

    {:ok, st}
  end

  def handle_ssh_msg({:ssh_cm, _, {:eof, _ch}}, st) do
    if st.stdin, do: Pipe.close_write(st.stdin)
    {:ok, st}
  end

  def handle_ssh_msg({:ssh_cm, _, {:window_change, _ch, cols, rows, _, _}}, st) do
    if st.tty, do: TTY.set_size(st.tty, size(rows, cols))
    {:ok, st}
  end

  def handle_ssh_msg({:ssh_cm, _, {:closed, ch}}, st), do: {:stop, ch, st}

  def handle_ssh_msg({:ssh_cm, conn, {_request, ch, want, _}}, st) when is_boolean(want) do
    reply(conn, want, :failure, ch)
    {:ok, st}
  end

  def handle_ssh_msg(_msg, st), do: {:ok, st}

  @impl true
  def terminate(_reason, st) do
    # The connection went away: like a hangup, end what the session started.
    if st.tty, do: Proc.hangup(st.tty)
    for pid <- [st.session, st.tty | st.outs], pid != nil, do: Process.exit(pid, :kill)
    :ok
  end

  # A client without a terminal of its own (`ssh -tt` from a script)
  # reports 0x0: assume 24x80.
  defp size(rows, cols) when rows < 1 or cols < 1, do: {24, 80}
  defp size(rows, cols), do: {max(rows, 2), max(cols, 10)}

  defp reply(_conn, false, _what, _ch), do: :ok
  defp reply(conn, true, :success, ch), do: :ssh_connection.reply_request(conn, true, :success, ch)
  defp reply(conn, true, :failure, ch), do: :ssh_connection.reply_request(conn, true, :failure, ch)

  defp start(%{session: nil} = st, conn, ch, want, command) do
    [user: user] = :ssh.connection_info(conn, [:user])
    account = Lepton.SSHD.account(user)
    home = if st.opts[:home], do: st.opts[:home].(account), else: account.home
    me = self()

    {st, ctx} =
      case st.pty do
        {term, size} ->
          {:ok, tty} = TTY.start(backend: {Backend, {conn, ch, size}}, name: "ssh", term: term, auto_probe: false)
          ctx = %Ctx{cwd: home, env: env(account, home, st.env, term, size), stdin: tty, stdout: tty, stderr: tty, tty: tty}
          {%{st | tty: tty}, ctx}

        nil ->
          {:ok, stdin} = Pipe.open()
          outs = [out(conn, ch, 0), out(conn, ch, 1)]
          ctx = %Ctx{cwd: home, env: env(account, home, st.env, "dumb", nil), stdin: stdin, stdout: hd(outs), stderr: List.last(outs)}
          {%{st | stdin: stdin, outs: outs}, ctx}
      end

    ctx = %{Users.as(ctx, account, login: true) | cwd: home, env: Map.put(ctx.env, "HOME", home)}
    reply(conn, want, :success, ch)

    session =
      spawn(fn ->
        if st.stdin, do: Pipe.set_reader(st.stdin, self())

        status =
          try do
            run(ctx, command)
          catch
            _, _ -> 255
          end

        send(me, {:session_done, if(is_integer(status), do: status, else: 0)})
      end)

    {:ok, %{st | session: session}}
  end

  defp start(st, conn, ch, want, _command) do
    reply(conn, want, :failure, ch)
    {:ok, st}
  end

  # A login shell, or COMMAND run by the shell.
  defp run(%{tty: tty} = ctx, nil) when tty != nil do
    case File.read("/etc/motd") do
      {:ok, text} -> Lepton.IO.write(ctx, text)
      _ -> :ok
    end

    Shell.login(ctx)
  end

  defp run(ctx, nil), do: run(ctx, Lepton.IO.read_all(ctx.stdin))

  defp run(ctx, command) do
    {_pid, beam, ref} =
      Proc.spawn(command, [tty: ctx.tty, monitor: true], fn _ ->
        status = Shell.run_string(command, cwd: ctx.cwd, env: ctx.env, stdin: ctx.stdin, stdout: ctx.stdout, stderr: ctx.stderr, tty: ctx.tty, rc: true, user: ctx.user)
        exit({:shutdown, {:status, status}})
      end)

    receive do
      {:DOWN, ^ref, :process, ^beam, {:shutdown, {:status, status}}} -> status
      {:DOWN, ^ref, :process, ^beam, _} -> 255
    end
  end

  defp env(account, home, client_env, term, size) do
    base = %{
      "HOME" => home,
      "USER" => account.name,
      "LOGNAME" => account.name,
      "SHELL" => account.shell,
      "PATH" => "/usr/local/bin:/usr/bin:/bin",
      "TERM" => term,
      "LANG" => "C.UTF-8",
      "HOSTNAME" => Lepton.Sys.hostname(),
      "EDITOR" => "le",
      "VISUAL" => "le",
      "PAGER" => "less"
    }

    base = if size, do: Map.merge(base, %{"COLUMNS" => to_string(elem(size, 1)), "LINES" => to_string(elem(size, 0))}), else: base
    Map.merge(base, client_env)
  end

  # An output stream (0 stdout, 1 stderr) of the channel, as an I/O server.
  defp out(conn, ch, type) do
    spawn(fn -> out_loop(conn, ch, type) end)
  end

  defp out_loop(conn, ch, type) do
    receive do
      {:io_request, from, reply_as, req} ->
        send(from, {:io_reply, reply_as, out_request(conn, ch, type, req)})
        out_loop(conn, ch, type)
    end
  end

  defp out_request(conn, ch, type, {:put_chars, enc, chars}) do
    data = if enc == :latin1, do: :erlang.iolist_to_binary(chars), else: :unicode.characters_to_binary(chars)

    case :ssh_connection.send(conn, ch, type, data) do
      :ok -> :ok
      _ -> {:error, :epipe}
    end
  end

  defp out_request(conn, ch, type, {:put_chars, enc, m, f, a}), do: out_request(conn, ch, type, {:put_chars, enc, apply(m, f, a)})
  defp out_request(conn, ch, type, {:requests, reqs}), do: Enum.reduce_while(reqs, :ok, fn r, _ -> case out_request(conn, ch, type, r) do :ok -> {:cont, :ok}; e -> {:halt, e} end end)
  defp out_request(_, _, _, :getopts), do: [binary: true, encoding: :unicode]
  defp out_request(_, _, _, {:setopts, _}), do: :ok
  defp out_request(_, _, _, _), do: {:error, :enotsup}
end
