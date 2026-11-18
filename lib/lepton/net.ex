defmodule Lepton.Net do
  @moduledoc """
  Networking, in Elixir on top of `:socket`:

    * `Lepton.Net.Netlink` - rtnetlink (`AF_NETLINK`) messages to bring links
      up, add addresses and routes (what `ip link/addr/route` do)
    * `Lepton.Net.DHCP` - a DHCPv4 client over UDP
    * DNS via Erlang's resolver, configured from the DHCP lease

  At boot `start_background/0` configures every ethernet interface with
  DHCP without delaying the login prompt.
  """

  use Agent
  require Logger

  alias Lepton.Net.{DHCP, Netlink}

  def start_link(_), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def leases do
    if Process.whereis(__MODULE__), do: Agent.get(__MODULE__, & &1), else: %{}
  end

  defp record(iface, lease) do
    unless Process.whereis(__MODULE__), do: Agent.start(fn -> %{} end, name: __MODULE__)
    Agent.update(__MODULE__, &Map.put(&1, iface, lease))
  end

  def start_background do
    spawn(fn ->
      # Let unprivileged-style ICMP echo sockets work for `ping`.
      File.write("/proc/sys/net/ipv4/ping_group_range", "0 2147483647")
      Netlink.link_up("lo")
      wait_for_ethernet(30)

      for iface <- ethernet_interfaces() do
        case configure(iface) do
          {:ok, lease} -> Logger.info("net: #{iface} #{format_ip(lease.ip)}/#{lease.prefix} via #{format_ip(lease.router)}")
          {:error, reason} -> Logger.warning("net: #{iface}: #{inspect(reason)}")
        end
      end
    end)
  end

  defp wait_for_ethernet(0), do: :ok

  defp wait_for_ethernet(n) do
    if ethernet_interfaces() == [], do: (Process.sleep(100); wait_for_ethernet(n - 1)), else: :ok
  end

  def interfaces do
    case File.ls("/sys/class/net") do
      {:ok, names} -> Enum.sort(names)
      _ -> []
    end
  end

  # (USB adapters whose address is locally administered are named usbN)
  def ethernet_interfaces, do: Enum.filter(interfaces(), &String.match?(&1, ~r/^(eth|en|usb\d)/))

  @doc "Bring up an interface and configure it with DHCP."
  def configure(iface) do
    with :ok <- Netlink.link_up(iface),
         {:ok, lease} <- DHCP.request(iface),
         :ok <- Netlink.add_address(iface, lease.ip, lease.prefix),
         :ok <- if(lease.router, do: Netlink.add_default_route(iface, lease.router), else: :ok) do
      configure_dns(lease.dns, lease.domain)
      record(iface, lease)
      {:ok, lease}
    end
  end

  def configure_dns(servers, domain) do
    resolv =
      (if domain, do: "search #{domain}\n", else: "") <>
        Enum.map_join(servers, "", &"nameserver #{format_ip(&1)}\n")

    File.write("/etc/resolv.conf", resolv)
    :inet_db.set_lookup([:file, :dns])
    for ns <- servers, do: :inet_db.add_ns(ns)
    if domain, do: :inet_db.add_search(String.to_charlist(domain))
    :ok
  end

  def format_ip(nil), do: "-"
  def format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  def parse_ip(text) do
    case :inet.parse_ipv4_address(String.to_charlist(text)) do
      {:ok, ip} -> ip
      _ -> nil
    end
  end

  def mask_to_prefix({a, b, c, d}) do
    import Bitwise
    n = a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d
    for(i <- 0..31, (n >>> i &&& 1) == 1, do: i) |> length()
  end

  def ifindex(iface) do
    case File.read("/sys/class/net/#{iface}/ifindex") do
      {:ok, n} -> String.to_integer(String.trim(n))
      _ -> nil
    end
  end

  def mac(iface) do
    case File.read("/sys/class/net/#{iface}/address") do
      {:ok, text} -> text |> String.trim() |> String.split(":") |> Enum.map(&String.to_integer(&1, 16)) |> :binary.list_to_bin()
      _ -> <<0, 0, 0, 0, 0, 0>>
    end
  end
