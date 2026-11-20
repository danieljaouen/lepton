defmodule Lepton.ProxyTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.{Proxy, SSH, SSHD, Users}

  setup do
    state = tmp_dir("proxystate")
    System.put_env("LEPTON_STATE_DIR", state)
    on_exit(fn -> System.delete_env("LEPTON_STATE_DIR") end)
    :ok
  end

  # -- servers for the tests ---------------------------------------------------------------

  defp listen(handler) do
    {:ok, l} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, exit_on_close: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(l)
    spawn(fn -> accept(l, handler) end)
    port
  end

  defp accept(l, handler) do
    case :gen_tcp.accept(l) do
      {:ok, c} ->
        pid = spawn(fn -> receive do: (:go -> handler.(c)) end)
        :gen_tcp.controlling_process(c, pid)
        send(pid, :go)
        accept(l, handler)

      _ ->
        :ok
    end
  end

  defp echo_server, do: listen(&echo/1)

  defp echo(c) do
    case :gen_tcp.recv(c, 0) do
      {:ok, d} -> :gen_tcp.send(c, d); echo(c)
      _ -> :gen_tcp.close(c)
    end
  end

  defp http_server(body) do
    listen(fn c ->
      {:ok, _} = :gen_tcp.recv(c, 0, 5000)
      :gen_tcp.send(c, "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}")
      :gen_tcp.close(c)
    end)
  end

  # A SOCKS5 proxy (with user/password when `auth` is given) that tells
  # the test about each connection it makes.
  defp socks5_proxy(test, auth \\ nil) do
    listen(fn c ->
      {:ok, <<5, n>>} = :gen_tcp.recv(c, 2)
      {:ok, _methods} = :gen_tcp.recv(c, n)

      ok =
        case auth do
          nil ->
            :gen_tcp.send(c, <<5, 0>>)
            true

          {u, p} ->
            :gen_tcp.send(c, <<5, 2>>)
            {:ok, <<1, ul>>} = :gen_tcp.recv(c, 2)
            {:ok, user} = :gen_tcp.recv(c, ul)
            {:ok, <<pl>>} = :gen_tcp.recv(c, 1)
            {:ok, pass} = :gen_tcp.recv(c, pl)
            good = {user, pass} == {u, p}
            :gen_tcp.send(c, <<1, if(good, do: 0, else: 1)>>)
            good
        end

      if ok do
        {:ok, <<5, 1, 0, atyp>>} = :gen_tcp.recv(c, 4)

        host =
          case atyp do
            1 -> {:ok, <<a, b, cc, d>>} = :gen_tcp.recv(c, 4); {a, b, cc, d}
            3 -> {:ok, <<len>>} = :gen_tcp.recv(c, 1); {:ok, name} = :gen_tcp.recv(c, len); String.to_charlist(name)
          end

        {:ok, <<port::16>>} = :gen_tcp.recv(c, 2)
        send(test, {:socks5, host, port})
        {:ok, up} = :gen_tcp.connect(host, port, [:binary, active: false, exit_on_close: false])
        :gen_tcp.send(c, <<5, 0, 0, 1, 0, 0, 0, 0, 0, 0>>)
        Proxy.splice(c, up)
      else
        :gen_tcp.close(c)
      end
    end)
  end

  # An HTTP CONNECT proxy.
  defp http_proxy(test, auth \\ nil) do
    listen(fn c ->
      head = read_head(c, "")
      [_, target] = Regex.run(~r/^CONNECT (\S+) HTTP/, head)
      authorized = auth == nil or head =~ "Proxy-Authorization: Basic #{Base.encode64(auth)}\r\n"

      if authorized do
        [h, p] = String.split(target, ":")
        send(test, {:connect, target})
        {:ok, up} = :gen_tcp.connect(String.to_charlist(h), String.to_integer(p), [:binary, active: false, exit_on_close: false])
        :gen_tcp.send(c, "HTTP/1.1 200 Connection established\r\n\r\n")
        Proxy.splice(c, up)
      else
        :gen_tcp.send(c, "HTTP/1.1 407 Proxy Authentication Required\r\n\r\n")
        :gen_tcp.close(c)
      end
    end)
  end

  defp read_head(c, acc) do
    if String.ends_with?(acc, "\r\n\r\n"), do: acc, else: (({:ok, b} = :gen_tcp.recv(c, 1)); read_head(c, acc <> b))
  end

  defp roundtrip(sock, text) do
    :ok = :gen_tcp.send(sock, text)
    {:ok, back} = :gen_tcp.recv(sock, byte_size(text), 5000)
    :gen_tcp.close(sock)
    back
  end

  # -- settings -------------------------------------------------------------------------

  describe "settings" do
    test "proxy URLs, shown without passwords" do
      assert {:ok, %{scheme: :http, host: "proxy.corp", port: 8080, user: "me", pass: "s3cret"} = h} = Proxy.parse("http://me:s3cret@proxy.corp:8080")
      assert Proxy.show(h) == "http://me:***@proxy.corp:8080"
      assert {:ok, %{scheme: :socks5, remote_dns: true, port: 9050}} = Proxy.parse("socks5h://127.0.0.1:9050")
      assert {:ok, %{scheme: :http, port: 3128}} = Proxy.parse("proxy.corp")
      assert {:error, _} = Proxy.parse("ftp://x:1")
    end

    test "which proxies: the system chain, a command's variables, no_proxy" do
      assert Proxy.chain("example.com", :https) == []
      :ok = Proxy.set(["http://a:3128", "socks5://b:1080"])
      assert [%{host: "a"}, %{host: "b"}] = Proxy.chain("example.com", :tcp)
      assert Proxy.chain("localhost", :https) == []
      assert Proxy.chain("printer.local", :https) == []
      assert [%{host: "c"}] = Proxy.chain("example.com", :https, %{"https_proxy" => "http://c:8080"})
      assert [%{host: "d"}] = Proxy.chain("example.com", :http, %{"ALL_PROXY" => "socks5://d:1"})
      assert Proxy.chain("git.corp.example", :https, %{"no_proxy" => ".corp.example"}) == []
      assert [] = Proxy.chain("x.internal", :tcp, %{"no_proxy" => "*"})

      :ok = Proxy.set(["http://a:3128"], ["intranet"])
      assert Proxy.chain("intranet", :https) == []
      assert Proxy.system() == %{chain: ["http://a:3128"], no_proxy: ["intranet"]}
      :ok = Proxy.set([])
      assert Proxy.chain("example.com", :tcp) == []
    end

    test "the proxy command (root to change it; passwords hidden)" do
      assert {_, 1} = sh("proxy set http://p:3128", user: "nobody")
      {out, 0} = sh("proxy set http://me:pw@p:3128 socks5h://q:9050")
      assert out =~ "1. http://me:***@p:3128"
      assert out =~ "2. socks5h://q:9050"
      refute out =~ "pw"
      {out, 0} = sh("proxy")
      assert out =~ "a chain of 2 proxies"
      {out, 0} = sh("proxy off")
      assert out =~ "No proxy"
      assert {_, 1} = sh("proxy set ftp://nope")
    end
  end

  # -- connecting ----------------------------------------------------------------------------

  describe "connections" do
    test "through SOCKS5 (by name and by address), SOCKS5 with a password, HTTP CONNECT, and a chain of them" do
      echo = echo_server()
      s = socks5_proxy(self())
      h = http_proxy(self())
      a = socks5_proxy(self(), {"me", "pw"})

      {:ok, hop} = Proxy.parse("socks5h://127.0.0.1:#{s}")
      {:ok, sock} = Proxy.connect("localhost", echo, [hop])
      assert roundtrip(sock, "via socks") == "via socks"
      assert_received {:socks5, ~c"localhost", ^echo}

      {:ok, hop} = Proxy.parse("socks5://127.0.0.1:#{s}")
      {:ok, sock} = Proxy.connect("127.0.0.1", echo, [hop])
      assert roundtrip(sock, "by address") == "by address"
      assert_received {:socks5, {127, 0, 0, 1}, ^echo}

      {:ok, good} = Proxy.parse("socks5://me:pw@127.0.0.1:#{a}")
      {:ok, sock} = Proxy.connect("127.0.0.1", echo, [good])
      assert roundtrip(sock, "with a password") == "with a password"
      {:ok, bad} = Proxy.parse("socks5://me:wrong@127.0.0.1:#{a}")
      assert {:error, msg} = Proxy.connect("127.0.0.1", echo, [bad])
      assert msg =~ "user name or password refused"

      {:ok, hop} = Proxy.parse("http://127.0.0.1:#{h}")
      {:ok, sock} = Proxy.connect("127.0.0.1", echo, [hop])
      assert roundtrip(sock, "via connect") == "via connect"
      assert_received {:connect, _}

      # a chain: HTTP proxy, then SOCKS5, then the destination
      {:ok, c1} = Proxy.parse("http://127.0.0.1:#{h}")
      {:ok, c2} = Proxy.parse("socks5://127.0.0.1:#{s}")
      {:ok, sock} = Proxy.connect("127.0.0.1", echo, [c1, c2])
      assert roundtrip(sock, "through two") == "through two"
      target = "127.0.0.1:#{s}"
      assert_received {:connect, ^target}
      assert_received {:socks5, {127, 0, 0, 1}, ^echo}
    end

    test "HTTP proxy errors say which proxy and why" do
      p = http_proxy(self(), "u:p")
      {:ok, hop} = Proxy.parse("http://127.0.0.1:#{p}")
      assert {:error, msg} = Proxy.connect("127.0.0.1", 9, [hop])
      assert msg =~ "proxy http://127.0.0.1:#{p} could not reach 127.0.0.1:9: the proxy wants a user name and password (407)"
      {:ok, dead} = Proxy.parse("socks5://127.0.0.1:1")
      assert {:error, "cannot reach the proxy 127.0.0.1:1" <> _} = Proxy.connect("x", 1, [dead])
    end

    test "web requests (httpc, curl) go through the chain, by the forwarder" do
      web = http_server("hello through the proxy")
      s = socks5_proxy(self())
      :ok = Proxy.set(["socks5://127.0.0.1:#{s}"], [])
      url = ~c"http://127.0.0.1:#{web}/"
      :inets.start()
      assert {:ok, {{_, 200, _}, _, "hello through the proxy"}} = :httpc.request(:get, {url, []}, [], [body_format: :binary], Proxy.httpc_profile(to_string(url)))
      assert_received {:socks5, {127, 0, 0, 1}, ^web}

      {out, 0} = sh("curl -s http://127.0.0.1:#{web}/")
      assert out == "hello through the proxy"
      assert_received {:socks5, _, ^web}

      # --noproxy, and curl -x
      :ok = Proxy.set([])
      {out, 0} = sh("curl -s -x socks5://127.0.0.1:#{s} http://127.0.0.1:#{web}/")
      assert out == "hello through the proxy"
      assert_received {:socks5, _, ^web}

      # Firefox gets the forwarder in its environment
      :ok = Proxy.set(["socks5://127.0.0.1:#{s}"])
      assert %{"https_proxy" => "http://127.0.0.1:" <> _, "no_proxy" => _} = Proxy.app_env()
      :ok = Proxy.set([])
      assert Proxy.app_env() == %{}
    end

    test "the forwarder tunnels CONNECT (what HTTPS uses)" do
      echo = echo_server()
      s = socks5_proxy(self())
      :ok = Proxy.set(["socks5://127.0.0.1:#{s}"], [])
      %{"http_proxy" => "http://127.0.0.1:" <> port} = Proxy.app_env()
      {:ok, c} = :gen_tcp.connect({127, 0, 0, 1}, String.to_integer(port), [:binary, active: false])
      :gen_tcp.send(c, "CONNECT 127.0.0.1:#{echo} HTTP/1.1\r\nHost: 127.0.0.1:#{echo}\r\n\r\n")
      assert read_head(c, "") =~ "200 Connection established"
      assert roundtrip(c, "tls would go here") == "tls would go here"
    end

    test "nc, directly and through a SOCKS proxy" do
      echo = echo_server()
      s = socks5_proxy(self())
      {out, 0} = sh("nc 127.0.0.1 #{echo}", stdin: elem(StringIO.open("ping\n"), 1))
      assert out == "ping\n"
      {out, 0} = sh("nc -x 127.0.0.1:#{s} 127.0.0.1 #{echo}", stdin: elem(StringIO.open("via proxy\n"), 1))
      assert out == "via proxy\n"
      assert_received {:socks5, _, ^echo}
      assert {"", 0} = sh("nc -z 127.0.0.1 #{echo}")
    end
  end

  # -- SSH --------------------------------------------------------------------------------------

  describe "SSH through proxies and jump hosts" do
    setup do
      homes = "/tmp/lepton-proxyhomes-#{System.unique_integer([:positive])}"
      File.mkdir_p!(homes)
      System.put_env("LEPTON_HOME_ROOT", homes)
      on_exit(fn -> System.delete_env("LEPTON_HOME_ROOT"); File.rm_rf(homes) end)
      {:ok, _} = Users.create("alice", "pw", home_root: homes, skel: tmp_dir("skel"))

      client = tmp_dir("proxyclient")
      key = SSH.generate()
      File.mkdir_p!(Path.join(client, ".ssh"))
      File.write!(Path.join(client, ".ssh/id_ed25519"), SSH.encode_private(key, "t"))
      File.chmod!(Path.join(client, ".ssh/id_ed25519"), 0o600)
      auth = Path.join(homes, "alice/.ssh/authorized_keys")
      File.mkdir_p!(Path.dirname(auth))
      File.write!(auth, SSH.public_line(SSH.public(key), "t") <> "\n")
      File.chmod!(auth, 0o600)

      home = &Path.join(homes, &1.name)
      state = System.get_env("LEPTON_STATE_DIR")
      {:ok, jump} = SSHD.start(0, host_key: Path.join(state, "jumpkey"), home: home)
      {:ok, target} = SSHD.start(0, host_key: Path.join(state, "targetkey"), home: home)
      on_exit(fn -> SSHD.stop(jump); SSHD.stop(target) end)
      {:ok, ji} = :ssh.daemon_info(jump)
      {:ok, ti} = :ssh.daemon_info(target)
      %{client: client, jump: ji[:port], target: ti[:port]}
    end

    defp whoami(conn) do
      {:ok, ch} = SSH.exec(conn, "whoami")
      {out, _, status} = SSH.recv_all(conn, ch, 20_000)
      SSH.close(conn)
      {out, status}
    end

    test "through a SOCKS proxy (all_proxy, or the system chain)", %{client: client, target: target} do
      s = socks5_proxy(self())
      env = %{"all_proxy" => "socks5://127.0.0.1:#{s}", "no_proxy" => "none.invalid"}
      assert {:ok, conn, _} = SSH.connect("alice@127.0.0.1", home: client, port: target, strict: "no", env: env)
      assert whoami(conn) == {"alice\n", 0}
      assert_received {:socks5, {127, 0, 0, 1}, ^target}
    end

    test "ProxyJump: -J, a chain of jumps, and ~/.ssh/config", %{client: client, jump: jump, target: target} do
      assert {:ok, conn, _} = SSH.connect("alice@127.0.0.1", home: client, port: target, strict: "no", jump: "alice@127.0.0.1:#{jump}")
      assert whoami(conn) == {"alice\n", 0}

      # two jumps: through the jump host twice
      assert {:ok, conn, _} = SSH.connect("alice@127.0.0.1", home: client, port: target, strict: "no", jump: "alice@127.0.0.1:#{jump},alice@127.0.0.1:#{jump}")
      assert whoami(conn) == {"alice\n", 0}

      File.write!(Path.join(client, ".ssh/config"), """
      Host bastion
        HostName 127.0.0.1
        Port #{jump}
        User alice
      Host inside
        HostName 127.0.0.1
        Port #{target}
        User alice
        ProxyJump bastion
      """)

      {out, 0} = sh("ssh -o StrictHostKeyChecking=no inside whoami", home: client)
      assert out == "alice\n"
      # the host key was recorded under the real port, not the tunnel's
      assert File.read!(Path.join(client, ".ssh/known_hosts")) =~ "[127.0.0.1]:#{target} "
    end

    test "ProxyCommand with ssh -W", %{client: client, jump: jump, target: target} do
      cmd = "ssh -W %h:%p -p #{jump} -o StrictHostKeyChecking=no alice@127.0.0.1"
      assert {:ok, conn, _} = SSH.connect("alice@127.0.0.1", home: client, port: target, strict: "no", proxy_command: cmd)
      assert whoami(conn) == {"alice\n", 0}

      {out, 0} = sh("ssh -o StrictHostKeyChecking=no -o 'ProxyCommand=#{cmd}' -p #{target} alice@127.0.0.1 whoami", home: client)
      assert out == "alice\n"
    end
  end
end
