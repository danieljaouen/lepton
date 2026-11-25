defmodule Lepton.Torrent.Storage do
  @moduledoc """
  A torrent's files on disk: pieces are byte ranges of the files laid end
  to end, so one piece may span several files. Files are made as the
  owner of the folder they're in (a download into your home is yours),
  and grow as pieces arrive. `check/2` reads what's there (a download
  resumed, or files to seed) and says which pieces are already right.
  """

  alias Lepton.Torrent.Metainfo

  @doc "Write piece `i` (checked already)."
  def write_piece(%Metainfo{} = m, dir, i, data) do
    each_span(m, dir, i * m.piece_length, byte_size(data), fn path, offset, at, len ->
      chunk = binary_part(data, at, len)

      Lepton.Users.own_new_in_home(path, fn ->
        File.mkdir_p!(Path.dirname(path))
        {:ok, f} = :file.open(String.to_charlist(path), [:raw, :binary, :read, :write])
        :ok = :file.pwrite(f, offset, chunk)
        :file.close(f)
      end)
    end)

    :ok
  end

  @doc "`len` bytes of piece `i` from `begin` (for a peer's request): `{:ok, data}` or `:error`."
  def read(%Metainfo{} = m, dir, i, begin, len) do
    parts =
      each_span(m, dir, i * m.piece_length + begin, len, fn path, offset, _at, n ->
        with {:ok, f} <- :file.open(String.to_charlist(path), [:raw, :binary, :read]) do
          result = :file.pread(f, offset, n)
          :file.close(f)
          result
        end
      end)

    if Enum.all?(parts, &match?({:ok, d} when is_binary(d), &1)) do
      data = parts |> Enum.map(&elem(&1, 1)) |> IO.iodata_to_binary()
      if byte_size(data) == len, do: {:ok, data}, else: :error
    else
      :error
    end
  end

  @doc "Which pieces are on disk and right (their SHA-1 matches): a MapSet of indexes."
  def check(%Metainfo{} = m, dir, progress \\ fn _ -> :ok end) do
    if Enum.any?(Metainfo.paths(m, dir), &File.exists?/1) do
      n = Metainfo.piece_count(m)

      Enum.reduce(0..(n - 1)//1, MapSet.new(), fn i, have ->
        if rem(i, 64) == 0, do: progress.(i / max(n, 1))

        case read(m, dir, i, 0, Metainfo.piece_size(m, i)) do
          {:ok, data} -> if :crypto.hash(:sha, data) == elem(m.pieces, i), do: MapSet.put(have, i), else: have
          :error -> have
        end
      end)
    else
      MapSet.new()
    end
  end

  # Call fun.(path, offset_in_file, offset_in_data, length) for each file
  # the byte range [start, start + len) falls in.
  defp each_span(m, dir, start, len, fun) do
    stop = start + len
    paths = Metainfo.paths(m, dir)

    for {f, path} <- Enum.zip(m.files, paths), f.offset < stop, f.offset + f.length > start, f.length > 0 do
      from = max(start, f.offset)
      to = min(stop, f.offset + f.length)
      fun.(path, from - f.offset, from - start, to - from)
    end
  end
end
