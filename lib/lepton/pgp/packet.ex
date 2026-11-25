defmodule Lepton.PGP.Packet do
  @moduledoc """
  OpenPGP's framing (RFC 9580, RFC 4880): packets (old and new headers,
  partial lengths), ASCII armor (with its CRC-24), and multiprecision
  integers (MPIs).
  """

  import Bitwise

  # -- packets ------------------------------------------------------------------------------------------

  @doc "The packets in `bin`: `{:ok, [{tag, body}]}` or `{:error, why}`."
  def parse(bin), do: parse(bin, [])

  defp parse(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp parse(<<1::1, 1::1, tag::6, rest::binary>>, acc) do
    case new_body(rest, []) do
      {:ok, body, rest} -> parse(rest, [{tag, body} | acc])
      err -> err
    end
  end

  defp parse(<<1::1, 0::1, tag::4, ltype::2, rest::binary>>, acc) do
    case {ltype, rest} do
      {0, <<len, body::binary-size(len), r::binary>>} -> parse(r, [{tag, body} | acc])
      {1, <<len::16, body::binary-size(len), r::binary>>} -> parse(r, [{tag, body} | acc])
      {2, <<len::32, body::binary-size(len), r::binary>>} -> parse(r, [{tag, body} | acc])
      # (indeterminate: to the end)
      {3, body} -> parse(<<>>, [{tag, body} | acc])
      _ -> {:error, "a truncated packet"}
    end
  end

  defp parse(_, _), do: {:error, "not OpenPGP data"}

  # New-format lengths: one, two or five octets, or partial (a power of two, more to come).
  defp new_body(<<l, rest::binary>>, acc) when l < 192, do: take(rest, l, acc)
  defp new_body(<<l1, l2, rest::binary>>, acc) when l1 in 192..223, do: take(rest, ((l1 - 192) <<< 8) + l2 + 192, acc)
  defp new_body(<<255, l::32, rest::binary>>, acc), do: take(rest, l, acc)

  defp new_body(<<l, rest::binary>>, acc) when l in 224..254 do
    n = 1 <<< (l &&& 0x1F)

    case rest do
      <<part::binary-size(^n), more::binary>> -> new_body(more, [part | acc])
      _ -> {:error, "a truncated packet"}
    end
  end

  defp new_body(_, _), do: {:error, "a truncated packet"}

  defp take(bin, n, acc) do
    case bin do
      <<last::binary-size(^n), rest::binary>> -> {:ok, IO.iodata_to_binary(Enum.reverse([last | acc])), rest}
      _ -> {:error, "a truncated packet"}
    end
  end

  @doc "A packet with a new-format header."
  def encode(tag, body) do
    body = IO.iodata_to_binary(body)
    <<0xC0 ||| tag>> <> len(byte_size(body)) <> body
  end

  @doc "New-format length octets."
  def len(n) when n < 192, do: <<n>>
  def len(n) when n < 8384, do: <<(((n - 192) >>> 8) + 192), (n - 192) &&& 0xFF>>
  def len(n), do: <<255, n::32>>

  # -- MPIs ---------------------------------------------------------------------------------------------

  @doc "An MPI: its bit count (2 octets), then the number, big-endian, without leading zeros."
  def mpi(n) when is_integer(n), do: mpi(:binary.encode_unsigned(n))

  def mpi(bin) when is_binary(bin) do
    bin = strip(bin)
    bits = if bin == <<>>, do: 0, else: (byte_size(bin) - 1) * 8 + bit_len(:binary.first(bin))
    <<bits::16>> <> bin
  end

  defp strip(<<0, rest::binary>>), do: strip(rest)
  defp strip(bin), do: bin

  defp bit_len(0), do: 0
  defp bit_len(b), do: 1 + bit_len(b >>> 1)

  @doc "Read an MPI: `{bytes, rest}`."
  def read_mpi(<<bits::16, rest::binary>>) do
    n = div(bits + 7, 8)
    <<v::binary-size(^n), r::binary>> = rest
    {v, r}
  end

  @doc "Read `count` MPIs: `{[bytes], rest}`."
  def read_mpis(bin, count), do: Enum.map_reduce(1..count//1, bin, fn _, b -> read_mpi(b) end)

  # -- armor --------------------------------------------------------------------------------------------

  @doc "ASCII armor: `-----BEGIN PGP <type>-----`, the base64, its CRC-24, the end line."
  def armor(type, bin, headers \\ []) do
    b64 = bin |> Base.encode64() |> chunk(64)
    head = Enum.map_join(headers, "", fn {k, v} -> "#{k}: #{v}\n" end)
    "-----BEGIN PGP #{type}-----\n#{head}\n#{b64}=#{Base.encode64(<<crc24(bin)::24>>)}\n-----END PGP #{type}-----\n"
  end

  defp chunk(s, n) when byte_size(s) <= n, do: s <> "\n"
  defp chunk(<<line::binary-size(64), rest::binary>>, n), do: line <> "\n" <> chunk(rest, n)

  @doc "Is `data` armored (`-----BEGIN PGP`)?"
  def armored?(data), do: String.contains?(binary_part(data, 0, min(byte_size(data), 1024)), "-----BEGIN PGP ")

  @doc """
  Every armored block in `text`: `[{type, bytes}]` (a clearsigned
  message's signature block among them). A bad checksum is an error.
  """
  def dearmor(text) do
    blocks = Regex.scan(~r/-----BEGIN PGP ([A-Z ,0-9\/]+)-----\r?\n(.*?)-----END PGP \1-----/s, text, capture: :all_but_first)

    Enum.reduce_while(blocks, {:ok, []}, fn [type, body], {:ok, acc} ->
      case dearmor_body(body) do
        {:ok, bin} -> {:cont, {:ok, acc ++ [{type, bin}]}}
        err -> {:halt, err}
      end
    end)
    |> then(fn
      {:ok, []} -> {:error, "no armored OpenPGP data"}
      other -> other
    end)
  end

  defp dearmor_body(body) do
    lines = String.split(body, ~r/\r?\n/)
    # Headers (Version: ...) end at the first blank line, if there are any.
    lines = if Enum.any?(lines, &(&1 =~ ~r/^[A-Za-z-]+: /)), do: lines |> Enum.drop_while(&(String.trim(&1) != "")), else: lines
    {crc, data} = Enum.split_with(lines, &String.starts_with?(&1, "="))
    b64 = data |> Enum.map(&String.trim/1) |> Enum.join()

    with {:ok, bin} <- Base.decode64(b64, ignore: :whitespace) do
      case crc do
        ["=" <> c | _] ->
          case Base.decode64(String.trim(c)) do
            {:ok, <<v::24>>} -> if v == crc24(bin), do: {:ok, bin}, else: {:error, "the armor's checksum is wrong (damaged data?)"}
            _ -> {:ok, bin}
          end

        _ ->
          {:ok, bin}
      end
    else
      :error -> {:error, "bad base64 in the armor"}
    end
  end

  @doc "OpenPGP's CRC-24."
  def crc24(bin) do
    Enum.reduce(:binary.bin_to_list(bin), 0xB704CE, fn byte, crc ->
      crc = bxor(crc, byte <<< 16)

      Enum.reduce(1..8, crc, fn _, c ->
        c = c <<< 1
        if (c &&& 0x1000000) != 0, do: bxor(c, 0x1864CFB), else: c
      end)
    end) &&& 0xFFFFFF
  end

  @doc "Bytes as packets: armored or binary, whichever `data` is (the first block if armored)."
  def unarmor(data) do
    if armored?(data) do
      case dearmor(data) do
        {:ok, blocks} -> {:ok, blocks |> Enum.map(&elem(&1, 1)) |> IO.iodata_to_binary()}
        err -> err
      end
    else
      {:ok, data}
    end
  end
end
