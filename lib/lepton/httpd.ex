defmodule Lepton.HTTPD do
  @moduledoc """
  `httpd`: a web server, for files and in front of web apps (as nginx is
  in front of Phoenix).

  Each **site** is chosen by the request's host name (`*` for any) and
  either serves a directory (`root`) or passes requests on to an app
  (`proxy`, as `http://127.0.0.1:4000`), adding `X-Forwarded-For`,
  `-Proto`, `-Host` and `-Port` (which Phoenix's `Plug.RewriteOn` reads).
  A WebSocket (Phoenix's LiveView and channels) is passed through as it
  is: the upgrade, then bytes both ways until either side closes.

  It listens on `port` (HTTP) and, with `tls_port`, HTTPS, the
  certificate chosen by the name the browser asks for (SNI): the site's
  `cert`/`key`, else one kept by `Lepton.Certs` for that name. With
  `redirect_https`, plain HTTP is sent to HTTPS, except Let's Encrypt's
  challenges (`/.well-known/acme-challenge/`), which every site answers
  from `Lepton.Certs.challenge_dir/0`.
  """

  alias Lepton.Certs

  defstruct port: 8080, tls_port: nil, redirect_https: false, sites: [], log: nil, cert: nil, key: nil

  @types %{
    ".html" => "text/html; charset=utf-8", ".htm" => "text/html; charset=utf-8", ".css" => "text/css", ".js" => "text/javascript",
    ".mjs" => "text/javascript", ".json" => "application/json", ".txt" => "text/plain; charset=utf-8", ".md" => "text/plain; charset=utf-8",
    ".png" => "image/png", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg", ".gif" => "image/gif", ".svg" => "image/svg+xml",
    ".ico" => "image/x-icon", ".webp" => "image/webp", ".woff" => "font/woff", ".woff2" => "font/woff2", ".pdf" => "application/pdf",
    ".wasm" => "application/wasm", ".xml" => "application/xml", ".mp4" => "video/mp4", ".webm" => "video/webm"
  }

  # -- configuration -----------------------------------------------------------------------------

  @doc """
  The configuration in a TOML file:

      port = 80
      tls_port = 443
      redirect_https = true

      [site.myapp]
      host = "myapp.example.com"
      proxy = "http://127.0.0.1:4000"

      [site.files]
      host = "*"
      root = "/srv/www"
  """
  def config(path) do
    with {:ok, text} <- File.read(path) do
      t = Lepton.TOML.parse(text)

      sites =
        for {_name, s} <- Enum.sort(t["site"] || %{}) do
          %{host: s["host"] || "*", root: s["root"] && Path.expand(s["root"]), proxy: s["proxy"], cert: s["cert"], key: s["key"]}
        end

      {:ok, %__MODULE__{port: int(t["port"], 8080), tls_port: t["tls_port"] && int(t["tls_port"], 443), redirect_https: t["redirect_https"] == true, sites: sites}}
    end
  end

  defp int(v, _) when is_integer(v), do: v
  defp int(v, d) when is_binary(v), do: (case Integer.parse(v) do {n, _} -> n; :error -> d end)
  defp int(_, d), do: d

  # -- running ------------------------------------------------------------------------------------

  @doc "Start the listeners: `{:ok, %{http: port, https: port}}` (the ports really bound)."
  def start(%__MODULE__{} = cfg) do
    log = cfg.log || fn _ -> :ok end
    cfg = %{cfg | log: log}

    with {:ok, http} <- listen_tcp(cfg.port),
         {:ok, tls} <- if(cfg.tls_port, do: listen_tls(cfg), else: {:ok, nil}) do
      {:ok, http_port} = :inet.port(http)
      https_port = if tls, do: elem(elem(:ssl.sockname(tls), 1), 1)
      cfg = %{cfg | port: http_port, tls_port: https_port}
      spawn_link(fn -> accept(:gen_tcp, http, cfg, false) end)
      if tls, do: spawn_link(fn -> accept(:ssl, tls, cfg, true) end)
      {:ok, %{http: http_port, https: https_port}}
    end
  end

  defp listen_tcp(port) do
    :gen_tcp.listen(port, [:binary, active: false, packet: :raw, reuseaddr: true, exit_on_close: false, backlog: 128])
  end

  defp listen_tls(cfg) do
    default = cfg.cert && cfg.key && [certfile: String.to_charlist(cfg.cert), keyfile: String.to_charlist(cfg.key)]

    sni = fn host ->
      case cert_for(cfg, to_string(host)) do
        {c, k} -> [certfile: String.to_charlist(c), keyfile: String.to_charlist(k)]
        nil -> default || :undefined
      end
    end

    # Without a default certificate a client that sends no name (an IP
    # address) is refused; the first certificate kept serves it.
    fallback =
      default ||
        case Certs.list() do
          [c | _] -> [certfile: String.to_charlist(Path.join(Certs.dir(), c.name <> ".crt")), keyfile: String.to_charlist(Path.join(Certs.dir(), c.name <> ".key"))]
          [] -> []
        end

    :ssl.listen(cfg.tls_port, [:binary, active: false, packet: :raw, reuseaddr: true, versions: [:"tlsv1.3", :"tlsv1.2"],
      alpn_preferred_protocols: ["http/1.1"], sni_fun: sni] ++ fallback)
  end

  defp cert_for(cfg, host) do
    case site(cfg, host) do
      %{cert: c, key: k} when is_binary(c) and is_binary(k) -> {c, k}
      _ -> Certs.lookup(host)
    end
  end

  @doc "Run until told to stop (the `httpd` command). Returns 0."
  def run(cfg) do
    Process.flag(:trap_exit, true)

    case start(cfg) do
      {:ok, ports} ->
        cfg.log.("httpd: http on port #{ports.http}" <> if(ports.https, do: ", https on port #{ports.https}", else: ""))
        for s <- cfg.sites, do: cfg.log.("httpd: #{s.host} -> #{s.proxy || s.root}")
        send(self(), :renew)
        wait(cfg)

      {:error, reason} ->
        cfg.log.("httpd: cannot listen: #{inspect(reason)}")
        1
    end
  end

  # Let's Encrypt's certificates last 90 days: twice a day, those within
  # 30 days of expiry are renewed (httpd answers the challenge), and TLS
  # picks up the new files.
  @renew_every 12 * 3600 * 1000

  defp wait(cfg) do
    receive do
      {:signal, s} when s in [:term, :int] -> 0
      {:EXIT, _, reason} -> cfg.log.("httpd: stopped: #{inspect(reason)}"); 1
      :renew ->
        me = self()
        spawn(fn -> send(me, {:renewed, Certs.renew(30)}) end)
        Process.send_after(self(), :renew, @renew_every)
        wait(cfg)

      {:renewed, results} ->
        for {name, r} <- results, do: cfg.log.("httpd: certificate #{name}: " <> if(match?({:ok, _}, r), do: "renewed", else: "not renewed: #{elem(r, 1)}"))
        if results != [], do: :ssl.clear_pem_cache()
        wait(cfg)

      _ ->
        wait(cfg)
    end
  end

  defp accept(mod, listen, cfg, tls?) do
    result = if mod == :ssl, do: :ssl.transport_accept(listen), else: :gen_tcp.accept(listen)

    case result do
      {:ok, sock} ->
        pid = spawn(fn -> receive do: (:go -> connection({mod, sock}, cfg, tls?)) end)
        mod.controlling_process(sock, pid)
        send(pid, :go)
        accept(mod, listen, cfg, tls?)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        accept(mod, listen, cfg, tls?)
    end
  end

  # -- one connection ------------------------------------------------------------------------------

  defp connection({:ssl, sock}, cfg, true) do
    case :ssl.handshake(sock, 15_000) do
      {:ok, sock} -> requests({:ssl, sock}, cfg, true)
      _ -> :ssl.close(sock)
    end
  end

  defp connection(conn, cfg, tls?), do: requests(conn, cfg, tls?)

  defp requests(conn, cfg, tls?) do
    case read_request(conn) do
      {:ok, req} ->
        case handle(conn, req, cfg, tls?) do
          :keep_alive -> requests(conn, cfg, tls?)
          :close -> close(conn)
        end

      _ ->
        close(conn)
    end
  end

  defp read_request(conn) do
    setopts(conn, packet: :http_bin)

    case recv(conn, 0, 60_000) do
      {:ok, {:http_request, method, target, version}} ->
        path =
          case target do
            {:abs_path, p} -> p
            {:absoluteURI, _, _, _, p} -> p
            :* -> "*"
            other -> to_string(other)
          end

        with {:ok, headers} <- read_headers(conn, []) do
          setopts(conn, packet: :raw)
          map = Map.new(headers, fn {k, v} -> {String.downcase(k), v} end)
          {:ok, %{method: to_string(method), path: path, version: version, headers: headers, h: map}}
        end

      _ ->
        :error
    end
  end

  defp read_headers(conn, acc) do
    case recv(conn, 0, 30_000) do
      {:ok, {:http_header, _, name, _, value}} -> read_headers(conn, [{to_string(name), value} | acc])
      {:ok, :http_eoh} -> {:ok, Enum.reverse(acc)}
      _ -> :error
    end
  end

  defp handle(conn, req, cfg, tls?) do
    host = (req.h["host"] || "") |> String.split(":") |> hd() |> String.downcase()
    site = site(cfg, host)

    cond do
      String.starts_with?(req.path, "/.well-known/acme-challenge/") and challenge(conn, req, cfg) ->
        :close

      cfg.redirect_https and not tls? and cfg.tls_port != nil ->
        port = if cfg.tls_port == 443, do: "", else: ":#{cfg.tls_port}"
        respond(conn, req, cfg, 301, [{"Location", "https://#{host}#{port}#{req.path}"}], "")
        :close

      site == nil ->
        respond(conn, req, cfg, 404, [], "no site for #{host}\n")
        :close

      site.proxy ->
        proxy(conn, req, site, cfg, tls?)
        :close

      site.root ->
        static(conn, req, site.root, cfg)

      true ->
        respond(conn, req, cfg, 404, [], "")
        :close
    end
  end

  @doc false
  def site(cfg, host) do
    Enum.find(cfg.sites, &(String.downcase(&1.host) == host)) ||
      Enum.find(cfg.sites, &(String.starts_with?(&1.host, "*.") and String.ends_with?(host, String.trim_leading(&1.host, "*")))) ||
      Enum.find(cfg.sites, &(&1.host == "*"))
  end

  # Let's Encrypt's HTTP-01 challenge: the key authorization Lepton.Certs left.
  defp challenge(conn, req, cfg) do
    token = req.path |> String.split("/") |> List.last() |> String.split("?") |> hd()

    if Regex.match?(~r/^[A-Za-z0-9_-]+$/, token) do
      case File.read(Path.join(Certs.challenge_dir(), token)) do
        {:ok, body} -> respond(conn, req, cfg, 200, [{"Content-Type", "application/octet-stream"}], body); true
        _ -> false
      end
    else
      false
    end
  end

  # -- files ---------------------------------------------------------------------------------------

  defp static(conn, req, root, cfg) do
    path = req.path |> String.split("?") |> hd() |> URI.decode()
    parts = String.split(path, "/", trim: true)

    cond do
      req.method not in ["GET", "HEAD"] ->
        respond(conn, req, cfg, 405, [{"Allow", "GET, HEAD"}], "")
        :close

      ".." in parts ->
        respond(conn, req, cfg, 403, [], "")
        :close

      true ->
        full = Path.join([root | parts])

        cond do
          File.dir?(full) and not String.ends_with?(path, "/") ->
            respond(conn, req, cfg, 301, [{"Location", path <> "/"}], "")
            keep(req)

          File.regular?(Path.join(full, "index.html")) ->
            send_file(conn, req, Path.join(full, "index.html"), cfg)

          File.regular?(full) ->
            send_file(conn, req, full, cfg)

          true ->
            respond(conn, req, cfg, 404, [{"Content-Type", "text/plain"}], "not found\n")
            keep(req)
        end
    end
  end

  defp send_file(conn, req, file, cfg) do
    %{size: size, mtime: mtime} = File.stat!(file, time: :posix)
    type = Map.get(@types, String.downcase(Path.extname(file)), "application/octet-stream")
    modified = mtime |> DateTime.from_unix!() |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
    headers = [{"Content-Type", type}, {"Content-Length", to_string(size)}, {"Last-Modified", modified}]
    send_data(conn, head(200, headers ++ connection_header(req)))
    log(cfg, conn, req, 200)

    if req.method == "GET" do
      {:ok, f} = :file.open(file, [:read, :raw, :binary])

      try do
        copy_file(conn, f)
      after
        :file.close(f)
      end
    end

    keep(req)
  end

  defp copy_file(conn, f) do
    case :file.read(f, 65_536) do
      {:ok, data} -> send_data(conn, data); copy_file(conn, f)
      _ -> :ok
    end
  end

  defp keep(req) do
    close? = String.downcase(req.h["connection"] || "") == "close" or req.version == {1, 0}
    if close?, do: :close, else: :keep_alive
  end

  defp connection_header(req), do: if(keep(req) == :close, do: [{"Connection", "close"}], else: [])

  # -- the proxy ---------------------------------------------------------------------------------------

  @hop ~w(connection keep-alive proxy-connection te trailer upgrade proxy-authorization)

  defp proxy(conn, req, site, cfg, tls?) do
    uri = URI.parse(site.proxy)
    websocket? = String.downcase(req.h["upgrade"] || "") == "websocket"

    case :gen_tcp.connect(String.to_charlist(uri.host), uri.port || 80, [:binary, active: false, packet: :raw, exit_on_close: false], 10_000) do
      {:ok, up} ->
        {client_ip, _} = peer(conn)
        forwarded_for = Enum.join(Enum.reject([req.h["x-forwarded-for"], client_ip], &is_nil/1), ", ")
        kept = Enum.reject(req.headers, fn {k, _} -> String.downcase(k) in @hop or String.downcase(k) |> String.starts_with?("x-forwarded-") end)
        port = if tls?, do: cfg.tls_port, else: cfg.port

        extra =
          [{"X-Forwarded-For", forwarded_for}, {"X-Forwarded-Proto", if(tls?, do: "https", else: "http")},
           {"X-Forwarded-Host", req.h["host"] || ""}, {"X-Forwarded-Port", to_string(port)}] ++
            if(websocket?, do: [{"Connection", "Upgrade"}, {"Upgrade", req.h["upgrade"]}], else: [{"Connection", "close"}])

        prefix = if uri.path in [nil, "", "/"], do: "", else: String.trim_trailing(uri.path, "/")
        :gen_tcp.send(up, ["#{req.method} #{prefix}#{req.path} HTTP/1.1\r\n", Enum.map(kept ++ extra, fn {k, v} -> "#{k}: #{v}\r\n" end), "\r\n"])

        # The request's body, as it came (length or chunks).
        cond do
          String.downcase(req.h["transfer-encoding"] || "") == "chunked" -> relay_chunks(conn, up)
          len = req.h["content-length"] -> relay_bytes(conn, up, String.to_integer(len))
          true -> :ok
        end

        case read_head(up, "") do
          {:ok, head, rest} ->
            status = head |> String.split(" ", parts: 3) |> Enum.at(1, "502") |> String.to_integer()
            log(cfg, conn, req, status)

            if status == 101 do
              send_data(conn, [head, rest])
              splice(conn, {:gen_tcp, up})
            else
              # One request per upstream connection: tell the client so too.
              send_data(conn, [close_head(head), rest])
              copy_until_closed({:gen_tcp, up}, conn)
              :gen_tcp.close(up)
            end

          :error ->
            :gen_tcp.close(up)
            respond(conn, req, cfg, 502, [{"Content-Type", "text/plain"}], "the app didn't answer\n")
        end

      {:error, reason} ->
        respond(conn, req, cfg, 502, [{"Content-Type", "text/plain"}], "the app at #{site.proxy} isn't answering (#{:inet.format_error(reason)})\n")
    end
  end

  # A response head with `Connection: close` in place of whatever was there.
  defp close_head(head) do
    [status | lines] = head |> String.trim_trailing("\r\n\r\n") |> String.split("\r\n")
    kept = Enum.reject(lines, &(String.downcase(&1) =~ ~r/^(connection|keep-alive):/))
    Enum.join([status | kept] ++ ["Connection: close", "", ""], "\r\n")
  end

  defp read_head(sock, acc) do
    case :binary.match(acc, "\r\n\r\n") do
      {i, 4} -> {:ok, binary_part(acc, 0, i + 4), binary_part(acc, i + 4, byte_size(acc) - i - 4)}
      :nomatch ->
        case :gen_tcp.recv(sock, 0, 60_000) do
          {:ok, data} when byte_size(acc) < 65_536 -> read_head(sock, acc <> data)
          _ -> :error
        end
    end
  end

  defp relay_bytes(_conn, _up, 0), do: :ok

  defp relay_bytes(conn, up, n) do
    case recv(conn, min(n, 65_536), 60_000) do
      {:ok, data} -> :gen_tcp.send(up, data); relay_bytes(conn, up, n - byte_size(data))
      _ -> :error
    end
  end

  # Chunks are passed on as they are (sizes and all).
  defp relay_chunks(conn, up) do
    setopts(conn, packet: :line)

    case recv(conn, 0, 60_000) do
      {:ok, line} ->
        :gen_tcp.send(up, line)
        {size, _} = Integer.parse(String.trim(line), 16)
        setopts(conn, packet: :raw)

        if size == 0 do
          trailers(conn, up)
        else
          relay_bytes(conn, up, size + 2)
          relay_chunks(conn, up)
        end

      _ ->
        :error
    end
  end

  defp trailers(conn, up) do
    setopts(conn, packet: :line)

    case recv(conn, 0, 30_000) do
      {:ok, line} when line in ["\r\n", "\n"] -> :gen_tcp.send(up, line); setopts(conn, packet: :raw)
      {:ok, line} -> :gen_tcp.send(up, line); trailers(conn, up)
      _ -> setopts(conn, packet: :raw)
    end
  end

  defp copy_until_closed({mod, from}, to) do
    case mod.recv(from, 0, 300_000) do
      {:ok, data} -> send_data(to, data); copy_until_closed({mod, from}, to)
      _ -> :ok
    end
  end

  # Both ways, until either side closes (a WebSocket).
  defp splice({cmod, c} = client, {umod, u} = upstream) do
    me = self()
    other = spawn(fn -> receive do: (:go -> pump(upstream, client)); send(me, :done) end)
    umod.controlling_process(u, other)
    send(other, :go)
    pump(client, upstream)

    receive do
      :done -> :ok
    after
      5_000 -> Process.exit(other, :kill)
    end

    cmod.close(c)
    umod.close(u)
  end

  defp pump({fmod, f}, {tmod, t}) do
    case fmod.recv(f, 0, :infinity) do
      {:ok, data} ->
        case tmod.send(t, data) do
          :ok -> pump({fmod, f}, {tmod, t})
          _ -> :ok
        end

      _ ->
        tmod.close(t)
    end
  end

  # -- responses -----------------------------------------------------------------------------------

  @reasons %{101 => "Switching Protocols", 200 => "OK", 301 => "Moved Permanently", 400 => "Bad Request", 403 => "Forbidden", 404 => "Not Found",
             405 => "Method Not Allowed", 502 => "Bad Gateway"}

  defp head(status, headers) do
    ["HTTP/1.1 #{status} #{@reasons[status] || ""}\r\n", "Server: Lepton httpd\r\n", Enum.map(headers, fn {k, v} -> "#{k}: #{v}\r\n" end), "\r\n"]
  end

  defp respond(conn, req, cfg, status, headers, body) do
    body = if req.method == "HEAD", do: "", else: body
    headers = if List.keymember?(headers, "Content-Type", 0), do: headers, else: [{"Content-Type", "text/plain; charset=utf-8"} | headers]
    send_data(conn, [head(status, headers ++ [{"Content-Length", to_string(byte_size(body))}] ++ connection_header(req)), body])
    log(cfg, conn, req, status)
  end

  defp log(cfg, conn, req, status) do
    {ip, _} = peer(conn)
    cfg.log.("#{ip} \"#{req.method} #{req.path}\" #{status} #{req.h["host"] || "-"}")
  end

  defp peer({mod, sock}) do
    peername = if mod == :ssl, do: :ssl.peername(sock), else: :inet.peername(sock)

    case peername do
      {:ok, {ip, port}} -> {to_string(:inet.ntoa(ip)), port}
      _ -> {"-", 0}
    end
  end

  defp recv({mod, s}, n, t), do: mod.recv(s, n, t)
  defp send_data({mod, s}, data), do: mod.send(s, data)
  defp setopts({:ssl, s}, o), do: :ssl.setopts(s, o)
  defp setopts({:gen_tcp, s}, o), do: :inet.setopts(s, o)
  defp close({mod, s}), do: mod.close(s)
end
