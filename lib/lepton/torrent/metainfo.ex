defmodule Lepton.Torrent.Metainfo do
  @moduledoc """
  What a torrent describes (a `.torrent` file's `info` dictionary): its
  name, the files and their sizes, the piece size and each piece's SHA-1,
  and the trackers to ask for peers. `create/2` makes one from a file or
  a folder.
  """

  alias Lepton.Torrent.Bencode

  defstruct [:info_hash, :info, :name, :piece_length, :pieces, :files, :length, trackers: [], private: false]

  @doc "Read a `.torrent` file's contents."
  def parse(bin) do
    with {:ok, %{"info" => _} = top} <- Bencode.decode(bin),
         info when is_binary(info) <- Bencode.raw(bin, "info") || {:error, "no info dictionary"} do
      trackers =
        case top do
          %{"announce-list" => tiers} when is_list(tiers) -> tiers |> List.flatten() |> Enum.filter(&is_binary/1)
          _ -> []
        end

      trackers = Enum.uniq(trackers ++ List.wrap(top["announce"] |> then(&if(is_binary(&1), do: &1))))
      from_info(info, trackers)
    else
      {:ok, _} -> {:error, "not a torrent (no info dictionary)"}
      {:error, why} -> {:error, "not a torrent (#{why})"}
    end
  end

  @doc "From the `info` dictionary's bytes (a magnet link's, once peers have sent them)."
  def from_info(info, trackers \\ []) do
    with {:ok, %{"name" => name, "piece length" => plen, "pieces" => pieces} = d} when is_binary(name) and is_integer(plen) and plen > 0 and is_binary(pieces) <- Bencode.decode(info),
         true <- rem(byte_size(pieces), 20) == 0 || {:error, "bad piece hashes"},
         {:ok, files} <- files(d) do
      length = files |> Enum.map(&elem(&1, 1)) |> Enum.sum()
      hashes = for <<h::binary-20 <- pieces>>, do: h

      if length(hashes) != max(div(length + plen - 1, plen), 1) and length > 0 do
        {:error, "the piece hashes don't match the size"}
      else
        {:ok,
         %__MODULE__{
           info_hash: :crypto.hash(:sha, info),
           info: info,
           name: safe(name),
           piece_length: plen,
           pieces: List.to_tuple(hashes),
           files: offsets(files),
           length: length,
           trackers: trackers,
           private: d["private"] == 1
         }}
      end
    else
      {:error, _} = e -> e
      _ -> {:error, "not a torrent's info"}
    end
  end

  # [{path parts, length}]: one file (named as the torrent), or several in a folder.
  defp files(%{"length" => n}) when is_integer(n), do: {:ok, [{[], n}]}

  defp files(%{"files" => list}) when is_list(list) do
    files =
      for %{"length" => n, "path" => parts} <- list, is_integer(n), is_list(parts) do
        {Enum.map(parts, &safe/1), n}
      end

    if files == [] or length(files) != length(list), do: {:error, "bad file list"}, else: {:ok, files}
  end

  defp files(_), do: {:error, "no files"}

  # A name in a path: nothing that climbs out of the download folder.
  defp safe(name) do
    name = name |> to_string() |> String.replace(["/", "\\", <<0>>], "_")
    if name in ["", ".", ".."], do: "_", else: name
  end

  defp offsets(files) do
    {list, _} = Enum.map_reduce(files, 0, fn {parts, n}, at -> {%{path: parts, length: n, offset: at}, at + n} end)
    list
  end

  def piece_count(%__MODULE__{pieces: p}), do: tuple_size(p)

  @doc "Piece `i`'s size (the last one is shorter)."
  def piece_size(%__MODULE__{} = m, i) do
    if i == piece_count(m) - 1, do: m.length - i * m.piece_length, else: m.piece_length
  end

  @doc "The files' paths under `dir` (a single file: `dir/name`; several: `dir/name/...`)."
  def paths(%__MODULE__{files: [%{path: []}]} = m, dir), do: [Path.join(dir, m.name)]
  def paths(%__MODULE__{} = m, dir), do: for(f <- m.files, do: Path.join([dir, m.name | f.path]))

  # -- making one --------------------------------------------------------------------------------

  @doc """
  A `.torrent` (its bytes) for the file or folder at `path`. Options:
  `:trackers` (announce addresses), `:piece_length` (else chosen from
  the size: about 1,000 to 2,000 pieces), `:private`, `:comment`.
  """
  def create(path, opts \\ []) do
    path = Path.expand(path)

    files =
      cond do
        File.regular?(path) -> [{[], path}]
        File.dir?(path) -> for f <- Path.wildcard(Path.join(path, "**/*"), match_dot: false), File.regular?(f), do: {Path.split(Path.relative_to(f, path)), f}
        true -> []
      end
      |> Enum.sort()

    if files == [] do
      {:error, "#{path}: nothing to share"}
    else
      total = files |> Enum.map(fn {_, f} -> File.stat!(f).size end) |> Enum.sum()
      plen = opts[:piece_length] || piece_length_for(total)
      pieces = hash_pieces(Enum.map(files, &elem(&1, 1)), plen)

      info =
        %{"name" => Path.basename(path), "piece length" => plen, "pieces" => pieces}
        |> Map.merge(if match?([{[], _}], files), do: %{"length" => total}, else: %{"files" => for({parts, f} <- files, do: %{"length" => File.stat!(f).size, "path" => parts})})
        |> Map.merge(if opts[:private], do: %{"private" => 1}, else: %{})

      trackers = opts[:trackers] || []

      top =
        %{"info" => info, "created by" => "Lepton", "creation date" => System.os_time(:second)}
        |> Map.merge(case trackers do
          [] -> %{}
          [one] -> %{"announce" => one}
          [first | _] -> %{"announce" => first, "announce-list" => Enum.map(trackers, &[&1])}
        end)
        |> Map.merge(if opts[:comment], do: %{"comment" => opts[:comment]}, else: %{})

      {:ok, Bencode.encode(top)}
    end
  end

  @doc false
  def piece_length_for(total) do
    target = div(total, 1500)
    Enum.find([16_384, 32_768, 65_536, 131_072, 262_144, 524_288, 1_048_576, 2_097_152, 4_194_304, 8_388_608], 16_777_216, &(&1 >= target))
  end

  # The files read as one stream, cut into pieces, each hashed.
  defp hash_pieces(paths, plen) do
    {hashes, rest} =
      Enum.reduce(paths, {[], <<>>}, fn p, acc ->
        File.stream!(p, plen) |> Enum.reduce(acc, fn chunk, {hs, buf} -> cut(buf <> chunk, plen, hs) end)
      end)

    hashes = if rest != <<>>, do: [:crypto.hash(:sha, rest) | hashes], else: hashes
    hashes |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp cut(buf, plen, hs) when byte_size(buf) >= plen do
    <<piece::binary-size(^plen), rest::binary>> = buf
    cut(rest, plen, [:crypto.hash(:sha, piece) | hs])
  end

  defp cut(buf, _plen, hs), do: {hs, buf}
end
