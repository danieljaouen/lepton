defmodule Lepton.Rsync.Flist do
  @moduledoc """
  The file list: what the sender has, sent to the receiver and referred
  to by index (in byte order of the names, as rsync sorts it).

  Names are relative to the transfer: `src/` sends its contents (and `.`,
  the directory itself), `src` sends `src` and everything below it.
  """

  import Bitwise
  alias Lepton.Rsync.{Delta, Wire}

  defmodule Entry do
    @moduledoc false
    defstruct [:name, :raw_name, :path, :mode, :size, :mtime, uid: 0, gid: 0, rdev: 0, link: nil, sum: nil, top: false]
  end

  @top_dir 0x01
  @same_mode 0x02
  @same_rdev 0x04
  @same_uid 0x08
  @same_gid 0x10
  @same_name 0x20
  @long_name 0x40
  @same_time 0x80

  @s_ifmt 0o170000
  @s_ifdir 0o040000
  @s_ifreg 0o100000
  @s_iflnk 0o120000
  @s_ifchr 0o020000
  @s_ifblk 0o060000

  def dir?(%Entry{mode: m}), do: (m &&& @s_ifmt) == @s_ifdir
  def file?(%Entry{mode: m}), do: (m &&& @s_ifmt) == @s_ifreg
  def link?(%Entry{mode: m}), do: (m &&& @s_ifmt) == @s_iflnk
  defp device?(m), do: (m &&& @s_ifmt) in [@s_ifchr, @s_ifblk]

  # -- building (the sender) --------------------------------------------------------------

  @doc """
  The entries for `sources` (absolute paths, each with the spelling given:
  a trailing `/` means "the contents"). Returns `{entries, warnings}`.
  """
  def build(sources, opts) do
    {entries, warnings} =
      Enum.reduce(sources, {[], []}, fn {given, full}, {acc, warn} ->
        contents? = String.ends_with?(given, "/") or given in [".", ""]

        case File.lstat(full, time: :posix) do
          {:ok, %{type: :directory} = st} ->
            cond do
              not opts.recursive and not opts.dirs ->
                {acc, ["skipping directory #{given}" | warn]}

              contents? ->
                top = entry(".", full, st, opts, true)
                kids = if opts.recursive, do: walk(full, "", opts), else: []
                {acc ++ [top | kids], warn}

              true ->
                name = Path.basename(full)
                kids = if opts.recursive, do: walk(full, name, opts), else: []
                {acc ++ [entry(name, full, st, opts, true) | kids], warn}
            end

          {:ok, st} ->
            case keep(Path.basename(full), full, st, opts) do
              {:ok, e} -> {acc ++ [e], warn}
              {:skip, why} -> {acc, [why | warn]}
            end

          {:error, reason} ->
            {acc, ["link_stat \"#{given}\" failed: #{:file.format_error(reason)}" | warn]}
        end
      end)

    {sort(entries), Enum.reverse(warnings)}
  end

  @doc "Sort by name, byte by byte, dropping duplicates (both sides index into this)."
  def sort(entries), do: entries |> Enum.sort_by(& &1.name) |> Enum.dedup_by(& &1.name)

  defp walk(dir, prefix, opts) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.flat_map(Enum.sort(names), fn n ->
          full = Path.join(dir, n)
          rel = if prefix == "", do: n, else: prefix <> "/" <> n

          with {:ok, st} <- File.lstat(full, time: :posix),
               false <- excluded?(opts.excludes, rel, st.type == :directory),
               {:ok, e} <- keep(rel, full, st, opts) do
            if st.type == :directory, do: [e | walk(full, rel, opts)], else: [e]
          else
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  defp keep(rel, full, st, opts) do
    case st.type do
      :directory -> {:ok, entry(rel, full, st, opts, false)}
      :regular -> {:ok, entry(rel, full, st, opts, false)}
      :symlink when opts.links -> {:ok, entry(rel, full, st, opts, false)}
      :symlink -> {:skip, "skipping non-regular file \"#{rel}\""}
      _ -> {:skip, "skipping non-regular file \"#{rel}\""}
    end
  end

  defp entry(name, full, st, opts, top) do
    link = if st.type == :symlink, do: (case File.read_link(full) do {:ok, t} -> t; _ -> "" end)
    sum = if opts.checksum and st.type == :regular, do: Delta.file_sum(File.read!(full), nil)
    mode = st.mode
    mode = if (mode &&& @s_ifmt) == 0, do: mode ||| type_bits(st.type), else: mode
    %Entry{name: name, path: full, mode: mode, size: if(st.type == :regular, do: st.size, else: 0), mtime: st.mtime, uid: st.uid, gid: st.gid, link: link, sum: sum, top: top}
  end

  defp type_bits(:directory), do: @s_ifdir
  defp type_bits(:symlink), do: @s_iflnk
  defp type_bits(_), do: @s_ifreg

  # -- excludes ------------------------------------------------------------------------------

  @doc """
  Is `rel` excluded? Patterns as rsync's: `*`, `?` and `[...]` within a
  name, `**` across `/`; a pattern with no `/` matches the name in any
  directory; a leading `/` anchors it to the top of the transfer; a
  trailing `/` matches only directories.
  """
  def excluded?([], _rel, _dir?), do: false

  def excluded?(patterns, rel, dir?) do
    Enum.any?(patterns, fn p ->
      {p, dir_only} = if String.ends_with?(p, "/"), do: {String.trim_trailing(p, "/"), true}, else: {p, false}

      (not dir_only or dir?) and
        cond do
          String.starts_with?(p, "/") -> Regex.match?(glob(String.trim_leading(p, "/")), rel)
          String.contains?(p, "/") -> Regex.match?(glob(p), rel) or Regex.match?(glob("**/" <> p), rel)
          true -> Regex.match?(glob(p), Path.basename(rel))
        end
    end)
  end

  defp glob(p) do
    re =
      p
      |> Regex.escape()
      |> String.replace("\\*\\*/", "(?:.*/)?")
      |> String.replace("\\*\\*", ".*")
      |> String.replace("\\*", "[^/]*")
      |> String.replace("\\?", "[^/]")
      |> String.replace("\\[", "[")
      |> String.replace("\\]", "]")

    Regex.compile!("^" <> re <> "$")
  end

  # -- the wire --------------------------------------------------------------------------------

  @doc "Send the list, the (empty) uid and gid name maps and the I/O error flag."
  def send(wire, entries, opts) do
    data =
      for e <- entries do
        flags = @long_name ||| if(e.top and dir?(e), do: @top_dir, else: 0)

        [
          <<flags>>,
          Wire.int(byte_size(e.name)),
          e.name,
          Wire.long(e.size),
          Wire.int(e.mtime |> max(-0x80000000) |> min(0x7FFFFFFF)),
          Wire.int(e.mode),
          if(opts.owner, do: Wire.int(e.uid), else: []),
          if(opts.group, do: Wire.int(e.gid), else: []),
          if(opts.devices and device?(e.mode), do: Wire.int(e.rdev), else: []),
          if(opts.links and link?(e), do: [Wire.int(byte_size(e.link)), e.link], else: []),
          if(opts.checksum, do: e.sum || :binary.copy(<<0>>, 16), else: [])
        ]
      end

    ids = if opts.numeric_ids, do: [], else: [if(opts.owner, do: Wire.int(0), else: []), if(opts.group, do: Wire.int(0), else: [])]
    Wire.write(wire, [data, <<0>>, ids, Wire.int(0)])
  end

  @doc "Receive the list (sorted), skipping the uid/gid maps. Returns `{entries, io_error}`."
  def recv(wire, opts), do: recv(wire, opts, nil, [])

  defp recv(wire, opts, last, acc) do
    case Wire.read_byte(wire) do
      0 ->
        unless opts.numeric_ids do
          if opts.owner, do: skip_ids(wire)
          if opts.group, do: skip_ids(wire)
        end

        io_error = Wire.read_int(wire)
        {sort(Enum.reverse(acc)), io_error}

      flags ->
        e = entry_from_wire(wire, flags, last, opts)
        recv(wire, opts, e, [e | acc])
    end
  end

  defp entry_from_wire(wire, flags, last, opts) do
    keep = if (flags &&& @same_name) != 0, do: Wire.read_byte(wire), else: 0
    len = if (flags &&& @long_name) != 0, do: Wire.read_int(wire), else: Wire.read_byte(wire)
    name = binary_part(last_name(last), 0, keep) <> Wire.read(wire, len)
    size = Wire.read_long(wire)
    mtime = if (flags &&& @same_time) != 0, do: last.mtime, else: Wire.read_int(wire)
    mode = if (flags &&& @same_mode) != 0, do: last.mode, else: Wire.read_int(wire) &&& 0xFFFFFFFF
    uid = if opts.owner, do: (if (flags &&& @same_uid) != 0, do: last.uid, else: Wire.read_int(wire)), else: 0
    gid = if opts.group, do: (if (flags &&& @same_gid) != 0, do: last.gid, else: Wire.read_int(wire)), else: 0

    rdev =
      if opts.devices and device?(mode),
        do: (if (flags &&& @same_rdev) != 0, do: last.rdev, else: Wire.read_int(wire)),
        else: 0

    link = if opts.links and (mode &&& @s_ifmt) == @s_iflnk, do: Wire.read(wire, Wire.read_int(wire))
    sum = if opts.checksum, do: Wire.read(wire, 16)
    %Entry{name: clean(name), raw_name: name, mode: mode, size: size, mtime: mtime, uid: uid, gid: gid, rdev: rdev, link: link, sum: sum, top: (flags &&& @top_dir) != 0}
  end

  defp last_name(nil), do: ""
  defp last_name(e), do: e.raw_name || e.name

  defp skip_ids(wire) do
    case Wire.read_int(wire) do
      0 -> :ok
      _id -> Wire.read(wire, Wire.read_byte(wire)); skip_ids(wire)
    end
  end

  # A name from the other side: relative, without `..`, `.` and `//`.
  defp clean(name) do
    parts = name |> String.split("/") |> Enum.reject(&(&1 in ["", "."]))
    if Enum.any?(parts, &(&1 == "..")), do: throw({:rsync_error, 2, "unsafe file name from the sender: #{name}"})
    if parts == [], do: ".", else: Enum.join(parts, "/")
  end
end
