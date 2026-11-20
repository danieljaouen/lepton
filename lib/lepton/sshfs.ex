defmodule Lepton.SSHFS do
  @moduledoc """
  `sshfs`: a directory of another machine, mounted here over SSH.

  The kernel's FUSE driver passes every operation on the mount point
  (`ls`, `cat`, an editor saving, Firefox opening a file) to this
  process as a request read from `/dev/fuse`; each is answered with SFTP
  over Lepton's SSH connection (with its keys, known hosts, proxies and
  jump hosts), and the reply written back. Files appear owned by the
  account that mounted them, as sshfs's `idmap=user` does.

  The mount itself needs the `/dev/fuse` descriptor to belong to the
  process that mounts, the VM, so it is made by `Lepton.FD.mount/5`.
  `fusermount -u DIR` (or stopping the process) unmounts.
  """

  import Bitwise
  alias Lepton.SSH

  # FUSE opcodes (include/uapi/linux/fuse.h)
  @lookup 1
  @forget 2
  @getattr 3
  @setattr 4
  @readlink 5
  @symlink 6
  @mknod 8
  @mkdir 9
  @unlink 10
  @rmdir 11
  @rename 12
  @link 13
  @open 14
  @read 15
  @write 16
  @statfs 17
  @release 18
  @fsync 20
  @flush 25
  @init 26
  @opendir 27
  @readdir 28
  @releasedir 29
  @fsyncdir 30
  @access 34
  @create 35
  @interrupt 36
  @destroy 38
  @batch_forget 42

  # The kernel wants each read to hold a whole write; the VM's fd port
  # reads 64 KiB at a time.
  @max_write 32 * 1024

  @errno %{
    no_such_file: 2, enoent: 2, permission_denied: 13, eacces: 13, file_already_exists: 17, eexist: 17,
    not_a_directory: 20, enotdir: 20, file_is_a_directory: 21, eisdir: 21, invalid_parameter: 22,
    no_space_on_filesystem: 28, quota_exceeded: 122, dir_not_empty: 39, directory_not_empty: 39,
    op_unsupported: 38, enosys: 38
  }

  defstruct [:sftp, :conn, :base, :uid, :gid, nodes: %{1 => ""}, ids: %{"" => 1}, next: 2, handles: %{}, next_fh: 1]

  # -- mounting --------------------------------------------------------------------------------

  @doc """
  Mount `remote` (`[user@]host:[path]`) on `dir`. Options: SSH's
  (`:port`, `:identity`, `:home`, `:jump`, ...), `:uid`/`:gid` (whose the
  files appear to be). Returns `{:ok, pid}` once mounted.
  """
  def mount(remote, dir, opts \\ []) do
    {target, path} =
      case String.split(remote, ":", parts: 2) do
        [t, p] -> {t, p}
        [t] -> {t, ""}
      end

    me = self()

    pid =
      spawn(fn ->
        case setup(target, path, dir, opts) do
          {:ok, st, dev, port} ->
            :global.re_register_name({__MODULE__, dir}, self())
            send(me, {:sshfs, self(), :ok})
            serve(dev, port, st)

          {:error, msg} ->
            send(me, {:sshfs, self(), {:error, msg}})
        end
      end)

    receive do
      {:sshfs, ^pid, :ok} ->
        # If the server goes (kill, a crash), don't leave a dead mount.
        spawn(fn ->
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, _, _, _} ->
              if Enum.any?(Lepton.Sys.mounts(), &(&1.dir == dir)), do: Lepton.Sys.shim("umount", ["-l", dir])
          end
        end)

        {:ok, pid}

      {:sshfs, ^pid, error} -> error
    after
      60_000 -> Process.exit(pid, :kill); {:error, "timed out"}
    end
  end

  @doc "Connect and check the remote directory: `{:ok, state}` (the FUSE side's state)."
  def connect(target, path, opts) do
    with {:ok, conn, _cfg} <- SSH.connect(target, opts),
         {:ok, sftp} <- start_sftp(conn),
         base = if(path == "", do: ".", else: path),
         {:ok, %{type: :directory}} <- stat(sftp, base) |> dir_check(base) do
      {:ok, %__MODULE__{sftp: sftp, conn: conn, base: String.trim_trailing(base, "/"), uid: opts[:uid] || 0, gid: opts[:gid] || 0}}
    end
  end

  defp setup(target, path, dir, opts) do
    with {:ok, st} <- connect(target, path, opts),
         _ = Lepton.Kmod.modprobe("fuse", []),
         {:ok, dev} <- open_fuse(),
         <<fd::native-32>> = :prim_file.get_handle(dev),
         data = "fd=#{fd},rootmode=40000,user_id=#{st.uid},group_id=#{st.gid},allow_other,max_read=#{@max_write}",
         :ok <- fuse_mount("#{target}:#{path}", dir, data) do
      # Requests are read by an fd port: one read(2) each. (The raw file's
      # reads loop until the buffer is full, which /dev/fuse never fills.)
      Process.flag(:trap_exit, true)
      port = Port.open({:fd, fd, fd}, [:binary, :stream])
      {:ok, st, dev, port}
    else
      {:error, msg} when is_binary(msg) -> {:error, msg}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp start_sftp(conn) do
    case :ssh_sftp.start_channel(conn, timeout: 20_000) do
      {:ok, ch} -> {:ok, ch}
      {:error, r} -> {:error, "the server has no SFTP (#{inspect(r)})"}
    end
  end

  defp dir_check({:ok, %{type: :directory}} = ok, _), do: ok
  defp dir_check({:ok, _}, base), do: {:error, "#{base} is not a directory"}
  defp dir_check({:error, e}, base), do: {:error, "#{base}: #{e}"}

  defp open_fuse do
    case :file.open(~c"/dev/fuse", [:read, :write, :raw, :binary]) do
      {:ok, dev} -> {:ok, dev}
      {:error, r} -> {:error, "cannot open /dev/fuse (#{r}): FUSE is not available"}
    end
  end

  # MS_NOSUID | MS_NODEV
  defp fuse_mount(source, dir, data) do
    case Lepton.FD.mount(source, dir, "fuse.sshfs", 0x2 ||| 0x4, data) do
      :ok -> :ok
      {:error, e} -> {:error, "mount #{dir}: #{e}"}
    end
  end

  @doc "Unmount `dir` (the FUSE server then ends)."
  def unmount(dir) do
    case Lepton.Sys.umount(dir) do
      :ok ->
        # The server ends too (the kernel's abort of the connection is
        # not always seen by its read).
        case :global.whereis_name({__MODULE__, dir}) do
          pid when is_pid(pid) -> send(pid, :unmounted)
          _ -> :ok
        end

        :ok

      {:error, msg} ->
        {:error, msg}
    end
  end

  # -- serving ----------------------------------------------------------------------------------

  defp serve(dev, port, st) do
    receive do
      {^port, {:data, request}} ->
        {reply, st} = handle(request, st)
        trace(request, reply)
        # Replies go out by the raw file: one write(2) each.
        if reply, do: :file.write(dev, reply)
        if st == :destroy, do: finish(dev, port, nil), else: serve(dev, port, st)

      # Unmounted (ENODEV), or the device closed.
      {:EXIT, ^port, _} ->
        finish(dev, nil, st)

      :unmounted ->
        finish(dev, port, st)

      _ ->
        serve(dev, port, st)
    end
  end

  # Debugging: :persistent_term.put({Lepton.SSHFS, :trace}, pid) gets each
  # request's opcode and the reply's error.
  defp trace(<<_::little-32, op::little-32, _::binary>>, reply) do
    case :persistent_term.get({__MODULE__, :trace}, nil) do
      nil -> :ok
      pid -> send(pid, {:sshfs_trace, op, reply && binary_part(IO.iodata_to_binary(reply), 0, 8)})
    end
  end

  defp trace(_, _), do: :ok

  defp finish(dev, port, st) do
    if port, do: (try do Port.close(port) catch _, _ -> :ok end)
    :file.close(dev)
    if is_map(st), do: SSH.close(st.conn)
    :ok
  end

  @doc """
  Answer one request (a binary as read from /dev/fuse): `{reply | nil,
  state}` (the state is `:destroy` at the end).
  """
  def handle(<<len::little-32, opcode::little-32, unique::little-64, node::little-64, _uid::little-32, _gid::little-32, _pid::little-32, _rest::binary-4, body::binary>>, st) do
    body = binary_part(body, 0, min(byte_size(body), len - 40))

    try do
      op(opcode, node, body, st)
    catch
      {:errno, e} -> {{:error, e}, st}
    end
    |> case do
      {:noreply, st} -> {nil, st}
      {:destroy, _} -> {reply(unique, 0, ""), :destroy}
      {{:error, e}, st} -> {reply(unique, -e, ""), st}
      {{:ok, data}, st} -> {reply(unique, 0, data), st}
    end
  end

  defp reply(unique, error, data), do: [<<16 + IO.iodata_length(data)::little-32, error::little-signed-32, unique::little-64>>, data]

  # -- operations --------------------------------------------------------------------------------

  defp op(@init, _node, <<major::little-32, minor::little-32, readahead::little-32, _::binary>>, st) do
    minor = min(minor, 31)
    # FUSE_BIG_WRITES
    flags = 1 <<< 5
    _ = major

    {{:ok,
      <<7::little-32, minor::little-32, readahead::little-32, flags::little-32, 16::little-16, 12::little-16,
        @max_write::little-32, 1::little-32, 32::little-16, 0::little-16, 0::little-32, 0::little-32, 0::size(24 * 8)>>}, st}
  end

  defp op(@destroy, _, _, st), do: {:destroy, st}
  defp op(op, _, _, st) when op in [@forget, @batch_forget, @interrupt], do: {:noreply, st}

  defp op(@lookup, node, body, st) do
    name = cstring(body)
    path = child(st, node, name)
    attr = lstat!(st, path)
    {id, st} = node_id(st, path)
    {{:ok, entry(id, attr, st)}, st}
  end

  defp op(@getattr, node, _body, st) do
    attr = lstat!(st, path!(st, node))
    {{:ok, attr_out(node, attr, st)}, st}
  end

  defp op(@setattr, node, body, st) do
    <<valid::little-32, _::little-32, fh::little-64, size::little-64, _lock::little-64, atime::little-64, mtime::little-64,
      _ctime::little-64, _an::little-32, _mn::little-32, _cn::little-32, mode::little-32, _::binary>> = body

    path = path!(st, node)
    remote = remote(st, path)

    if (valid &&& 8) != 0 do
      handle = if (valid &&& 64) != 0, do: get_in(st.handles, [fh, :handle])
      truncate!(st, remote, handle, size)
    end

    info = %{}
    info = if (valid &&& 1) != 0, do: Map.put(info, :mode, mode &&& 0o7777), else: info
    now = System.os_time(:second)
    info = if (valid &&& 16) != 0, do: Map.put(info, :atime, if((valid &&& 128) != 0, do: now, else: atime)), else: info
    info = if (valid &&& 32) != 0, do: Map.put(info, :mtime, if((valid &&& 256) != 0, do: now, else: mtime)), else: info
    if info != %{}, do: set_info!(st, remote, info)

    {{:ok, attr_out(node, lstat!(st, path), st)}, st}
  end

  defp op(@readlink, node, _body, st) do
    case :ssh_sftp.read_link(st.sftp, ch(remote(st, path!(st, node)))) do
      {:ok, target} -> {{:ok, to_string(target)}, st}
      {:error, e} -> throw({:errno, errno(e)})
    end
  end

  defp op(@symlink, node, body, st) do
    [name, target | _] = :binary.split(body, <<0>>, [:global])
    path = child(st, node, name)
    ok!(:ssh_sftp.make_symlink(st.sftp, ch(remote(st, path)), ch(target)))
    new_entry(st, path)
  end

  defp op(@mknod, _node, _body, st), do: {{:error, 1}, st}
  defp op(@link, _node, _body, st), do: {{:error, 1}, st}

  defp op(@mkdir, node, <<mode::little-32, _umask::little-32, rest::binary>>, st) do
    path = child(st, node, cstring(rest))
    ok!(:ssh_sftp.make_dir(st.sftp, ch(remote(st, path))))
    _ = set_info(st, remote(st, path), %{mode: mode &&& 0o7777})
    new_entry(st, path)
  end

  defp op(@unlink, node, body, st) do
    path = child(st, node, cstring(body))
    ok!(:ssh_sftp.delete(st.sftp, ch(remote(st, path))))
    {{:ok, ""}, forget(st, path)}
  end

  defp op(@rmdir, node, body, st) do
    path = child(st, node, cstring(body))
    ok!(:ssh_sftp.del_dir(st.sftp, ch(remote(st, path))))
    {{:ok, ""}, forget(st, path)}
  end

  defp op(@rename, node, <<newdir::little-64, rest::binary>>, st) do
    [old, new | _] = :binary.split(rest, <<0>>, [:global])
    from = child(st, node, old)
    to = child(st, newdir, new)
    # SFTP's rename won't replace; POSIX's does.
    if match?({:ok, %{type: t}} when t != :directory, stat(st.sftp, remote(st, to), :lstat)),
      do: _ = :ssh_sftp.delete(st.sftp, ch(remote(st, to)))

    ok!(:ssh_sftp.rename(st.sftp, ch(remote(st, from)), ch(remote(st, to))))
    {{:ok, ""}, renamed(st, from, to)}
  end

  defp op(@open, node, <<flags::little-32, _::binary>>, st) do
    path = path!(st, node)
    {handle, st} = open!(st, remote(st, path), modes(flags))
    {{:ok, <<handle::little-64, 0::little-32, 0::little-32>>}, st}
  end

  defp op(@create, node, <<flags::little-32, mode::little-32, _umask::little-32, _open::little-32, rest::binary>>, st) do
    path = child(st, node, cstring(rest))
    {fh, st} = open!(st, remote(st, path), Enum.uniq([:creat, :trunc | modes(flags)]) -- [:append])
    _ = set_info(st, remote(st, path), %{mode: mode &&& 0o7777})
    attr = lstat!(st, path)
    {id, st} = node_id(st, path)
    {{:ok, [entry(id, attr, st), <<fh::little-64, 0::little-32, 0::little-32>>]}, st}
  end

  defp op(@read, _node, <<fh::little-64, offset::little-64, size::little-32, _::binary>>, st) do
    case :ssh_sftp.pread(st.sftp, handle!(st, fh), offset, size) do
      {:ok, data} -> {{:ok, data}, st}
      :eof -> {{:ok, ""}, st}
      {:error, e} -> throw({:errno, errno(e)})
    end
  end

  defp op(@write, _node, <<fh::little-64, offset::little-64, size::little-32, _flags::little-32, _lock::little-64, _f::little-32, _pad::little-32, data::binary>>, st) do
    data = binary_part(data, 0, min(size, byte_size(data)))
    ok!(:ssh_sftp.pwrite(st.sftp, handle!(st, fh), offset, data))
    {{:ok, <<byte_size(data)::little-32, 0::little-32>>}, st}
  end

  defp op(op, _node, <<fh::little-64, _::binary>>, st) when op in [@release, @releasedir] do
    case Map.pop(st.handles, fh) do
      {%{handle: h}, handles} when h != nil -> _ = :ssh_sftp.close(st.sftp, h); {{:ok, ""}, %{st | handles: handles}}
      {_, handles} -> {{:ok, ""}, %{st | handles: handles}}
    end
  end

  defp op(op, _node, _body, st) when op in [@flush, @fsync, @fsyncdir, @access], do: {{:ok, ""}, st}

  defp op(@opendir, node, _body, st) do
    path = path!(st, node)

    case :ssh_sftp.list_dir(st.sftp, ch(remote(st, path))) do
      {:ok, names} ->
        entries = [".", ".." | names |> Enum.map(&to_string/1) |> Enum.reject(&(&1 in [".", ".."])) |> Enum.sort()]
        fh = st.next_fh
        {{:ok, <<fh::little-64, 0::little-32, 0::little-32>>}, %{st | handles: Map.put(st.handles, fh, %{entries: entries}), next_fh: fh + 1}}

      {:error, e} ->
        throw({:errno, errno(e)})
    end
  end

  defp op(@readdir, _node, <<fh::little-64, offset::little-64, size::little-32, _::binary>>, st) do
    entries = get_in(st.handles, [fh, :entries]) || []

    data =
      entries
      |> Enum.with_index(1)
      |> Enum.drop(offset)
      |> Enum.reduce_while([], fn {name, i}, acc ->
        dirent = dirent(:erlang.phash2(name, 0xFFFFFF) + 2, i, name)
        if IO.iodata_length([acc, dirent]) > size, do: {:halt, acc}, else: {:cont, [acc, dirent]}
      end)

    {{:ok, data}, st}
  end

  defp op(@statfs, _node, _body, st) do
    {{:ok, <<1_000_000::little-64, 500_000::little-64, 500_000::little-64, 1_000_000::little-64, 500_000::little-64,
             4096::little-32, 255::little-32, 4096::little-32, 0::little-32, 0::size(24 * 8)>>}, st}
  end

  defp op(_op, _node, _body, st), do: {{:error, 38}, st}

  # -- helpers ---------------------------------------------------------------------------------

  defp cstring(bin), do: bin |> :binary.split(<<0>>) |> hd()

  defp path!(st, node) do
    case Map.fetch(st.nodes, node) do
      {:ok, p} -> p
      :error -> throw({:errno, 2})
    end
  end

  defp child(st, node, name) do
    parent = path!(st, node)
    if parent == "", do: name, else: parent <> "/" <> name
  end

  defp remote(st, ""), do: st.base
  defp remote(st, path), do: st.base <> "/" <> path

  defp ch(s), do: String.to_charlist(s)

  defp node_id(st, path) do
    case Map.fetch(st.ids, path) do
      {:ok, id} -> {id, st}
      :error -> {st.next, %{st | ids: Map.put(st.ids, path, st.next), nodes: Map.put(st.nodes, st.next, path), next: st.next + 1}}
    end
  end

  defp new_entry(st, path) do
    attr = lstat!(st, path)
    {id, st} = node_id(st, path)
    {{:ok, entry(id, attr, st)}, st}
  end

  defp forget(st, path) do
    case Map.pop(st.ids, path) do
      {nil, _} -> st
      {id, ids} -> %{st | ids: ids, nodes: Map.delete(st.nodes, id)}
    end
  end

  # A rename moves the node, and everything below it.
  defp renamed(st, from, to) do
    st = forget(st, to)

    moved =
      for {path, id} <- st.ids, path == from or String.starts_with?(path, from <> "/"), into: %{} do
        {id, to <> binary_part(path, byte_size(from), byte_size(path) - byte_size(from))}
      end

    ids = st.ids |> Map.reject(fn {_, id} -> Map.has_key?(moved, id) end) |> Map.merge(Map.new(moved, fn {id, p} -> {p, id} end))
    %{st | ids: ids, nodes: Map.merge(st.nodes, moved)}
  end

  defp modes(flags) do
    access =
      case flags &&& 3 do
        0 -> [:read]
        1 -> [:write]
        _ -> [:read, :write]
      end

    access ++ [:binary] ++ if((flags &&& 0o1000) != 0, do: [:trunc], else: []) ++ if((flags &&& 0o2000) != 0, do: [:append], else: [])
  end

  defp open!(st, remote, modes) do
    case :ssh_sftp.open(st.sftp, ch(remote), modes) do
      {:ok, h} ->
        fh = st.next_fh
        {fh, %{st | handles: Map.put(st.handles, fh, %{handle: h}), next_fh: fh + 1}}

      {:error, e} ->
        throw({:errno, errno(e)})
    end
  end

  defp handle!(st, fh) do
    case get_in(st.handles, [fh, :handle]) do
      nil -> throw({:errno, 9})
      h -> h
    end
  end

  # SFTP's own way (the size attribute) isn't applied by every server
  # (OTP's isn't), so: to zero, open with truncation; shorter, rewrite the
  # part kept; longer, write a zero at the new end.
  defp truncate!(st, remote, _handle, size) do
    current = case stat(st.sftp, remote) do
      {:ok, %{size: n}} -> n
      {:error, e} -> throw({:errno, errno(e)})
    end

    cond do
      size == current ->
        :ok

      size > current ->
        with_file!(st, remote, [:write, :binary], &ok!(:ssh_sftp.pwrite(st.sftp, &1, size - 1, <<0>>)))

      true ->
        kept = if size == 0, do: "", else: with_file!(st, remote, [:read, :binary], &read_all!(st, &1, size))
        with_file!(st, remote, [:write, :trunc, :binary], fn h -> if kept != "", do: ok!(:ssh_sftp.pwrite(st.sftp, h, 0, kept)) end)
    end
  end

  defp with_file!(st, remote, modes, fun) do
    case :ssh_sftp.open(st.sftp, ch(remote), modes) do
      {:ok, h} ->
        try do
          fun.(h)
        after
          :ssh_sftp.close(st.sftp, h)
        end

      {:error, e} ->
        throw({:errno, errno(e)})
    end
  end

  defp read_all!(st, h, size), do: read_all!(st, h, size, 0, [])

  defp read_all!(_st, _h, size, pos, acc) when pos >= size, do: IO.iodata_to_binary(Enum.reverse(acc))

  defp read_all!(st, h, size, pos, acc) do
    case :ssh_sftp.pread(st.sftp, h, pos, min(65_536, size - pos)) do
      {:ok, data} -> read_all!(st, h, size, pos + byte_size(data), [data | acc])
      :eof -> IO.iodata_to_binary(Enum.reverse(acc))
      {:error, e} -> throw({:errno, errno(e)})
    end
  end

  defp set_info!(st, remote, info), do: ok!(set_info(st, remote, info))

  defp set_info(st, remote, info) do
    with {:ok, fi} <- :ssh_sftp.read_file_info(st.sftp, ch(remote)) do
      fi = if Map.has_key?(info, :mode), do: put_elem(fi, 7, (elem(fi, 7) &&& bnot(0o7777)) ||| info.mode), else: fi
      fi = if Map.has_key?(info, :size), do: put_elem(fi, 1, info.size), else: fi
      fi = if Map.has_key?(info, :mtime), do: put_elem(fi, 5, to_local(info.mtime)), else: fi
      fi = if Map.has_key?(info, :atime), do: put_elem(fi, 4, to_local(info.atime)), else: fi
      :ssh_sftp.write_file_info(st.sftp, ch(remote), fi)
    end
  end

  defp ok!(:ok), do: :ok
  defp ok!({:ok, _}), do: :ok
  defp ok!({:error, e}), do: throw({:errno, errno(e)})

  defp errno(e) when is_atom(e), do: Map.get(@errno, e, 5)
  defp errno(_), do: 5

  # -- attributes ---------------------------------------------------------------------------------

  @doc false
  def stat(sftp, remote, how \\ :stat) do
    fun = if how == :lstat, do: :read_link_info, else: :read_file_info

    case apply(:ssh_sftp, fun, [sftp, ch(remote)]) do
      {:ok, {:file_info, size, type, _access, atime, mtime, ctime, mode, links, _maj, _min, _ino, _uid, _gid}} ->
        {:ok, %{size: size, type: type, atime: to_posix(atime), mtime: to_posix(mtime), ctime: to_posix(ctime), mode: mode, links: links}}

      {:error, e} ->
        {:error, e}
    end
  end

  defp lstat!(st, path) do
    case stat(st.sftp, remote(st, path), :lstat) do
      {:ok, a} -> a
      {:error, e} -> throw({:errno, errno(e)})
    end
  end

  # ssh_sftp gives times in the VM's local time.
  defp to_posix({{_, _, _}, {_, _, _}} = dt) do
    [utc | _] = :calendar.local_time_to_universal_time_dst(dt) ++ [dt]
    :calendar.datetime_to_gregorian_seconds(utc) - 62_167_219_200
  end

  defp to_posix(n) when is_integer(n), do: n
  defp to_posix(_), do: 0

  defp to_local(posix), do: :calendar.universal_time_to_local_time(:calendar.gregorian_seconds_to_datetime(posix + 62_167_219_200))

  @type_bits %{regular: 0o100000, directory: 0o040000, symlink: 0o120000}

  defp attr(id, a, st) do
    mode = if (a.mode &&& 0o170000) == 0, do: a.mode ||| Map.get(@type_bits, a.type, 0o100000), else: a.mode
    blocks = div(a.size + 511, 512)

    <<id::little-64, a.size::little-64, blocks::little-64, a.atime::little-64, a.mtime::little-64, a.ctime::little-64,
      0::little-32, 0::little-32, 0::little-32, mode::little-32, max(a.links, 1)::little-32, st.uid::little-32,
      st.gid::little-32, 0::little-32, 4096::little-32, 0::little-32>>
  end

  # One second of caching for names and attributes.
  defp entry(id, a, st), do: [<<id::little-64, 0::little-64, 1::little-64, 1::little-64, 0::little-32, 0::little-32>>, attr(id, a, st)]
  defp attr_out(id, a, st), do: [<<1::little-64, 0::little-32, 0::little-32>>, attr(id, a, st)]

  defp dirent(ino, off, name) do
    n = byte_size(name)
    pad = rem(8 - rem(24 + n, 8), 8)
    <<ino::little-64, off::little-64, n::little-32, 0::little-32>> <> name <> :binary.copy(<<0>>, pad)
  end
end