end

defmodule Lepton.Net.Netlink do
  @moduledoc "Minimal rtnetlink client (RTM_NEWLINK / RTM_NEWADDR / RTM_NEWROUTE)."

  import Bitwise

  @af_netlink 16
  @netlink_route 0
  @rtm_newlink 16
  @rtm_newaddr 20
  @rtm_newroute 24
  @nlm_f_request 1
  @nlm_f_ack 4
  @nlm_f_excl 0x200
  @nlm_f_create 0x400
  @nlm_f_replace 0x100
  @iff_up 1
  @af_inet 2

  def link_up(iface) do
    case Lepton.Net.ifindex(iface) do
      nil -> {:error, :no_such_interface}
      idx -> request(@rtm_newlink, @nlm_f_ack, <<0, 0, 0::little-16, idx::little-signed-32, @iff_up::little-32, @iff_up::little-32>>)
    end
  end

  def add_address(iface, {a, b, c, d} = ip, prefix) do
    idx = Lepton.Net.ifindex(iface)
    import Bitwise
    host = a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d
    bcast_int = host ||| (0xFFFFFFFF >>> prefix)
    bcast = <<bcast_int::32>>
    body = <<@af_inet, prefix, 0, 0, idx::little-32>> <> attr(2, ip4(ip)) <> attr(1, ip4(ip)) <> attr(4, bcast)

    case request(@rtm_newaddr, @nlm_f_ack ||| @nlm_f_create ||| @nlm_f_replace, body) do
      {:error, {:netlink, 17}} -> :ok
      other -> other
    end
  end

  def add_default_route(iface, gw) do
    idx = Lepton.Net.ifindex(iface)
    # rtmsg: family dst_len src_len tos table protocol(boot) scope(universe) type(unicast) flags
    body = <<@af_inet, 0, 0, 0, 254, 3, 0, 1, 0::little-32>> <> attr(5, ip4(gw)) <> attr(4, <<idx::little-32>>)

    case request(@rtm_newroute, @nlm_f_ack ||| @nlm_f_create ||| @nlm_f_excl, body) do
      {:error, {:netlink, 17}} -> :ok
      other -> other
    end
  end

  defp ip4({a, b, c, d}), do: <<a, b, c, d>>

  defp attr(type, data) do
    len = 4 + byte_size(data)
    pad = rem(4 - rem(len, 4), 4)
    <<len::little-16, type::little-16>> <> data <> :binary.copy(<<0>>, pad)
  end

  defp request(type, flags, body) do
    with {:ok, sock} <- :socket.open(@af_netlink, :raw, @netlink_route) do
      try do
        seq = :erlang.unique_integer([:positive]) &&& 0xFFFFFFFF
        msg = <<16 + byte_size(body)::little-32, type::little-16, (flags ||| @nlm_f_request)::little-16, seq::little-32, 0::little-32>> <> body
        :ok = :socket.send(sock, msg)

        case :socket.recv(sock, 0, 2000) do
          # NLMSG_ERROR (2) carries an errno; 0 means success (an ACK).
          {:ok, <<_len::little-32, 2::little-16, _f::little-16, _s::little-32, _p::little-32, err::little-signed-32, _::binary>>} ->
            if err == 0, do: :ok, else: {:error, {:netlink, -err}}

          {:ok, _other} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end
      after
        :socket.close(sock)
      end
    end
  end
end

