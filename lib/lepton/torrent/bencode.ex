defmodule Lepton.Torrent.Bencode do
  @moduledoc """
  Bencoding, BitTorrent's format: integers (`i42e`), byte strings
  (`4:spam`), lists (`l...e`) and dictionaries (`d...e`, keys sorted).
  Strings stay binaries (piece hashes aren't text).
  """

  @doc "Decode one value: `{:ok, value}` or `{:error, reason}` (trailing bytes are an error)."
  def decode(bin) do
    case value(bin) do
      {:ok, v, ""} -> {:ok, v}
      {:ok, _, _} -> {:error, "trailing data"}
      err -> err
    end
  end

  @doc "Decode one value from the start of `bin`: `{:ok, value, rest}`."
  def decode_prefix(bin), do: value(bin)

  @doc """
  The bytes `key`'s value takes in a top-level dictionary, exactly as
  they are (the info hash is the SHA-1 of the `info` dictionary's).
  """
  def raw(bin, key) do
    with <<?d, rest::binary>> <- bin do
      find_raw(rest, key)
    else
      _ -> nil
    end
  end

  defp find_raw(<<?e, _::binary>>, _key), do: nil

  defp find_raw(bin, key) do
    with {:ok, k, rest} <- string(bin),
         {:ok, _v, after_v} <- value(rest) do
      if k == key, do: binary_part(rest, 0, byte_size(rest) - byte_size(after_v)), else: find_raw(after_v, key)
    else
      _ -> nil
    end
  end

  defp value(<<?i, rest::binary>>) do
    case :binary.match(rest, "e") do
      {at, 1} ->
        digits = binary_part(rest, 0, at)

        case Integer.parse(digits) do
          {n, ""} -> {:ok, n, binary_part(rest, at + 1, byte_size(rest) - at - 1)}
          _ -> {:error, "bad integer"}
        end

      :nomatch ->
        {:error, "unterminated integer"}
    end
  end

  defp value(<<?l, rest::binary>>), do: list(rest, [])
  defp value(<<?d, rest::binary>>), do: dict(rest, %{})
  defp value(<<c, _::binary>> = bin) when c in ?0..?9, do: string(bin)
  defp value(<<>>), do: {:error, "unexpected end"}
  defp value(_), do: {:error, "not bencoded"}

  defp string(bin) do
    case :binary.match(bin, ":") do
      {at, 1} when at <= 12 ->
        with {len, ""} <- Integer.parse(binary_part(bin, 0, at)),
             true <- byte_size(bin) - at - 1 >= len do
          <<_::binary-size(^at), ?:, s::binary-size(^len), rest::binary>> = bin
          {:ok, s, rest}
        else
          _ -> {:error, "bad string"}
        end

      _ ->
        {:error, "bad string"}
    end
  end

  defp list(<<?e, rest::binary>>, acc), do: {:ok, Enum.reverse(acc), rest}

  defp list(bin, acc) do
    case value(bin) do
      {:ok, v, rest} -> list(rest, [v | acc])
      err -> err
    end
  end

  defp dict(<<?e, rest::binary>>, acc), do: {:ok, acc, rest}

  defp dict(bin, acc) do
    with {:ok, k, rest} <- string(bin),
         {:ok, v, rest} <- value(rest) do
      dict(rest, Map.put(acc, k, v))
    else
      {:error, _} = err -> err
    end
  end

  @doc "Encode a value (maps' keys sorted, as the format wants; atoms as strings)."
  def encode(v), do: IO.iodata_to_binary(enc(v))

  defp enc(n) when is_integer(n), do: ["i", Integer.to_string(n), "e"]
  defp enc(s) when is_binary(s), do: [Integer.to_string(byte_size(s)), ":", s]
  defp enc(a) when is_atom(a), do: enc(Atom.to_string(a))
  defp enc(l) when is_list(l), do: ["l", Enum.map(l, &enc/1), "e"]

  defp enc(m) when is_map(m) do
    pairs = m |> Enum.map(fn {k, v} -> {to_string(k), v} end) |> Enum.sort_by(&elem(&1, 0))
    ["d", Enum.map(pairs, fn {k, v} -> [enc(k), enc(v)] end), "e"]
  end
end
