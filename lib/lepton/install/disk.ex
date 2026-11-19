defmodule Lepton.Install.Disk do
  @moduledoc """
  Raw block-device access for the installer: device discovery from sysfs
  and positioned reads/writes on `/dev/*` nodes.
  """

  import Bitwise, only: [<<<: 2]

  @doc "Candidate install targets: [%{name, path, bytes, model, removable}]."
  def disks do
    case File.ls("/sys/block") do
      {:ok, names} ->
        names
        |> Enum.filter(&Regex.match?(~r/^(vd[a-z]+|sd[a-z]+|nvme\d+n\d+|xvd[a-z]+|mmcblk\d+)$/, &1))
        |> Enum.map(fn name ->
          sectors = read_int("/sys/block/#{name}/size")
          %{
            name: name,
            path: "/dev/" <> name,
            bytes: sectors * 512,
            model: read("/sys/block/#{name}/device/model") || read("/sys/block/#{name}/device/vendor") || "virtual disk",
            removable: read("/sys/block/#{name}/removable") == "1"
          }
        end)
        |> Enum.reject(&(&1.bytes == 0))
        |> Enum.sort_by(& &1.name)

      _ ->
        []
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, v} -> String.trim(v)
      _ -> nil
    end
  end

  defp read_int(path), do: path |> read() |> Kernel.||("0") |> String.to_integer()

  def human(bytes) when bytes >= 1 <<< 30, do: "#{Float.round(bytes / (1 <<< 30), 1)} GiB"
  def human(bytes), do: "#{div(bytes, 1 <<< 20)} MiB"

  def open(path), do: :file.open(path, [:read, :write, :raw, :binary])
  def open_read(path), do: :file.open(path, [:read, :raw, :binary])
  def pwrite(fd, offset, data), do: :ok = :file.pwrite(fd, offset, data)

  @doc "Write `bytes` zero bytes starting at `offset`, in large chunks."
  def zero(fd, offset, bytes) do
    chunk = :binary.copy(<<0>>, min(bytes, 1 <<< 20))

    Stream.unfold(0, fn
      done when done >= bytes -> nil
      done -> {done, done + byte_size(chunk)}
    end)
    |> Enum.each(fn done ->
      n = min(byte_size(chunk), bytes - done)
      pwrite(fd, offset + done, binary_part(chunk, 0, n))
    end)
  end

  @doc "Copy a host file into the device at `offset`."
  def copy_file(fd, offset, path) do
    {:ok, src} = :file.open(path, [:read, :raw, :binary])

    try do
      copy_loop(src, fd, offset)
    after
      :file.close(src)
    end
  end

  defp copy_loop(src, fd, offset) do
    case :file.read(src, 1 <<< 20) do
      {:ok, data} ->
        pwrite(fd, offset, data)
        copy_loop(src, fd, offset + byte_size(data))

      :eof ->
        :ok
    end
  end
end