defmodule Lepton.Net.DHCP do
  @moduledoc "DHCPv4 client (DISCOVER -> OFFER -> REQUEST -> ACK) over a broadcast UDP socket."

  @cookie <<99, 130, 83, 99>>

  def request(iface, attempts \\ 3) do
    mac = Lepton.Net.mac(iface)
    xid = :rand.uniform(0xFFFFFFFF)

    with {:ok, sock} <- open(iface) do
      try do
        Enum.reduce_while(1..attempts, {:error, :timeout}, fn _, _ ->
          case exchange(sock, mac, xid) do
            {:ok, lease} -> {:halt, {:ok, lease}}
            err -> {:cont, err}
          end
        end)
      after
        :socket.close(sock)
      end
    end
  end

  defp open(iface) do
    with {:ok, s} <- :socket.open(:inet, :dgram, :udp) do
      :socket.setopt(s, {:socket, :reuseaddr}, true)
      :socket.setopt(s, {:socket, :broadcast}, true)
      :socket.setopt(s, {:socket, :bindtodevice}, String.to_charlist(iface))

      case :socket.bind(s, %{family: :inet, addr: :any, port: 68}) do
        :ok -> {:ok, s}
        err -> err
      end
    end
  end

  defp exchange(sock, mac, xid) do
    with :ok <- send_msg(sock, packet(1, mac, xid, [])),
         {:ok, offer} <- await(sock, xid, 2, 3000),
         :ok <- send_msg(sock, packet(3, mac, xid, [{50, ip4(offer.yiaddr)}, {54, ip4(offer.options[54])}])),
         {:ok, ack} <- await(sock, xid, 5, 3000) do
      opts = ack.options
      mask = opts[1] || {255, 255, 255, 0}

      {:ok,
       %{
         ip: ack.yiaddr,
         prefix: Lepton.Net.mask_to_prefix(mask),
         mask: mask,
         router: opts[3],
         dns: opts[6] || [],
         domain: opts[15],
         lease: opts[51],
         server: opts[54]
       }}
    end
  end

  defp send_msg(sock, data), do: :socket.sendto(sock, data, %{family: :inet, addr: {255, 255, 255, 255}, port: 67})

  defp await(sock, xid, type, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      left = deadline - System.monotonic_time(:millisecond)
      if left <= 0, do: {:error, :timeout}, else: :socket.recvfrom(sock, 0, left)
    end)
    |> Enum.find_value(fn
      {:error, reason} -> {:error, reason}
      {:ok, {_from, data}} ->
        case parse(data) do
          %{xid: ^xid, options: %{53 => ^type}} = msg -> {:ok, msg}
          %{xid: ^xid, options: %{53 => 6}} -> {:error, :nak}
          _ -> nil
        end
    end)
  end

  def packet(msg_type, mac, xid, options) do
    opts =
      [{53, <<msg_type>>}, {55, <<1, 3, 6, 15, 51, 54>>}, {12, "lepton"}, {61, <<1>> <> mac} | options]
      |> Enum.map(fn {code, data} -> <<code, byte_size(data)>> <> data end)
      |> IO.iodata_to_binary()

    # BROADCAST flag: we have no address yet, so replies must be broadcast.
    header = <<1, 1, 6, 0, xid::32, 0::16, 0x8000::16, 0::32, 0::32, 0::32, 0::32>> <> mac <> :binary.copy(<<0>>, 10 + 64 + 128)
    header <> @cookie <> opts <> <<255>>
  end

  def parse(<<2, _htype, _hlen, _hops, xid::32, _secs::16, _flags::16, _ciaddr::32, a, b, c, d, _siaddr::32, _giaddr::32,
              _chaddr::binary-size(16), _sname::binary-size(64), _file::binary-size(128), @cookie, opts::binary>>) do
    %{xid: xid, yiaddr: {a, b, c, d}, options: parse_options(opts, %{})}
  end

  def parse(_), do: nil

  defp parse_options(<<255, _::binary>>, acc), do: acc
  defp parse_options(<<0, rest::binary>>, acc), do: parse_options(rest, acc)

  defp parse_options(<<code, len, data::binary-size(len), rest::binary>>, acc) do
    value =
      case code do
        c when c in [1, 3, 28, 54] -> to_ip(data)
        6 -> for <<a, b, c, d <- data>>, do: {a, b, c, d}
        53 -> :binary.first(data)
        51 -> :binary.decode_unsigned(data)
        15 -> data
        _ -> data
      end

    parse_options(rest, Map.put(acc, code, value))
  end

  defp parse_options(_, acc), do: acc

  defp to_ip(<<a, b, c, d, _::binary>>), do: {a, b, c, d}
  defp to_ip(_), do: nil

  defp ip4({a, b, c, d}), do: <<a, b, c, d>>
  defp ip4(nil), do: <<0, 0, 0, 0>>
end
