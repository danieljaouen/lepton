defmodule Lepton.Archive.Tar do
  @moduledoc """
  tar archives, as GNU tar reads and writes them: ustar headers, GNU long
  names (`L`, `K`) and pax extended headers (`x`) when reading; ustar, with
  a pax header for names that don't fit, when writing. Compressed with
  gzip (`.tar.gz`: Erlang's zlib), bzip2, xz or zstd (`.tar.bz2`,
  `.tar.xz`, `.tar.zst`: programs, see `Lepton.Archive.Compress`), both
  ways; reading recognises the compression by the archive's first bytes.

  `cli/2` is the `tar` command.
  """

  import Bitwise
  alias Lepton.{Ctx, IO}

  @block 512

  # -- reading ------------------------------------------------------------------------------------

  @doc "What compresses `data`: :gzip, :bzip2, :xz, :zstd, :lzip or :none."
  def compression(<<0x1F, 0x8B, _::binary>>), do: :gzip
  def compression(<<"BZh", _::binary>>), do: :bzip2
  def compression(<<0xFD, "7zXZ", 0, _::binary>>), do: :xz
  def compression(<<0x28, 0xB5, 0x2F, 0xFD, _::binary>>), do: :zstd
  def compression(<<"LZIP", _::binary>>), do: :lzip
  def compression(_), do: :none

  @doc """
  Decompress an archive (`{:ok, tar}` or `{:error, message}`): gzip here;
  bzip2, xz and zstd with their programs, on `path` (the archive's file,
  or nil) for `ctx` (which may be asked to install them).
  """
  def decompress(data, path \\ nil, ctx \\ nil) do
    case compression(data) do
      :none -> {:ok, data}
      :gzip -> gunzip(data)
      other -> Lepton.Archive.Compress.decompress(other, data, path, ctx)
    end
  end

  # :zlib.gunzip reads every member of a .gz (as `cat a.gz b.gz` makes).
  defp gunzip(data) do
    {:ok, :zlib.gunzip(data)}
  rescue
    _ -> {:error, "not in gzip format, or damaged"}
  end

  @doc """
  The archive's entries, in order: maps with `name`, `type` (:file, :dir,
  :symlink, :link, :other), `mode`, `uid`, `gid`, `uname`, `gname`,
  `size`, `mtime`, `link` (a link's target) and `data` (a file's contents).
  """
  def entries(tar), do: entries(tar, %{}, [])

  defp entries(<<header::binary-size(@block), rest::binary>>, ext, acc) do
    if header == <<0::size(@block * 8)>> do
      {:ok, Enum.reverse(acc)}
    else
      with {:ok, h} <- header(header) do
        size = h.size
        skip = div(size + @block - 1, @block) * @block - size

        case rest do
          <<data::binary-size(^size), _::binary-size(^skip), rest2::binary>> -> entry(h, data, rest2, ext, acc)
          _ -> {:error, "unexpected end of archive (#{h.name})"}
        end
      end
    end
  end

  # No end blocks: what's there is the archive (as GNU tar reads it).
  defp entries(_, _ext, acc), do: {:ok, Enum.reverse(acc)}

  defp entry(%{typeflag: "L"}, data, rest, ext, acc), do: entries(rest, Map.put(ext, :name, cstring(data)), acc)
  defp entry(%{typeflag: "K"}, data, rest, ext, acc), do: entries(rest, Map.put(ext, :link, cstring(data)), acc)
  defp entry(%{typeflag: "x"}, data, rest, ext, acc), do: entries(rest, Map.merge(ext, pax(data)), acc)
  defp entry(%{typeflag: "g"}, _data, rest, ext, acc), do: entries(rest, ext, acc)

  defp entry(h, data, rest, ext, acc) do
    type =
      case h.typeflag do
        t when t in ["0", "", "7"] -> :file
        "5" -> :dir
        "2" -> :symlink
        "1" -> :link
        _ -> :other
      end

    name = ext[:name] || h.name
    type = if type == :file and String.ends_with?(name, "/"), do: :dir, else: type

    e = %{
      name: name,
      type: type,
      mode: h.mode,
      uid: h.uid,
      gid: h.gid,
      uname: ext[:uname] || h.uname,
      gname: ext[:gname] || h.gname,
      size: if(type == :file, do: byte_size(data), else: 0),
      mtime: ext[:mtime] || h.mtime,
      link: ext[:link] || h.link,
      data: if(type == :file, do: data, else: "")
    }

    entries(rest, %{}, [e | acc])
  end

  defp header(<<name::binary-100, mode::binary-8, uid::binary-8, gid::binary-8, size::binary-12, mtime::binary-12, chksum::binary-8, typeflag::binary-1, link::binary-100, magic::binary-6, _version::binary-2, uname::binary-32, gname::binary-32, _dev::binary-16, prefix::binary-155, _::binary>> = block) do
    sum = block |> binary_part(0, 148) |> :binary.bin_to_list() |> Enum.sum()
    sum = sum + 8 * 32 + (block |> binary_part(156, 356) |> :binary.bin_to_list() |> Enum.sum())

    if number(chksum) != sum do
      {:error, "not a tar archive (or damaged: a header's checksum is wrong)"}
    else
      name = cstring(name)
      prefix = if String.starts_with?(magic, "ustar"), do: cstring(prefix), else: ""

      {:ok,
       %{
         name: if(prefix == "", do: name, else: prefix <> "/" <> name),
         mode: number(mode) &&& 0o7777,
         uid: number(uid),
         gid: number(gid),
         size: number(size),
         mtime: number(mtime),
         typeflag: cstring(typeflag),
         link: cstring(link),
         uname: cstring(uname),
         gname: cstring(gname)
       }}
    end
  end

  defp cstring(bin), do: bin |> :binary.split(<<0>>) |> hd()

  # Octal (space or NUL ended), or base-256 (GNU: the high bit set) for big numbers.
  defp number(<<1::1, _::7, _::binary>> = bin) do
    bits = bit_size(bin) - 1
    <<_::1, n::size(^bits)>> = bin
    n
  end

  defp number(bin) do
    case bin |> cstring() |> String.trim() do
      "" -> 0
      s -> case Integer.parse(s, 8), do: ({n, _} -> n; :error -> 0)
    end
  end

  # "LEN key=value\n" records.
  defp pax(data, acc \\ %{})
  defp pax("", acc), do: acc

  defp pax(data, acc) do
    with {len, " " <> _} <- Integer.parse(data),
         <<record::binary-size(^len), rest::binary>> <- data do
      [_, kv] = String.split(record, " ", parts: 2)
      [k, v] = String.split(String.trim_trailing(kv, "\n"), "=", parts: 2)

      acc =
        case k do
          "path" -> Map.put(acc, :name, v)
          "linkpath" -> Map.put(acc, :link, v)
          "uname" -> Map.put(acc, :uname, v)
          "gname" -> Map.put(acc, :gname, v)
          "mtime" -> Map.put(acc, :mtime, v |> Float.parse() |> elem(0) |> trunc())
          _ -> acc
        end

      pax(rest, acc)
    else
      _ -> acc
    end
  end

  # -- writing ------------------------------------------------------------------------------------

  @doc """
  An archive of `paths` (as given, relative to `cwd`): directories with
  everything in them. Returns `{tar, warnings}`; `exclude` is a list of
  glob patterns matched against each name and its basename.
  """
  def create(paths, cwd, exclude \\ []) do
    {blocks, warnings} =
      Enum.reduce(paths, {[], []}, fn p, {blocks, warns} ->
        {name, warn} = member_name(p)
        warns = if warn && warn not in warns, do: [warn | warns], else: warns
        add(Path.expand(p, cwd), name, exclude, {blocks, warns})
      end)

    {Elixir.IO.iodata_to_binary([Enum.reverse(blocks), <<0::size(@block * 16)>>]), Enum.reverse(warnings)}
  end

  @doc "A member's name for `path`: leading `/` and `../` left out, as GNU tar does (with its warning)."
  def member_name(path) do
    parts = Path.split(path)
    {lead, rest} = Enum.split_while(parts, &(&1 in ["/", ".."]))
    name = Path.join(if rest == [], do: ["."], else: rest)

    case lead do
      [] -> {strip_dot(path), nil}
      _ -> {name, "Removing leading '#{Enum.join(lead) |> String.replace("..", "../") |> String.replace("//", "/")}' from member names"}
    end
  end

  defp strip_dot(p), do: String.trim_trailing(p, "/") |> then(&if(&1 == "", do: "/", else: &1))

  defp add(full, name, exclude, {blocks, warns}) do
    if excluded?(name, exclude) or skip?(full) do
      {blocks, warns}
    else
      case File.lstat(full, time: :posix) do
        {:ok, st} ->
          case st.type do
            :directory ->
              acc = {[header_blocks(name <> "/", "5", st, 0, "") | blocks], warns}

              case File.ls(full) do
                {:ok, names} -> names |> Enum.sort() |> Enum.reduce(acc, fn n, acc -> add(Path.join(full, n), join(name, n), exclude, acc) end)
                {:error, r} -> {elem(acc, 0), warns ++ ["#{name}: Cannot open: #{:file.format_error(r)}"]}
              end

            :symlink ->
              {:ok, target} = :file.read_link_all(String.to_charlist(full))
              {[header_blocks(name, "2", st, 0, List.to_string(target)) | blocks], warns}

            :regular ->
              case File.read(full) do
                {:ok, data} -> {[pad(data), header_blocks(name, "0", st, byte_size(data), "") | blocks], warns}
                {:error, r} -> {blocks, warns ++ ["#{name}: Cannot open: #{:file.format_error(r)}"]}
              end

            _ ->
              {blocks, warns ++ ["#{name}: socket ignored"]}
          end

        {:error, r} ->
          {blocks, warns ++ ["#{name}: Cannot stat: #{:file.format_error(r)}"]}
      end
    end
  end

  defp join(".", n), do: "./" <> n
  defp join(dir, n), do: dir <> "/" <> n

  @doc false
  def excluded?(name, patterns) do
    Enum.any?(patterns, fn pat ->
      re = glob_regex(pat)
      Regex.match?(re, String.trim_trailing(name, "/")) or Regex.match?(re, Path.basename(name)) or
        Regex.match?(re, String.trim_leading(name, "./"))
    end)
  end

  @doc "A shell glob (`*`, `?`, `[...]`) as an anchored regex."
  def glob_regex(pat) do
    body =
      pat
      |> String.graphemes()
      |> Enum.map_join(fn
        "*" -> ".*"
        "?" -> "."
        "[" -> "["
        "]" -> "]"
        c -> Regex.escape(c)
      end)

    Regex.compile!("^" <> body <> "$", "s")
  end

  defp pad(data) do
    case rem(byte_size(data), @block) do
      0 -> data
      r -> [data, <<0::size((@block - r) * 8)>>]
    end
  end

  defp header_blocks(name, type, st, size, link) do
    names = Process.get(:tar_names) || Process.put(:tar_names, Lepton.Users.names_by_id()) || Process.get(:tar_names)
    user = names.users[st.uid] || ""
    group = names.groups[st.gid] || ""
    fits = byte_size(link) <= 100 && split_name(name)
    mtime = max(st.mtime, 0)

    pax =
      if fits do
        []
      else
        records = [{"path", name}] ++ if(byte_size(link) > 100, do: [{"linkpath", link}], else: [])
        body = Enum.map_join(records, &pax_record/1)
        [header("././@PaxHeader", "x", 0o644, 0, 0, byte_size(body), mtime, "", "", "") |> elem(1), pad(body)]
      end

    {prefix, base} = fits || {"", String.slice(name, 0, 99)}
    [pax, header(base, type, st.mode &&& 0o7777, st.uid, st.gid, size, mtime, String.slice(link, 0, 99), user, group, prefix) |> elem(1)]
  end

  defp pax_record({k, v}) do
    body = " #{k}=#{v}\n"
    len = byte_size(body)
    # The length counts its own digits.
    n = Enum.find(1..10, fn d -> byte_size(Integer.to_string(len + d)) == d end)
    "#{len + n}#{body}"
  end

  # A name in ustar's 100 bytes, or 155 of prefix and 100 split at a slash.
  defp split_name(name) when byte_size(name) <= 100, do: {"", name}

  defp split_name(name) do
    parts = :binary.matches(name, "/") |> Enum.map(&elem(&1, 0))

    Enum.find_value(parts, fn i ->
      prefix = binary_part(name, 0, i)
      base = binary_part(name, i + 1, byte_size(name) - i - 1)
      if byte_size(prefix) <= 155 and byte_size(base) <= 100 and base != "", do: {prefix, base}
    end)
  end

  defp header(name, type, mode, uid, gid, size, mtime, link, user, group, prefix \\ "") do
    fields = [
      field(name, 100),
      octal(mode, 8),
      octal(uid, 8),
      octal(gid, 8),
      octal(size, 12),
      octal(mtime, 12),
      "        ",
      type,
      field(link, 100),
      "ustar\0",
      "00",
      field(user, 32),
      field(group, 32),
      octal(0, 8),
      octal(0, 8),
      field(prefix, 155),
      <<0::size(12 * 8)>>
    ]

    block = Elixir.IO.iodata_to_binary(fields)
    sum = block |> :binary.bin_to_list() |> Enum.sum()
    chk = String.pad_leading(Integer.to_string(sum, 8), 6, "0") <> <<0, " ">>
    <<a::binary-148, _::binary-8, b::binary>> = block
    {:ok, a <> chk <> b}
  end

  defp field(s, n), do: binary_part(s <> <<0::size(n * 8)>>, 0, n)

  # Octal with a NUL, or base-256 when it doesn't fit (sizes of 8 GiB and more).
  defp octal(n, width) do
    s = Integer.to_string(n, 8)

    if byte_size(s) <= width - 1 do
      String.pad_leading(s, width - 1, "0") <> <<0>>
    else
      <<1::1, n::size(width * 8 - 1)>>
    end
  end

  # -- extracting ---------------------------------------------------------------------------------

  @doc """
  Where an entry goes under `dir`, after `strip` leading components;
  nil for one to skip (nothing left, or `..` in it).
  """
  def target(name, dir, strip \\ 0) do
    parts = name |> Path.split() |> Enum.reject(&(&1 in ["/", "."])) |> Enum.drop(strip)

    cond do
      parts == [] -> nil
      ".." in parts -> nil
      true -> Path.join([dir | parts])
    end
  end

  @doc "Write `e` at `path`: `{:ok, :done}`, `{:ok, :kept}` (`keep`: it exists) or `{:error, reason}`."
  def extract(e, path, opts \\ []) do
    exists? = match?({:ok, _}, File.lstat(path))

    cond do
      e.type == :dir ->
        with :ok <- File.mkdir_p(path) do
          File.chmod(path, e.mode ||| 0o700)
          {:ok, :done}
        end

      exists? and opts[:keep] ->
        {:ok, :kept}

      true ->
        File.mkdir_p(Path.dirname(path))
        if exists? and not File.dir?(path), do: File.rm(path)
        write_entry(e, path, opts)
    end
  end

  defp write_entry(%{type: :symlink} = e, path, _opts), do: File.ln_s(e.link, path) |> done()

  defp write_entry(%{type: :link} = e, path, opts) do
    case opts[:link_target] && opts[:link_target].(e.link) do
      nil -> {:error, :enoent}
      src -> File.ln(src, path) |> done()
    end
  end

  defp write_entry(%{type: :file} = e, path, _opts) do
    with :ok <- File.write(path, e.data) do
      File.chmod(path, e.mode)
      File.touch(path, e.mtime)
      {:ok, :done}
    end
  end

  defp write_entry(_e, _path, _opts), do: {:ok, :skipped}

  defp done(:ok), do: {:ok, :done}
  defp done(err), do: err

  # -- the command --------------------------------------------------------------------------------

  @doc "The `tar` command."
  def cli(args, ctx) do
    case parse(args) do
      {:error, msg} ->
        IO.err(ctx, "tar: " <> msg)
        IO.err(ctx, "Try 'man tar' for more information.")
        2

      %{mode: nil} ->
        IO.err(ctx, "tar: You must specify one of the '-ctx' options")
        2

      %{mode: :create, members: []} ->
        IO.err(ctx, "tar: Cowardly refusing to create an empty archive")
        2

      # (as GNU tar: an archive isn't for the screen)
      %{mode: :create, file: "-"} when ctx.tty != nil and ctx.stdout == ctx.tty ->
        IO.err(ctx, "tar: Refusing to write archive contents to terminal (missing -f option?)")
        2

      o ->
        run(o, ctx)
    end
  end

  defp parse(args) do
    o = %{mode: nil, file: "-", verbose: 0, comp: nil, dir: nil, strip: 0, stdout: false, keep: false, exclude: [], members: [], compress: nil}

    args =
      case args do
        # The old form: "xzvf file", the first argument without its dash.
        [first | rest] when first != "" ->
          if String.starts_with?(first, "-"), do: args, else: ["-" <> first | rest]

        _ ->
          args
      end

    opts(args, o)
  end

  defp opts([], o), do: o
  defp opts(["--" | rest], o), do: %{o | members: o.members ++ rest}
  defp opts(["--" <> long | rest], o), do: long_opt(String.split(long, "=", parts: 2), rest, o)

  defp opts(["-" <> flags | rest], o) when flags != "" do
    short(String.graphemes(flags), rest, o)
  end

  defp opts([m | rest], o), do: opts(rest, %{o | members: o.members ++ [m]})

  defp short([], rest, o), do: opts(rest, o)

  # A flag taking a value: the rest of this argument, or the next one.
  defp short([f | more], rest, o) when f in ["f", "C"] do
    {value, rest} =
      case more do
        [] -> {List.first(rest), Enum.drop(rest, 1)}
        _ -> {Enum.join(more), rest}
      end

    cond do
      value == nil -> {:error, "option requires an argument -- '#{f}'"}
      f == "f" -> opts(rest, %{o | file: value})
      true -> opts(rest, %{o | dir: value})
    end
  end

  defp short([f | more], rest, o) do
    case flag(f, o) do
      {:error, _} = e -> e
      o -> short(more, rest, o)
    end
  end

  defp flag("c", o), do: set_mode(o, :create)
  defp flag("x", o), do: set_mode(o, :extract)
  defp flag("t", o), do: set_mode(o, :list)
  defp flag("v", o), do: %{o | verbose: o.verbose + 1}
  defp flag("z", o), do: %{o | comp: :gzip}
  defp flag("j", o), do: %{o | comp: :bzip2}
  defp flag("J", o), do: %{o | comp: :xz}
  defp flag("Z", o), do: %{o | comp: :zstd}
  defp flag("a", o), do: %{o | compress: :auto}
  defp flag("O", o), do: %{o | stdout: true}
  defp flag("k", o), do: %{o | keep: true}
  defp flag(f, o) when f in ["p", "o", "h", "m"], do: o
  defp flag(f, _o), do: {:error, "invalid option -- '#{f}'"}

  defp set_mode(%{mode: nil} = o, m), do: %{o | mode: m}
  defp set_mode(%{mode: m} = o, m), do: o
  defp set_mode(_o, _m), do: {:error, "You may not specify more than one '-ctx' option"}

  defp long_opt([name], rest, o) when name in ["file", "directory", "strip-components", "exclude"] do
    case rest do
      [v | rest] -> long_opt([name, v], rest, o)
      [] -> {:error, "option '--#{name}' requires an argument"}
    end
  end

  defp long_opt(["file", v], rest, o), do: opts(rest, %{o | file: v})
  defp long_opt(["directory", v], rest, o), do: opts(rest, %{o | dir: v})
  defp long_opt(["exclude", v], rest, o), do: opts(rest, %{o | exclude: o.exclude ++ [v]})

  defp long_opt(["strip-components", v], rest, o) do
    case Integer.parse(v) do
      {n, ""} when n >= 0 -> opts(rest, %{o | strip: n})
      _ -> {:error, "invalid number of elements: '#{v}'"}
    end
  end

  defp long_opt([name], rest, o) do
    short_for = %{"create" => "c", "extract" => "x", "get" => "x", "list" => "t", "verbose" => "v", "gzip" => "z", "gunzip" => "z",
                  "auto-compress" => "a", "to-stdout" => "O", "keep-old-files" => "k", "preserve-permissions" => "p",
                  "no-same-owner" => "o", "bzip2" => "j", "xz" => "J", "zstd" => "Z", "touch" => "m"}

    case short_for[name] do
      nil -> {:error, "unrecognized option '--#{name}'"}
      f -> with %{} = o <- flag(f, o), do: opts(rest, o)
    end
  end

  defp long_opt([name, _], _rest, _o), do: {:error, "unrecognized option '--#{name}'"}

  defp run(o, ctx) do
    base = if o.dir, do: Ctx.path(ctx, o.dir), else: ctx.cwd

    cond do
      o.dir && not File.dir?(base) ->
        IO.err(ctx, "tar: #{o.dir}: Cannot open: No such file or directory")
        2

      o.mode == :create ->
        create_cmd(o, ctx, base)

      true ->
        with {:ok, raw, path} <- read_archive(o, ctx),
             {:ok, tar} <- decompress(raw, path, ctx),
             {:ok, entries} <- entries(tar) do
          entries = select(entries, o.members)

          status =
            case o.mode do
              :list -> list(entries, o, ctx)
              :extract -> extract_cmd(entries, o, ctx, base)
            end

          missing = Enum.reject(o.members, fn m -> Enum.any?(entries, &member_match?(&1.name, m)) end)
          Enum.each(missing, &IO.err(ctx, "tar: #{&1}: Not found in archive"))
          if missing != [], do: 2, else: status
        else
          {:error, msg} ->
            IO.err(ctx, "tar: " <> msg)
            2
        end
    end
  end

  defp read_archive(%{file: "-"}, ctx), do: {:ok, IO.read_all(ctx.stdin), nil}

  defp read_archive(%{file: f}, ctx) do
    case File.read(Ctx.path(ctx, f)) do
      {:ok, data} -> {:ok, data, Ctx.path(ctx, f)}
      {:error, r} -> {:error, "#{f}: Cannot open: #{:file.format_error(r)}"}
    end
  end

  defp select(entries, []), do: entries
  defp select(entries, members), do: Enum.filter(entries, fn e -> Enum.any?(members, &member_match?(e.name, &1)) end)

  # A member named on the command line: that entry, or everything in that directory (globs too).
  defp member_match?(name, m) do
    name = name |> String.trim_leading("./") |> String.trim_trailing("/")
    m = m |> String.trim_leading("./") |> String.trim_trailing("/")
    name == m or String.starts_with?(name, m <> "/") or Regex.match?(glob_regex(m), name)
  end

  defp list(entries, o, ctx) do
    Enum.each(entries, fn e ->
      if o.verbose > 0, do: IO.puts(ctx, long_line(e)), else: IO.puts(ctx, e.name)
    end)

    0
  end

  @doc "A `tar -tv` line: `-rw-r--r-- user/group  SIZE YYYY-MM-DD HH:MM name`."
  def long_line(e) do
    owner = "#{if e.uname == "", do: e.uid, else: e.uname}/#{if e.gname == "", do: e.gid, else: e.gname}"
    size = if e.type == :file, do: e.size, else: 0
    {{y, mo, d}, {h, mi, _}} = Lepton.Time.erl(e.mtime)
    date = :io_lib.format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B", [y, mo, d, h, mi]) |> List.to_string()
    # GNU tar: user/group and the size, right-aligned, fill 19 columns.
    size = Integer.to_string(size)
    width = max(19 - String.length(owner), String.length(size))

    name =
      case e.type do
        :symlink -> "#{e.name} -> #{e.link}"
        :link -> "#{e.name} link to #{e.link}"
        _ -> e.name
      end

    "#{type_char(e.type)}#{perms(e.mode)} #{owner} #{String.pad_leading(size, width)} #{date} #{name}"
  end

  defp type_char(:dir), do: "d"
  defp type_char(:symlink), do: "l"
  defp type_char(:link), do: "h"
  defp type_char(_), do: "-"

  defp perms(mode) do
    for {bit, c} <- [{0o400, "r"}, {0o200, "w"}, {0o100, "x"}, {0o40, "r"}, {0o20, "w"}, {0o10, "x"}, {0o4, "r"}, {0o2, "w"}, {0o1, "x"}], into: "" do
      if (mode &&& bit) != 0, do: c, else: "-"
    end
  end

  defp extract_cmd(entries, o, ctx, base) do
    since = System.os_time(:second)

    if Lepton.Users.check_write(ctx, base) != :ok do
      IO.err(ctx, "tar: #{base}: Cannot write: Permission denied")
      2
    else
      warned = :erlang.make_ref()
      Process.put(warned, false)
      link_target = fn link -> target(link, base, o.strip) end

      # Directories' permissions last, so a read-only one can still be filled.
      status =
        Enum.reduce(entries, 0, fn e, status ->
          if String.starts_with?(e.name, "/") and not Process.get(warned) do
            IO.err(ctx, "tar: Removing leading '/' from member names")
            Process.put(warned, true)
          end

          cond do
            o.stdout ->
              if e.type == :file, do: IO.write(ctx, e.data)
              status

            true ->
              case target(e.name, base, o.strip) do
                nil ->
                  if String.contains?(e.name, ".."), do: IO.err(ctx, "tar: #{e.name}: Member name contains '..'")
                  status

                path ->
                  if o.verbose > 0, do: IO.puts(ctx, if(o.verbose > 1, do: long_line(e), else: e.name))

                  case extract(e, path, keep: o.keep, link_target: link_target) do
                    {:ok, :kept} ->
                      IO.err(ctx, "tar: #{e.name}: Cannot open: File exists")
                      2

                    {:ok, _} ->
                      status

                    {:error, r} ->
                      IO.err(ctx, "tar: #{e.name}: Cannot open: #{:file.format_error(r)}")
                      2
                  end
              end
          end
        end)

      Process.delete(warned)
      Lepton.Users.adopt(ctx, base, since)
      status
    end
  end

  defp create_cmd(o, ctx, base) do
    # -z, -j, -J, --zstd; or -a, by the archive's name.
    kind = o.comp || if(o.compress == :auto, do: Lepton.Archive.Compress.by_name(o.file), else: :none)

    cond do
      true ->
        missing = Enum.reject(o.members, &match?({:ok, _}, File.lstat(Path.expand(&1, base))))
        Enum.each(missing, &IO.err(ctx, "tar: #{&1}: Cannot stat: No such file or directory"))
        present = o.members -- missing

        # The archive itself is left out (tar -czf a.tgz . in the same folder).
        out_path = if o.file != "-", do: Ctx.path(ctx, o.file)
        excludes = o.exclude
        {tar, warnings} = create_skipping(present, base, excludes, out_path)
        Enum.each(warnings, &IO.err(ctx, "tar: " <> &1))
        # -v: the names, on stderr when the archive goes to stdout.
        if o.verbose > 0, do: tar |> entries() |> elem(1) |> Enum.each(&verbose_line(ctx, o, &1))
        compressed =
          case kind do
            :none -> {:ok, tar}
            :gzip -> {:ok, :zlib.gzip(tar)}
            other -> Lepton.Archive.Compress.compress(other, tar, ctx)
          end

        result =
          case {compressed, out_path} do
            {{:error, msg}, _} -> {:error, msg}
            {{:ok, data}, nil} -> IO.write(ctx, data)
            {{:ok, data}, p} -> if Lepton.Users.check_write(ctx, p) == :ok, do: Lepton.Users.own_new(ctx, p, fn -> File.write(p, data) end), else: {:error, :eacces}
          end

        case result do
          :ok ->
            if missing != [] or Enum.any?(warnings, &String.contains?(&1, "Cannot")), do: 2, else: 0

          {:error, msg} when is_binary(msg) ->
            IO.err(ctx, "tar: " <> msg)
            2

          {:error, r} ->
            IO.err(ctx, "tar: #{o.file}: Cannot open: #{:file.format_error(r)}")
            2
        end
    end
  end

  defp create_skipping(paths, base, excludes, out_path) do
    Process.put(:tar_skip, out_path)
    result = create(paths, base, excludes)
    Process.delete(:tar_skip)
    Process.delete(:tar_names)
    result
  end

  @doc false
  def skip?(full), do: Process.get(:tar_skip) == full

  defp verbose_line(ctx, o, e) do
    line = if o.verbose > 1, do: long_line(e), else: e.name
    if o.file == "-", do: IO.err(ctx, line), else: IO.puts(ctx, line)
  end
end
