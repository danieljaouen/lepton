defmodule Lepton.Archive.Zip do
  @moduledoc """
  Reading .zip archives, as Info-ZIP's `unzip`: the central directory
  (zip64 too), stored and deflated members, Unix permissions and symbolic
  links, and the extended timestamp. Members are read from the file as
  they're extracted, in chunks, so a big archive needn't fit in memory.

  `cli/2` is the `unzip` command.
  """

  import Bitwise
  alias Lepton.{Ctx, IO}

  @chunk 1 <<< 20

  defmodule Entry do
    @moduledoc false
    defstruct [:name, :method, :flags, :crc, :csize, :size, :offset, :mtime, :mode, :unix?, :comment]
  end

  # -- reading the directory ------------------------------------------------------------------------

  @doc "Open `path` and read its directory: `{:ok, fd, [Entry], comment}` or `{:error, msg}`."
  def open(path) do
    with {:ok, fd} <- :file.open(path, [:read, :raw, :binary]) do
      case directory(fd) do
        {:ok, entries, comment} -> {:ok, fd, entries, comment}
        {:error, _} = e -> :file.close(fd) && e
      end
    else
      {:error, r} -> {:error, :file.format_error(r) |> List.to_string()}
    end
  end

  def close(fd), do: :file.close(fd)

  defp directory(fd) do
    {:ok, size} = :file.position(fd, :eof)
    # The end record is in the last 22 bytes, plus a comment of up to 64 KiB.
    tail_len = min(size, 22 + 65_535)
    {:ok, tail} = pread(fd, size - tail_len, tail_len)

    case last_match(tail, <<"PK", 5, 6>>) do
      nil ->
        {:error, "End-of-central-directory signature not found. Either this file is not a zipfile, or it constitutes one disk of a multi-part archive."}

      at ->
        <<_::32, _disk::16-little, _cd_disk::16-little, _n_disk::16-little, n::16-little, cd_size::32-little, cd_off::32-little, clen::16-little, comment::binary>> =
          binary_part(tail, at, tail_len - at)

        comment = binary_part(comment, 0, min(clen, byte_size(comment)))
        eocd_pos = size - tail_len + at

        {_n, cd_size, cd_off} =
          if n == 0xFFFF or cd_off == 0xFFFFFFFF or cd_size == 0xFFFFFFFF, do: zip64_end(fd, eocd_pos) || {n, cd_size, cd_off}, else: {n, cd_size, cd_off}

        # Data before the archive (a self-extractor's stub): offsets move by it.
        shift = max(eocd_pos - cd_size - cd_off, 0)

        case pread(fd, cd_off + shift, cd_size) do
          {:ok, cd} when byte_size(cd) == cd_size ->
            entries = central(cd, [])
            {:ok, Enum.map(entries, &%{&1 | offset: &1.offset + shift}), comment}

          _ ->
            {:error, "the central directory is damaged or missing"}
        end
    end
  end

  defp zip64_end(fd, eocd_pos) do
    with true <- eocd_pos >= 20,
         {:ok, <<"PK", 6, 7, _::32, off::64-little, _::32>>} <- pread(fd, eocd_pos - 20, 20),
         {:ok, <<"PK", 6, 6, _::64, _::16, _::16, _::32, _::32, _::64, n::64-little, cd_size::64-little, cd_off::64-little>>} <- pread(fd, off, 56) do
      {n, cd_size, cd_off}
    else
      _ -> nil
    end
  end

  defp central(<<"PK", 1, 2, made::16-little, _need::16-little, flags::16-little, method::16-little, time::16-little, date::16-little, crc::32-little, csize::32-little, size::32-little,
                 nlen::16-little, elen::16-little, clen::16-little, _disk::16-little, _int::16-little, ext::32-little, off::32-little, rest::binary>>, acc) do
    <<name::binary-size(^nlen), extra::binary-size(^elen), comment::binary-size(^clen), rest::binary>> = rest
    {size, csize, off} = zip64_extra(extra, size, csize, off)
    unix? = made >>> 8 == 3
    mode = if unix?, do: ext >>> 16, else: if((ext &&& 0x10) != 0, do: 0o40755, else: 0o100644)

    e = %Entry{
      name: name_text(name, flags),
      method: method,
      flags: flags,
      crc: crc,
      csize: csize,
      size: size,
      offset: off,
      mtime: unix_time(extra) || dos_time(date, time),
      mode: if(mode == 0, do: 0o100644, else: mode),
      unix?: unix?,
      comment: comment
    }

    central(rest, [e | acc])
  end

  defp central(_, acc), do: Enum.reverse(acc)

  # Names are UTF-8 with flag bit 11; otherwise IBM code page 437, which is
  # ASCII for nearly every name (and Latin-1 as the fallback here).
  defp name_text(name, flags) do
    if (flags &&& 0x800) != 0 or String.valid?(name), do: name, else: :unicode.characters_to_binary(name, :latin1)
  end

  # The zip64 extra field: the 64-bit values of those that are 0xFFFFFFFF, in order.
  defp zip64_extra(extra, size, csize, off) do
    case find_extra(extra, 0x0001) do
      nil ->
        {size, csize, off}

      data ->
        {size, data} = take64(size, data)
        {csize, data} = take64(csize, data)
        {off, _} = take64(off, data)
        {size, csize, off}
    end
  end

  defp take64(0xFFFFFFFF, <<v::64-little, rest::binary>>), do: {v, rest}
  defp take64(v, data), do: {v, data}

  defp find_extra(<<id::16-little, len::16-little, rest::binary>>, want) do
    case rest do
      <<data::binary-size(^len), more::binary>> -> if id == want, do: data, else: find_extra(more, want)
      _ -> nil
    end
  end

  defp find_extra(_, _), do: nil

  defp unix_time(extra) do
    case find_extra(extra, 0x5455) do
      <<flags, t::32-little-signed, _::binary>> when (flags &&& 1) == 1 -> t
      _ -> nil
    end
  end

  defp dos_time(date, time) do
    y = (date >>> 9) + 1980
    mo = max((date >>> 5) &&& 0xF, 1)
    d = max(date &&& 0x1F, 1)
    h = time >>> 11
    mi = (time >>> 5) &&& 0x3F
    s = (time &&& 0x1F) * 2

    case NaiveDateTime.new(y, mo, d, min(h, 23), min(mi, 59), min(s, 59)) do
      # DOS times are local: the clock's offset then, taken away.
      {:ok, ndt} ->
        t = ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
        %{utc_offset: u, std_offset: s} = Lepton.Time.local(t)
        t - u - s
      _ -> 0
    end
  end

  defp last_match(bin, pat) do
    case :binary.matches(bin, pat) do
      [] -> nil
      ms -> ms |> List.last() |> elem(0)
    end
  end

  defp pread(fd, pos, len) do
    case :file.pread(fd, pos, len) do
      :eof -> {:ok, ""}
      other -> other
    end
  end

  # -- members ------------------------------------------------------------------------------------

  def dir?(%Entry{name: n, mode: mode}), do: String.ends_with?(n, "/") or (mode &&& 0o170000) == 0o040000
  def symlink?(%Entry{unix?: true, mode: mode}), do: (mode &&& 0o170000) == 0o120000
  def symlink?(_), do: false
  def encrypted?(%Entry{flags: f}), do: (f &&& 1) == 1

  @doc """
  Feed the member's contents to `sink` (`fn chunk, acc -> acc end`) in
  chunks. Returns `{:ok, acc}`, or `{:error, msg}`: a bad CRC, an
  unsupported method, encryption.
  """
  def read(fd, %Entry{} = e, acc, sink) do
    cond do
      encrypted?(e) -> {:error, "encrypted (not supported)"}
      e.method not in [0, 8] -> {:error, "unsupported compression method #{e.method}"}
      true -> read_data(fd, e, acc, sink)
    end
  end

  defp read_data(fd, e, acc, sink) do
    with {:ok, <<"PK", 3, 4, _::binary-22, nlen::16-little, elen::16-little>>} <- pread(fd, e.offset, 30) do
      start = e.offset + 30 + nlen + elen

      z =
        if e.method == 8 do
          z = :zlib.open()
          :zlib.inflateInit(z, -15)
          z
        end

      try do
        {crc, acc} = pump(fd, z, start, e.csize, 0, acc, sink)
        if crc == e.crc, do: {:ok, acc}, else: {:error, "bad CRC #{hex(crc)}  (should be #{hex(e.crc)})"}
      rescue
        ErlangError -> {:error, "invalid compressed data"}
      after
        z && :zlib.close(z)
      end
    else
      _ -> {:error, "bad local header (the archive is damaged)"}
    end
  end

  defp hex(n), do: n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(8, "0")

  defp pump(_fd, z, _pos, 0, crc, acc, sink) do
    # A deflate stream with nothing left to read may still hold output.
    if z, do: drain(z, :zlib.safeInflate(z, []), crc, acc, sink), else: {crc, acc}
  end

  defp pump(fd, z, pos, left, crc, acc, sink) do
    n = min(left, @chunk)
    {:ok, data} = pread(fd, pos, n)
    if byte_size(data) < n, do: raise(ErlangError, original: :truncated)

    if z do
      {crc, acc} = drain(z, :zlib.safeInflate(z, data), crc, acc, sink)
      pump(fd, z, pos + n, left - n, crc, acc, sink)
    else
      pump(fd, z, pos + n, left - n, :erlang.crc32(crc, data), sink.(data, acc), sink)
    end
  end

  defp drain(z, {status, out}, crc, acc, sink) do
    out = Elixir.IO.iodata_to_binary(out)
    {crc, acc} = if out == "", do: {crc, acc}, else: {:erlang.crc32(crc, out), sink.(out, acc)}

    case status do
      :continue -> drain(z, :zlib.safeInflate(z, []), crc, acc, sink)
      _ -> {crc, acc}
    end
  end

  # -- the command --------------------------------------------------------------------------------

  @doc "The `unzip` command."
  def cli(args, ctx) do
    case parse(args, %{mode: :extract, overwrite: nil, quiet: 0, junk: false, dir: nil, zip: nil, members: [], exclude: []}) do
      {:error, msg} ->
        IO.err(ctx, "unzip: " <> msg)
        10

      %{zip: nil} ->
        IO.err(ctx, "usage: unzip [-l | -v | -t | -p | -Z1] [-o | -n] [-q] [-j] [-d DIR] ZIPFILE [MEMBER...] [-x MEMBER...]")
        10

      o ->
        run(o, ctx)
    end
  end

  defp parse([], o), do: o
  defp parse(["-x" | rest], o) when o.zip != nil, do: %{o | exclude: o.exclude ++ rest}
  defp parse(["-d", dir | rest], o), do: parse(rest, %{o | dir: dir})
  defp parse(["-d"], _o), do: {:error, "option -d needs a folder"}
  defp parse(["-Z1" | rest], o), do: parse(rest, %{o | mode: :names})

  defp parse(["-" <> flags | rest], o) when flags != "" do
    Enum.reduce_while(String.graphemes(flags), o, fn f, o ->
      case f do
        "l" -> {:cont, %{o | mode: :list}}
        "v" -> {:cont, %{o | mode: :verbose}}
        "t" -> {:cont, %{o | mode: :test}}
        "p" -> {:cont, %{o | mode: :pipe}}
        "c" -> {:cont, %{o | mode: :pipe}}
        "o" -> {:cont, %{o | overwrite: :all}}
        "n" -> {:cont, %{o | overwrite: :none}}
        "q" -> {:cont, %{o | quiet: o.quiet + 1}}
        "j" -> {:cont, %{o | junk: true}}
        "a" -> {:cont, o}
        "X" -> {:cont, o}
        _ -> {:halt, {:error, "invalid option -#{f}"}}
      end
    end)
    |> case do
      {:error, _} = e -> e
      o -> parse(rest, o)
    end
  end

  defp parse([zip | rest], %{zip: nil} = o), do: parse(rest, %{o | zip: zip})
  defp parse([m | rest], o), do: parse(rest, %{o | members: o.members ++ [m]})

  defp run(o, ctx) do
    # As Info-ZIP: NAME, then NAME.zip.
    path = Ctx.path(ctx, o.zip)
    path = if not File.regular?(path) and File.regular?(path <> ".zip"), do: path <> ".zip", else: path

    case open(path) do
      {:ok, fd, entries, comment} ->
        try do
          chosen = Enum.filter(entries, &chosen?(&1.name, o))
          missing = Enum.reject(o.members, fn m -> Enum.any?(entries, &matches?(&1.name, m)) end)
          status = mode(o.mode, o, ctx, fd, chosen, comment)
          Enum.each(missing, &IO.err(ctx, "caution: filename not matched:  #{&1}"))
          if missing != [] and status == 0, do: 11, else: status
        after
          close(fd)
        end

      {:error, msg} ->
        cond do
          not File.exists?(path) ->
            IO.err(ctx, "unzip:  cannot find or open #{o.zip}, #{o.zip}.zip or #{o.zip}.ZIP.")
            9

          true ->
            IO.err(ctx, "unzip:  cannot read #{o.zip}: #{msg}")
            9
        end
    end
  end

  defp chosen?(name, o) do
    (o.members == [] or Enum.any?(o.members, &matches?(name, &1))) and not Enum.any?(o.exclude, &matches?(name, &1))
  end

  # Members are wildcards (`*`, `?`, `[...]`) matched against the whole name, as unzip does.
  defp matches?(name, pat), do: Regex.match?(Lepton.Archive.Tar.glob_regex(pat), name)

  defp mode(:names, _o, ctx, _fd, entries, _comment) do
    Enum.each(entries, &IO.puts(ctx, &1.name))
    0
  end

  defp mode(:list, o, ctx, _fd, entries, comment) do
    IO.puts(ctx, "Archive:  #{o.zip}")
    if comment != "", do: IO.puts(ctx, comment)
    IO.puts(ctx, "  Length      Date    Time    Name\n---------  ---------- -----   ----")
    Enum.each(entries, &IO.puts(ctx, "#{pad(&1.size, 9)}  #{date(&1.mtime)}   #{&1.name}"))
    total = entries |> Enum.map(& &1.size) |> Enum.sum()
    IO.puts(ctx, "---------                     -------")
    IO.puts(ctx, "#{pad(total, 9)}                     #{length(entries)} file#{if length(entries) == 1, do: "", else: "s"}")
    0
  end

  defp mode(:verbose, o, ctx, _fd, entries, _comment) do
    IO.puts(ctx, "Archive:  #{o.zip}")
    IO.puts(ctx, " Length   Method    Size  Cmpr    Date    Time   CRC-32   Name\n--------  ------  ------- ---- ---------- ----- --------  ----")

    Enum.each(entries, fn e ->
      method = if e.method == 8, do: "Defl:N", else: if(e.method == 0, do: "Stored", else: "Unk:#{e.method}")
      IO.puts(ctx, "#{pad(e.size, 8)}  #{method}  #{pad(e.csize, 7)} #{ratio(e.size, e.csize)} #{date(e.mtime)} #{hex(e.crc)}  #{e.name}")
    end)

    size = entries |> Enum.map(& &1.size) |> Enum.sum()
    csize = entries |> Enum.map(& &1.csize) |> Enum.sum()
    IO.puts(ctx, "--------          -------  ---                            -------")
    IO.puts(ctx, "#{pad(size, 8)}          #{pad(csize, 7)} #{ratio(size, csize)}                            #{length(entries)} file#{if length(entries) == 1, do: "", else: "s"}")
    0
  end

  defp mode(:test, o, ctx, fd, entries, _comment) do
    IO.puts(ctx, "Archive:  #{o.zip}")

    errors =
      Enum.count(entries, fn e ->
        case if(dir?(e), do: {:ok, nil}, else: read(fd, e, nil, fn _, a -> a end)) do
          {:ok, _} ->
            if o.quiet == 0, do: IO.puts(ctx, "    testing: #{String.pad_trailing(e.name, 24)} OK")
            false

          {:error, msg} ->
            IO.puts(ctx, "    testing: #{String.pad_trailing(e.name, 24)} #{msg}")
            true
        end
      end)

    if errors == 0 do
      IO.puts(ctx, "No errors detected in compressed data of #{o.zip}.")
      0
    else
      IO.puts(ctx, "At least one error was detected in #{o.zip}.")
      2
    end
  end

  defp mode(:pipe, _o, ctx, fd, entries, _comment) do
    Enum.reduce(entries, 0, fn e, status ->
      if dir?(e) do
        status
      else
        case read(fd, e, nil, fn chunk, a -> IO.write(ctx, chunk) && a end) do
          {:ok, _} -> status
          {:error, msg} -> IO.err(ctx, "unzip: #{e.name}: #{msg}") && 2
        end
      end
    end)
  end

  defp mode(:extract, o, ctx, fd, entries, comment) do
    base = if o.dir, do: Ctx.path(ctx, o.dir), else: ctx.cwd
    since = System.os_time(:second)

    if Lepton.Users.check_write(ctx, base) != :ok do
      IO.err(ctx, "unzip: #{base}: permission denied")
      50
    else
      say = fn line -> if o.quiet == 0, do: IO.puts(ctx, line) end
      say.("Archive:  #{o.zip}")
      if comment != "" and o.quiet == 0, do: IO.puts(ctx, comment)
      File.mkdir_p(base)
      Process.put(:unzip_overwrite, o.overwrite)

      status =
        Enum.reduce(entries, 0, fn e, status ->
          case target(e.name, base, o.junk) do
            nil ->
              IO.err(ctx, "warning:  skipped \"../\" path component(s) in #{e.name}")
              max(status, 1)

            :skip ->
              status

            path ->
              max(status, extract_one(ctx, fd, e, path, shown(path, ctx), say))
          end
        end)

      Process.delete(:unzip_overwrite)
      Lepton.Users.adopt(ctx, base, since)
      status
    end
  end

  # As unzip shows them: relative to here (as -d gave it), or from ~.
  defp shown(path, ctx) do
    rel = Path.relative_to(path, ctx.cwd)
    if rel == path, do: Ctx.tildify(ctx, path), else: rel
  end

  @doc "Where `name` goes under `base` (nil: it climbs out with `..`; :skip: a folder, with -j)."
  def target(name, base, junk \\ false) do
    parts = name |> String.replace("\\", "/") |> String.split("/", trim: true) |> Enum.reject(&(&1 == "."))

    cond do
      ".." in parts -> nil
      parts == [] -> :skip
      junk and String.ends_with?(name, "/") -> :skip
      junk -> Path.join(base, List.last(parts))
      true -> Path.join([base | parts])
    end
  end

  defp extract_one(ctx, fd, e, path, shown, say) do
    cond do
      dir?(e) ->
        say.("   creating: #{shown}/" |> String.replace("//", "/"))
        File.mkdir_p(path)
        0

      encrypted?(e) ->
        IO.err(ctx, "   skipping: #{e.name}  encrypted (not supported)")
        1

      not replace?(ctx, path, shown) ->
        0

      true ->
        File.mkdir_p(Path.dirname(path))
        if match?({:ok, _}, File.lstat(path)), do: File.rm(path)
        say.(String.pad_leading(if(e.method == 0, do: "extracting", else: "inflating"), 11) <> ": " <> shown <> if(symlink?(e), do: "  -> link", else: ""))
        write(ctx, fd, e, path)
    end
  end

  defp write(ctx, fd, e, path) do
    result =
      if symlink?(e) do
        with {:ok, target} <- read(fd, e, [], fn c, a -> [a, c] end) do
          File.ln_s(Elixir.IO.iodata_to_binary(target), path)
        end
      else
        with {:ok, out} <- :file.open(path, [:write, :raw, :binary]) do
          r = read(fd, e, out, fn c, out -> :ok = :file.write(out, c); out end)
          :file.close(out)
          if e.unix?, do: File.chmod(path, e.mode &&& 0o7777)
          File.touch(path, e.mtime)
          if match?({:ok, _}, r), do: :ok, else: r
        end
      end

    case result do
      :ok -> 0
      {:error, msg} when is_binary(msg) -> IO.err(ctx, "unzip: #{e.name}: #{msg}") && 2
      {:error, r} -> IO.err(ctx, "unzip: #{e.name}: #{:file.format_error(r)}") && 50
    end
  end

  # An existing file: -o replaces, -n keeps; otherwise ask, as unzip does.
  defp replace?(ctx, path, shown) do
    exists? = match?({:ok, _}, File.lstat(path)) and not File.dir?(path)

    case {exists?, Process.get(:unzip_overwrite)} do
      {false, _} -> true
      {true, :all} -> true
      {true, :none} -> false
      {true, nil} -> ask(ctx, shown)
    end
  end

  defp ask(ctx, shown) do
    IO.write(ctx, "replace #{shown}? [y]es, [n]o, [A]ll, [N]one: ")

    case IO.read_line(ctx.stdin) do
      :eof ->
        IO.puts(ctx, "(EOF or read error, treating as \"[N]one\" ...)")
        Process.put(:unzip_overwrite, :none)
        false

      line ->
        case String.trim(line) do
          "y" -> true
          "A" -> Process.put(:unzip_overwrite, :all) && true
          "N" -> Process.put(:unzip_overwrite, :none) && false
          "n" -> false
          _ -> ask(ctx, shown)
        end
    end
  end

  defp pad(n, w), do: n |> Integer.to_string() |> String.pad_leading(w)

  defp ratio(0, _), do: "  0%"
  defp ratio(size, csize), do: String.pad_leading("#{max(round((1 - csize / size) * 100), 0)}%", 4)

  # Info-ZIP's MM-DD-YYYY HH:MM.
  defp date(t) do
    {{y, mo, d}, {h, mi, _}} = Lepton.Time.erl(max(t, 0))
    :io_lib.format("~2..0B-~2..0B-~4..0B ~2..0B:~2..0B", [mo, d, y, h, mi]) |> List.to_string()
  end
end
