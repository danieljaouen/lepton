defmodule Lepton.Proxy do
  @moduledoc """
  Internet proxies: one, or a chain of them, for everything Lepton
  connects to.

  A proxy is `http://[user:pass@]host:port` (HTTP CONNECT, as most
  corporate proxies), `socks5://` (names resolved here) or `socks5h://`
  (resolved by the proxy, as Tor needs), `socks4://` or `socks4a://`.
  A chain goes through each in turn, as proxychains does: Lepton connects
  to the first, asks it for the second, and so on, then the destination.

  The system's chain is set with `proxy set` (kept in
  `/var/lib/lepton/proxy`) and applies to every connection: web (curl,
  www, git and gh, lpm, apps, Firefox) and SSH. For one command, the
  usual variables win: `https_proxy`/`http_proxy` for the web,
  `all_proxy` for anything; `no_proxy` lists hosts reached directly
  (by default `localhost`, `127.0.0.1`, `::1` and `.local` names).

  The web clients (OTP's `httpc`, and Firefox) speak to proxies only by
  HTTP, so for them a forwarder on 127.0.0.1 takes requests and makes
  each connection through the chain (`httpc_profile/2`).
  """

  use GenServer

  defmodule Hop do
    @moduledoc false
    defstruct [:scheme, :host, :port, :user, :pass, remote_dns: false]
  end

  @default_no_proxy ["localhost", "127.0.0.1", "::1", ".local"]

  # -- configuration ------------------------------------------------------------------------

  defp path, do: Lepton.Persist.state_path("proxy")

  @doc "The system setting: `%{chain: [url], no_proxy: [pattern]}`."
  def system do
    case File.read(path()) do
      {:ok, text} ->
        lines = String.split(text, "\n", trim: true)
        chain = for "proxy " <> url <- lines, do: String.trim(url)
        no = for "no_proxy " <> list <- lines, item <- split_list(list), do: item
        %{chain: chain, no_proxy: if(Enum.any?(lines, &String.starts_with?(&1, "no_proxy ")), do: no, else: @default_no_proxy)}

      _ ->
        %{chain: [], no_proxy: @default_no_proxy}
    end
  end

  @doc "Set the system chain (`[]` for none) and, optionally, the hosts reached directly."
  def set(chain, no_proxy \\ nil) do
    with :ok <- Enum.reduce_while(chain, :ok, fn u, _ -> case parse(u) do {:ok, _} -> {:cont, :ok}; e -> {:halt, e} end end) do
      no = no_proxy || system().no_proxy
      text = Enum.map_join(chain, "", &"proxy #{&1}\n") <> "no_proxy #{Enum.join(no, ",")}\n"
      File.mkdir_p!(Path.dirname(path()))
      File.write!(path(), text)
      File.chmod(path(), 0o600)
      :ok
    end
  end

  defp split_list(s), do: s |> String.split([",", " "], trim: true)

  @doc "Parse a proxy URL into a hop."
  def parse(url) do
    case URI.parse(if String.contains?(url, "://"), do: url, else: "http://" <> url) do
      %URI{scheme: scheme, host: host, port: port, userinfo: info} when is_binary(host) and host != "" ->
        {user, pass} =
          case info && String.split(info, ":", parts: 2) do
            nil -> {nil, nil}
            [u] -> {URI.decode(u), ""}
            [u, p] -> {URI.decode(u), URI.decode(p)}
          end

        case scheme do
          "http" -> {:ok, %Hop{scheme: :http, host: host, port: explicit_port(url, port, 3128), user: user, pass: pass}}
          s when s in ["socks5", "socks5h", "socks"] -> {:ok, %Hop{scheme: :socks5, host: host, port: explicit_port(url, port, 1080), user: user, pass: pass, remote_dns: s != "socks5"}}
          s when s in ["socks4", "socks4a"] -> {:ok, %Hop{scheme: :socks4, host: host, port: explicit_port(url, port, 1080), user: user, remote_dns: s == "socks4a"}}
          s -> {:error, "#{url}: proxies are http://, socks5://, socks5h://, socks4:// or socks4a:// (not #{s}://)"}
        end

      _ ->
        {:error, "#{url}: not a proxy address (http://host:port, socks5://host:port)"}
    end
  end

  # URI fills in http's port 80; a proxy's default is 3128 (SOCKS: 1080).
  defp explicit_port(url, port, default) do
    if Regex.match?(~r/^(?:[a-z0-9]+:\/\/)?(?:[^@\/]*@)?(?:\[[^\]]+\]|[^:\/]+):\d+(?:\/|$)/i, url), do: port, else: default
  end

  @doc "A hop as a URL, the password hidden."
  def show(%Hop{} = h) do
    scheme = case h do
      %{scheme: :http} -> "http"
      %{scheme: :socks5, remote_dns: true} -> "socks5h"
      %{scheme: :socks5} -> "socks5"
      %{scheme: :socks4, remote_dns: true} -> "socks4a"
      %{scheme: :socks4} -> "socks4"
    end

    user = if h.user, do: "#{h.user}#{if h.pass not in [nil, ""], do: ":***"}@", else: ""
    "#{scheme}://#{user}#{h.host}:#{h.port}"
  end

  # -- which chain ------------------------------------------------------------------------------

  @doc """
  The hops to reach `host` for `kind` (`:http`, `:https` or `:tcp`), with
  the environment `env` (a command's): `[]` means directly.
  """
  def chain(host, kind, env \\ %{}) do
    sys = system()
    no = case var(env, "no_proxy") do
      nil -> sys.no_proxy
      v -> split_list(v)
    end

    cond do
      direct?(host, no) ->
        []

      url = env_proxy(env, kind) ->
        case parse(url) do
          {:ok, hop} -> [hop]
          _ -> []
        end

      true ->
        for u <- sys.chain, {:ok, hop} <- [parse(u)], do: hop
    end
  end

  defp env_proxy(env, :http), do: var(env, "http_proxy") || var(env, "all_proxy")
  defp env_proxy(env, :https), do: var(env, "https_proxy") || var(env, "all_proxy")
  defp env_proxy(env, :tcp), do: var(env, "all_proxy")

  defp var(env, name) do
    v = Map.get(env || %{}, name) || Map.get(env || %{}, String.upcase(name))
    if v in [nil, ""], do: nil, else: v
  end

  @doc "Is `host` reached directly (`no_proxy` patterns: names, `.domain`, `*`, addresses)?"
  def direct?(host, patterns) do
    host = String.downcase(host |> String.trim_leading("[") |> String.trim_trailing("]"))

    Enum.any?(patterns, fn p ->
        p = String.downcase(String.trim(p))
        p == "*" or host == String.trim_leading(p, ".") or String.ends_with?(host, "." <> String.trim_leading(p, "."))
      end)
  end

  # -- connecting -------------------------------------------------------------------------------

  @doc """
  A TCP connection to `host`:`port` through `hops` (directly when there
  are none): `{:ok, socket}` (binary, passive, owned by the caller) or
  `{:error, message}`.
  """
  def connect(host, port, hops, timeout \\ 20_000)

  def connect(host, port, [], timeout) do
    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false, packet: :raw, exit_on_close: false], timeout) do
      {:ok, s} -> {:ok, s}
      {:error, r} -> {:error, "connect to #{host} port #{port}: #{:inet.format_error(r)}"}
    end
  end

  def connect(host, port, [first | _] = hops, timeout) do
    with {:ok, sock} <- tcp(first.host, first.port, timeout) do
      targets = Enum.map(tl(hops), &{&1.host, &1.port}) ++ [{host, port}]

      result =
        hops
        |> Enum.zip(targets)
        |> Enum.reduce_while(:ok, fn {hop, {h, p}}, :ok ->
          case handshake(sock, hop, h, p, timeout) do
            :ok -> {:cont, :ok}
            {:error, why} -> {:halt, {:error, "proxy #{show(hop)} could not reach #{h}:#{p}: #{why}"}}
          end
        end)

      case result do
        :ok -> {:ok, sock}
        e -> (:gen_tcp.close(sock); e)
      end
    end
  end

  defp tcp(host, port, timeout) do
    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false, packet: :raw, exit_on_close: false], timeout) do
      {:ok, s} -> {:ok, s}
      {:error, r} -> {:error, "cannot reach the proxy #{host}:#{port}: #{:inet.format_error(r)}"}
    end
  end

  # HTTP CONNECT
  defp handshake(sock, %Hop{scheme: :http} = hop, host, port, timeout) do
    auth = if hop.user, do: "Proxy-Authorization: Basic #{Base.encode64("#{hop.user}:#{hop.pass}")}\r\n", else: ""
    target = if String.contains?(host, ":"), do: "[#{host}]:#{port}", else: "#{host}:#{port}"
    :ok = :gen_tcp.send(sock, "CONNECT #{target} HTTP/1.1\r\nHost: #{target}\r\n#{auth}\r\n")

    with {:ok, head} <- read_head(sock, "", timeout) do
      case Regex.run(~r/^HTTP\/1\.[01] (\d{3})([^\r\n]*)/, head) do
        [_, "200", _] -> :ok
        [_, "407", _] -> {:error, "the proxy wants a user name and password (407)"}
        [_, code, text] -> {:error, "HTTP #{code}#{text}"}
        _ -> {:error, "not an HTTP proxy"}
      end
    end
  end

  # SOCKS5 (RFC 1928), with user/password (RFC 1929)
  defp handshake(sock, %Hop{scheme: :socks5} = hop, host, port, timeout) do
    methods = if hop.user, do: <<0, 2>>, else: <<0>>
    :ok = :gen_tcp.send(sock, <<5, byte_size(methods)>> <> methods)

    with {:ok, <<5, method>>} <- :gen_tcp.recv(sock, 2, timeout),
         :ok <- socks5_auth(sock, hop, method, timeout),
         {:ok, addr} <- socks5_addr(host, hop.remote_dns),
         :ok <- :gen_tcp.send(sock, <<5, 1, 0>> <> addr <> <<port::16>>),
         {:ok, <<5, rep, 0, atyp>>} <- :gen_tcp.recv(sock, 4, timeout),
         :ok <- if(rep == 0, do: :ok, else: {:error, socks5_error(rep)}),
         {:ok, _} <- skip_bound(sock, atyp, timeout) do
      :ok
    else
      {:ok, <<5, 0xFF>>} -> {:error, "no acceptable authentication (does it need a user name and password?)"}
      {:ok, _} -> {:error, "not a SOCKS5 proxy"}
      {:error, r} when is_atom(r) -> {:error, :inet.format_error(r)}
      {:error, _} = e -> e
    end
  end

  # SOCKS4, and 4a (the name resolved by the proxy)
  defp handshake(sock, %Hop{scheme: :socks4} = hop, host, port, timeout) do
    user = hop.user || ""

    request =
      case :inet.parse_ipv4_address(String.to_charlist(host)) do
        {:ok, {a, b, c, d}} -> {:ok, <<4, 1, port::16, a, b, c, d>> <> user <> <<0>>}
        _ when hop.remote_dns -> {:ok, <<4, 1, port::16, 0, 0, 0, 1>> <> user <> <<0>> <> host <> <<0>>}
        _ ->
          case :inet.getaddr(String.to_charlist(host), :inet) do
            {:ok, {a, b, c, d}} -> {:ok, <<4, 1, port::16, a, b, c, d>> <> user <> <<0>>}
            {:error, r} -> {:error, "cannot resolve #{host}: #{r}"}
          end
      end

    with {:ok, req} <- request,
         :ok <- :gen_tcp.send(sock, req),
         {:ok, <<0, status, _::binary-6>>} <- :gen_tcp.recv(sock, 8, timeout) do
      if status == 0x5A, do: :ok, else: {:error, "refused (SOCKS4 status #{status})"}
    else
      {:error, r} when is_atom(r) -> {:error, :inet.format_error(r)}
      {:error, _} = e -> e
      _ -> {:error, "not a SOCKS4 proxy"}
    end
  end

  defp socks5_auth(_sock, _hop, 0, _timeout), do: :ok

  defp socks5_auth(sock, hop, 2, timeout) do
    u = hop.user || ""
    p = hop.pass || ""
    :ok = :gen_tcp.send(sock, <<1, byte_size(u)>> <> u <> <<byte_size(p)>> <> p)

    case :gen_tcp.recv(sock, 2, timeout) do
      {:ok, <<1, 0>>} -> :ok
      {:ok, _} -> {:error, "user name or password refused"}
      e -> e
    end
  end

  defp socks5_auth(_sock, _hop, m, _), do: {:error, "unsupported authentication method #{m}"}

  defp socks5_addr(host, remote_dns) do
    charlist = String.to_charlist(host)

    case {:inet.parse_ipv4_address(charlist), :inet.parse_ipv6_address(charlist)} do
      {{:ok, {a, b, c, d}}, _} -> {:ok, <<1, a, b, c, d>>}
      {_, {:ok, v6}} -> {:ok, <<4>> <> for(w <- Tuple.to_list(v6), into: <<>>, do: <<w::16>>)}
      _ when remote_dns -> {:ok, <<3, byte_size(host)>> <> host}
      _ ->
        case :inet.getaddr(charlist, :inet) do
          {:ok, {a, b, c, d}} -> {:ok, <<1, a, b, c, d>>}
          {:error, r} -> {:error, "cannot resolve #{host}: #{r}"}
        end
    end
  end

  defp skip_bound(sock, 1, t), do: :gen_tcp.recv(sock, 6, t)
  defp skip_bound(sock, 4, t), do: :gen_tcp.recv(sock, 18, t)
  defp skip_bound(sock, 3, t), do: with({:ok, <<n>>} <- :gen_tcp.recv(sock, 1, t), do: :gen_tcp.recv(sock, n + 2, t))
  defp skip_bound(_, _, _), do: {:error, "bad SOCKS5 reply"}

  @socks5_errors %{1 => "general failure", 2 => "not allowed by its rules", 3 => "network unreachable", 4 => "host unreachable",
                   5 => "connection refused", 6 => "TTL expired", 7 => "command not supported", 8 => "address type not supported"}
  defp socks5_error(rep), do: Map.get(@socks5_errors, rep, "error #{rep}")

  # The HTTP head, a byte at a time (nothing after it may be consumed).
  defp read_head(sock, acc, timeout) do
    cond do
      String.ends_with?(acc, "\r\n\r\n") -> {:ok, acc}
      byte_size(acc) > 16_384 -> {:error, "reply too long"}
      true ->
        case :gen_tcp.recv(sock, 1, timeout) do
          {:ok, b} -> read_head(sock, acc <> b, timeout)
          {:error, r} -> {:error, :inet.format_error(r)}
        end
    end
  end

  # -- the web: a forwarder for httpc and Firefox ------------------------------------------------

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def child_spec(arg), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}}

  @doc """
  The `httpc` profile for `url`, with a command's environment: `:default`
  (directly) or one whose proxy is a forwarder for the chain.
  """
  def httpc_profile(url, env \\ %{}) do
    uri = URI.parse(url)
    kind = if uri.scheme == "https", do: :https, else: :http

    case chain(uri.host || "", kind, env) do
      [] -> :default
      hops -> forwarder(hops, env) |> elem(1)
    end
  end

  @doc """
  The variables a native program (Firefox) needs to use the proxy:
  `http_proxy`, `https_proxy` and `no_proxy` pointing at a forwarder, or
  none when there is no proxy.
  """
  def app_env(env \\ %{}) do
    case chain("example.com", :https, env) do
      [] ->
        %{}

      hops ->
        {port, _} = forwarder(hops, env)
        url = "http://127.0.0.1:#{port}"
        no = Enum.join(system().no_proxy, ",")
        %{"http_proxy" => url, "https_proxy" => url, "HTTP_PROXY" => url, "HTTPS_PROXY" => url, "no_proxy" => no, "NO_PROXY" => no}
    end
  end

  # {port, httpc profile} of the forwarder for `hops` (started on first use).
  defp forwarder(hops, env) do
    no = case var(env, "no_proxy") do
      nil -> system().no_proxy
      v -> split_list(v)
    end

    unless Process.whereis(__MODULE__), do: GenServer.start(__MODULE__, nil, name: __MODULE__)
    GenServer.call(__MODULE__, {:forwarder, hops, no}, 30_000)
  end

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:forwarder, hops, no}, _from, st) do
    key = {hops, no}

    case st do
      %{^key => found} ->
        {:reply, found, st}

      _ ->
        {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, exit_on_close: false, reuseaddr: true, ip: {127, 0, 0, 1}])
        {:ok, port} = :inet.port(listen)
        spawn_link(fn -> accept(listen, hops, no) end)
        profile = :"lepton_proxy_#{port}"
        :inets.start()
        _ = :inets.start(:httpc, profile: profile)
        :ok = :httpc.set_options([proxy: {{~c"127.0.0.1", port}, []}, https_proxy: {{~c"127.0.0.1", port}, []}], profile)
        {:reply, {port, profile}, Map.put(st, key, {port, profile})}
    end
  end

  defp accept(listen, hops, no) do
    case :gen_tcp.accept(listen) do
      {:ok, client} ->
        pid = spawn(fn -> receive do: (:go -> serve(client, hops, no)) end)
        :gen_tcp.controlling_process(client, pid)
        send(pid, :go)
        accept(listen, hops, no)

      {:error, _} ->
        :ok
    end
  end

  # One client connection: `CONNECT host:port` (HTTPS), or a plain HTTP
  # request with an absolute URL, sent on with `Connection: close`.
  defp serve(client, hops, no) do
    with {:ok, head} <- read_head(client, "", 30_000),
         [request_line | headers] <- String.split(head, "\r\n") do
      case String.split(request_line, " ") do
        ["CONNECT", target, _] ->
          {host, port} = host_port(target, 443)

          case upstream(host, port, hops, no) do
            {:ok, server} ->
              :gen_tcp.send(client, "HTTP/1.1 200 Connection established\r\n\r\n")
              splice(client, server)

            {:error, msg} ->
              :gen_tcp.send(client, "HTTP/1.1 502 Bad Gateway\r\ncontent-type: text/plain\r\ncontent-length: #{byte_size(msg)}\r\nconnection: close\r\n\r\n#{msg}")
              :gen_tcp.close(client)
          end

        [method, "http://" <> _ = url, version] ->
          uri = URI.parse(url)
          path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")

          kept =
            Enum.reject(headers, fn h -> String.downcase(h) =~ ~r/^(connection|proxy-connection|keep-alive|proxy-authorization):/ or h == "" end)

          case upstream(uri.host, uri.port || 80, hops, no) do
            {:ok, server} ->
              :gen_tcp.send(server, Enum.join(["#{method} #{path} #{version}" | kept] ++ ["Connection: close", "", ""], "\r\n"))
              splice(client, server)

            {:error, msg} ->
              :gen_tcp.send(client, "HTTP/1.1 502 Bad Gateway\r\ncontent-length: #{byte_size(msg)}\r\nconnection: close\r\n\r\n#{msg}")
              :gen_tcp.close(client)
          end

        _ ->
          :gen_tcp.send(client, "HTTP/1.1 400 Bad Request\r\nconnection: close\r\ncontent-length: 0\r\n\r\n")
          :gen_tcp.close(client)
      end
    else
      _ -> :gen_tcp.close(client)
    end
  end

  defp upstream(host, port, hops, no) do
    if direct?(host, no), do: connect(host, port, []), else: connect(host, port, hops)
  end

  defp host_port(target, default) do
    case Regex.run(~r/^\[?([^\]]+?)\]?(?::(\d+))?$/, target) do
      [_, h, p] -> {h, String.to_integer(p)}
      [_, h] -> {h, default}
      _ -> {target, default}
    end
  end

  @doc "Copy bytes both ways between two sockets until either closes."
  def splice(a, b) do
    me = self()
    # The other direction reads `b` once it owns it.
    other = spawn(fn -> receive do: (:go -> pump(b, a)); send(me, :done) end)
    :gen_tcp.controlling_process(b, other)
    send(other, :go)
    pump(a, b)
    # The other direction may still be answering (a client that
    # half-closed); give it time to finish.
    receive do: (:done -> :ok), after: (60_000 -> Process.exit(other, :kill))
    :gen_tcp.close(a)
    :gen_tcp.close(b)
    :ok
  end

  defp pump(from, to) do
    case :gen_tcp.recv(from, 0) do
      {:ok, data} ->
        case :gen_tcp.send(to, data) do
          :ok -> pump(from, to)
          _ -> :gen_tcp.shutdown(from, :read)
        end

      {:error, _} ->
        :gen_tcp.shutdown(to, :write)
    end
  end
end
