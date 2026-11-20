defmodule Lepton.SSH do
  @moduledoc """
  SSH client support on OTP's `:ssh`: the user's keys and `~/.ssh/config`,
  known hosts, and connections for `ssh`, `ssh-keyscan` and git's SSH
  transport (`git@github.com:OWNER/REPO.git`).

  Keys: `~/.ssh/id_ed25519`, `id_ecdsa` and `id_rsa` (or the `IdentityFile`s
  from `~/.ssh/config`) in OpenSSH format, without a passphrase: OTP cannot
  decrypt bcrypt-protected OpenSSH keys. `ssh-keygen` writes ed25519 keys.

  Known hosts: the `UserKnownHostsFile`s (default `~/.ssh/known_hosts`,
  plain or hashed entries), `/etc/ssh/ssh_known_hosts`, and GitHub's
  published host keys, built in. A changed key is always refused; an
  unknown host is refused unless `StrictHostKeyChecking` is `accept-new` or
  `no`, or the caller's `:on_unknown` function accepts it (`ssh` asks on a
  terminal, like OpenSSH).
  """

  alias Lepton.SSH.KeyCb

  @pinned_path Path.expand("../../rootfs/etc/ssh/ssh_known_hosts", __DIR__)
  @external_resource @pinned_path
  @pinned File.read!(@pinned_path)

  @default_ids ~w(id_ed25519 id_ecdsa id_rsa)
  @ed25519 {1, 3, 101, 112}

  def home(opts \\ []), do: opts[:home] || System.get_env("HOME") || "/root"

  # -- ~/.ssh/config ---------------------------------------------------------------------

  @doc "The settings for `host` from `~/.ssh/config`, with OpenSSH's defaults."
  def config(host, home) do
    blocks = parse_config(read(Path.join(home, ".ssh/config")))
    matching = for {patterns, kvs} <- blocks, host_match?(host, patterns), kv <- kvs, do: kv
    # The first value obtained wins, except for IdentityFile, which adds up.
    first = Enum.reduce(matching, %{}, fn {k, v}, acc -> Map.put_new(acc, k, v) end)
    ids = for {"identityfile", v} <- matching, do: expand(v, home, host)
    known = String.split(first["userknownhostsfile"] || "~/.ssh/known_hosts")

    %{
      host: host,
      hostname: String.replace(first["hostname"] || host, "%h", host),
      user: first["user"],
      port: String.to_integer(first["port"] || "22"),
      identity_files: if(ids == [], do: Enum.map(@default_ids, &Path.join([home, ".ssh", &1])), else: ids),
      strict: String.downcase(first["stricthostkeychecking"] || "ask"),
      known_hosts: Enum.map(known, &expand(&1, home, host)),
      proxy_jump: first["proxyjump"],
      proxy_command: first["proxycommand"]
    }
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> text
      _ -> ""
    end
  end

  # [{host patterns, [{keyword, value}]}]; settings before any `Host` apply
  # to every host, and `Match` blocks (unsupported) to none.
  defp parse_config(text) do
    text
    |> String.split("\n")
    |> Enum.reduce([{["*"], []}], fn line, [{pats, kvs} | done] = blocks ->
      case Regex.run(~r/^\s*([A-Za-z]+)\s*(?:=\s*|\s+)(.+?)\s*$/, line) do
        [_, k, v] ->
          case String.downcase(k) do
            "host" -> [{String.split(v), []} | blocks]
            "match" -> [{[], []} | blocks]
            k -> [{pats, [{k, String.trim(v, "\"")} | kvs]} | done]
          end

        nil ->
          blocks
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn {pats, kvs} -> {pats, Enum.reverse(kvs)} end)
  end

  defp expand(path, home, host) do
    path |> String.replace("%d", home) |> String.replace("%h", host) |> String.replace(~r/^~(?=\/|$)/, home)
  end

  @doc "Does `host` match an OpenSSH pattern list (`*`, `?`, `!negation`)?"
  def host_match?(host, patterns) do
    {neg, pos} = Enum.split_with(patterns, &String.starts_with?(&1, "!"))
    Enum.any?(pos, &glob?(host, &1)) and not Enum.any?(neg, &glob?(host, String.trim_leading(&1, "!")))
  end

  defp glob?(host, pattern) do
    re = pattern |> Regex.escape() |> String.replace("\\*", ".*") |> String.replace("\\?", ".")
    Regex.match?(~r/^#{re}$/i, host)
  end

  # -- keys ----------------------------------------------------------------------------------

  @doc "Read a private key (OpenSSH or PEM format, no passphrase)."
  def load_key(path) do
    with {:ok, pem} <- File.read(path) do
      if encrypted?(pem) do
        {:error, "#{path} is protected by a passphrase, which Lepton cannot decrypt; create a key here with ssh-keygen"}
      else
        try do
          case :ssh_file.decode_ssh_file(:private, :any, pem, :ignore) do
            {:ok, [{key, _} | _]} -> {:ok, key}
            _ -> {:error, "#{path}: not a private key Lepton can read"}
          end
        catch
          _, _ -> {:error, "#{path}: not a private key Lepton can read"}
        end
      end
    end
  end

  defp encrypted?(pem) do
    body = pem |> String.split("\n") |> Enum.reject(&String.starts_with?(&1, "-----")) |> Enum.join()

    case Base.decode64(body, ignore: :whitespace) do
      {:ok, <<"openssh-key-v1", 0, n::32, cipher::binary-size(n), _::binary>>} -> cipher != "none"
      _ -> String.contains?(pem, "ENCRYPTED")
    end
  end

  @doc "A new ed25519 key pair."
  def generate, do: :public_key.generate_key({:namedCurve, :ed25519})

  @doc "An ed25519 private key in OpenSSH's `openssh-key-v1` format (no passphrase)."
  def encode_private({:ECPrivateKey, _, priv, {:namedCurve, @ed25519}, pub, _}, comment) do
    # OTP's own encoder writes a 32-byte private part; OpenSSH expects the
    # 64-byte seed || public key.
    check = :crypto.strong_rand_bytes(4)
    secret = check <> check <> str("ssh-ed25519") <> str(pub) <> str(priv <> pub) <> str(comment)
    secret = secret <> pad(byte_size(secret))
    data = "openssh-key-v1\0" <> str("none") <> str("none") <> str("") <> <<1::32>> <> str(str("ssh-ed25519") <> str(pub)) <> str(secret)
    body = ~r/.{1,70}/ |> Regex.scan(Base.encode64(data)) |> Enum.map_join(&(hd(&1) <> "\n"))
    "-----BEGIN OPENSSH PRIVATE KEY-----\n" <> body <> "-----END OPENSSH PRIVATE KEY-----\n"
  end

  defp str(bin), do: <<byte_size(bin)::32, bin::binary>>
  defp pad(n), do: for(i <- 1..rem(8 - rem(n, 8), 8)//1, into: "", do: <<i>>)

  @doc "The public half of a private key."
  def public(priv), do: :ssh_file.extract_public_key(priv)

  def blob(pub), do: :ssh_file.encode(pub, :ssh2_pubkey)

  @doc "The key's SSH type name, e.g. `ssh-ed25519`."
  def type(pub) do
    <<n::32, name::binary-size(n), _::binary>> = blob(pub)
    name
  end

  @doc "A public key as an `authorized_keys` / `.pub` line."
  def public_line(pub, comment \\ ""), do: String.trim_trailing("#{type(pub)} #{Base.encode64(blob(pub))} #{comment}")

  def fingerprint(pub), do: "SHA256:" <> Base.encode64(:crypto.hash(:sha256, blob(pub)), padding: false)

  @doc "Short key kind for messages, e.g. `ED25519`."
  def kind(pub) do
    case type(pub) do
      "ssh-ed25519" -> "ED25519"
      "ecdsa-" <> _ -> "ECDSA"
      "ssh-rsa" -> "RSA"
      t -> t
    end
  end

  @doc "Can private key `key` sign with public-key algorithm `alg`?"
  def signs?(key, alg) do
    :ssh_transport.valid_key_sha_alg(:private, key, alg)
  catch
    _, _ -> false
  end

  # -- known hosts ------------------------------------------------------------------------------

  @doc "The name a host is recorded under: `host`, or `[host]:port`."
  def host_name(host, 22), do: host
  def host_name(host, port), do: "[#{host}]:#{port}"

  @doc "Known-host entries `{patterns, key}` from `files`, the system file and the built-in keys."
  def known_entries(files) do
    texts = for f <- files ++ ["/etc/ssh/ssh_known_hosts"], {:ok, t} <- [File.read(f)], do: t

    for text <- texts ++ [@pinned], line <- String.split(text, "\n"), entry = parse_known(line), entry != nil, do: entry
  end

  defp parse_known(line) do
    case String.split(String.trim(line)) do
      # @cert-authority and @revoked lines are not supported; skipping a
      # @revoked line means its key is simply not trusted.
      ["@" <> _ | _] -> nil
      ["#" <> _ | _] -> nil
      [hosts, _type, b64 | _] ->
        with {:ok, blob} <- Base.decode64(b64),
             {:ok, key} <- decode_blob(blob) do
          {String.split(hosts, ","), key}
        else
          _ -> nil
        end

      _ -> nil
    end
  end

  defp decode_blob(blob) do
    {:ok, :ssh_file.decode(blob, :ssh2_pubkey)}
  catch
    _, _ -> :error
  end

  @doc "Is `key` the known key for `host`? `:known`, `:changed` or `:unknown`."
  def host_key_status(host, port, key, files) do
    name = host_name(host, port)
    keys = for {patterns, k} <- known_entries(files), known_match?(name, patterns), do: k

    cond do
      key in keys -> :known
      Enum.any?(keys, &(type(&1) == type(key))) -> :changed
      true -> :unknown
    end
  end

  @doc "Is a `known_hosts` line about `host` (`ssh-keygen -R`)?"
  def known_line_for?(line, host) do
    case String.split(String.trim(line)) do
      ["@" <> _, hosts | _] -> known_match?(host, String.split(hosts, ","))
      [hosts, _ | _] -> known_match?(host, String.split(hosts, ","))
      _ -> false
    end
  end

  defp known_match?(name, patterns) do
    {neg, pos} = Enum.split_with(patterns, &String.starts_with?(&1, "!"))
    Enum.any?(pos, &known_pattern?(name, &1)) and not Enum.any?(neg, &known_pattern?(name, String.trim_leading(&1, "!")))
  end

  # Hashed entries: |1|base64(salt)|base64(HMAC-SHA1(salt, name)).
  defp known_pattern?(name, "|1|" <> rest) do
    with [salt, hash] <- String.split(rest, "|"),
         {:ok, salt} <- Base.decode64(salt),
         {:ok, hash} <- Base.decode64(hash) do
      :crypto.mac(:hmac, :sha, salt, name) == hash
    else
      _ -> false
    end
  end

  defp known_pattern?(name, pattern), do: glob?(name, pattern)

  @doc "Record `key` for `host` in the known-hosts file `file`."
  def add_known_host(file, host, port, key) do
    File.mkdir_p!(Path.dirname(file))
    File.chmod(Path.dirname(file), 0o700)
    text = read(file)
    prefix = if text != "" and not String.ends_with?(text, "\n"), do: "\n", else: ""
    File.write!(file, prefix <> "#{host_name(host, port)} #{public_line(key)}\n", [:append])
  end

  # -- connections ---------------------------------------------------------------------------------

  @doc """
  Connect to `target` (`[user@]host`, a `~/.ssh/config` alias or address).

  Options: `:home`, `:port`, `:user`, `:identity` (key files, before the
  configured ones), `:strict` (overrides `StrictHostKeyChecking`), `:on_unknown` (`fn host, key -> boolean`, asked about an
  unknown host key), `:timeout`, `:jump` (`ssh -J`: hosts to go through),
  `:proxy_command`, `:env` (for `all_proxy`). Returns `{:ok, conn,
  settings}` or `{:error, message}`.

  The way there, first that applies: a ProxyCommand (`-o ProxyCommand=`
  or `~/.ssh/config`), a ProxyJump chain (`-J` or the config: each host
  reached through the one before, over SSH), the proxy chain
  (`Lepton.Proxy`), or directly. `none` turns either off for a host.
  """
  def connect(target, opts \\ []) do
    home = home(opts)
    {user, host} = split_target(target)
    cfg = config(host, home)
    cfg = %{cfg | proxy_jump: opts[:jump] || cfg.proxy_jump, proxy_command: opts[:proxy_command] || cfg.proxy_command}
    user = user || opts[:user] || cfg.user || "root"
    port = opts[:port] || cfg.port
    files = (opts[:identity] || []) ++ cfg.identity_files
    loaded = for f <- Enum.uniq(files), File.exists?(f), do: {f, load_key(f)}
    keys = for {_, {:ok, k}} <- loaded, do: k
    start()

    # The real port: through a tunnel, OTP sees a local one.
    private = [host: cfg.hostname, port: port, keys: keys, known: cfg.known_hosts, strict: opts[:strict] || cfg.strict, ask: opts[:on_unknown], caller: self()]

    ssh_opts = [
      user: String.to_charlist(user),
      user_dir: String.to_charlist(Path.join(home, ".ssh")),
      key_cb: {KeyCb, private},
      auth_methods: ~c"publickey",
      user_interaction: false,
      silently_accept_hosts: false,
      save_accepted_host: false,
      quiet_mode: true,
      disconnectfun: &quiet/1,
      connect_timeout: opts[:timeout] || 20_000
    ]

    # Every other way ends at a port on 127.0.0.1 (OTP's ssh hangs when
    # handed a connected socket, so it always connects by address).
    result =
      case way(cfg, user, port, opts) do
        :direct -> :ssh.connect(String.to_charlist(cfg.hostname), port, ssh_opts, opts[:timeout] || 30_000)
        {:local, lport, cleanup} -> with_cleanup(:ssh.connect(~c"127.0.0.1", lport, ssh_opts, opts[:timeout] || 30_000), cleanup)
        {:error, msg} -> {:error, {:proxy, msg}}
      end

    case result do
      {:error, {:proxy, msg}} ->
        {:error, msg}

      {:ok, conn} ->
        {:ok, conn, %{cfg | user: user, port: port}}

      {:error, reason} ->
        receive do
          {:lepton_ssh_host_key, status, name, key} -> {:error, host_key_error(status, name, key)}
        after
          0 -> {:error, connect_error(reason, user, cfg.hostname, port, loaded)}
        end
    end
  end

  # -- the way there: ProxyCommand, ProxyJump, a proxy chain, or directly ------------------

  defp way(cfg, user, port, opts) do
    cond do
      cfg.proxy_command not in [nil, "none"] -> proxy_command(cfg.proxy_command, cfg, user, port, opts)
      cfg.proxy_jump not in [nil, "none"] -> jump(cfg.proxy_jump, cfg.hostname, port, opts)
      true ->
        case Lepton.Proxy.chain(cfg.hostname, :tcp, opts[:env] || %{}) do
          [] -> :direct
          hops -> with {:ok, sock} <- Lepton.Proxy.connect(cfg.hostname, port, hops), do: relay(sock)
        end
    end
  end

  # When the connection ends, so do the hops it went through.
  defp with_cleanup({:ok, conn} = ok, cleanup) do
    spawn(fn ->
      ref = Process.monitor(conn)
      receive do: ({:DOWN, ^ref, _, _, _} -> cleanup.())
    end)

    ok
  end

  defp with_cleanup(error, cleanup), do: (cleanup.(); error)

  # ProxyJump a,b,c: connect to c through a and b, then open a tunnel from
  # c to the destination.
  defp jump(spec, host, port, opts) do
    hops = String.split(spec, ",", trim: true)
    {last, before} = List.pop_at(hops, -1)
    {jump_target, jump_port} = jump_spec(last)
    jopts = opts |> Keyword.drop([:jump, :proxy_command, :port, :user, :identity]) |> Keyword.put(:jump, if(before == [], do: "none", else: Enum.join(before, ",")))
    jopts = if jump_port, do: Keyword.put(jopts, :port, jump_port), else: jopts

    case connect(jump_target, jopts) do
      {:ok, jconn, jcfg} ->
        case tunnel_first(jconn, host, port, 3, 3000) do
          {:ok, sock, first} when first != "" -> relay(sock, first, fn -> close(jconn) end)
          {:ok, sock, ""} -> (:gen_tcp.close(sock); close(jconn); {:error, "#{jcfg.hostname}: no SSH server answered at #{host}:#{port}"})
          {:error, msg} -> (close(jconn); {:error, "#{jcfg.hostname}: #{msg}"})
        end

      {:error, msg} ->
        {:error, "jump host #{last}: #{msg}"}
    end
  end

  # user@host:port in -J
  defp jump_spec(spec) do
    case Regex.run(~r/^(.*?)(?::(\d+))?$/, spec) do
      [_, t, p] -> {t, String.to_integer(p)}
      [_, t] -> {t, nil}
    end
  end

  @doc """
  A TCP connection through an SSH connection's server (`direct-tcpip`,
  like `ssh -W`): a local socket whose bytes reach `host`:`port`.
  """
  def tunnel(conn, host, port) do
    with {:ok, lport} <- tunnel_port(conn, host, port) do
      case :gen_tcp.connect({127, 0, 0, 1}, lport, [:binary, active: false, packet: :raw, exit_on_close: false], 15_000) do
        {:ok, sock} -> {:ok, sock}
        {:error, r} -> {:error, "tunnel: #{:inet.format_error(r)}"}
      end
    end
  end

  @doc """
  A tunnel, and the first data from its far end: `{:ok, sock, first}`.
  OTP's tunnels sometimes lose what the far end sends first (an SSH
  server's greeting), so when nothing comes within `timeout` a new
  tunnel is opened, up to `tries` times; after that `first` is "" (a
  server that waits for the client to speak).
  """
  def tunnel_first(conn, host, port, tries, timeout) do
    with {:ok, sock} <- tunnel(conn, host, port) do
      case :gen_tcp.recv(sock, 0, timeout) do
        {:ok, data} -> {:ok, sock, data}
        {:error, :timeout} when tries > 1 -> (:gen_tcp.close(sock); tunnel_first(conn, host, port, tries - 1, timeout))
        {:error, :timeout} -> {:ok, sock, ""}
        {:error, r} -> (:gen_tcp.close(sock); {:error, "tunnel to #{host}:#{port}: #{:inet.format_error(r)}"})
      end
    end
  end

  # The local port of a tunnel through `conn` to host:port.
  defp tunnel_port(conn, host, port) do
    # OTP loads its forwarding modules on first use, and the very first
    # tunnel then loses the data that arrives meanwhile: load them first.
    for m <- [:ssh_tcpip_forward_client, :ssh_tcpip_forward_acceptor, :ssh_tcpip_forward_acceptor_sup, :ssh_tcpip_forward_srv], do: Code.ensure_loaded(m)

    case :ssh.tcpip_tunnel_to_server(conn, ~c"127.0.0.1", 0, String.to_charlist(host), port, 15_000) do
      {:ok, lport} -> {:ok, lport}
      {:error, reason} -> {:error, "the server would not open a tunnel to #{host}:#{port} (#{inspect(reason)}; is TCP forwarding allowed there?)"}
    end
  end

  # A port on 127.0.0.1 whose one connection is joined to `sock` (after
  # `first`, the bytes already read from it).
  defp relay(sock, first \\ "", cleanup \\ fn -> :ok end) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, exit_on_close: false, ip: {127, 0, 0, 1}])
    {:ok, lport} = :inet.port(listen)

    pid =
      spawn(fn ->
        receive do: (:go -> :ok)

        case :gen_tcp.accept(listen, 30_000) do
          {:ok, c} -> :gen_tcp.close(listen); if(first != "", do: :gen_tcp.send(c, first)); Lepton.Proxy.splice(c, sock)
          _ -> :gen_tcp.close(listen); :gen_tcp.close(sock)
        end
      end)

    :gen_tcp.controlling_process(sock, pid)
    :gen_tcp.controlling_process(listen, pid)
    send(pid, :go)
    {:local, lport, fn -> Process.exit(pid, :kill); cleanup.() end}
  end

  # ProxyCommand: a command (run by Lepton's shell) whose input and output
  # are the connection; %h %p %r %n %% as in OpenSSH.
  defp proxy_command(command, cfg, user, port, opts) do
    cmd =
      Regex.replace(~r/%([hprn%])/, command, fn _, c ->
        case c do
          "h" -> cfg.hostname
          "p" -> to_string(port)
          "r" -> user
          "n" -> cfg.host
          "%" -> "%"
        end
      end)

    # ssh connects to a local port; its one connection is the command's
    # input and output.
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, exit_on_close: false, ip: {127, 0, 0, 1}])
    {:ok, lport} = :inet.port(listen)
    home = home(opts)
    env = Map.merge(%{"HOME" => home, "PATH" => "/bin"}, opts[:env] || %{})
    pid = spawn(fn -> run_proxy_command(cmd, listen, home, env) end)
    :gen_tcp.controlling_process(listen, pid)
    send(pid, :go)
    {:local, lport, fn -> Process.exit(pid, :kill) end}
  end

  defp run_proxy_command(cmd, listen, home, env) do
    receive do: (:go -> :ok)
    {:ok, sock} = :gen_tcp.accept(listen, 30_000)
    :gen_tcp.close(listen)
    {:ok, stdin} = Lepton.Pipe.open()
    out = spawn_link(fn -> socket_writer(sock) end)
    me = self()
    spawn_link(fn -> socket_reader(sock, stdin, me) end)
    Lepton.Shell.run_string(cmd, cwd: home, env: env, stdin: stdin, stdout: out, stderr: Process.group_leader())
    :gen_tcp.close(sock)
  end

  defp socket_reader(sock, pipe, _owner) do
    case :gen_tcp.recv(sock, 0) do
      {:ok, data} -> IO.binwrite(pipe, data); socket_reader(sock, pipe, nil)
      _ -> Lepton.Pipe.close_write(pipe)
    end
  end

  # An I/O server writing to the socket (the command's standard output).
  defp socket_writer(sock) do
    receive do
      {:io_request, from, reply_as, req} ->
        send(from, {:io_reply, reply_as, socket_put(sock, req)})
        socket_writer(sock)
    end
  end

  defp socket_put(sock, {:put_chars, enc, chars}) do
    data = if enc == :latin1, do: :erlang.iolist_to_binary(chars), else: :unicode.characters_to_binary(chars)
    case :gen_tcp.send(sock, data) do
      :ok -> :ok
      _ -> {:error, :epipe}
    end
  end

  defp socket_put(sock, {:put_chars, enc, m, f, a}), do: socket_put(sock, {:put_chars, enc, apply(m, f, a)})
  defp socket_put(_sock, :getopts), do: [binary: true, encoding: :unicode]
  defp socket_put(_sock, {:setopts, _}), do: :ok
  defp socket_put(_sock, _), do: {:error, :enotsup}

  @doc "Split `[user@]host`."
  def split_target(target) do
    case String.split(target, "@") |> Enum.reverse() do
      [host] -> {nil, host}
      [host | user] -> {user |> Enum.reverse() |> Enum.join("@"), host}
    end
  end

  defp host_key_error(:unknown, name, key) do
    """
    Host key verification failed: #{name} is not a known host.
    Its #{kind(key)} key fingerprint is #{fingerprint(key)}.
    To trust it, run `ssh #{name}` once and answer yes, or check the fingerprint and run
      ssh-keyscan #{name} >> ~/.ssh/known_hosts\
    """
  end

  defp host_key_error(:changed, name, key) do
    """
    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED for #{name}!
    Someone could be eavesdropping on you right now (man-in-the-middle attack),
    or the host key has just been changed. The #{kind(key)} key sent is
    #{fingerprint(key)}. Remove the old key from ~/.ssh/known_hosts once you
    have confirmed the new one.
    Host key verification failed.\
    """
  end

  defp connect_error(reason, user, host, port, loaded) do
    text = if is_list(reason), do: to_string(reason), else: inspect(reason)

    cond do
      text =~ ~r/authentication methods/i ->
        unreadable = for {_, {:error, e}} <- loaded, do: "  " <> e
        hint =
          cond do
            unreadable != [] -> "\n" <> Enum.join(unreadable, "\n")
            loaded == [] -> "\nNo SSH key found. Create one with `ssh-keygen`, then add ~/.ssh/id_ed25519.pub to GitHub with `gh ssh-key add`."
            true -> ""
          end

        "#{user}@#{host}: Permission denied (publickey)." <> hint

      text =~ "econnrefused" -> "connect to host #{host} port #{port}: Connection refused"
      text =~ "nxdomain" -> "Could not resolve hostname #{host}"
      text =~ ~r/timeout|etimedout/ -> "connect to host #{host} port #{port}: Connection timed out"
      text =~ ~r/ehostunreach|enetunreach/ -> "connect to host #{host} port #{port}: Network is unreachable"
      true -> "connect to host #{host} port #{port}: #{text}"
    end
  end

  def close(conn), do: :ssh.close(conn)

  # OTP's ssh logs every disconnect (a failed key exchange, a refused key)
  # unless a disconnect fun is set; the commands report errors themselves.
  defp quiet(_reason), do: :ok

  defp start, do: {:ok, _} = Application.ensure_all_started(:ssh)

  # -- channels ------------------------------------------------------------------------------------

  @doc "Run `command` on a new session channel. `{:ok, channel}`."
  def exec(conn, command, timeout \\ 30_000) do
    case :ssh_connection.session_channel(conn, timeout) do
      {:ok, ch} ->
        case :ssh_connection.exec(conn, ch, String.to_charlist(command), timeout) do
          :success -> {:ok, ch}
          :failure -> {:error, "the server refused to run: #{command}"}
          {:error, r} -> {:error, "ssh: #{inspect(r)}"}
        end

      {:error, r} ->
        {:error, "ssh: cannot open a session: #{inspect(r)}"}
    end
  end

  @doc """
  Receive a channel's output until `done?.(stdout)` holds (`{:ok, stdout}`)
  or the channel closes (`{:closed, stdout, stderr, exit_status}`).
  """
  def recv_until(conn, ch, done?, timeout \\ 120_000), do: recv_until(conn, ch, done?, "", "", nil, timeout)

  defp recv_until(conn, ch, done?, out, err, status, timeout) do
    receive do
      {:ssh_cm, ^conn, {:data, ^ch, type, data}} ->
        :ssh_connection.adjust_window(conn, ch, byte_size(data))

        if type == 1 do
          recv_until(conn, ch, done?, out, err <> data, status, timeout)
        else
          out = out <> data
          if done?.(out), do: {:ok, out}, else: recv_until(conn, ch, done?, out, err, status, timeout)
        end

      {:ssh_cm, ^conn, {:exit_status, ^ch, s}} -> recv_until(conn, ch, done?, out, err, s, timeout)
      {:ssh_cm, ^conn, {:closed, ^ch}} -> {:closed, out, err, status}
      {:ssh_cm, ^conn, _other} -> recv_until(conn, ch, done?, out, err, status, timeout)
    after
      timeout -> {:closed, out, err <> "ssh: timed out waiting for the server", status}
    end
  end

  @doc "Receive everything until the channel closes: `{stdout, stderr, exit_status}`."
  def recv_all(conn, ch, timeout \\ 300_000), do: recv_all(conn, ch, [], [], nil, timeout)

  defp recv_all(conn, ch, out, err, status, timeout) do
    receive do
      {:ssh_cm, ^conn, {:data, ^ch, type, data}} ->
        :ssh_connection.adjust_window(conn, ch, byte_size(data))
        if type == 1, do: recv_all(conn, ch, out, [err, data], status, timeout), else: recv_all(conn, ch, [out, data], err, status, timeout)

      {:ssh_cm, ^conn, {:exit_status, ^ch, s}} -> recv_all(conn, ch, out, err, s, timeout)
      {:ssh_cm, ^conn, {:closed, ^ch}} -> {IO.iodata_to_binary(out), IO.iodata_to_binary(err), status}
      {:ssh_cm, ^conn, _other} -> recv_all(conn, ch, out, err, status, timeout)
    after
      timeout -> {IO.iodata_to_binary(out), IO.iodata_to_binary([err, "ssh: timed out waiting for the server"]), status}
    end
  end

  @doc "Fetch a host's public keys without logging in: `{:ok, [key]}`."
  def scan(host, port \\ 22, timeout \\ 10_000) do
    start()

    algs = [:"ssh-ed25519", :"ecdsa-sha2-nistp256", :"ecdsa-sha2-nistp384", :"ecdsa-sha2-nistp521", :"rsa-sha2-512"]

    keys =
      for alg <- algs, supported_host_alg?(alg) do
        private = [host: host, keys: [], known: [], strict: "scan", ask: nil, caller: self()]
        opts = [user: ~c"lepton-keyscan", key_cb: {KeyCb, private}, user_interaction: false, silently_accept_hosts: false,
                save_accepted_host: false, quiet_mode: true, disconnectfun: &quiet/1, connect_timeout: timeout,
                preferred_algorithms: [public_key: [alg]]]

        _ = :ssh.connect(String.to_charlist(host), port, opts, timeout)

        receive do
          {:lepton_ssh_host_key, :scanned, _, key} -> key
        after
          0 -> nil
        end
      end

    case Enum.uniq(Enum.reject(keys, &is_nil/1)) do
      [] -> {:error, "#{host}: no host keys received"}
      keys -> {:ok, keys}
    end
  end

  defp supported_host_alg?(alg), do: alg in :ssh.default_algorithms()[:public_key]

  @doc "Keys built into Lepton (GitHub's), as `known_hosts` text."
  def pinned, do: @pinned
