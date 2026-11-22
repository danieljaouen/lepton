defmodule Lepton.Git.Repo do
  @moduledoc "A repository on disk: worktree root and `.git` directory."
  defstruct [:root, :git_dir]

  def open(root), do: %__MODULE__{root: root, git_dir: Path.join(root, ".git")}

  def init(root, branch \\ "main") do
    git = Path.join(root, ".git")

    for d <- ["objects/info", "objects/pack", "refs/heads", "refs/tags", "info", "hooks"] do
      File.mkdir_p!(Path.join(git, d))
    end

    File.write!(Path.join(git, "HEAD"), "ref: refs/heads/#{branch}\n")
    File.write!(Path.join(git, "description"), "Unnamed repository; edit this file 'description' to name the repository.\n")
    File.write!(Path.join(git, "info/exclude"), "# git ls-files --others --exclude-from=.git/info/exclude\n")

    File.write!(Path.join(git, "config"), """
    [core]
    \trepositoryformatversion = 0
    \tfilemode = true
    \tbare = false
    \tlogallrefupdates = true
    """)

    open(root)
  end
end

defmodule Lepton.Git.Object do
  @moduledoc """
  The object database: loose objects (`objects/xx/yyyy...`, zlib) and
  pack files (`objects/pack/*.pack` with v2 `.idx`), including delta
  resolution. Objects are `{type, content}` with type in
  `:blob | :tree | :commit | :tag`.
  """

  alias Lepton.Git.Repo

  def hash(type, content) do
    :crypto.hash(:sha, [Atom.to_string(type), " ", Integer.to_string(byte_size(content)), 0, content])
    |> Base.encode16(case: :lower)
  end

  def write(%Repo{} = repo, type, content) do
    sha = hash(type, content)
    path = loose_path(repo, sha)

    unless File.exists?(path) do
      File.mkdir_p!(Path.dirname(path))
      data = :zlib.compress([Atom.to_string(type), " ", Integer.to_string(byte_size(content)), 0, content])
      File.write!(path <> ".tmp", data)
      File.rename!(path <> ".tmp", path)
    end

    sha
  end

  def exists?(repo, sha), do: File.exists?(loose_path(repo, sha)) or match?({:ok, _}, read_packed(repo, sha))

  def read(repo, sha) do
    case File.read(loose_path(repo, sha)) do
      {:ok, data} ->
        raw = :zlib.uncompress(data)
        [header, content] = :binary.split(raw, <<0>>)
        [type, _size] = String.split(header, " ")
        {:ok, {String.to_existing_atom(type), content}}

      {:error, :enoent} ->
        read_packed(repo, sha)
    end
  end

  def read!(repo, sha) do
    case read(repo, sha) do
      {:ok, obj} -> obj
      _ -> raise "object #{sha} not found"
    end
  end

  defp loose_path(repo, sha), do: Path.join([repo.git_dir, "objects", String.slice(sha, 0, 2), String.slice(sha, 2..-1//1)])

  # -- parsing -----------------------------------------------------------------------

  @doc "Parse a tree into [{mode, name, sha}]."
  def parse_tree(content), do: parse_tree(content, [])

  defp parse_tree(<<>>, acc), do: Enum.reverse(acc)

  defp parse_tree(data, acc) do
    [mode, rest] = :binary.split(data, " ")
    [name, rest] = :binary.split(rest, <<0>>)
    <<sha::binary-size(20), rest::binary>> = rest
    parse_tree(rest, [{mode, name, Base.encode16(sha, case: :lower)} | acc])
  end

  def encode_tree(entries) do
    entries
    |> Enum.sort_by(fn {mode, name, _} -> if mode == "40000", do: name <> "/", else: name end)
    |> Enum.map(fn {mode, name, sha} -> [mode, " ", name, 0, Base.decode16!(sha, case: :lower)] end)
    |> IO.iodata_to_binary()
  end

  @doc "Parse a commit into a map."
  def parse_commit(content) do
    [headers, message] =
      case :binary.split(content, "\n\n") do
        [h, m] -> [h, m]
        [h] -> [h, ""]
      end

    fields =
      headers
      |> String.split("\n")
      |> Enum.reduce(%{parents: []}, fn line, acc ->
        case String.split(line, " ", parts: 2) do
          ["tree", sha] -> Map.put(acc, :tree, sha)
          ["parent", sha] -> Map.update!(acc, :parents, &(&1 ++ [sha]))
          ["author", who] -> Map.put(acc, :author, who)
          ["committer", who] -> Map.put(acc, :committer, who)
          _ -> acc
        end
      end)

    {name, email, time} = parse_person(fields[:author] || "")
    tz = case Regex.run(~r/ ([+-]\d{4})$/, fields[:author] || "") do [_, z] -> z; _ -> "+0000" end
    Map.merge(fields, %{message: message, subject: message |> String.split("\n") |> hd(), author_name: name, author_email: email, time: time, tz: tz})
  end

  def parse_person(text) do
    case Regex.run(~r/^(.*) <([^>]*)> (\d+) ([+-]\d{4})$/, text) do
      [_, name, email, ts, _tz] -> {name, email, String.to_integer(ts)}
      _ -> {text, "", 0}
    end
  end

  # -- packs ---------------------------------------------------------------------------

  defp read_packed(repo, sha) do
    packs = Path.wildcard(Path.join([repo.git_dir, "objects", "pack", "*.idx"]))

    Enum.find_value(packs, {:error, :not_found}, fn idx_path ->
      case idx_lookup(idx_path, sha) do
        nil -> nil
        offset ->
          pack = File.read!(String.replace_suffix(idx_path, ".idx", ".pack"))
          {type, content} = Lepton.Git.Pack.object_at(pack, offset, fn base -> read!(repo, base) end)
          {:ok, {type, content}}
      end
    end)
  end

  defp idx_lookup(path, sha) do
    data = File.read!(path)
    <<0xFF, "tOc", 2::32, fanout::binary-size(1024), rest::binary>> = data
    target = Base.decode16!(sha, case: :lower)
    <<first, _::binary>> = target
    hi = :binary.part(fanout, first * 4, 4) |> :binary.decode_unsigned()
    lo = if first == 0, do: 0, else: :binary.part(fanout, (first - 1) * 4, 4) |> :binary.decode_unsigned()
    total = :binary.part(fanout, 255 * 4, 4) |> :binary.decode_unsigned()

    case bsearch(rest, target, lo, hi - 1) do
      nil -> nil
      i ->
        offsets_at = total * 20 + total * 4
        <<off::32>> = :binary.part(rest, offsets_at + i * 4, 4)

        if Bitwise.band(off, 0x80000000) != 0 do
          large_at = offsets_at + total * 4 + Bitwise.band(off, 0x7FFFFFFF) * 8
          <<big::64>> = :binary.part(rest, large_at, 8)
          big
        else
          off
        end
    end
  end

  defp bsearch(_names, _target, lo, hi) when lo > hi, do: nil

  defp bsearch(names, target, lo, hi) do
    mid = div(lo + hi, 2)
    name = :binary.part(names, mid * 20, 20)

    cond do
      name == target -> mid
      name < target -> bsearch(names, target, mid + 1, hi)
      true -> bsearch(names, target, lo, mid - 1)
    end
  end
end

defmodule Lepton.Git.Pack do
  @moduledoc """
  Pack file encoding and decoding (version 2), with OFS_DELTA/REF_DELTA
  resolution. Used for clone/fetch (decode) and push (encode).
  """

  import Bitwise

  @types %{1 => :commit, 2 => :tree, 3 => :blob, 4 => :tag, 6 => :ofs_delta, 7 => :ref_delta}
  @codes %{commit: 1, tree: 2, blob: 3, tag: 4}

  @doc """
  Decode every object in a pack. `lookup` resolves REF_DELTA bases that
  are not in the pack. Returns [{sha, type, content}].
  """
  def decode(pack, lookup \\ fn _ -> nil end)

  def decode(<<"PACK", 2::32, count::32, _::binary>> = pack, lookup) do
    {entries, _} =
      Enum.reduce(1..count//1, {[], 12}, fn _, {acc, offset} ->
        {entry, next} = read_entry(pack, offset)
        {[Map.put(entry, :offset, offset) | acc], next}
      end)

    entries = Enum.reverse(entries)
    by_offset = Map.new(entries, &{&1.offset, &1})
    resolve_all(entries, by_offset, lookup)
  end

  def decode(_, _), do: raise("not a version 2 pack")

  defp resolve_all(entries, by_offset, lookup) do
    # Resolve bases first; memoize by offset and by sha.
    {result, _cache} =
      Enum.reduce(entries, {[], %{}}, fn e, {acc, cache} ->
        {{type, content}, cache} = resolve(e, by_offset, cache, lookup)
        sha = Lepton.Git.Object.hash(type, content)
        {[{sha, type, content} | acc], Map.put(cache, {:sha, sha}, {type, content})}
      end)

    Enum.reverse(result)
  end

  defp resolve(%{offset: off} = e, by_offset, cache, lookup) do
    case Map.fetch(cache, off) do
      {:ok, obj} -> {obj, cache}
      :error ->
        {obj, cache} =
          case e.type do
            :ofs_delta ->
              base = Map.fetch!(by_offset, off - e.base_offset)
              {{type, base_content}, cache} = resolve(base, by_offset, cache, lookup)
              {{type, apply_delta(base_content, e.data)}, cache}

            :ref_delta ->
              {type, base_content} =
                case Map.fetch(cache, {:sha, e.base_sha}) do
                  {:ok, obj} -> obj
                  :error ->
                    case Enum.find(Map.values(by_offset), fn c -> c.type not in [:ofs_delta, :ref_delta] and Lepton.Git.Object.hash(c.type, c.data) == e.base_sha end) do
                      nil -> lookup.(e.base_sha) || raise("missing delta base #{e.base_sha}")
                      base -> {base.type, base.data}
                    end
                end

              {{type, apply_delta(base_content, e.data)}, cache}

            type ->
              {{type, e.data}, cache}
          end

        {obj, Map.put(cache, off, obj)}
    end
  end

  @doc "Read the object at `offset` of a pack binary (used with .idx lookups)."
  def object_at(pack, offset, base_lookup) do
    {e, _} = read_entry(pack, offset)

    case e.type do
      :ofs_delta ->
        {type, base} = object_at(pack, offset - e.base_offset, base_lookup)
        {type, apply_delta(base, e.data)}

      :ref_delta ->
        {type, base} = base_lookup.(e.base_sha)
        {type, apply_delta(base, e.data)}

      type ->
        {type, e.data}
    end
  end

  defp read_entry(pack, offset) do
    rest = binary_part(pack, offset, byte_size(pack) - offset)
    {type_code, size, rest, hlen} = entry_header(rest)
    type = Map.fetch!(@types, type_code)

    {extra, rest, elen} =
      case type do
        :ofs_delta ->
          {n, rest, len} = ofs_varint(rest)
          {%{base_offset: n}, rest, len}

        :ref_delta ->
          <<sha::binary-size(20), rest::binary>> = rest
          {%{base_sha: Base.encode16(sha, case: :lower)}, rest, 20}

        _ ->
          {%{}, rest, 0}
      end

    {data, consumed} = inflate_object(rest, size)
    {Map.merge(%{type: type, data: data}, extra), offset + hlen + elen + consumed}
  end

  defp entry_header(<<byte, rest::binary>>) do
    type = byte >>> 4 &&& 7
    size = byte &&& 15
    if (byte &&& 0x80) == 0, do: {type, size, rest, 1}, else: size_cont(rest, type, size, 4, 1)
  end

  defp size_cont(<<byte, rest::binary>>, type, size, shift, len) do
    size = size ||| (byte &&& 0x7F) <<< shift
    if (byte &&& 0x80) == 0, do: {type, size, rest, len + 1}, else: size_cont(rest, type, size, shift + 7, len + 1)
  end

  defp ofs_varint(<<byte, rest::binary>>), do: ofs_varint(rest, byte &&& 0x7F, byte, 1)

  defp ofs_varint(rest, n, prev, len) when (prev &&& 0x80) == 0, do: {n, rest, len}

  defp ofs_varint(<<byte, rest::binary>>, n, _prev, len) do
    ofs_varint(rest, ((n + 1) <<< 7) ||| (byte &&& 0x7F), byte, len + 1)
  end

  # zlib does not report how much input it consumed, but a zlib stream ends
  # with the Adler-32 of its output: find that trailer and verify the slice.
  defp inflate_object(data, size) do
    z = :zlib.open()
    :ok = :zlib.inflateInit(z)
    out = inflate_until_done(z, data)
    :zlib.close(z)
    out = IO.iodata_to_binary(out)
    if byte_size(out) != size, do: raise("pack object size mismatch")
    checksum = <<:erlang.adler32(out)::32>>
    {out, find_end(data, checksum, out, 2)}
  end

  defp inflate_until_done(z, data) do
    case :zlib.safeInflate(z, data) do
      {:continue, out} -> [out | inflate_until_done(z, [])]
      {:finished, out} -> out
    end
  end

  defp find_end(data, checksum, out, from) do
    case :binary.match(data, checksum, scope: {from, byte_size(data) - from}) do
      {pos, 4} ->
        len = pos + 4
        if (try do :zlib.uncompress(binary_part(data, 0, len)) == out rescue _ -> false end),
          do: len,
          else: find_end(data, checksum, out, pos + 1)

      :nomatch ->
        raise "could not find end of zlib stream in pack"
    end
  end

  def apply_delta(base, delta) do
    {_src_size, rest} = varint(delta)
    {_dst_size, rest} = varint(rest)
    apply_ops(base, rest, [])
  end

  defp apply_ops(_base, <<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp apply_ops(base, <<op, rest::binary>>, acc) when (op &&& 0x80) != 0 do
    {offset, rest} = gather(op, rest, [{0x01, 0}, {0x02, 8}, {0x04, 16}, {0x08, 24}])
    {size, rest} = gather(op, rest, [{0x10, 0}, {0x20, 8}, {0x40, 16}])
    size = if size == 0, do: 0x10000, else: size
    apply_ops(base, rest, [binary_part(base, offset, size) | acc])
  end

  defp apply_ops(base, <<n, rest::binary>>, acc) when n > 0 do
    <<data::binary-size(^n), rest::binary>> = rest
    apply_ops(base, rest, [data | acc])
  end

  defp gather(op, rest, bits) do
    Enum.reduce(bits, {0, rest}, fn {mask, shift}, {v, rest} ->
      if (op &&& mask) != 0 do
        <<b, rest::binary>> = rest
        {v ||| b <<< shift, rest}
      else
        {v, rest}
      end
    end)
  end

  defp varint(bin), do: varint(bin, 0, 0)

  defp varint(<<byte, rest::binary>>, n, shift) do
    n = n ||| (byte &&& 0x7F) <<< shift
    if (byte &&& 0x80) == 0, do: {n, rest}, else: varint(rest, n, shift + 7)
  end

  @doc "Encode objects [{type, content}] as a pack (no deltas)."
  def encode(objects) do
    body =
      Enum.map(objects, fn {type, content} ->
        [header(@codes[type], byte_size(content)), :zlib.compress(content)]
      end)

    data = IO.iodata_to_binary([<<"PACK", 2::32, length(objects)::32>> | body])
    data <> :crypto.hash(:sha, data)
  end

  defp header(type, size) do
    first = type <<< 4 ||| (size &&& 15)
    rest = size >>> 4
    if rest == 0, do: <<first>>, else: <<first ||| 0x80>> <> size_bytes(rest)
  end

  defp size_bytes(n) when n < 0x80, do: <<n>>
  defp size_bytes(n), do: <<(n &&& 0x7F) ||| 0x80>> <> size_bytes(n >>> 7)
end

defmodule Lepton.Git.Index do
  @moduledoc """
  The git index (`.git/index`, DIRC version 2): the staging area.
  Entries are maps with `:path`, `:sha`, `:mode`, `:size`, `:mtime`.
  Extensions (cache-tree etc.) are skipped on read and not written, which
  git accepts.
  """

  import Bitwise

  def path(repo), do: Path.join(repo.git_dir, "index")

  def read(repo) do
    case File.read(path(repo)) do
      {:ok, <<"DIRC", version::32, count::32, rest::binary>>} when version in [2, 3] ->
        {entries, _} = Enum.reduce(1..count//1, {[], rest}, fn _, {acc, data} -> {e, data} = entry(data); {[e | acc], data} end)
        entries |> Enum.reverse() |> Map.new(&{&1.path, &1})

      _ ->
        %{}
    end
  end

  defp entry(data) do
    <<ctime_s::32, ctime_ns::32, mtime_s::32, mtime_ns::32, dev::32, ino::32, mode::32, uid::32, gid::32, size::32,
      sha::binary-size(20), flags::16, rest::binary>> = data

    extended = (flags &&& 0x4000) != 0
    {rest, extra} = if extended, do: {binary_part(rest, 2, byte_size(rest) - 2), 2}, else: {rest, 0}
    [name, _] = :binary.split(rest, <<0>>)
    entry_len = 62 + extra + byte_size(name)
    padded = div(entry_len + 8, 8) * 8
    skip = padded - 62 - extra
    rest = binary_part(rest, skip, byte_size(rest) - skip)

    {%{path: name, sha: Base.encode16(sha, case: :lower), mode: mode, size: size, mtime: {mtime_s, mtime_ns}, ctime: {ctime_s, ctime_ns}, dev: dev, ino: ino, uid: uid, gid: gid}, rest}
  end

  def write(repo, entries) do
    sorted = entries |> Map.values() |> Enum.sort_by(& &1.path)

    body =
      Enum.map(sorted, fn e ->
        {ms, mns} = e[:mtime] || {0, 0}
        {cs, cns} = e[:ctime] || {ms, mns}
        name = e.path
        flags = min(byte_size(name), 0xFFF)
        fixed = <<cs::32, cns::32, ms::32, mns::32, (e[:dev] || 0)::32, (e[:ino] || 0)::32, e.mode::32, 0::32, 0::32, e.size::32, Base.decode16!(e.sha, case: :lower)::binary, flags::16>>
        len = 62 + byte_size(name)
        pad = div(len + 8, 8) * 8 - len
        [fixed, name, :binary.copy(<<0>>, pad)]
      end)

    data = IO.iodata_to_binary([<<"DIRC", 2::32, length(sorted)::32>> | body])
    File.write!(path(repo), data <> :crypto.hash(:sha, data))
  end

  @doc "The index entry of a submodule (a gitlink): its commit, mode 160000, nothing on disk to stat."
  def gitlink_entry(rel, sha), do: %{path: rel, sha: sha, mode: 0o160000, size: 0, mtime: {0, 0}, ctime: {0, 0}, ino: 0, dev: 0}

  @doc "Build an index entry for a worktree file whose blob is `sha`."
  def entry_for(full_path, rel, sha) do
    {:ok, st} = File.stat(full_path, time: :posix)
    mode = if (st.mode &&& 0o111) != 0, do: 0o100755, else: 0o100644
    %{path: rel, sha: sha, mode: mode, size: st.size, mtime: {st.mtime, 0}, ctime: {st.ctime, 0}, ino: st.inode, dev: 0}
  end
end