defmodule Lepton.Install.GPT do
  @moduledoc """
  GUID Partition Table writer/reader (UEFI spec 2.x, 512-byte LBAs):
  protective MBR, primary header and entry array, backup array and header.
  """

  @esp_type "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
  @linux_type "0FC63DAF-8483-4772-8E79-3D69D8477DE4"
  @entries 128
  @entry_size 128

  def esp_type, do: @esp_type
  def linux_type, do: @linux_type

  @doc """
  Build the partition table for a disk of `sectors` LBAs.
  `partitions` is [%{type, name, first, last}], numbered in order, or each
  at its own `index` (1-based: other systems' partitions keep their
  numbers). `type` is a GUID string or its 16 on-disk bytes; `guid` (the
  partition's own, on-disk bytes) and `attrs` are kept when given.
  Returns [{byte_offset, binary}] to write.
  """
  def build(sectors, partitions, disk_guid \\ random_guid()) do
    entry_lbas = div(@entries * @entry_size, 512)
    last_usable = sectors - 1 - entry_lbas - 1

    slots =
      partitions
      |> Enum.with_index(1)
      |> Map.new(fn {p, i} -> {p[:index] || i, p} end)

    entries =
      for i <- 1..@entries, into: <<>> do
        case slots[i] do
          nil ->
            :binary.copy(<<0>>, @entry_size)

          p ->
            name = p.name |> :unicode.characters_to_binary(:utf8, {:utf16, :little}) |> pad(72)
            type = if byte_size(p.type) == 16, do: p.type, else: guid(p.type)
            type <> (p[:guid] || random_guid()) <> <<p.first::little-64, p.last::little-64, (p[:attrs] || 0)::little-64>> <> binary_part(name, 0, 72)
        end
      end

    entries_crc = :erlang.crc32(entries)

    primary = header(1, sectors - 1, 2, last_usable, disk_guid, entries_crc)
    backup = header(sectors - 1, 1, sectors - 1 - entry_lbas, last_usable, disk_guid, entries_crc)

    [
      {0, protective_mbr(sectors)},
      {512, primary},
      {1024, entries},
      {(sectors - 1 - entry_lbas) * 512, entries},
      {(sectors - 1) * 512, backup}
    ]
  end

  defp header(my_lba, alt_lba, entries_lba, last_usable, disk_guid, entries_crc) do
    fields = fn crc ->
      <<"EFI PART", 0x00010000::little-32, 92::little-32, crc::little-32, 0::32, my_lba::little-64, alt_lba::little-64,
        34::little-64, last_usable::little-64>> <>
        disk_guid <> <<entries_lba::little-64, @entries::little-32, @entry_size::little-32, entries_crc::little-32>>
    end

    crc = :erlang.crc32(fields.(0))
    pad(fields.(crc), 512)
  end

  defp protective_mbr(sectors) do
    size = min(sectors - 1, 0xFFFFFFFF)
    part = <<0, 0, 2, 0, 0xEE, 0xFF, 0xFF, 0xFF, 1::little-32, size::little-32>>
    :binary.copy(<<0>>, 446) <> part <> :binary.copy(<<0>>, 48) <> <<0x55, 0xAA>>
  end

  @doc "Encode a GUID string in the mixed-endian on-disk layout."
  def guid(text) do
    [a, b, c, d, e] = text |> String.split("-") |> Enum.map(&Base.decode16!(&1, case: :mixed))
    <<x::32>> = a
    <<y::16>> = b
    <<z::16>> = c
    <<x::little-32, y::little-16, z::little-16>> <> d <> e
  end

  @doc "A stable GUID derived from `seed` (for reproducible images)."
  def guid_from(seed) do
    <<a::48, _::4, b::12, _::2, c::62, _::binary>> = :crypto.hash(:sha256, seed)
    <<a::48, 4::4, b::12, 2::2, c::62>>
  end

  # A version-4 GUID (byte order is irrelevant for random values).
  def random_guid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    <<a::48, 4::4, b::12, 2::2, c::62>>
  end

  defp pad(bin, size), do: bin <> :binary.copy(<<0>>, max(size - byte_size(bin), 0))

  @doc """
  Read partition entries from a device: [%{index, type, guid, attrs,
  name, first, last}] (`type` and `guid` as their on-disk bytes).
  """
  def read(fd) do
    with {:ok, <<"EFI PART", _::binary-size(64), entries_lba::little-64, count::little-32, size::little-32, _::binary>>} <- :file.pread(fd, 512, 92),
         {:ok, data} <- :file.pread(fd, entries_lba * 512, count * size) do
      for {<<type::binary-size(16), uniq::binary-size(16), first::little-64, last::little-64, attrs::little-64, name::binary-size(72)>>, i} <-
            Enum.with_index(for(<<e::binary-size(^size) <- data>>, do: binary_part(e, 0, 128)), 1),
          type != :binary.copy(<<0>>, 16) do
        %{index: i, type: type, guid: uniq, attrs: attrs, first: first, last: last, name: name |> :unicode.characters_to_binary({:utf16, :little}) |> String.trim_trailing(<<0>>)}
      end
    else
      _ -> []
    end
  end

  @doc "The table's header: `%{disk_guid, first_usable, last_usable}`, or nil (no GPT)."
  def header(fd) do
    case :file.pread(fd, 512, 92) do
      {:ok, <<"EFI PART", _::binary-size(32), first::little-64, last::little-64, disk_guid::binary-16, _::binary>>} ->
        %{disk_guid: disk_guid, first_usable: first, last_usable: last}

      _ ->
        nil
    end
  end
end
