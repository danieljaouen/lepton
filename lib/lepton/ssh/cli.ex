defmodule Lepton.SSH.CLI do
  @moduledoc "The `ssh`, `ssh-keygen` and `ssh-keyscan` commands (see `Lepton.SSH`)."

  alias Lepton.{Ctx, IO, Keys, SSH, TTY}

  # -- ssh -----------------------------------------------------------------------------------

  @ssh_usage "usage: ssh [-p PORT] [-i KEY] [-l USER] [-o StrictHostKeyChecking=VALUE] [-T|-t] DESTINATION [COMMAND...]"

  def ssh(args, ctx) do
    case ssh_args(args, %{}) do
      {:ok, opts, [dest | command]} -> ssh_run(ctx, dest, Enum.join(command, " "), opts)
      _ -> IO.err(ctx, @ssh_usage); 255
    end
  end

  # Options come before the destination; everything after it is the command.
  defp ssh_args([flag, v | rest], o) when flag in ~w(-p -i -l -o), do: ssh_args(rest, Map.update(o, flag, [v], &(&1 ++ [v])))
  defp ssh_args([flag | rest], o) when flag in ~w(-T -t -q -v -n -A -x -4 -6), do: ssh_args(rest, Map.put(o, flag, true))
  defp ssh_args(["-" <> _ = flag | _], _o), do: {:error, flag}
  defp ssh_args(rest, o), do: {:ok, o, rest}

  defp ssh_run(ctx, dest, command, o) do
    {user, host} = SSH.split_target(dest)
    strict = for "StrictHostKeyChecking=" <> v <- o["-o"] || [], do: String.downcase(v)

    copts = [
      home: Ctx.home(ctx),
      user: List.last(o["-l"] || [nil]),
      port: o["-p"] && String.to_integer(List.last(o["-p"])),
      identity: Enum.map(o["-i"] || [], &Ctx.path(ctx, &1)),
      on_unknown: if(ctx.tty, do: &confirm_host(ctx, &1, &2))
    ]

    copts = if strict != [], do: [{:strict, List.last(strict)} | copts], else: copts
    target = if user, do: "#{user}@#{host}", else: host

    case SSH.connect(target, copts) do
      {:ok, conn, cfg} ->
        try do
          pty? = terminal?(ctx) and !o["-T"] and (command == "" or o["-t"] == true)
          session(ctx, conn, command, pty?, cfg)
        after
          SSH.close(conn)
        end

      {:error, msg} ->
        IO.err(ctx, msg)
        255
    end
  end

  # Asked from the connection process while the key exchange waits.
  defp confirm_host(ctx, name, key) do
    IO.write(ctx.stderr, """
    The authenticity of host '#{name}' can't be established.
    #{SSH.kind(key)} key fingerprint is #{SSH.fingerprint(key)}.
    Are you sure you want to continue connecting (yes/no)? \
    """)

    case IO.read_line(ctx.stdin) do
      line when is_binary(line) ->
        if String.trim(line) in ["yes", "y"] do
          IO.err(ctx, "Warning: Permanently added '#{name}' (#{SSH.kind(key)}) to the list of known hosts.")
          true
        else
          false
        end

      _ ->
        false
    end
  end

  defp session(ctx, conn, command, pty?, cfg) do
    {:ok, ch} = :ssh_connection.session_channel(conn, 30_000)

    if pty? do
      tty = ctx.tty
      {rows, cols} = TTY.size(tty)
      :ssh_connection.ptty_alloc(conn, ch, [term: String.to_charlist(TTY.term(tty)), width: cols, height: rows], 30_000)
      if start(conn, ch, command) do
        status = interactive(ctx, conn, ch)
        IO.err(ctx, "Connection to #{cfg.hostname} closed.")
        status
      else
        IO.err(ctx, "ssh: the server refused the request")
        255
      end
    else
      if start(conn, ch, command) do
        send_stdin(ctx, conn, ch)
        stream(ctx, conn, ch, nil)
      else
        IO.err(ctx, "ssh: the server refused the request")
        255
      end
    end
  end

  # Start a shell or a command on the channel; true once the server agrees.
  defp start(conn, ch, ""), do: :ssh_connection.shell(conn, ch) == :ok
  defp start(conn, ch, command), do: :ssh_connection.exec(conn, ch, String.to_charlist(command), 30_000) == :success

  defp terminal?(ctx), do: ctx.tty != nil and TTY.tty?(ctx.stdin)

  # Piped input goes to the remote command; a terminal's does not (as -n).
  defp send_stdin(ctx, conn, ch) do
    if ctx.stdin != nil and not TTY.tty?(ctx.stdin) do
      data = IO.read_all(ctx.stdin)
      if data != "", do: :ssh_connection.send(conn, ch, data)
    end

    :ssh_connection.send_eof(conn, ch)
  end

  defp stream(ctx, conn, ch, status) do
    receive do
      {:ssh_cm, ^conn, {:data, ^ch, type, data}} ->
        :ssh_connection.adjust_window(conn, ch, byte_size(data))
        IO.write(if(type == 1, do: ctx.stderr, else: ctx.stdout), data)
        stream(ctx, conn, ch, status)

      {:ssh_cm, ^conn, {:exit_status, ^ch, s}} -> stream(ctx, conn, ch, s)
      {:ssh_cm, ^conn, {:closed, ^ch}} -> status || 0
      {:ssh_cm, ^conn, _} -> stream(ctx, conn, ch, status)
    end
  end

  # A remote terminal session: keys go to the server as bytes, its output
  # to the terminal; `~.` at the start of a line disconnects (as OpenSSH).
  defp interactive(ctx, conn, ch) do
    tty = ctx.tty
    TTY.set_mode(tty, :raw)
    me = self()
    reader = spawn_link(fn -> read_keys(tty, me) end)

    try do
      remote_loop(conn, ch, tty, :line_start, nil)
    after
      send(reader, :stop)
      TTY.set_mode(tty, :cooked)
    end
  end

  defp read_keys(tty, owner) do
    receive do
      :stop -> :ok
    after
      0 ->
        case TTY.read_key(tty, 200) do
          :timeout -> :ok
          key -> send(owner, {:ssh_key, key})
        end

        read_keys(tty, owner)
    end
  end

  defp remote_loop(conn, ch, tty, esc, status) do
    receive do
      {:ssh_cm, ^conn, {:data, ^ch, _type, data}} ->
        :ssh_connection.adjust_window(conn, ch, byte_size(data))
        TTY.write(tty, data)
        remote_loop(conn, ch, tty, esc, status)

      {:ssh_cm, ^conn, {:exit_status, ^ch, s}} -> remote_loop(conn, ch, tty, esc, s)
      {:ssh_cm, ^conn, {:closed, ^ch}} -> status || 0
      {:ssh_cm, ^conn, _} -> remote_loop(conn, ch, tty, esc, status)

      {:ssh_key, {:resize, rows, cols}} ->
        :ssh_connection.window_change(conn, ch, cols, rows)
        remote_loop(conn, ch, tty, esc, status)

      {:ssh_key, {:cpr, _, _}} ->
        remote_loop(conn, ch, tty, esc, status)

      {:ssh_key, key} ->
        case {esc, key} do
          {:tilde, "."} ->
            TTY.write(tty, "\r\n")
            status || 255

          {:line_start, "~"} ->
            remote_loop(conn, ch, tty, :tilde, status)

          {:tilde, "~"} ->
            :ssh_connection.send(conn, ch, "~")
            remote_loop(conn, ch, tty, :other, status)

          {:tilde, key} ->
            :ssh_connection.send(conn, ch, "~" <> Keys.encode(key))
            remote_loop(conn, ch, tty, next_esc(key), status)

          {_, key} ->
            :ssh_connection.send(conn, ch, Keys.encode(key))
            remote_loop(conn, ch, tty, next_esc(key), status)
        end
    end
  end

  defp next_esc(key) when key in ["RET", "C-j", "C-m"], do: :line_start
  defp next_esc(_), do: :other

  # -- ssh-keygen ------------------------------------------------------------------------------

  def keygen(args, ctx) do
    {opts, _} = Lepton.Args.getopt(args, "t:f:C:N:lyqR:b:")
    home = Ctx.home(ctx)
    file = if opts["f"], do: Ctx.path(ctx, opts["f"]), else: Path.join(home, ".ssh/id_ed25519")

    cond do
      opts["R"] -> remove_host(ctx, opts["R"], if(opts["f"], do: file, else: Path.join(home, ".ssh/known_hosts")))
      opts["l"] -> show_key(ctx, file, :fingerprint)
      opts["y"] -> show_key(ctx, file, :public)
      opts["t"] not in [nil, "ed25519"] -> fail(ctx, "ssh-keygen: only ed25519 keys can be generated (-t ed25519)")
      opts["N"] not in [nil, "", true] -> fail(ctx, "ssh-keygen: passphrases are not supported; leave -N empty")
      true -> generate(ctx, file, opts["C"] || default_comment(), opts["q"])
    end
  end

  defp generate(ctx, file, comment, quiet) do
    if File.exists?(file) and not overwrite?(ctx, file) do
      1
    else
      key = SSH.generate()
      pub = SSH.public(key)
      File.mkdir_p!(Path.dirname(file))
      File.chmod(Path.dirname(file), 0o700)
      File.write!(file, SSH.encode_private(key, comment))
      File.chmod!(file, 0o600)
      File.write!(file <> ".pub", SSH.public_line(pub, comment) <> "\n")

      unless quiet do
        IO.puts(ctx, """
        Generated an ed25519 key pair.
        Your identification has been saved in #{Ctx.tildify(ctx, file)}
        Your public key has been saved in #{Ctx.tildify(ctx, file)}.pub
        The key fingerprint is:
        #{SSH.fingerprint(pub)} #{comment}
        Add it to GitHub with: gh ssh-key add #{Ctx.tildify(ctx, file)}.pub\
        """)
      end

      0
    end
  end

  defp overwrite?(ctx, file) do
    if ctx.tty do
      IO.write(ctx.stderr, "#{Ctx.tildify(ctx, file)} already exists.\nOverwrite (y/n)? ")

      case IO.read_line(ctx.stdin) do
        line when is_binary(line) -> String.trim(line) in ["y", "yes"]
        _ -> false
      end
    else
      IO.err(ctx, "#{Ctx.tildify(ctx, file)} already exists.")
      false
    end
  end

  defp default_comment do
    host =
      case File.read("/etc/hostname") do
        {:ok, h} when h != "" -> String.trim(h)
        _ -> :inet.gethostname() |> elem(1) |> to_string()
      end

    "root@" <> host
  end

  defp show_key(ctx, file, what) do
    pub_file = if String.ends_with?(file, ".pub"), do: file, else: file <> ".pub"

    loaded =
      cond do
        what == :fingerprint and File.exists?(pub_file) -> read_public(pub_file)
        String.ends_with?(file, ".pub") -> read_public(file)
        true -> with {:ok, k} <- SSH.load_key(file), do: {:ok, SSH.public(k), comment_of(pub_file)}
      end

    case {loaded, what} do
      {{:ok, pub, comment}, :public} -> IO.puts(ctx, SSH.public_line(pub, comment)); 0
      {{:ok, pub, comment}, :fingerprint} -> IO.puts(ctx, "#{bits(pub)} #{SSH.fingerprint(pub)} #{comment} (#{SSH.kind(pub)})"); 0
      {{:error, :enoent}, _} -> fail(ctx, "ssh-keygen: #{Ctx.tildify(ctx, file)}: No such file or directory")
      {{:error, e}, _} -> fail(ctx, "ssh-keygen: #{e}")
    end
  end

  defp read_public(file) do
    with {:ok, text} <- File.read(file) do
      case :ssh_file.decode(text, :openssh_key) do
        [{pub, attrs} | _] -> {:ok, pub, to_string(attrs[:comment] || "")}
        _ -> {:error, "#{file} is not a public key"}
      end
    end
  end

  defp comment_of(pub_file) do
    case read_public(pub_file) do
      {:ok, _, c} -> c
      _ -> ""
    end
  end

  defp bits(pub) do
    case SSH.type(pub) do
      "ssh-ed25519" -> 256
      "ecdsa-sha2-nistp" <> n -> String.to_integer(n)
      _ ->
        case pub do
          {:RSAPublicKey, n, _} -> byte_size(:binary.encode_unsigned(n)) * 8
          _ -> 0
        end
    end
  end

  defp remove_host(ctx, host, file) do
    case File.read(file) do
      {:ok, text} ->
        lines = String.split(text, "\n", trim: true)
        {gone, kept} = Enum.split_with(lines, &SSH.known_line_for?(&1, host))
        File.write!(file, Enum.map_join(kept, &(&1 <> "\n")))
        IO.puts(ctx, if(gone == [], do: "Host #{host} not found in #{Ctx.tildify(ctx, file)}", else: "# Host #{host} found\n#{Ctx.tildify(ctx, file)} updated."))
        0

      _ ->
        fail(ctx, "ssh-keygen: #{Ctx.tildify(ctx, file)}: No such file or directory")
    end
  end

  # -- ssh-keyscan --------------------------------------------------------------------------------

  def keyscan(args, ctx) do
    {opts, hosts} = Lepton.Args.getopt(args, "p:t:H")
    port = Lepton.Args.int(opts, "p", 22)
    types = if opts["t"], do: String.split(opts["t"], ","), else: nil

    if hosts == [] do
      IO.err(ctx, "usage: ssh-keyscan [-p PORT] [-t ed25519,ecdsa,rsa] HOST...")
      1
    else
      results =
        for host <- hosts do
          case SSH.scan(host, port) do
            {:ok, keys} ->
              for key <- keys, types == nil or short_type(key) in types,
                  do: IO.puts(ctx, "#{SSH.host_name(host, port)} #{SSH.public_line(key)}")

              :ok

            {:error, e} ->
              IO.err(ctx, "ssh-keyscan: #{e}")
              :error
          end
        end

      if :error in results, do: 1, else: 0
    end
  end

  defp short_type(key) do
    case SSH.type(key) do
      "ssh-ed25519" -> "ed25519"
      "ecdsa-" <> _ -> "ecdsa"
      "ssh-rsa" -> "rsa"
      t -> t
    end
  end

  defp fail(ctx, msg), do: (IO.err(ctx, msg); 1)
end
