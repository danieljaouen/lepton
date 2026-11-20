defmodule Lepton.Commands.Network do
  @moduledoc "Network utilities."

  use Lepton.Command
  alias Lepton.Net

  defcmd "ip", "show / manipulate network interfaces, addresses and routes", usage: "ip [addr|link|route]" do
    case args do
      [obj | _] when obj in ["r", "route"] -> routes(ctx)
      [obj | _] when obj in ["l", "link"] -> links(ctx, false)
      _ -> links(ctx, true)
    end
  end

  defcmd "ifconfig", "show network interfaces", usage: "ifconfig" do
    links(ctx, true)
  end

  defp links(ctx, with_addr) do
    leases = Net.leases()

    for {iface, i} <- Enum.with_index(Net.interfaces(), 1) do
      read = fn f -> case File.read("/sys/class/net/#{iface}/#{f}") do
          {:ok, v} -> String.trim(v)
          _ -> "?"
        end end

      IO.puts(ctx, "#{i}: #{iface}: <#{String.upcase(read.("operstate"))}> mtu #{read.("mtu")}")
      IO.puts(ctx, "    link/ether #{read.("address")}  rx #{read.("statistics/rx_bytes")} bytes  tx #{read.("statistics/tx_bytes")} bytes")

      if with_addr do
        cond do
          iface == "lo" -> IO.puts(ctx, "    inet 127.0.0.1/8 scope host lo")
          lease = leases[iface] -> IO.puts(ctx, "    inet #{Net.format_ip(lease.ip)}/#{lease.prefix} scope global dynamic #{iface}")
          true -> :ok
        end
      end
    end

    0
  end

  defp routes(ctx) do
    case File.read("/proc/net/route") do
      {:ok, text} ->
        for line <- text |> String.split("\n", trim: true) |> tl() do
          [iface, dest, gw, _flags, _, _, _, mask | _] = String.split(line)
          d = hex_ip(dest)
          g = hex_ip(gw)
          prefix = Net.mask_to_prefix(hex_ip(mask))
          target = if d == {0, 0, 0, 0} and prefix == 0, do: "default", else: "#{Net.format_ip(d)}/#{prefix}"
          via = if g == {0, 0, 0, 0}, do: "", else: " via #{Net.format_ip(g)}"
          IO.puts(ctx, "#{target}#{via} dev #{iface}")
        end

        0

      _ ->
        IO.err(ctx, "ip: routing table unavailable")
        1
    end
  end

  defp hex_ip(hex) do
    <<d, c, b, a>> = <<String.to_integer(hex, 16)::32>>
    {a, b, c, d}
  end

  defcmd "dhclient", "configure an interface with DHCP", aliases: ["udhcpc", "dhcpcd"], usage: "dhclient [IFACE]", root: true do
    ifaces = if args == [], do: Net.ethernet_interfaces(), else: Enum.reject(args, &String.starts_with?(&1, "-"))

    Enum.reduce(ifaces, 0, fn iface, st ->
      IO.puts(ctx, "#{iface}: sending DHCPDISCOVER...")

      case Net.configure(iface) do
        {:ok, l} -> IO.puts(ctx, "#{iface}: bound to #{Net.format_ip(l.ip)}/#{l.prefix}, router #{Net.format_ip(l.router)}, dns #{Enum.map_join(l.dns, " ", &Net.format_ip/1)}"); st
        {:error, e} -> IO.err(ctx, "#{iface}: #{inspect(e)}"); 1
      end
    end)
  end

  defcmd "nslookup", "query DNS", usage: "nslookup NAME", aliases: ["host"] do
    case args do
      [name | _] ->
        case :inet.getaddrs(String.to_charlist(name), :inet) do
          {:ok, ips} ->
            for ip <- ips, do: IO.puts(ctx, "#{name} has address #{Net.format_ip(ip)}")
            0

          {:error, e} ->
            IO.err(ctx, "#{name}: #{e}")
            1
        end

      [] ->
        1
    end
  end

  defcmd "ping", "send ICMP ECHO_REQUEST to a host", usage: "ping [-c COUNT] HOST" do
    {opts, hosts} = getopt(args, "c:")
    count = Lepton.Args.int(opts, "c", 4)

    with [host | _] <- hosts,
         {:ok, ip} <- :inet.getaddr(String.to_charlist(host), :inet),
         {:ok, sock} <- :socket.open(:inet, :dgram, :icmp) do
      IO.puts(ctx, "PING #{host} (#{Net.format_ip(ip)}) 56 data bytes")

      received =
        Enum.count(1..count, fn seq ->
          payload = :crypto.strong_rand_bytes(56)
          pkt = icmp(seq, payload)
          t0 = System.monotonic_time(:microsecond)
          :socket.sendto(sock, pkt, %{family: :inet, addr: ip, port: 0})

          result =
            case :socket.recvfrom(sock, 0, 2000) do
              {:ok, {_, <<0, 0, _::16, _id::16, ^seq::16, _::binary>>}} ->
                ms = (System.monotonic_time(:microsecond) - t0) / 1000
                IO.puts(ctx, "64 bytes from #{Net.format_ip(ip)}: icmp_seq=#{seq} time=#{:erlang.float_to_binary(ms, decimals: 2)} ms")
                true

              _ ->
                IO.puts(ctx, "Request timeout for icmp_seq #{seq}")
                false
            end

          if seq < count, do: Process.sleep(1000)
          result
        end)

      :socket.close(sock)
      IO.puts(ctx, "--- #{host} ping statistics ---\n#{count} packets transmitted, #{received} received, #{div((count - received) * 100, count)}% packet loss")
      if received > 0, do: 0, else: 1
    else
      [] -> IO.err(ctx, "usage: ping [-c COUNT] HOST"); 2
      {:error, e} -> IO.err(ctx, "ping: #{inspect(e)}"); 2
    end
  end

  defp icmp(seq, payload) do
    import Bitwise
    base = <<8, 0, 0::16, 0::16, seq::16>> <> payload
    sum = for(<<w::16 <- pad_even(base)>>, reduce: 0, do: (acc -> acc + w))
    sum = (sum &&& 0xFFFF) + (sum >>> 16)
    sum = (sum &&& 0xFFFF) + (sum >>> 16)
    csum = bnot(sum) &&& 0xFFFF
    <<8, 0, csum::16, 0::16, seq::16>> <> payload
  end

  defp pad_even(b) when rem(byte_size(b), 2) == 1, do: b <> <<0>>
  defp pad_even(b), do: b

  defcmd "curl", "transfer a URL (HTTP/HTTPS)", aliases: ["wget", "fetch"], usage: "curl [-o FILE] [-I] [-s] [-x PROXY] URL" do
    {opts, urls} = getopt(args, "o:O:IsLkX:H:d:x:")

    case urls do
      [url | _] ->
        url = if String.contains?(url, "://"), do: url, else: "http://" <> url
        :inets.start()
        :ssl.start()
        ssl = if opts["k"], do: [verify: :verify_none], else: Lepton.Git.Remote.ssl_opts([])
        method = if opts["I"], do: :head, else: (if opts["d"], do: :post, else: :get)
        headers = [{~c"user-agent", ~c"curl/8.0 (lepton)"}]
        req = if method == :post, do: {String.to_charlist(url), headers, ~c"application/x-www-form-urlencoded", opts["d"]}, else: {String.to_charlist(url), headers}

        # -x/--proxy wins over the environment and the system's; --noproxy '*' goes direct.
        env =
          cond do
            opts["noproxy"] -> Map.put(ctx.env, "no_proxy", opts["noproxy"])
            px = opts["x"] || opts["proxy"] -> %{"all_proxy" => px}
            true -> ctx.env
          end

        case :httpc.request(method, req, [ssl: ssl, timeout: 60_000, autoredirect: true], [body_format: :binary], Lepton.Proxy.httpc_profile(url, env)) do
          {:ok, {{_, code, reason}, hdrs, body}} ->
            if opts["I"] do
              IO.puts(ctx, "HTTP/1.1 #{code} #{reason}")
              for {k, v} <- hdrs, do: IO.puts(ctx, "#{k}: #{v}")
            else
              dest = opts["o"] || (opts["O"] && (url |> URI.parse() |> Map.get(:path) |> Kernel.||("/index.html") |> Path.basename()))

              case dest do
                nil -> IO.write(ctx, body)
                path -> File.write!(Ctx.path(ctx, path), body); unless opts["s"], do: IO.err(ctx, "saved #{byte_size(body)} bytes to #{path}")
              end
            end

            if code < 400, do: 0, else: 22

          {:error, e} ->
            IO.err(ctx, "curl: #{inspect(e)}")
            6
        end

      [] ->
        IO.err(ctx, "curl: try 'curl URL'")
        2
    end
  end

  defcmd "proxy", "the internet proxy (or chain of proxies) for web and SSH connections",
    usage: "proxy [status] | set URL... | off | no-proxy HOST,... | test [URL]" do
    proxy(args, ctx)
  end

  defp proxy(args, ctx) when args in [[], ["status"]] do
    sys = Lepton.Proxy.system()

    case sys.chain do
      [] -> IO.puts(ctx, "No proxy: connections go directly.")
      chain ->
        IO.puts(ctx, "Through #{if length(chain) > 1, do: "a chain of #{length(chain)} proxies", else: "a proxy"}, for web and SSH connections:")
        for {u, i} <- Enum.with_index(chain, 1), {:ok, hop} <- [Lepton.Proxy.parse(u)], do: IO.puts(ctx, "  #{i}. #{Lepton.Proxy.show(hop)}")
    end

    IO.puts(ctx, "Directly: #{Enum.join(sys.no_proxy, ", ")} (no_proxy)")

    vars = for v <- ~w(http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY), val = ctx.env[v], val not in [nil, ""], do: "#{v}=#{val}"
    if vars != [], do: IO.puts(ctx, "This shell's variables take precedence: " <> Enum.join(vars, " "))
    0
  end

  defp proxy(["test" | rest], ctx) do
    url = List.first(rest) || "https://trylepton.app/"
    uri = URI.parse(url)
    hops = Lepton.Proxy.chain(uri.host || "", if(uri.scheme == "https", do: :https, else: :http), ctx.env)
    IO.puts(ctx, if(hops == [], do: "#{uri.host}: directly (no proxy applies)", else: "#{uri.host}: through " <> Enum.map_join(hops, " -> ", &Lepton.Proxy.show/1)))

    with {:ok, sock} <- Lepton.Proxy.connect(uri.host, uri.port || 443, hops) do
      :gen_tcp.close(sock)
      IO.puts(ctx, "connected to #{uri.host}:#{uri.port}")
      :inets.start()
      :ssl.start()

      case :httpc.request(:head, {String.to_charlist(url), []}, [ssl: Lepton.Git.Remote.ssl_opts([]), timeout: 20_000], [], Lepton.Proxy.httpc_profile(url, ctx.env)) do
        {:ok, {{_, code, reason}, _, _}} -> IO.puts(ctx, "#{url}: HTTP #{code} #{reason}"); 0
        {:error, e} -> IO.err(ctx, "proxy: #{url}: #{inspect(e)}"); 1
      end
    else
      {:error, msg} -> IO.err(ctx, "proxy: #{msg}"); 1
    end
  end

  defp proxy([cmd | _], ctx) when cmd in ~w(set off no-proxy) and ctx.user != "root", do: Lepton.Users.denied(ctx, "proxy #{cmd}")

  defp proxy(["set" | urls], ctx) when urls != [] do
    case Lepton.Proxy.set(urls) do
      :ok -> proxy([], ctx)
      {:error, msg} -> IO.err(ctx, "proxy: #{msg}"); 1
    end
  end

  defp proxy(["off"], ctx) do
    :ok = Lepton.Proxy.set([])
    proxy([], ctx)
  end

  defp proxy(["no-proxy" | hosts], ctx) when hosts != [] do
    list = hosts |> Enum.join(",") |> String.split([",", " "], trim: true)
    :ok = Lepton.Proxy.set(Lepton.Proxy.system().chain, list)
    proxy([], ctx)
  end

  defp proxy(_, ctx) do
    IO.err(ctx, "usage: proxy [status] | set URL... | off | no-proxy HOST,... | test [URL]")
    2
  end

  defcmd "nc", "connect to a TCP port and pass standard input and output (netcat), optionally through a proxy",
    usage: "nc [-x PROXY[:PORT]] [-X 4|5|connect] [-w SECONDS] [-z] [-v] HOST PORT" do
    {opts, operands} = getopt(args, "x:X:w:zvN")
    timeout = Lepton.Args.int(opts, "w", 20) * 1000

    hops =
      case opts["x"] do
        nil ->
          {:ok, []}

        px ->
          scheme = case opts["X"] do
            "connect" -> "http"
            "4" -> "socks4a"
            _ -> "socks5h"
          end

          with {:ok, hop} <- Lepton.Proxy.parse("#{scheme}://#{px}"), do: {:ok, [hop]}
      end

    with [host, port] <- operands,
         {p, ""} <- Integer.parse(port),
         {:ok, hops} <- hops,
         {:ok, sock} <- Lepton.Proxy.connect(host, p, hops, timeout) do
      if opts["v"] || opts["z"], do: IO.err(ctx, "Connection to #{host} port #{port} succeeded!")

      if opts["z"] do
        :gen_tcp.close(sock)
        0
      else
        nc_session(ctx, sock)
      end
    else
      {:error, msg} -> IO.err(ctx, "nc: #{msg}"); 1
      _ -> IO.err(ctx, "usage: nc [-x PROXY[:PORT]] [-X 4|5|connect] [-w SECONDS] [-z] [-v] HOST PORT"); 1
    end
  end

  defp nc_session(ctx, sock) do
    me = self()
    reader = spawn_link(fn -> nc_out(sock, ctx); send(me, :closed) end)
    :gen_tcp.controlling_process(sock, reader)
    nc_in(ctx, sock)

    receive do
      :closed -> 0
    end
  end

  defp nc_in(ctx, sock) do
    case Elixir.IO.binread(ctx.stdin, 65_536) do
      data when is_binary(data) -> :gen_tcp.send(sock, data); nc_in(ctx, sock)
      _ -> :gen_tcp.shutdown(sock, :write)
    end
  end

  defp nc_out(sock, ctx) do
    case :gen_tcp.recv(sock, 0) do
      {:ok, data} -> Elixir.IO.binwrite(ctx.stdout, data); nc_out(sock, ctx)
      _ -> :ok
    end
  end

  defcmd "sshfs", "mount a directory of another machine over SSH (SFTP)",
    usage: "sshfs [USER@]HOST:[DIR] MOUNTPOINT [-p PORT] [-o OPTION=VALUE]..." do
    sshfs(args, ctx)
  end

  defp sshfs(args, ctx) do
    {opts, operands} = getopt(args, "p:o:fh")
    settings = for v <- List.wrap(opts["o"]), kv <- String.split(v, ","), [k, val] <- [String.split(kv, "=", parts: 2) ++ [""]] |> Enum.map(&Enum.take(&1, 2)), into: %{}, do: {String.downcase(k), val}

    case operands do
      [remote, mountpoint] ->
        dir = Ctx.path(ctx, mountpoint)
        account = Lepton.Users.get(ctx.user) || %Lepton.Users{uid: 0, gid: 0}

        cond do
          not String.contains?(remote, ":") ->
            IO.err(ctx, "sshfs: #{remote}: write it as [USER@]HOST:[DIR]")
            1

          not File.dir?(dir) ->
            IO.err(ctx, "sshfs: #{mountpoint}: no such directory (create it first: mkdir #{mountpoint})")
            1

          Lepton.Users.check_write(ctx, dir) != :ok ->
            IO.err(ctx, "sshfs: #{mountpoint}: permission denied (mount in your home)")
            1

          true ->
            sopts =
              [home: Ctx.home(ctx), env: ctx.env, uid: account.uid, gid: account.gid,
               on_unknown: if(ctx.tty, do: &sshfs_confirm(ctx, &1, &2))] ++
                if(opts["p"], do: [port: String.to_integer(opts["p"])], else: []) ++
                if(settings["port"], do: [port: String.to_integer(settings["port"])], else: []) ++
                if(settings["identityfile"], do: [identity: [Ctx.path(ctx, settings["identityfile"])]], else: []) ++
                if(settings["proxyjump"], do: [jump: settings["proxyjump"]], else: []) ++
                if(settings["proxycommand"], do: [proxy_command: settings["proxycommand"]], else: []) ++
                if(settings["stricthostkeychecking"], do: [strict: String.downcase(settings["stricthostkeychecking"])], else: [])

            case Lepton.SSHFS.mount(remote, dir, sopts) do
              {:ok, pid} ->
                Lepton.Proc.register(pid, "sshfs #{remote} #{Ctx.tildify(ctx, dir)}")
                0

              {:error, msg} ->
                IO.err(ctx, "sshfs: #{msg}")
                1
            end
        end

      _ ->
        IO.err(ctx, "usage: sshfs [USER@]HOST:[DIR] MOUNTPOINT [-p PORT] [-o OPTION=VALUE]...")
        2
    end
  end

  defp sshfs_confirm(ctx, name, key) do
    IO.write(ctx.stderr, "The authenticity of host '#{name}' can't be established.\n#{Lepton.SSH.kind(key)} key fingerprint is #{Lepton.SSH.fingerprint(key)}.\nAre you sure you want to continue connecting (yes/no)? ")

    case IO.read_line(ctx.stdin) do
      line when is_binary(line) -> String.trim(line) in ["yes", "y"]
      _ -> false
    end
  end

  defcmd "fusermount", "unmount a FUSE filesystem (sshfs) you mounted", usage: "fusermount -u MOUNTPOINT" do
    case getopt(args, "uqz") do
      {%{"u" => true}, [mountpoint]} ->
        dir = Ctx.path(ctx, mountpoint)
        fuse? = Enum.any?(Lepton.Sys.mounts(), &(&1.dir == dir and String.starts_with?(&1.type, "fuse")))

        cond do
          not fuse? -> IO.err(ctx, "fusermount: #{mountpoint}: not a FUSE mount"); 1
          Lepton.Users.check_write(ctx, dir) != :ok -> IO.err(ctx, "fusermount: #{mountpoint}: permission denied"); 1
          true ->
            case Lepton.SSHFS.unmount(dir) do
              :ok -> 0
              {:error, msg} -> IO.err(ctx, "fusermount: #{msg}"); 1
            end
        end

      _ ->
        IO.err(ctx, "usage: fusermount -u MOUNTPOINT")
        2
    end
  end

  defcmd "www", "text-mode web browser (preview of the Lepton browser)", aliases: ["lynx", "browse"], usage: "www URL" do
    case args do
      [url | _] -> Lepton.Browser.run(ctx, url)
      [] -> IO.err(ctx, "usage: www URL"); 2
    end
  end

  # -- SSH ------------------------------------------------------------------------------------

  defcmd "ssh", "OpenSSH-compatible client: remote shells and commands, keys from ~/.ssh",
    usage: "ssh [-p PORT] [-i KEY] [-l USER] [-o StrictHostKeyChecking=VALUE] [-T|-t] [USER@]HOST [COMMAND...]" do
    Lepton.SSH.CLI.ssh(args, ctx)
  end

  defcmd "ssh-keygen", "create an SSH key, show fingerprints, forget a host",
    usage: "ssh-keygen [-t ed25519] [-f FILE] [-C COMMENT] | -l -f FILE | -y -f FILE | -R HOST" do
    Lepton.SSH.CLI.keygen(args, ctx)
  end

  defcmd "rsync", "copy and synchronise files, locally or with another machine over SSH, sending only what changed",
    usage: "rsync [-avrlptnczuh] [--delete] [--exclude PATTERN] [-e 'ssh OPTIONS'] SOURCE... DEST" do
    Lepton.Rsync.run(args, ctx)
  end

  defcmd "ssh-keyscan", "print a host's SSH public keys (known_hosts lines)", usage: "ssh-keyscan [-p PORT] [-t TYPES] HOST..." do
    Lepton.SSH.CLI.keyscan(args, ctx)
  end
end