end

defmodule Lepton.SSH.KeyCb do
  @moduledoc false
  # The client key callback: host keys are checked against Lepton's known
  # hosts (Lepton.SSH.host_key_status/4) and the user's keys come from the
  # connect options rather than fixed paths.
  @behaviour :ssh_client_key_api

  alias Lepton.SSH

  @impl true
  def is_host_key(key, host, port, _alg, opts) do
    o = opts[:key_cb_private]
    # Keys are recorded under the name connected to; OTP passes the address.
    name = o[:host] || peer(host)

    if o[:strict] == "scan" do
      send(o[:caller], {:lepton_ssh_host_key, :scanned, name, key})
      {:error, :scanned}
    else
      port = o[:port] || port

      case SSH.host_key_status(name, port, key, o[:known]) do
        :known ->
          true

        :changed ->
          send(o[:caller], {:lepton_ssh_host_key, :changed, SSH.host_name(name, port), key})
          {:error, :host_key_changed}

        :unknown ->
          if accept?(o, name, port, key) do
            SSH.add_known_host(hd(o[:known]), name, port, key)
            true
          else
            send(o[:caller], {:lepton_ssh_host_key, :unknown, SSH.host_name(name, port), key})
            {:error, :host_key_unknown}
          end
      end
    end
  end

  defp accept?(o, name, port, key) do
    case o[:strict] do
      s when s in ["no", "off", "accept-new"] -> true
      s when s in ["yes", "true"] -> false
      _ -> o[:ask] != nil and o[:ask].(SSH.host_name(name, port), key) == true
    end
  end

  # OTP passes [PeerName, IP] (or just the name, from older callers).
  defp peer([name, _ip]) when is_list(name), do: to_string(name)
  defp peer([name, _ip]) when is_tuple(name), do: name |> :inet.ntoa() |> to_string()
  defp peer(name) when is_list(name), do: to_string(name)
  defp peer(name) when is_tuple(name), do: name |> :inet.ntoa() |> to_string()

  @impl true
  def add_host_key(_host, _port, _key, _opts), do: :ok

  @impl true
  def user_key(alg, opts) do
    case Enum.find(opts[:key_cb_private][:keys], &SSH.signs?(&1, alg)) do
      nil -> {:error, :no_key}
      key -> {:ok, key}
    end
  end
end
