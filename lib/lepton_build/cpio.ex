defmodule LeptonBuild.Cpio do
  @moduledoc """
  Writer for the `newc` cpio format the Linux kernel unpacks as initramfs.

  Entries:

    * `{:dir, path, mode}`
    * `{:file, path, mode, {:data, binary} | {:path, host_path}}`
    * `{:symlink, path, target}`
    * `{:chardev, path, mode, major, minor}`
  """

  import Bitwise

  @s_ifdir 0o040000
  @s_ifreg 0o100000
  @s_iflnk 0o120000
  @s_ifchr 0o020000

  @doc """
  Writes the archive zstd-compressed to `dest` (level 19): smaller than
  gzip, and the kernel unpacks it several times faster, which counts
  where the CPU is emulated (UTM on an iPad).
  """
  def write_zstd!(entries, dest) do
    {:ok, z} = :zstd.context(:compress, %{compressionLevel: 19})
    {:ok, io} = File.open(dest, [:write, :binary, :raw])

    emit = fn data -> IO.binwrite(io, zstd_stream(z, data)) end

    entries
    |> Enum.with_index(1)
    |> Enum.each(fn {entry, ino} -> emit.(encode(entry, ino)) end)

    emit.(record("TRAILER!!!", 0, 0, 0, 0, 0, <<>>))
    {:done, out} = :zstd.finish(z, [])
    IO.binwrite(io, out)
    :zstd.close(z)
    File.close(io)
  end

  defp zstd_stream(z, data) do
    case :zstd.stream(z, data) do
      {:continue, out} -> out
      {:continue, rest, out} -> [out | zstd_stream(z, rest)]
    end
  end

  @doc "Writes the archive gzip-compressed to `dest`."
  def write_gzip!(entries, dest) do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, 9, :deflated, 31, 8, :default)
    {:ok, io} = File.open(dest, [:write, :binary, :raw])

    emit = fn data -> IO.binwrite(io, :zlib.deflate(z, data)) end

    entries
    |> Enum.with_index(1)
    |> Enum.each(fn {entry, ino} -> emit.(encode(entry, ino)) end)

    emit.(record("TRAILER!!!", 0, 0, 0, 0, 0, <<>>))
    IO.binwrite(io, :zlib.deflate(z, [], :finish))
    :zlib.deflateEnd(z)
    :zlib.close(z)
    File.close(io)
  end

  def encode({:dir, path, mode}, ino), do: record(path, ino, @s_ifdir ||| mode, 2, 0, 0, <<>>)

  def encode({:file, path, mode, source}, ino) do
    data =
      case source do
        {:data, bin} -> bin
        {:path, host} -> File.read!(host)
      end

    record(path, ino, @s_ifreg ||| mode, 1, 0, 0, data)
  end

  def encode({:symlink, path, target}, ino), do: record(path, ino, @s_iflnk ||| 0o777, 1, 0, 0, target)

  def encode({:chardev, path, mode, major, minor}, ino),
    do: record(path, ino, @s_ifchr ||| mode, 1, major, minor, <<>>)

  defp record(path, ino, mode, nlink, rmajor, rminor, data) do
    name = String.trim_leading(path, "/") <> <<0>>
    name = if name == <<0>>, do: ".\0", else: name

    header =
      [
        "070701",
        hex(ino),
        hex(mode),
        hex(0),
        hex(0),
        hex(nlink),
        hex(0),
        hex(byte_size(data)),
        hex(0),
        hex(0),
        hex(rmajor),
        hex(rminor),
        hex(byte_size(name)),
        hex(0)
      ]
      |> IO.iodata_to_binary()

    head = header <> name
    [head, pad4(byte_size(head)), data, pad4(byte_size(data))]
  end

  defp hex(n), do: n |> Integer.to_string(16) |> String.pad_leading(8, "0")
  defp pad4(n), do: :binary.copy(<<0>>, rem(4 - rem(n, 4), 4))
end
