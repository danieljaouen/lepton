defmodule Lepton.Install.FAT16 do
  @moduledoc """
  Formats a FAT16 EFI System Partition directly on a block device and
  writes files into it, streaming file contents (the kernel and initramfs
  are ~90 MB). 4 KiB clusters, contiguous allocation, 8.3 names.
  """

  alias Lepton.Install.Disk

  @sector 512
  @spc 8
  @cluster @sector * @spc
  @reserved 4
  @nfats 2
  @root_entries 512

  @doc """
  `files`: [{"EFI/BOOT/BOOTAA64.EFI", {:path, src} | {:data, bin}}].
  `offset` is the partition's byte offset, `sectors` its length,
  `hidden` its starting LBA.
  """
  def format(fd, offset, sectors, hidden, files) do
    root_sectors = div(@root_entries * 32, @sector)
    clusters_est = div(sectors, @spc)
    fat_sectors = div(clusters_est * 2 + 4 + @sector - 1, @sector)
    data_start = @reserved + @nfats * fat_sectors + root_sectors
    clusters = div(sectors - data_start, @spc)
    unless clusters in 4085..65524, do: raise("partition size not suitable for FAT16 (#{clusters} clusters)")

    tree = build_tree(files)
    {tree, next, chains} = allocate(tree, 2, %{})
    if next - 2 > clusters, do: raise("files do not fit in the EFI partition")

    cluster_offset = fn c -> offset + (data_start + (c - 2) * @spc) * @sector end

    # Boot sector, FATs, root directory.
    Disk.zero(fd, offset, data_start * @sector)
    Disk.pwrite(fd, offset, boot_sector(sectors, fat_sectors, hidden))
    fat = encode_fat(chains, clusters + 2) |> pad(fat_sectors * @sector)
    for i <- 0..(@nfats - 1), do: Disk.pwrite(fd, offset + (@reserved + i * fat_sectors) * @sector, fat)
    Disk.pwrite(fd, offset + (@reserved + @nfats * fat_sectors) * @sector, dir_entries(tree, nil, nil, true))

    write_tree(fd, tree, nil, cluster_offset)
    :ok
  end

  # tree: %{name => {:dir, sub} | {:file, source, size}} -> annotated with first clusters
  defp build_tree(files) do
    Enum.reduce(files, %{}, fn {path, src}, acc ->
      put(acc, path |> String.upcase() |> String.split("/", trim: true), src)
    end)
  end

  defp put(tree, [name], src), do: Map.put(tree, name, {:file, src, size(src)})
  defp put(tree, [d | rest], src) do
    sub = case tree[d] do
      {:dir, s} -> s
      nil -> %{}
    end

    Map.put(tree, d, {:dir, put(sub, rest, src)})
  end

  defp size({:data, b}), do: byte_size(b)
  defp size({:path, p}), do: File.stat!(p).size

  defp nclusters(0), do: 0
  defp nclusters(bytes), do: div(bytes + @cluster - 1, @cluster)

  defp allocate(tree, next, chains) do
    Enum.reduce(Enum.sort(tree), {%{}, next, chains}, fn
      {name, {:file, src, sz}}, {acc, next, chains} ->
        n = nclusters(sz)
        first = if n == 0, do: 0, else: next
        chains = if n > 0, do: Map.put(chains, next, n), else: chains
        {Map.put(acc, name, {:file, src, sz, first}), next + n, chains}

      {name, {:dir, sub}}, {acc, next, chains} ->
        me = next
        {sub, next2, chains} = allocate(sub, next + 1, Map.put(chains, me, 1))
        {Map.put(acc, name, {:dir, sub, me}), next2, chains}
    end)
  end

  defp write_tree(fd, tree, self_cluster, cluster_offset) do
    for {_name, node} <- tree do
      case node do
        {:file, {:data, bin}, _sz, first} when first > 0 -> Disk.pwrite(fd, cluster_offset.(first), bin)
        {:file, {:path, p}, _sz, first} when first > 0 -> Disk.copy_file(fd, cluster_offset.(first), p)
        {:file, _, _, 0} -> :ok
        {:dir, sub, me} ->
          entries = dir_entries(sub, me, self_cluster, false)
          if byte_size(entries) > @cluster, do: raise("directory too large")
          Disk.pwrite(fd, cluster_offset.(me), pad(entries, @cluster))
          write_tree(fd, sub, me, cluster_offset)
      end
    end
  end

  defp dir_entries(tree, self, parent, root?) do
    head =
      if root?,
        do: [entry("LEPTON ESP ", 0x08, 0, 0)],
        else: [entry(".          ", 0x10, self, 0), entry("..         ", 0x10, parent || 0, 0)]

    items =
      for {name, node} <- Enum.sort(tree) do
        case node do
          {:file, _, sz, first} -> entry(short(name), 0x20, first, sz)
          {:dir, _, me} -> entry(short(name), 0x10, me, 0)
        end
      end

    IO.iodata_to_binary(head ++ items)
  end

  defp short(name) do
    {base, ext} = case String.split(name, ".", parts: 2) do
      [b, e] -> {b, e}
      [b] -> {b, ""}
    end

    if byte_size(base) > 8 or byte_size(ext) > 3, do: raise("not an 8.3 name: #{name}")
    String.pad_trailing(base, 8) <> String.pad_trailing(ext, 3)
  end

  @date Bitwise.bor(Bitwise.bsl(2026 - 1980, 9), Bitwise.bor(Bitwise.bsl(1, 5), 1))
  defp entry(name, attr, cluster, size) do
    import Bitwise
    <<name::binary-size(11), attr, 0, 0, 0::16, @date::little-16, @date::little-16, (cluster >>> 16)::little-16,
      0::16, @date::little-16, (cluster &&& 0xFFFF)::little-16, size::little-32>>
  end

  defp encode_fat(chains, n) do
    table =
      Enum.reduce(chains, %{0 => 0xFFF8, 1 => 0xFFFF}, fn {first, len}, acc ->
        Enum.reduce(0..(len - 1), acc, fn i, acc -> Map.put(acc, first + i, if(i == len - 1, do: 0xFFFF, else: first + i + 1)) end)
      end)

    for i <- 0..(n - 1), into: <<>>, do: <<Map.get(table, i, 0)::little-16>>
  end

  defp boot_sector(sectors, fat_sectors, hidden) do
    bpb =
      <<0xEB, 0x3C, 0x90, "LEPTON  ", @sector::little-16, @spc, @reserved::little-16, @nfats, @root_entries::little-16,
        0::little-16, 0xF8, fat_sectors::little-16, 63::little-16, 255::little-16, hidden::little-32,
        sectors::little-32, 0x80, 0, 0x29, 0x4C455054::little-32, "LEPTON ESP ", "FAT16   ">>

    pad(bpb, 510) <> <<0x55, 0xAA>>
  end

  defp pad(bin, size), do: bin <> :binary.copy(<<0>>, max(size - byte_size(bin), 0))
