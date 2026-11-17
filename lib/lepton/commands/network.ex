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

  defcmd "ifconfig", "show network interfaces" do
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

  defcmd "dhclient", "configure an interface with DHCP", aliases: ["udhcpc", "dhcpcd"], usage: "dhclient [IFACE]" do
    ifaces = if args == [], do: Net.ethernet_interfaces(), else: Enum.reject(args, &String.starts_with?(&1, "-"))

    Enum.reduce(ifaces, 0, fn iface, st ->
      IO.puts(ctx, "#{iface}: sending DHCPDISCOVER...")

      case Net.configure(iface) do
        {:ok, l} -> IO.puts(ctx, "#{iface}: bound to #{Net.format_ip(l.ip)}/#{l.prefix}, router #{Net.format_ip(l.router)}, dns #{Enum.map_join(l.dns, " ", &Net.format_ip/1)}"); st
        {:error, e} -> IO.err(ctx, "#{iface}: #{inspect(e)}"); 1
      end
    end)
  end

  defcmd "nslookup", "query DNS", aliases: ["host"] do
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

  defcmd "curl", "transfer a URL (HTTP/HTTPS)", aliases: ["wget", "fetch"], usage: "curl [-o FILE] [-I] [-s] URL" do
    {opts, urls} = getopt(args, "o:O:IsLkX:H:d:")

    case urls do
      [url | _] ->
        url = if String.contains?(url, "://"), do: url, else: "http://" <> url
        :inets.start()
        :ssl.start()
        ssl = if opts["k"], do: [verify: :verify_none], else: Lepton.Git.Remote.ssl_opts([])
        method = if opts["I"], do: :head, else: (if opts["d"], do: :post, else: :get)
        headers = [{~c"user-agent", ~c"curl/8.0 (lepton)"}]
        req = if method == :post, do: {String.to_charlist(url), headers, ~c"application/x-www-form-urlencoded", opts["d"]}, else: {String.to_charlist(url), headers}

        case :httpc.request(method, req, [ssl: ssl, timeout: 60_000, autoredirect: true], body_format: :binary) do
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

  defcmd "www", "text-mode web browser (preview of the Lepton browser)", aliases: ["lynx", "browse"], usage: "www URL" do
    case args do
      [url | _] -> Lepton.Browser.run(ctx, url)
      [] -> IO.err(ctx, "usage: www URL"); 2
    end
  end
end
