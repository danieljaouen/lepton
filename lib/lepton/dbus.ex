defmodule Lepton.DBus do
  @moduledoc """
  A D-Bus client: a connection to a bus (the system bus at
  `/run/dbus/system_bus_socket`), over `:socket`, speaking the wire format
  in `Lepton.DBus.Wire`.

    * `call/7` sends a method call and waits for its reply:
      `{:ok, values}` or `{:error, name, message}`.
    * `subscribe/3` asks the bus for signals matching a rule and sends
      them to a process as `{:dbus_signal, message}`.
    * `export/3` serves an object path: method calls to it go to a
      function `(member, args, message) -> {:reply, signature, values} |
      {:error, name, text}` (Lepton's Bluetooth pairing agent is one).

  Authentication is `EXTERNAL`: the bus knows who we are from the socket.
  """

  use GenServer
  require Logger

  alias Lepton.DBus.Wire

  @system_bus "/run/dbus/system_bus_socket"
  @bus "org.freedesktop.DBus"

  def system_bus, do: @system_bus

  def connect(path \\ @system_bus, opts \\ []), do: GenServer.start(__MODULE__, path, opts)
  def close(conn), do: GenServer.stop(conn)

  @doc "Call `interface.member` on `path` of `dest` with `args` (by `signature`)."
  def call(conn, dest, path, interface, member, signature \\ "", args \\ [], timeout \\ 25_000) do
    msg = %{type: :method_call, destination: dest, path: path, interface: interface, member: member, signature: signature, body: args}

    try do
      GenServer.call(conn, {:call, msg}, timeout + 1000)
    catch
      :exit, reason -> {:error, "org.freedesktop.DBus.Error.NoReply", inspect(reason)}
    end
  end

  @doc "Read a property: `{:ok, value}`."
  def get(conn, dest, path, interface, name) do
    with {:ok, [v]} <- call(conn, dest, path, "org.freedesktop.DBus.Properties", "Get", "ss", [interface, name]), do: {:ok, v}
  end

  @doc "Set a property; `type` is its signature (`\"b\"`, `\"q\"`, ...)."
  def set(conn, dest, path, interface, name, type, value) do
    with {:ok, _} <- call(conn, dest, path, "org.freedesktop.DBus.Properties", "Set", "ssv", [interface, name, {:variant, type, value}]), do: :ok
  end

  @doc "Send signals matching `rule` (a match rule: `type='signal',sender='org.bluez'`) to `pid`."
  def subscribe(conn, rule, pid \\ self()) do
    with {:ok, _} <- call(conn, @bus, "/org/freedesktop/DBus", @bus, "AddMatch", "s", [rule]) do
      GenServer.call(conn, {:subscribe, pid})
    end
  end

  @doc "Serve `path` with `handler`."
  def export(conn, path, handler), do: GenServer.call(conn, {:export, path, handler})

  @doc "This connection's unique name on the bus."
  def name(conn), do: GenServer.call(conn, :name)

  # -- the connection ---------------------------------------------------------------------------------

  @impl true
  def init(path) do
    with {:ok, sock} <- :socket.open(:local, :stream, :default),
         :ok <- :socket.connect(sock, %{family: :local, path: path}),
         :ok <- auth(sock) do
      me = self()
      reader = spawn_link(fn -> read_loop(sock, me) end)
      st = %{sock: sock, reader: reader, serial: 1, pending: %{}, subscribers: [], exports: %{}, buf: "", name: nil}
      # Every connection says Hello first; the reply is our unique name.
      {:ok, send_msg(st, %{type: :method_call, destination: @bus, path: "/org/freedesktop/DBus", interface: @bus, member: "Hello"}, {:hello, nil})}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # SASL: a NUL byte, then AUTH EXTERNAL with our uid in hex.
  defp auth(sock) do
    uid = case File.read("/proc/self/status") do
      {:ok, text} -> (Regex.run(~r/^Uid:\s+(\d+)/m, text) || [nil, "0"]) |> List.last()
      _ -> "0"
    end

    with :ok <- :socket.send(sock, <<0>> <> "AUTH EXTERNAL " <> Base.encode16(uid, case: :lower) <> "\r\n"),
         {:ok, "OK " <> _} <- :socket.recv(sock, 0, 5000),
         :ok <- :socket.send(sock, "BEGIN\r\n") do
      :ok
    else
      {:ok, other} -> {:error, {:auth, String.trim(other)}}
      err -> err
    end
  end

  defp read_loop(sock, owner) do
    case :socket.recv(sock, 0, :infinity) do
      {:ok, data} ->
        send(owner, {:dbus_data, data})
        read_loop(sock, owner)

      {:error, reason} ->
        send(owner, {:dbus_closed, reason})
    end
  end

  defp send_msg(st, msg, waiter) do
    serial = st.serial
    :socket.send(st.sock, Wire.message(Map.put(msg, :serial, serial)))
    pending = if waiter, do: Map.put(st.pending, serial, waiter), else: st.pending
    %{st | serial: serial + 1, pending: pending}
  end

  @impl true
  def handle_call({:call, msg}, from, st), do: {:noreply, send_msg(st, msg, from)}
  def handle_call({:subscribe, pid}, _from, st), do: {:reply, :ok, %{st | subscribers: Enum.uniq([pid | st.subscribers])}}
  def handle_call({:export, path, handler}, _from, st), do: {:reply, :ok, put_in(st.exports[path], handler)}
  def handle_call(:name, _from, st), do: {:reply, st.name, st}

  @impl true
  def handle_info({:dbus_data, data}, st), do: {:noreply, drain(%{st | buf: st.buf <> data})}
  def handle_info({:dbus_closed, reason}, st), do: {:stop, {:shutdown, reason}, st}
  def handle_info({:dbus_send, msg}, st), do: {:noreply, send_msg(st, msg, nil)}
  def handle_info(_msg, st), do: {:noreply, st}

  defp drain(st) do
    case Wire.split(st.buf) do
      {:ok, msg, rest} -> drain(dispatch(%{st | buf: rest}, msg))
      :more -> st
    end
  end

  defp dispatch(st, %{type: type, reply_serial: serial} = msg) when type in [:method_return, :error] do
    {waiter, pending} = Map.pop(st.pending, serial)
    st = %{st | pending: pending}

    case {waiter, type} do
      {{:hello, _}, :method_return} -> %{st | name: hd(msg.body)}
      {nil, _} -> st
      {{:hello, _}, :error} -> st
      {from, :method_return} -> reply(st, from, {:ok, msg.body})
      {from, :error} -> reply(st, from, {:error, msg.error_name, List.first(msg.body) || ""})
    end
  end


  defp dispatch(st, %{type: :signal} = msg) do
    for pid <- st.subscribers, do: send(pid, {:dbus_signal, msg})
    st
  end

  # A call to an object we serve is answered from a process of its own:
  # the answer may take a person (a Bluetooth PIN), and the connection
  # carries on meanwhile.
  defp dispatch(st, %{type: :method_call} = msg) do
    handler = Map.get(st.exports, msg[:path])
    me = self()

    spawn(fn ->
      reply =
        case {handler, msg[:interface]} do
          {_, "org.freedesktop.DBus.Peer"} -> if msg.member == "Ping", do: {:reply, "", []}, else: {:error, "org.freedesktop.DBus.Error.UnknownMethod", msg.member}
          {nil, _} -> {:error, "org.freedesktop.DBus.Error.UnknownObject", "no object at #{msg[:path]}"}
          {handler, _} -> safe(handler, msg)
        end

      base = %{destination: msg[:sender], reply_serial: msg.serial}

      out =
        case reply do
          {:reply, sig, values} -> Map.merge(base, %{type: :method_return, signature: sig, body: values})
          {:error, name, text} -> Map.merge(base, %{type: :error, error_name: name, signature: "s", body: [text]})
        end

      # (unless the caller said it wants no reply)
      if Bitwise.band(msg.flags, Wire.flag_no_reply()) == 0, do: send(me, {:dbus_send, out})
    end)

    st
  end

  defp reply(st, from, result) do
    GenServer.reply(from, result)
    st
  end

  defp safe(handler, msg) do
    handler.(msg.member, msg.body, msg)
  rescue
    e ->
      Logger.warning("dbus: #{msg[:path]} #{msg.member}: #{Exception.message(e)}")
      {:error, "org.freedesktop.DBus.Error.Failed", Exception.message(e)}
  end
end
