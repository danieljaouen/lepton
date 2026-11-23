defmodule Lepton.HTTPDTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.{Certs, HTTPD}

  setup do
    state = tmp_dir("httpdstate")
    System.put_env("LEPTON_STATE_DIR", state)
    on_exit(fn -> System.delete_env("LEPTON_STATE_DIR") end)
    :ok
  end

  defp start(cfg) do
    {:ok, ports} = HTTPD.start(%{cfg | port: 0, tls_port: cfg.tls_port && 0})
    ports
  end

  # A request on a fresh connection: {status, headers (lower-case), body}.
  defp get(port, path, headers \\ [], opts \\ []) do
    {:ok, s} = connect(port, opts)
    send_(s, ["GET #{path} HTTP/1.1\r\n", Enum.map([{"Connection", "close"} | headers], fn {k, v} -> "#{k}: #{v}\r\n" end), "\r\n"])
    parse(read_all(s, ""))
  end

  defp connect(port, opts) do
    case opts[:tls] do
      nil -> :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
      tls -> :ssl.connect(~c"127.0.0.1", port, [:binary, active: false] ++ tls, 5000)
    end
  end

  defp send_(s, d) when elem(s, 0) == :sslsocket, do: :ssl.send(s, d)
  defp send_(s, d), do: :gen_tcp.send(s, d)

  defp read_all(s, acc) when elem(s, 0) == :sslsocket, do: (case :ssl.recv(s, 0, 5000) do {:ok, d} -> read_all(s, acc <> d); _ -> acc end)
  defp read_all(s, acc), do: (case :gen_tcp.recv(s, 0, 5000) do {:ok, d} -> read_all(s, acc <> d); _ -> acc end)

  defp parse(resp) do
    [head, body] = String.split(resp, "\r\n\r\n", parts: 2)
    [status | lines] = String.split(head, "\r\n")
    code = status |> String.split(" ") |> Enum.at(1) |> String.to_integer()
    {code, Map.new(lines, &(String.split(&1, ": ", parts: 2) |> then(fn [k, v] -> {String.downcase(k), v} end))), body}
  end

  # An app (as Phoenix behind a proxy): answers with what it was sent, and
  # turns a WebSocket upgrade into an echo.
  defp fake_app do
    {:ok, l} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(l)
    spawn_link(fn -> app_loop(l) end)
    "http://127.0.0.1:#{port}"
  end

  defp app_loop(l) do
    {:ok, c} = :gen_tcp.accept(l)
    pid = spawn(fn -> receive do: (:go -> app_conn(c)) end)
    :gen_tcp.controlling_process(c, pid)
    send(pid, :go)
    app_loop(l)
  end

  defp app_conn(c) do
    {head, rest} = read_head(c, "")
    [line | hs] = String.split(head, "\r\n", trim: true)
    h = Map.new(hs, &(String.split(&1, ": ", parts: 2) |> then(fn [k, v] -> {String.downcase(k), v} end)))

    if h["upgrade"] == "websocket" do
      :gen_tcp.send(c, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: x\r\n\r\n" <> rest)
      echo(c)
    else
      body = read_body(c, h, rest)
      seen = JSON.encode!(%{"line" => line, "headers" => h, "body" => body})
      :gen_tcp.send(c, "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(seen)}\r\nconnection: keep-alive\r\n\r\n" <> seen)
      :gen_tcp.close(c)
    end
  end

  defp echo(c) do
    case :gen_tcp.recv(c, 0) do
      {:ok, d} -> :gen_tcp.send(c, "echo:" <> d); echo(c)
      _ -> :ok
    end
  end

  defp read_head(c, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [h, rest] -> {h, rest}
      _ -> {:ok, d} = :gen_tcp.recv(c, 0, 5000); read_head(c, acc <> d)
    end
  end

  defp read_body(c, h, acc) do
    cond do
      h["transfer-encoding"] == "chunked" -> if String.ends_with?(acc, "0\r\n\r\n"), do: dechunk(acc), else: read_body(c, h, acc <> elem(:gen_tcp.recv(c, 0, 5000), 1))
      len = h["content-length"] -> if byte_size(acc) >= String.to_integer(len), do: acc, else: read_body(c, h, acc <> elem(:gen_tcp.recv(c, 0, 5000), 1))
      true -> acc
    end
  end

  defp dechunk(data) do
    [size, rest] = String.split(data, "\r\n", parts: 2)
    {n, _} = Integer.parse(size, 16)
    if n == 0, do: "", else: binary_part(rest, 0, n) <> dechunk(binary_part(rest, n + 2, byte_size(rest) - n - 2))
  end

  defp site(fields), do: Map.merge(%{host: "*", root: nil, proxy: nil, cert: nil, key: nil}, Map.new(fields))

  test "files: pages, types, directories, keep-alive, HEAD, and nothing outside the root" do
    root = tmp_dir("www")
    File.mkdir_p!(Path.join(root, "docs"))
    File.write!(Path.join(root, "index.html"), "<h1>hi</h1>")
    File.write!(Path.join(root, "docs/app.js"), "x()")
    File.write!(Path.join(Path.dirname(root), "secret"), "no")
    %{http: port} = start(%HTTPD{sites: [site(root: root)]})

    assert {200, %{"content-type" => "text/html; charset=utf-8"}, "<h1>hi</h1>"} = get(port, "/")
    assert {200, %{"content-type" => "text/javascript"}, "x()"} = get(port, "/docs/app.js?v=1")
    assert {301, %{"location" => "/docs/"}, _} = get(port, "/docs")
    assert {404, _, _} = get(port, "/nope")
    assert {403, _, _} = get(port, "/../secret")

    # two requests on one connection
    {:ok, s} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :gen_tcp.send(s, "HEAD / HTTP/1.1\r\nHost: x\r\n\r\nGET /docs/app.js HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    both = read_all(s, "")
    assert [_, second] = String.split(both, "HTTP/1.1 200 OK", trim: true) |> then(&if(length(&1) == 2, do: &1, else: [nil]))
    assert String.ends_with?(second, "x()")
  end

  test "an app behind it: X-Forwarded headers, request bodies (chunked too), and a WebSocket passed through" do
    app = fake_app()
    %{http: port} = start(%HTTPD{sites: [site(host: "myapp.test", proxy: app), site(host: "*", root: tmp_dir("other"))]})

    {200, _, body} = get(port, "/live?x=1", [{"Host", "myapp.test"}, {"X-Forwarded-For", "10.0.0.9"}])
    seen = JSON.decode!(body)
    assert seen["line"] == "GET /live?x=1 HTTP/1.1"
    assert seen["headers"]["host"] == "myapp.test"
    assert seen["headers"]["x-forwarded-for"] == "10.0.0.9, 127.0.0.1"
    assert seen["headers"]["x-forwarded-proto"] == "http"
    assert seen["headers"]["x-forwarded-host"] == "myapp.test"
    assert seen["headers"]["x-forwarded-port"] == "#{port}"

    for {enc, payload} <- [{"Content-Length: 11", "hello=world"}, {"Transfer-Encoding: chunked", "5\r\nhello\r\n6\r\n=world\r\n0\r\n\r\n"}] do
      {:ok, s} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
      :gen_tcp.send(s, "POST /form HTTP/1.1\r\nHost: myapp.test\r\n#{enc}\r\n\r\n" <> payload)
      {200, h, body} = parse(read_all(s, ""))
      assert h["connection"] == "close"
      assert JSON.decode!(body)["body"] == "hello=world"
    end

    # the WebSocket: the upgrade, then bytes both ways
    {:ok, s} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :gen_tcp.send(s, "GET /live/websocket HTTP/1.1\r\nHost: myapp.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: k\r\nSec-WebSocket-Version: 13\r\n\r\n")
    {:ok, head} = :gen_tcp.recv(s, 0, 5000)
    assert head =~ "HTTP/1.1 101"
    for msg <- ["one", "two"] do
      :gen_tcp.send(s, msg)
      assert {:ok, "echo:" <> ^msg} = :gen_tcp.recv(s, 0, 5000)
    end

    :gen_tcp.close(s)

    # no app there
    %{http: dead} = start(%HTTPD{sites: [site(proxy: "http://127.0.0.1:1")]})
    assert {502, _, body} = get(dead, "/")
    assert body =~ "isn't answering"
  end

  test "HTTPS: the certificate for the name asked (SNI), from Lepton's local CA, and HTTP sent to HTTPS" do
    {:ok, "app.test"} = Certs.local(["app.test", "127.0.0.1"])
    {:ok, "other.test"} = Certs.self_signed(["other.test"])
    app = fake_app()
    %{http: http, https: https} = start(%HTTPD{redirect_https: true, tls_port: 0, sites: [site(proxy: app)]})
    {ca, _} = Certs.ca()

    tls = [verify: :verify_peer, cacerts: [ca], server_name_indication: ~c"app.test"]
    {200, _, body} = get(https, "/", [{"Host", "app.test"}], tls: tls)
    assert JSON.decode!(body)["headers"]["x-forwarded-proto"] == "https"

    {:ok, s} = :ssl.connect(~c"127.0.0.1", https, [verify: :verify_none, server_name_indication: ~c"other.test"], 5000)
    {:ok, der} = :ssl.peercert(s)
    assert Certs.info(der).subject == "other.test"
    :ssl.close(s)

    assert {301, %{"location" => location}, _} = get(http, "/a?b", [{"Host", "app.test"}])
    assert location == "https://app.test:#{https}/a?b"
  end

  # As browsers offer it (x25519mlkem768 first): ML-KEM needs OpenSSL 3.5,
  # in Lepton's runtime since 1.12.0. TLS 1.2 has no post-quantum groups.
  test "HTTPS key exchange is post-quantum: x25519mlkem768" do
    {:ok, "pq.test"} = Certs.self_signed(["pq.test"])
    %{https: https} = start(%HTTPD{tls_port: 0, sites: []})
    {:ok, s} = :ssl.connect(~c"127.0.0.1", https, [verify: :verify_none, server_name_indication: ~c"pq.test"], 5000)
    assert {:ok, info} = :ssl.connection_information(s, [:protocol, :selected_group])
    assert info[:protocol] == :"tlsv1.3"
    assert info[:selected_group] == :x25519mlkem768
    :ssl.close(s)
  end

  test "Let's Encrypt: the order, the HTTP-01 challenge (answered by httpd), the certificate, renewal" do
    %{http: port} = start(%HTTPD{sites: [site(root: tmp_dir("www2"))]})
    acme = Lepton.FakeACME.start(port)
    me = self()

    assert {:ok, "example.test"} = Certs.acme(["example.test", "www.example.test"], email: "a@example.test", directory: acme, log: &send(me, {:log, &1}))
    assert_received {:log, "answering the challenge for example.test"}
    [c] = Certs.list()
    assert c.hosts == ["example.test", "www.example.test"]
    assert c.issuer == "Fake ACME CA"
    assert Certs.lookup("www.example.test") == {Path.join(Certs.dir(), "example.test.crt"), Path.join(Certs.dir(), "example.test.key")}
    assert File.ls!(Certs.challenge_dir()) == []

    # not near expiry (397 days left): nothing to renew; asked to renew within 400 days: renewed
    assert Certs.renew(30) == []
    assert [{"example.test", {:ok, "example.test"}}] = Certs.renew(400)
  end

  test "cert: made, listed and removed by root; the CA for anyone" do
    assert {out, 0} = sh("cert local dev.test localhost")
    assert out =~ "dev.test.crt (from Lepton's local CA)"
    assert {_, 0} = sh("cert self-signed box.test")
    {out, 0} = sh("cert list")
    assert out =~ ~r/dev\.test\s+\d+ days\s+dev\.test localhost  \(Lepton local CA/
    assert out =~ "box.test"
    {out, 0} = sh("cert ca", user: "nobody")
    assert out =~ "-----BEGIN CERTIFICATE-----"
    assert {_, 1} = sh("cert local x.test", user: "nobody")
    assert {"", 0} = sh("cert rm box.test")
    assert {_, 1} = sh("cert rm box.test")
  end

  test "the config file: sites by name" do
    dir = tmp_dir("httpdconf")
    conf = Path.join(dir, "httpd.toml")
    File.write!(conf, """
    port = 8081
    tls_port = 8444
    redirect_https = true

    [site.app]
    host = "app.test"
    proxy = "http://127.0.0.1:4000"

    [site.files]
    host = "*"
    root = "/srv/www"
    """)

    {:ok, cfg} = HTTPD.config(conf)
    assert %{port: 8081, tls_port: 8444, redirect_https: true} = cfg
    assert HTTPD.site(cfg, "app.test").proxy == "http://127.0.0.1:4000"
    assert HTTPD.site(cfg, "else.test").root == "/srv/www"
  end
end

defmodule Lepton.FakeACME do
  @moduledoc false
  # Just enough of an ACME server (RFC 8555) to issue a certificate: it
  # checks each request's signature and the HTTP-01 challenge (at httpd).

  def start(httpd_port) do
    {:ok, l} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(l)
    base = "http://127.0.0.1:#{port}"
    ca_key = Lepton.Certs.generate_key()
    ca = Lepton.Certs.certificate(ca_key, "Fake ACME CA", [], nil, ca: true)
    {:ok, agent} = Agent.start(fn -> %{jwk: nil, orders: %{}} end)
    spawn(fn -> loop(l, %{base: base, httpd: httpd_port, ca: {ca, ca_key}, agent: agent}) end)
    base <> "/directory"
  end

  defp loop(l, st) do
    case :gen_tcp.accept(l) do
      {:ok, c} -> handle(c, st); :gen_tcp.close(c); loop(l, st)
      _ -> :ok
    end
  end

  defp handle(c, st) do
    {:ok, data} = :gen_tcp.recv(c, 0, 5000)
    {head, body} = read(c, data)
    [method, path | _] = String.split(head, " ")
    b = st.base

    case {method, path} do
      {"GET", "/directory"} ->
        reply(c, 200, [], JSON.encode!(%{"newNonce" => b <> "/nonce", "newAccount" => b <> "/account", "newOrder" => b <> "/order"}))

      {"HEAD", "/nonce"} ->
        reply(c, 200, [], "")

      {"POST", p} ->
        payload = verify!(body, st)

        case p do
          "/account" -> reply(c, 201, [{"Location", b <> "/acct/1"}], "{}")
          "/order" ->
            domains = for %{"value" => v} <- payload["identifiers"], do: v
            Agent.update(st.agent, &put_in(&1.orders[1], %{domains: domains, cert: nil}))
            reply(c, 201, [{"Location", b <> "/order/1"}], JSON.encode!(%{"status" => "pending", "authorizations" => Enum.map(domains, &(b <> "/authz/" <> &1)), "finalize" => b <> "/finalize/1"}))
          "/authz/" <> d ->
            status = if Agent.get(st.agent, &Map.get(&1, {:valid, d})), do: "valid", else: "pending"
            reply(c, 200, [], JSON.encode!(%{"status" => status, "identifier" => %{"value" => d}, "challenges" => [%{"type" => "http-01", "token" => "tok" <> String.replace(d, ".", ""), "url" => b <> "/chall/" <> d}]}))
          "/chall/" <> d ->
            # fetch the key authorization from httpd, as Let's Encrypt does
            token = "tok" <> String.replace(d, ".", "")
            {:ok, s} = :gen_tcp.connect(~c"127.0.0.1", st.httpd, [:binary, active: false])
            :gen_tcp.send(s, "GET /.well-known/acme-challenge/#{token} HTTP/1.1\r\nHost: #{d}\r\nConnection: close\r\n\r\n")
            got = recv_all(s, "") |> String.split("\r\n\r\n", parts: 2) |> List.last()
            jwk = Agent.get(st.agent, & &1.jwk)
            want = token <> "." <> Base.url_encode64(:crypto.hash(:sha256, ~s({"crv":"P-256","kty":"EC","x":"#{jwk["x"]}","y":"#{jwk["y"]}"})), padding: false)
            if got == want, do: Agent.update(st.agent, &Map.put(&1, {:valid, d}, true))
            reply(c, 200, [], "{}")
          "/finalize/1" ->
            csr = Base.url_decode64!(payload["csr"], padding: false)
            {:CertificationRequest, info, _, _} = :public_key.der_decode(:CertificationRequest, csr)
            {:CertificationRequestInfo, _, _, {:CertificationRequestInfo_subjectPKInfo, _, pub}, _} = info
            order = Agent.get(st.agent, & &1.orders[1])
            {ca, ca_key} = st.ca
            # a key with the request's public point, to reuse Certs.certificate
            subject = {:ECPrivateKey, 1, <<>>, {:namedCurve, {1, 2, 840, 10045, 3, 1, 7}}, pub, :asn1_NOVALUE}
            leaf = Lepton.Certs.certificate(subject, hd(order.domains), order.domains, {ca, ca_key})
            Agent.update(st.agent, &put_in(&1.orders[1].cert, Lepton.Certs.cert_pem(leaf)))
            reply(c, 200, [], JSON.encode!(%{"status" => "processing"}))
          "/order/1" ->
            reply(c, 200, [], JSON.encode!(%{"status" => "valid", "certificate" => b <> "/cert/1"}))
          "/cert/1" ->
            reply(c, 200, [], Agent.get(st.agent, & &1.orders[1].cert))
        end
    end
  end

  # The JWS's signature, by the account's key (sent with newAccount).
  defp verify!(body, st) do
    %{"protected" => p, "payload" => pl, "signature" => sig} = JSON.decode!(body)
    prot = JSON.decode!(Base.url_decode64!(p, padding: false))
    if prot["jwk"], do: Agent.update(st.agent, &%{&1 | jwk: prot["jwk"]})
    jwk = Agent.get(st.agent, & &1.jwk)
    <<r::256, s::256>> = Base.url_decode64!(sig, padding: false)
    der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
    point = <<4>> <> Base.url_decode64!(jwk["x"], padding: false) <> Base.url_decode64!(jwk["y"], padding: false)
    true = :public_key.verify(p <> "." <> pl, :sha256, der, {{:ECPoint, point}, {:namedCurve, {1, 2, 840, 10045, 3, 1, 7}}})
    if pl == "", do: nil, else: JSON.decode!(Base.url_decode64!(pl, padding: false))
  end

  defp read(c, data) do
    case String.split(data, "\r\n\r\n", parts: 2) do
      [head, body] ->
        case Regex.run(~r/content-length: *(\d+)/i, head) do
          [_, n] -> if byte_size(body) < String.to_integer(n), do: read(c, data <> elem(:gen_tcp.recv(c, 0, 5000), 1)), else: {head, body}
          nil -> {head, body}
        end

      _ ->
        read(c, data <> elem(:gen_tcp.recv(c, 0, 5000), 1))
    end
  end

  defp recv_all(s, acc), do: (case :gen_tcp.recv(s, 0, 5000) do {:ok, d} -> recv_all(s, acc <> d); _ -> acc end)

  defp reply(c, code, headers, body) do
    hs = [{"Replay-Nonce", Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)}, {"Content-Length", "#{byte_size(body)}"}, {"Connection", "close"} | headers]
    :gen_tcp.send(c, ["HTTP/1.1 #{code} X\r\n", Enum.map(hs, fn {k, v} -> "#{k}: #{v}\r\n" end), "\r\n", body])
  end
end
