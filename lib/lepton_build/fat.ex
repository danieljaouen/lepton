defmodule LeptonBuild.FAT do
  @moduledoc """
  Writes a small FAT12 filesystem image. Used for the El Torito EFI system
  partition that holds `EFI/BOOT/BOOTAA64.EFI`.

  `files` is a list of `{"EFI/BOOT/BOOTAA64.EFI", binary}`; names must
  already be valid 8.3 names (they are upper-cased here).
  """

  import Bitwise

  @sector 512
  @spc 4
  @cluster @sector * @spc
  @root_entries 512
  @reserved 1
  @nfats 2

  def image(files, total_sectors \\ nil) do
    tree = build_tree(files)
    data_bytes = tree_size(tree)
    total_sectors = total_sectors || max(4096, div(data_bytes, @sector) * 2 + 512)
    # Round to a whole number of clusters' worth of tracks.
    total_sectors = div(total_sectors + 63, 64) * 64

    root_sectors = div(@root_entries * 32, @sector)
    clusters_guess = div(total_sectors, @spc)
    fat_sectors = div(div((clusters_guess + 2) * 3, 2) + @sector - 1, @sector)
    data_start = @reserved + @nfats * fat_sectors + root_sectors
    clusters = div(total_sectors - data_start, @spc)
    if clusters > 4084, do: raise("image too large for FAT12")

    # Allocate clusters depth-first.
    {placed, _next, chains} = place(tree, 2, %{}, nil)
    data = for {cluster, bytes} <- placed, into: %{}, do: {cluster, bytes}

    root_dir = dir_entries(tree, nil, nil) |> pad_to(root_sectors * @sector)

    fat = encode_fat(chains, clusters + 2) |> pad_to(fat_sectors * @sector)

    data_area =
      for c <- 2..(clusters + 1)//1, into: <<>> do
        Map.get(data, c, <<0::size(@cluster * 8)>>)
      end

    IO.iodata_to_binary([
      boot_sector(total_sectors, fat_sectors),
      fat,
      fat,
      root_dir,
      data_area
    ])
  end

  # -- tree --------------------------------------------------------------------

  defp build_tree(files) do
    Enum.reduce(files, %{}, fn {path, bin}, acc ->
      parts = path |> String.upcase() |> String.split("/", trim: true)
      put_in_tree(acc, parts, bin)
    end)
  end

  defp put_in_tree(tree, [name], bin), do: Map.put(tree, name, {:file, bin})

  defp put_in_tree(tree, [dir | rest], bin) do
    sub =
      case Map.get(tree, dir) do
        {:dir, sub} -> sub
        nil -> %{}
      end

    Map.put(tree, dir, {:dir, put_in_tree(sub, rest, bin)})
  end

  defp tree_size(tree) do
    Enum.reduce(tree, 0, fn
      {_, {:file, bin}}, acc -> acc + round_cluster(byte_size(bin))
      {_, {:dir, sub}}, acc -> acc + @cluster + tree_size(sub)
    end)
  end

  defp round_cluster(0), do: 0
  defp round_cluster(n), do: div(n + @cluster - 1, @cluster) * @cluster

  # Returns {[{cluster, bytes}], next_free, %{first_cluster => n_clusters}} and
  # annotates nodes with their first cluster via the process dictionary.
  defp place(tree, next, chains, parent_cluster) do
    Enum.reduce(Enum.sort(tree), {[], next, chains}, fn
      {name, {:file, bin}}, {acc, next, chains} ->
        n = div(round_cluster(byte_size(bin)), @cluster)
        Process.put({__MODULE__, parent_cluster, name}, if(n == 0, do: 0, else: next))
        blocks = for i <- 0..(n - 1)//1, do: {next + i, chunk(bin, i)}
        chains = if n > 0, do: Map.put(chains, next, n), else: chains
        {acc ++ blocks, next + n, chains}

      {name, {:dir, sub}}, {acc, next, chains} ->
        me = next
        Process.put({__MODULE__, parent_cluster, name}, me)
        {sub_blocks, next2, chains2} = place(sub, next + 1, Map.put(chains, me, 1), me)
        entries = dir_entries(sub, me, parent_cluster) |> pad_to(@cluster)
        if byte_size(entries) > @cluster, do: raise("directory too large")
        {acc ++ [{me, entries}] ++ sub_blocks, next2, chains2}
    end)
  end

  defp chunk(bin, i) do
    start = i * @cluster
    part = binary_part(bin, start, min(@cluster, byte_size(bin) - start))
    pad_to(part, @cluster)
  end

  defp dir_entries(tree, self_cluster, parent_cluster) do
    dots =
      if self_cluster do
        [entry(".          ", 0x10, self_cluster, 0), entry("..         ", 0x10, parent_cluster || 0, 0)]
      else
        [entry("LEPTON EFI ", 0x08, 0, 0)]
      end

    items =
      for {name, node} <- Enum.sort(tree) do
        cluster = Process.get({__MODULE__, self_cluster, name})

        case node do
          {:file, bin} -> entry(short_name(name), 0x20, cluster, byte_size(bin))
          {:dir, _} -> entry(short_name(name), 0x10, cluster, 0)
        end
      end

    IO.iodata_to_binary(dots ++ items)
  end

  defp short_name(name) do
    {base, ext} =
      case String.split(name, ".", parts: 2) do
        [b, e] -> {b, e}
        [b] -> {b, ""}
      end

    if byte_size(base) > 8 or byte_size(ext) > 3, do: raise("not an 8.3 name: #{name}")
    String.pad_trailing(base, 8) <> String.pad_trailing(ext, 3)
  end

  # 2026-01-01 00:00
  @fat_date (2026 - 1980) <<< 9 ||| 1 <<< 5 ||| 1
  defp entry(name11, attr, cluster, size) do
    <<name11::binary-size(11), attr, 0, 0, 0::little-16, @fat_date::little-16, @fat_date::little-16, 0::little-16,
      0::little-16, @fat_date::little-16, cluster::little-16, size::little-32>>
  end

  defp encode_fat(chains, n_entries) do
    table =
      Enum.reduce(chains, %{0 => 0xFF8, 1 => 0xFFF}, fn {first, n}, acc ->
        Enum.reduce(0..(n - 1), acc, fn i, acc ->
          Map.put(acc, first + i, if(i == n - 1, do: 0xFFF, else: first + i + 1))
        end)
      end)

    values = for i <- 0..(n_entries - 1 + rem(n_entries, 2)), do: Map.get(table, i, 0)

    values
    |> Enum.chunk_every(2)
    |> Enum.map(fn [a, b] -> <<a &&& 0xFF, (a >>> 8 &&& 0x0F) ||| (b &&& 0x0F) <<< 4, b >>> 4>> end)
    |> IO.iodata_to_binary()
  end

  defp boot_sector(total_sectors, fat_sectors) do
    bpb =
      <<0xEB, 0x3C, 0x90, "LEPTON  ", @sector::little-16, @spc, @reserved::little-16, @nfats, @root_entries::little-16,
        total_sectors::little-16, 0xF8, fat_sectors::little-16, 32::little-16, 64::little-16, 0::little-32,
        0::little-32, 0x80, 0, 0x29, 0x4C455054::little-32, "LEPTON EFI ", "FAT12   ">>

    pad_to(bpb, 510) <> <<0x55, 0xAA>>
  end

  defp pad_to(bin, size) when byte_size(bin) <= size, do: bin <> :binary.copy(<<0>>, size - byte_size(bin))
end
