defmodule Lepton.Copy do
  @moduledoc """
  Copying files and trees for `cp` and `mv`, safely at any size.

  - In chunks (8 MiB), in the command's own process, so Ctrl-C stops it
    between two chunks (the partial file is left, as GNU cp leaves it).
  - Written out as it goes (`fdatasync` every 64 MiB): a big copy doesn't
    pile up gigabytes of unwritten pages, which stall the whole machine
    while the kernel catches up on a slow disk.
  - Checked for space first: the copy has to fit on the file system it
    goes to. `/` (and `/tmp`) is in memory on Lepton, so a big copy there
    (over 64 MiB) must also leave the machine some memory: 512 MiB, or an
    eighth of it on a small machine. Otherwise it's refused, rather than
    filling memory until the system hangs. (Small copies are left alone:
    they can't hang anything, and a machine short of memory still copies
    its little files.)
  """

  import Bitwise

  @chunk 8 <<< 20
  @sync_every 64 <<< 20
  @reserve 512 <<< 20
  @small 64 <<< 20
  @in_memory ~w(rootfs tmpfs ramfs)

  @doc "Copy `src` (a file, a symbolic link or, with `recursive`, a folder) to `dst`."
  def copy(src, dst, recursive \\ false) do
    case File.lstat(src) do
      {:ok, %{type: :directory}} when not recursive -> {:error, :eisdir}
      # (A file it replaces gives its space back.)
      {:ok, _} -> with :ok <- fits(dst, size(src) - replaced(dst)), do: copy_any(src, dst)
      err -> err
    end
  end

  defp replaced(dst) do
    case File.lstat(dst) do
      {:ok, %{type: :regular, size: s}} -> s
      _ -> 0
    end
  end

  @doc "Bytes in `path`, everything in it included (links not followed)."
  def size(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        case File.ls(path) do
          {:ok, names} -> Enum.reduce(names, 0, &(&2 + size(Path.join(path, &1))))
          _ -> 0
        end

      {:ok, %{type: :regular, size: s}} ->
        s

      _ ->
        0
    end
  end

  @doc "`:ok` if `bytes` fit where `dst` goes, `{:error, :enospc}` if not."
  def fits(dst, bytes) do
    case where(dst) do
      nil -> :ok
      %{avail: avail, memory?: false} -> if bytes <= avail, do: :ok, else: {:error, :enospc}
      %{memory?: true} when bytes <= @small -> :ok
      %{avail: avail, total: total} -> if bytes <= avail - min(@reserve, div(total, 8)), do: :ok, else: {:error, :enospc}
    end
  end

  # The file system `dst` goes to: what's free there; for one in memory,
  # no more than the memory the machine has free.
  defp where(dst) do
    mounts = Lepton.Sys.mounts()
    dir = existing_parent(Path.expand(dst))

    case Lepton.DiskFree.rows(mounts, [dir], &Lepton.Sys.statfs/1, Lepton.Sys.meminfo()) do
      [%{avail: avail, dir: mount}] ->
        type = Enum.find_value(mounts, &(&1.dir == mount && &1.type))
        memory? = type in @in_memory
        info = Lepton.Sys.meminfo()
        mem = Map.get(info, "MemAvailable")
        avail = if memory? and is_integer(mem), do: min(avail, mem), else: avail
        %{avail: avail, memory?: memory?, total: Map.get(info, "MemTotal") || 0}

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp existing_parent(path) do
    cond do
      File.dir?(path) -> path
      Path.dirname(path) == path -> path
      true -> existing_parent(Path.dirname(path))
    end
  end

  defp copy_any(src, dst) do
    case File.lstat(src) do
      {:ok, %{type: :directory, mode: mode}} ->
        with :ok <- mkdir(dst),
             {:ok, names} <- File.ls(src),
             :ok <- each(Enum.sort(names), &copy_any(Path.join(src, &1), Path.join(dst, &1))) do
          File.chmod(dst, mode &&& 0o7777)
        end

      {:ok, %{type: :symlink}} ->
        {:ok, target} = :file.read_link_all(String.to_charlist(src))
        _ = File.rm(dst)
        File.ln_s(List.to_string(target), dst)

      {:ok, %{type: :regular}} ->
        file(src, dst)

      {:ok, _} ->
        # A device, a socket or a pipe: as cp -r without its special-file options.
        {:error, :einval}

      err ->
        err
    end
  end

  defp mkdir(dst) do
    case File.mkdir(dst) do
      {:error, :eexist} -> if File.dir?(dst), do: :ok, else: {:error, :eexist}
      other -> other
    end
  end

  defp each([], _fun), do: :ok

  defp each([x | rest], fun) do
    case fun.(x) do
      :ok -> each(rest, fun)
      err -> err
    end
  end

  @doc "Copy one regular file, in chunks, syncing as it goes; the mode comes along."
  def file(src, dst) do
    with {:ok, %{mode: mode}} <- File.stat(src),
         {:ok, in_fd} <- :file.open(src, [:read, :raw, :binary]) do
      try do
        with {:ok, out_fd} <- :file.open(dst, [:write, :raw, :binary]) do
          try do
            pump(in_fd, out_fd, 0)
          after
            :file.close(out_fd)
          end
          |> case do
            :ok -> File.chmod(dst, mode &&& 0o7777)
            err -> err
          end
        end
      after
        :file.close(in_fd)
      end
    end
  end

  defp pump(in_fd, out_fd, unsynced) do
    case :file.read(in_fd, @chunk) do
      {:ok, data} ->
        with :ok <- :file.write(out_fd, data) do
          unsynced = unsynced + byte_size(data)

          if unsynced >= @sync_every do
            _ = :file.datasync(out_fd)
            pump(in_fd, out_fd, 0)
          else
            pump(in_fd, out_fd, unsynced)
          end
        end

      :eof ->
        :ok

      err ->
        err
    end
  end
end
