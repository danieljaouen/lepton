defmodule Lepton.Wayland.Conn do
  @moduledoc """
  A Wayland socket: listening, connecting, reading and sending messages
  with their file descriptors (`SCM_RIGHTS`).

  A reader process per connection forwards everything received to its
  owner as `{:wl_data, conn, bytes, fds}` (fds as integers) and
  `{:wl_closed, conn}`; the owner parses with `Lepton.Wayland.Wire`.
  """

  @doc "The socket path for `display` (`wayland-0`) in `XDG_RUNTIME_DIR`."
  def socket_path(env, display \\ nil) do
    display = display || env["WAYLAND_DISPLAY"] || "wayland-0"
    if String.starts_with?(display, "/"), do: display, else: Path.join(env["XDG_RUNTIME_DIR"] || "/run", display)
  end

  def listen(path) do
    _ = File.rm(path)

    with {:ok, sock} <- :socket.open(:local, :stream, :default),
         :ok <- :socket.bind(sock, %{family: :local, path: path}),
         :ok <- :socket.listen(sock) do
      File.chmod(path, 0o700)
      {:ok, sock}
    end
  end

  def connect(path) do
    with {:ok, sock} <- :socket.open(:local, :stream, :default) do
      case :socket.connect(sock, %{family: :local, path: path}) do
        :ok -> {:ok, sock}
        err -> :socket.close(sock) && err
      end
    end
  end

  @doc "Accept connections forever, handing each to `fun` (in the acceptor process)."
  def accept_loop(listener, fun) do
    case :socket.accept(listener) do
      {:ok, sock} ->
        fun.(sock)
        accept_loop(listener, fun)

      {:error, _} ->
        :ok
    end
  end

  @doc "Start the reader for `sock`, delivering to `owner`; it takes over the socket's controlling process."
  # The reader owns the socket (its controlling process) and watches the
  # process it reads for: when that ends, however it ends (a window's
  # process killed rather than closed), the socket is closed, and the
  # compositor drops its windows. (Before, a killed window's process left
  # its window on the screen, its socket held open by its reader.)
  def start_reader(sock, owner) do
    pid = spawn(fn -> read_loop(sock, owner, Process.monitor(owner)) end)
    _ = :socket.setopt(sock, {:otp, :controlling_process}, pid)
    pid
  end

  defp read_loop(sock, owner, mref) do
    case :socket.recvmsg(sock, 0, 512, [], :nowait) do
      {:ok, %{iov: iov} = msg} ->
        data = IO.iodata_to_binary(iov)
        fds = for %{level: :socket, type: :rights, data: d} <- Map.get(msg, :ctrl, []), <<fd::native-32 <- d>>, do: fd

        if data == "" and fds == [] do
          send(owner, {:wl_closed, sock})
        else
          send(owner, {:wl_data, sock, data, fds})
          read_loop(sock, owner, mref)
        end

      # Nothing yet: wait for data, or for the owner to end.
      {:select, {:select_info, _, ref}} ->
        receive do
          {:"$socket", ^sock, :select, ^ref} ->
            read_loop(sock, owner, mref)

          {:DOWN, ^mref, :process, _, _} ->
            :socket.close(sock)
        end

      {:error, _} ->
        send(owner, {:wl_closed, sock})
    end
  end

  @doc "Send `iodata` with `fds` (integers or native 32-bit binaries)."
  def send_data(sock, iodata, fds \\ []) do
    data = IO.iodata_to_binary(iodata)

    msg =
      case fds do
        [] -> %{iov: [data]}
        fds -> %{iov: [data], ctrl: [%{level: :socket, type: :rights, data: IO.iodata_to_binary(Enum.map(fds, &fd_bin/1))}]}
      end

    case :socket.sendmsg(sock, msg, 2000) do
      :ok -> :ok
      {:ok, rest} -> :socket.send(sock, rest, 2000) |> ok()
      err -> err
    end
  end

  defp ok({:ok, _}), do: :ok
  defp ok(other), do: other

  defp fd_bin(fd) when is_integer(fd), do: <<fd::native-32>>
  defp fd_bin(fd) when is_binary(fd), do: fd

  @doc "The descriptor number behind a raw file opened with `:file.open/2`."
  def file_fd(file), do: :prim_file.get_handle(file)

  @doc """
  Open a received descriptor as a file (`/proc/self/fd/N`, `/dev/fd/N` on
  macOS) and close the received one (`Lepton.FD`). Returns `{:ok, file}`.
  """
  def open_fd(fd, modes \\ [:read]) do
    path = if File.dir?("/proc/self/fd"), do: "/proc/self/fd/#{fd}", else: "/dev/fd/#{fd}"
    result = :file.open(String.to_charlist(path), [:raw, :binary | modes])
    close_fd(fd)
    result
  end

  @doc "Close a received descriptor the VM has no handle for."
  def close_fd(fd), do: Lepton.FD.close(fd)
end
