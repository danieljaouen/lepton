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
      known_hosts: Enum.map(known, &expand(&1, home, host))
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
  unknown host key), `:timeout`. Returns `{:ok, conn, settings}` or
  `{:error, message}`.
  """
  def connect(target, opts \\ []) do
    home = home(opts)
    {user, host} = split_target(target)
    cfg = config(host, home)
    user = user || opts[:user] || cfg.user || "root"
    port = opts[:port] || cfg.port
    files = (opts[:identity] || []) ++ cfg.identity_files
    loaded = for f <- Enum.uniq(files), File.exists?(f), do: {f, load_key(f)}
    keys = for {_, {:ok, k}} <- loaded, do: k
    start()

    private = [host: cfg.hostname, keys: keys, known: cfg.known_hosts, strict: opts[:strict] || cfg.strict, ask: opts[:on_unknown], caller: self()]

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

    case :ssh.connect(String.to_charlist(cfg.hostname), port, ssh_opts, opts[:timeout] || 30_000) do
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
