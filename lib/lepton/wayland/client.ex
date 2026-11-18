defmodule Lepton.Wayland.Client do
  @moduledoc """
  The client side of the Wayland protocol, for Lepton's own graphical
  programs (`Lepton.Photon.Term`) and the tests.

  A functional connection state used inside the client's process: the
  reader delivers `{:wl_data, sock, data, fds}` messages, which
  `handle_data/3` turns into events `{id, interface, event, args}`.

      {:ok, c} = Client.connect(path)
      {c, globals} = Client.registry(c)
      {c, compositor} = Client.bind(c, "wl_compositor", 4)
  """

  alias Lepton.Wayland.{Conn, Protocol, Wire}

  defstruct [:sock, :registry, buf: "", fds: [], next_id: 2, objects: %{1 => "wl_display"}, globals: %{}]

  def connect(path) do
    with {:ok, sock} <- Conn.connect(path) do
      Conn.start_reader(sock, self())
      {:ok, %__MODULE__{sock: sock}}
    end
  end

  def close(%__MODULE__{sock: sock}), do: :socket.close(sock)

  @doc "Allocate an ID for a new object of `iface`."
  def new_id(c, iface), do: {%{c | next_id: c.next_id + 1, objects: Map.put(c.objects, c.next_id, iface)}, c.next_id}

  @doc "Send request `name` on object `id`. Arguments are in protocol order (fds included)."
  def request(c, id, name, args) do
    iface = Map.fetch!(c.objects, id)
    {op, types} = Protocol.request_op(iface, name)
    {data, fds} = Wire.encode(id, op, types, args)
    :ok = Conn.send_data(c.sock, data, fds)
    c
  end

  @doc "Send a request that creates an object: `{c, new_id}`. `args` has `:new` where the ID goes."
  def create(c, id, name, iface, args \\ [:new]) do
    {c, new} = new_id(c, iface)
    {request(c, id, name, Enum.map(args, &if(&1 == :new, do: new, else: &1))), new}
  end

  @doc "Parse received data: `{events, c}`."
  def handle_data(c, data, fds) do
    {msgs, rest} = Wire.split(c.buf <> data)
    c = %{c | buf: rest, fds: c.fds ++ fds}

    Enum.reduce(msgs, {[], c}, fn {id, op, payload}, {events, c} ->
      case Map.fetch(c.objects, id) do
        {:ok, iface} ->
          {name, types} = Protocol.event(iface, op)
          {args, fds} = Wire.decode(types, payload, c.fds)
          c = %{c | fds: fds}

          case {iface, name, args} do
            {"wl_display", :delete_id, [gone]} -> {events, %{c | objects: Map.delete(c.objects, gone)}}
            {"wl_display", :error, [obj, code, msg]} -> raise "Wayland error on object #{obj} (code #{code}): #{msg}"
            {"wl_registry", :global, [n, gi, v]} -> {events ++ [{id, iface, name, args}], %{c | globals: Map.put(c.globals, gi, {n, v})}}
            _ -> {events ++ [{id, iface, name, args}], c}
          end

        :error ->
          {events, c}
      end
    end)
  end

  @doc """
  Wait (receiving `:wl_data`) until the server has handled everything sent
  so far. Events that arrive meanwhile are returned. Raises on a closed
  connection or after `timeout`.
  """
  def roundtrip(c, timeout \\ 5000) do
    {c, cb} = create(c, 1, :sync, "wl_callback")
    wait(c, cb, [], timeout)
  end

  defp wait(c, cb, acc, timeout) do
    sock = c.sock

    receive do
      {:wl_data, ^sock, data, fds} ->
        {events, c} = handle_data(c, data, fds)

        if Enum.any?(events, &match?({^cb, _, :done, _}, &1)),
          do: {c, acc ++ Enum.reject(events, &match?({^cb, _, _, _}, &1))},
          else: wait(c, cb, acc ++ events, timeout)

      {:wl_closed, ^sock} ->
        raise "Wayland connection closed"
    after
      timeout -> raise "Wayland roundtrip timed out"
    end
  end

  @doc "Get the registry and its globals: `{c, %{interface => {name, version}}}`."
  def registry(c) do
    {c, reg} = create(c, 1, :get_registry, "wl_registry")
    {c, _events} = roundtrip(c)
    {%{c | registry: reg}, c.globals}
  end

  @doc "Bind a global at `min(version, advertised)`: `{c, id}`."
  def bind(c, iface, version) do
    {name, max} = Map.fetch!(c.globals, iface)
    {c, id} = new_id(c, iface)
    {request(c, c.registry, :bind, [name, {iface, min(version, max), id}]), id}
  end

  # -- shared memory --------------------------------------------------------------------------

  @doc """
  A shared-memory pool of `size` bytes: a file in `dir` (the compositor's
  `XDG_RUNTIME_DIR`), handed to the compositor through `shm`, a
  `lepton_shm` (by path; the compositor removes the file) or a `wl_shm`
  (by descriptor). Returns `{c, pool_id, file}`; draw by `:file.pwrite/3`
  on the file.
  """
  def shm_pool(c, shm, size, dir) do
    path = Path.join(dir, "lepton-shm-#{System.unique_integer([:positive])}")
    {:ok, f} = :file.open(String.to_charlist(path), [:raw, :binary, :read, :write])
    {:ok, _} = :file.position(f, size)
    :ok = :file.truncate(f)
    {c, pool} = new_id(c, "wl_shm_pool")

    c =
      case c.objects[shm] do
        "lepton_shm" ->
          request(c, shm, :create_pool, [pool, path, size])

        "wl_shm" ->
          File.rm(path)
          request(c, shm, :create_pool, [pool, Conn.file_fd(f), size])
      end

    {c, pool, f}
  end
end
