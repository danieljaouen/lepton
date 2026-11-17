defmodule LeptonBuild.ISO9660 do
  @moduledoc """
  ISO 9660 image writer with Rock Ridge names and an El Torito UEFI boot
  entry.

  `files` is a list of `{"/path/on/disc", {:data, bin} | {:path, host_path}}`.
  `efi_image` is the FAT image the firmware boots from (no-emulation, platform
  0xEF). It is also exposed on the disc as `/boot/grub/efi.img`.

  The image is also *hybrid*: a protective MBR and GPT in the (otherwise
  unused) system area declare an EFI System partition covering that same
  FAT image, so firmware that attaches the ISO as a disk rather than a CD
  (Apple Virtualization in UTM, USB sticks) can boot it too.
  """

  import Bitwise

  @sector 2048
  @efi_path "/boot/grub/efi.img"

  def write!(dest, files, efi_image, opts \\ []) do
    volume_id = opts[:volume_id] || "LEPTON"
    files = [{@efi_path, {:data, efi_image}} | files]

    tree = build_tree(files)
    Process.put({__MODULE__, :names}, assign_names(tree, "/", %{}))
    dirs = bfs([{"/", tree, 1}], [])
    # dirs: [{path, node, parent_index, index}] in breadth-first order (index 1 = root)

    # Layout: 0-15 system area, 16 PVD, 17 boot record, 18 terminator,
    # 19 boot catalog, 20.. path tables, then directories, then files.
    catalog_lba = 19
    l_path_table = encode_path_table(dirs, %{}, :little)
    pt_sectors = sectors(byte_size(l_path_table))
    l_pt_lba = 20
    m_pt_lba = l_pt_lba + pt_sectors
    dir_start = m_pt_lba + pt_sectors

    # Directory sizes depend only on names, so compute them before placement.
    dir_sizes = Map.new(dirs, fn {path, node, _, _} -> {path, dir_extent_size(path, node)} end)

    {dir_lbas, next} =
      Enum.reduce(dirs, {%{}, dir_start}, fn {path, _, _, _}, {acc, lba} ->
        {Map.put(acc, path, lba), lba + sectors(dir_sizes[path])}
      end)

    file_list = for {path, src} <- Enum.sort(files), do: {path, src, source_size(src)}

    {file_lbas, total} =
      Enum.reduce(file_list, {%{}, next}, fn {path, _src, size}, {acc, lba} ->
        {Map.put(acc, path, lba), lba + max(sectors(size), 1)}
      end)

    locate = fn path ->
      case Map.fetch(dir_lbas, path) do
        {:ok, lba} -> {lba, dir_sizes[path]}
        :error -> {file_lbas[path], file_list |> Enum.find(&(elem(&1, 0) == path)) |> elem(2)}
      end
    end

    efi_lba = file_lbas[@efi_path]

    {:ok, io} = File.open(dest, [:write, :binary, :raw])

    w = fn bin -> :ok = IO.binwrite(io, bin) end

    w.(:binary.copy(<<0>>, 16 * @sector))
    w.(pvd(volume_id, total, l_pt_lba, m_pt_lba, byte_size(l_path_table), root_record(dir_lbas["/"], dir_sizes["/"])))
    w.(boot_record(catalog_lba))
    w.(terminator())
    w.(boot_catalog(efi_lba, byte_size(efi_image)))
    # The table was first encoded without LBAs only to learn its size.
    w.(pad(encode_path_table(dirs, dir_lbas, :little)))
    w.(pad(encode_path_table(dirs, dir_lbas, :big)))

    for {path, node, _parent, _idx} <- dirs do
      w.(pad(dir_extent(path, node, locate)))
    end

    for {_path, src, size} <- file_list do
      data =
        case src do
          {:data, bin} -> bin
          {:path, host} -> File.read!(host)
        end

      ^size = byte_size(data)
      w.(if size == 0, do: :binary.copy(<<0>>, @sector), else: pad(data))
    end

    bytes = write_hybrid_gpt(io, total, efi_lba, byte_size(efi_image))
    File.close(io)
    bytes
  end

  # Room after the ISO for the backup GPT (entries + header), in 2 KiB sectors.
  @gpt_tail_sectors 16

  defp write_hybrid_gpt(io, total, efi_lba, efi_size) do
    bytes = (total + @gpt_tail_sectors) * @sector
    disk_sectors = div(bytes, 512)
    first = efi_lba * div(@sector, 512)
    last = first + div(efi_size + 511, 512) - 1

    {:ok, _} = :file.position(io, bytes - 1)
    :ok = IO.binwrite(io, <<0>>)

    for {offset, data} <- Lepton.Install.GPT.build(disk_sectors, [%{type: Lepton.Install.GPT.esp_type(), name: "EFI System", first: first, last: last}]) do
      :ok = :file.pwrite(io, offset, data)
    end

    bytes
  end

  # -- tree --------------------------------------------------------------------

  defp build_tree(files) do
    Enum.reduce(files, %{}, fn {path, _src}, acc ->
      parts = String.split(path, "/", trim: true)
      put_path(acc, parts)
    end)
  end

  defp put_path(tree, [name]), do: Map.put_new(tree, name, :file)
  defp put_path(tree, [dir | rest]), do: Map.update(tree, dir, put_path(%{}, rest), &put_path(&1, rest))

  # Breadth-first directory list: path tables require parents before children.
  defp bfs([], acc), do: Enum.reverse(acc)

  defp bfs([{path, node, parent} | queue], acc) do
    idx = length(acc) + 1

    children =
      for {name, _iso, true} <- dir_children(path, node) do
        {join(path, name), node[name], idx}
      end

    bfs(queue ++ children, [{path, node, parent, idx} | acc])
  end

  # Unique ISO identifiers per directory; Rock Ridge NM carries the real name.
  defp assign_names(node, path, acc) do
    {acc, _seen} =
      node
      |> Enum.sort()
      |> Enum.reduce({acc, MapSet.new()}, fn {name, sub}, {acc, seen} ->
        iso = unique(iso_name(name, is_map(sub)), seen, 1)
        child = join(path, name)
        acc = Map.put(acc, child, iso)
        acc = if is_map(sub), do: assign_names(sub, child, acc), else: acc
        {acc, MapSet.put(seen, iso)}
      end)

    acc
  end

  defp unique(iso, seen, n) do
    if MapSet.member?(seen, iso) do
      {base, suffix} = if String.ends_with?(iso, ";1"), do: {String.trim_trailing(iso, ";1"), ";1"}, else: {iso, ""}
      candidate = String.slice(base, 0, 26) <> "_" <> Integer.to_string(n) <> suffix
      if MapSet.member?(seen, candidate), do: unique(iso, seen, n + 1), else: candidate
    else
      iso
    end
  end

  defp join("/", name), do: "/" <> name
  defp join(dir, name), do: dir <> "/" <> name

  defp source_size({:data, bin}), do: byte_size(bin)
  defp source_size({:path, host}), do: File.stat!(host).size

  # -- names ---------------------------------------------------------------------

  defp iso_name(name, dir?) do
    base =
      name
      |> String.upcase()
      |> String.replace(~r/[^A-Z0-9_.]/, "_")
      |> String.replace(".", "_", global: true)

    base = String.slice(base, 0, 30)
    if dir?, do: base, else: base <> ";1"
  end

  defp dir_children(path, node) do
    names = Process.get({__MODULE__, :names})

    node
    |> Enum.map(fn {name, sub} -> {name, Map.fetch!(names, join(path, name)), is_map(sub)} end)
    |> Enum.sort_by(fn {_, iso, _} -> iso end)
  end

  # -- directory records -------------------------------------------------------

  defp dir_extent_size(path, node) do
    records = dir_records(path, node, fn _ -> {0, 0} end)
    pack_records(records) |> byte_size()
  end

  defp dir_extent(path, node, locate), do: pack_records(dir_records(path, node, locate))

  defp dir_records(path, node, locate) do
    {self_lba, self_size} = locate.(path)
    parent_path = if path == "/", do: "/", else: Path.dirname(path)
    {parent_lba, parent_size} = locate.(parent_path)

    root_su =
      if path == "/" do
        # SUSP "SP" marks the start of system use; "ER" declares Rock Ridge.
        sp = <<"SP", 7, 1, 0xBE, 0xEF, 0>>
        id = "RRIP_1991A"
        # Kept short: a directory record (including system use) must fit in 255 bytes.
        desc = "ROCK RIDGE POSIX"
        src = "IEEE P1282"
        er = <<"ER", 8 + byte_size(id) + byte_size(desc) + byte_size(src), 1, byte_size(id), byte_size(desc), byte_size(src), 1>> <> id <> desc <> src
        sp <> px(0o040555) <> er
      else
        px(0o040555)
      end

    dot = record(<<0>>, self_lba, self_size, true, root_su)
    dotdot = record(<<1>>, parent_lba, parent_size, true, px(0o040555))

    children =
      for {name, iso, dir?} <- dir_children(path, node) do
        child = join(path, name)
        {lba, size} = locate.(child)
        mode = if dir?, do: 0o040555, else: 0o100444
        record(iso, lba, size, dir?, px(mode) <> nm(name))
      end

    [dot, dotdot | children]
  end

  defp px(mode) do
    <<"PX", 44, 1, both32(mode)::binary, both32(1)::binary, both32(0)::binary, both32(0)::binary, both32(0)::binary>>
  end

  defp nm(name), do: <<"NM", 5 + byte_size(name), 1, 0>> <> name

  defp record(id, lba, size, dir?, system_use) do
    id_len = byte_size(id)
    pad_id = if rem(id_len, 2) == 0, do: <<0>>, else: <<>>
    base_len = 33 + id_len + byte_size(pad_id)
    su = if rem(base_len + byte_size(system_use), 2) == 1, do: system_use <> <<0>>, else: system_use
    len = base_len + byte_size(su)
    if len > 255, do: raise("ISO directory record too long for #{inspect(id)}")

    <<len, 0, both32(lba)::binary, both32(size)::binary, date7()::binary, if(dir?, do: 2, else: 0), 0, 0,
      both16(1)::binary, id_len>> <> id <> pad_id <> su
  end

  defp pack_records(records) do
    {sectors, current} =
      Enum.reduce(records, {[], <<>>}, fn rec, {done, cur} ->
        if byte_size(cur) + byte_size(rec) > @sector do
          {[pad(cur) | done], rec}
        else
          {done, cur <> rec}
        end
      end)

    IO.iodata_to_binary(Enum.reverse([pad(current) | sectors]))
  end

  defp root_record(lba, size), do: record(<<0>>, lba, size, true, <<>>)

  # -- path tables -------------------------------------------------------------

  defp encode_path_table(dirs, lbas, endian) do
    for {path, _node, parent, _idx} <- dirs, into: <<>> do
      name = if path == "/", do: <<0>>, else: Map.fetch!(Process.get({__MODULE__, :names}), path)
      lba = Map.get(lbas, path, 0)
      len = byte_size(name)
      padding = if rem(len, 2) == 1, do: <<0>>, else: <<>>

      case endian do
        :little -> <<len, 0, lba::little-32, parent::little-16>> <> name <> padding
        :big -> <<len, 0, lba::big-32, parent::big-16>> <> name <> padding
      end
    end
  end

  # -- volume descriptors ------------------------------------------------------

  defp pvd(volume_id, total, l_pt, m_pt, pt_size, root) do
    now = "2026010100000000" <> <<0>>
    blank = String.duplicate("0", 16) <> <<0>>

    body =
      <<1, "CD001", 1, 0>> <>
        a("LEPTON", 32) <>
        a(volume_id, 32) <>
        <<0::size(64)>> <>
        both32(total) <>
        <<0::size(256)>> <>
        both16(1) <>
        both16(1) <>
        both16(@sector) <>
        both32(pt_size) <>
        <<l_pt::little-32, 0::little-32, m_pt::big-32, 0::big-32>> <>
        root <>
        a("LEPTON", 128) <>
        a("LEPTON PROJECT", 128) <>
        a("LEPTON BUILD (ELIXIR)", 128) <>
        a("LEPTON OS - A UNIX-LIKE OS WRITTEN IN ELIXIR", 128) <>
        a("", 37) <> a("", 37) <> a("", 37) <> now <> now <> blank <> now <> <<1, 0>>

    pad(body)
  end

  defp boot_record(catalog_lba) do
    pad(<<0, "CD001", 1>> <> a("EL TORITO SPECIFICATION", 32, 0) <> <<0::size(256)>> <> <<catalog_lba::little-32>>)
  end

  defp terminator, do: pad(<<255, "CD001", 1>>)

  defp boot_catalog(efi_lba, efi_size) do
    # Validation entry: header 1, platform 0xEF (UEFI), checksum, 0x55AA.
    v0 = <<1, 0xEF, 0::16>> <> a("LEPTON", 24, 0) <> <<0::16, 0x55, 0xAA>>
    sum = for(<<w::little-16 <- v0>>, reduce: 0, do: (acc -> acc + w)) &&& 0xFFFF
    checksum = 0x10000 - sum &&& 0xFFFF
    <<head::binary-size(28), _::16, tail::binary>> = v0
    validation = head <> <<checksum::little-16>> <> tail

    # Sector count is in 512-byte units; firmware treats 0/1 as "to end".
    count = min(div(efi_size + 511, 512), 0xFFFF)
    default = <<0x88, 0, 0::little-16, 0, 0, count::little-16, efi_lba::little-32>> <> :binary.copy(<<0>>, 20)
    pad(validation <> default)
  end

  # -- helpers -----------------------------------------------------------------

  defp a(s, n, fill \\ ?\s), do: String.pad_trailing(String.slice(s, 0, n), n, <<fill>>)
  defp both16(n), do: <<n::little-16, n::big-16>>
  defp both32(n), do: <<n::little-32, n::big-32>>
  defp date7, do: <<126, 1, 1, 0, 0, 0, 0>>
  defp sectors(bytes), do: div(bytes + @sector - 1, @sector)

  defp pad(bin) do
    r = rem(byte_size(bin), @sector)
    if r == 0 and byte_size(bin) > 0, do: bin, else: bin <> :binary.copy(<<0>>, @sector - r)
  end
end