end

defmodule Lepton.Install.Ext2 do
  @moduledoc """
  `mkfs.ext2` in Elixir: 4 KiB blocks, 128-byte inodes, `sparse_super`
  and `filetype` features, a root directory and `lost+found`. The Linux
  ext4 driver mounts it as ext2.
  """

  import Bitwise
  alias Lepton.Install.Disk

  @bs 4096
  @bpg 32_768
  @ipg 8192
  @isize 128
  @itable_blocks div(@ipg * @isize, @bs)

  def format(fd, offset, bytes, label \\ "lepton-data") do
    total = div(bytes, @bs)
    groups = div(total + @bpg - 1, @bpg)
    # Drop a tiny trailing group that cannot hold its own metadata.
    {total, groups} =
      if total - (groups - 1) * @bpg < 300, do: {(groups - 1) * @bpg, groups - 1}, else: {total, groups}

    gdt_blocks = div(groups * 32 + @bs - 1, @bs)
    now = System.os_time(:second)

    layout =
      for g <- 0..(groups - 1) do
        start = g * @bpg
        size = min(@bpg, total - start)
        meta = if has_super?(g), do: 1 + gdt_blocks, else: 0
        %{g: g, start: start, size: size, super: has_super?(g), bbitmap: start + meta, ibitmap: start + meta + 1, itable: start + meta + 2, first_free: start + meta + 2 + @itable_blocks}
      end

    g0 = hd(layout)
    root_block = g0.first_free
    lf_block = g0.first_free + 1

    used = fn grp -> grp.first_free - grp.start + if(grp.g == 0, do: 2, else: 0) end
    free_blocks = Enum.map(layout, &(&1.size - used.(&1)))
    free_inodes = Enum.map(layout, &(if &1.g == 0, do: @ipg - 11, else: @ipg))

    gdt =
      layout
      |> Enum.map(fn grp ->
        <<grp.bbitmap::little-32, grp.ibitmap::little-32, grp.itable::little-32, Enum.at(free_blocks, grp.g)::little-16,
          Enum.at(free_inodes, grp.g)::little-16, if(grp.g == 0, do: 2, else: 0)::little-16, 0::16, 0::96>>
      end)
      |> IO.iodata_to_binary()

    uuid = :crypto.strong_rand_bytes(16)

    sb = fn grp_nr ->
      <<groups * @ipg::little-32, total::little-32, div(total, 20)::little-32, Enum.sum(free_blocks)::little-32,
        Enum.sum(free_inodes)::little-32, 0::little-32, 2::little-32, 2::little-32, @bpg::little-32, @bpg::little-32,
        @ipg::little-32, 0::little-32, now::little-32, 0::little-16, 0xFFFF::little-16, 0xEF53::little-16,
        1::little-16, 1::little-16, 0::little-16, now::little-32, 0::little-32, 0::little-32, 1::little-32,
        0::little-16, 0::little-16, 11::little-32, @isize::little-16, grp_nr::little-16, 0::little-32,
        0x2::little-32, 0x1::little-32>> <> uuid <> pad(label, 16)
      |> pad(1024)
    end

    for grp <- layout do
      base = offset + grp.start * @bs

      if grp.super do
        if grp.g == 0 do
          Disk.zero(fd, offset, @bs)
          Disk.pwrite(fd, offset + 1024, sb.(0))
        else
          Disk.pwrite(fd, base, pad(sb.(grp.g), @bs))
        end

        Disk.pwrite(fd, base + @bs, pad(gdt, gdt_blocks * @bs))
      end

      used_blocks = used.(grp)
      Disk.pwrite(fd, offset + grp.bbitmap * @bs, bitmap(used_blocks, grp.size, @bpg))
      Disk.pwrite(fd, offset + grp.ibitmap * @bs, bitmap(if(grp.g == 0, do: 11, else: 0), @ipg, @bs * 8))
      Disk.zero(fd, offset + grp.itable * @bs, @itable_blocks * @bs)
    end

    # Inodes 2 (root) and 11 (lost+found).
    root = inode(0o040755, 3, root_block, now)
    lf = inode(0o040700, 2, lf_block, now)
    itable = offset + g0.itable * @bs
    Disk.pwrite(fd, itable + 1 * @isize, root)
    Disk.pwrite(fd, itable + 10 * @isize, lf)
    Disk.pwrite(fd, offset + root_block * @bs, dir([{2, "."}, {2, ".."}, {11, "lost+found"}]))
    Disk.pwrite(fd, offset + lf_block * @bs, dir([{11, "."}, {2, ".."}]))
    %{blocks: total, groups: groups}
  end

  defp has_super?(0), do: true
  defp has_super?(1), do: true
  defp has_super?(g), do: power_of?(g, 3) or power_of?(g, 5) or power_of?(g, 7)

  defp power_of?(1, _), do: true
  defp power_of?(n, b) when rem(n, b) == 0, do: power_of?(div(n, b), b)
  defp power_of?(_, _), do: false

  # First `used` bits set, bits past `valid` (padding) set, block-sized.
  defp bitmap(used, valid, bits) do
    for i <- 0..(@bs * 8 - 1), into: <<>> do
      if i < used or i >= valid or i >= bits, do: <<1::1>>, else: <<0::1>>
    end
    |> reverse_bits()
  end

  # ext2 bitmaps are little-endian within each byte.
  defp reverse_bits(bin), do: for(<<b::8 <- bin>>, into: <<>>, do: <<rev(b)>>)
  defp rev(b), do: for(i <- 0..7, reduce: 0, do: (acc -> acc ||| ((b >>> i &&& 1) <<< (7 - i))))

  defp inode(mode, links, block, now) do
    blocks = [block | List.duplicate(0, 14)] |> Enum.map(&<<&1::little-32>>) |> IO.iodata_to_binary()

    <<mode::little-16, 0::little-16, @bs::little-32, now::little-32, now::little-32, now::little-32, 0::little-32,
      0::little-16, links::little-16, div(@bs, 512)::little-32, 0::little-32, 0::little-32>> <>
      blocks <> :binary.copy(<<0>>, @isize - 40 - 60)
  end

  defp dir(entries) do
    {body, _} =
      entries
      |> Enum.with_index()
      |> Enum.map_reduce(0, fn {{ino, name}, i}, used ->
        len = byte_size(name)
        rec = div(8 + len + 3, 4) * 4
        rec = if i == length(entries) - 1, do: @bs - used, else: rec
        {<<ino::little-32, rec::little-16, len, 2>> <> name <> :binary.copy(<<0>>, rec - 8 - len), used + rec}
      end)

    IO.iodata_to_binary(body)
  end

  defp pad(bin, size), do: bin <> :binary.copy(<<0>>, max(size - byte_size(bin), 0))
end
