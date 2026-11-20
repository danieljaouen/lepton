defmodule Lepton.Rsync.Delta do
  @moduledoc """
  rsync's delta algorithm (protocol 27).

  The receiver splits its copy of a file into blocks and sends each
  block's checksums: a fast rolling one (Adler-32-like, over *signed*
  bytes, as rsync computes it) and a strong one (MD4 of the block then
  the session seed). The sender slides a window over its file and, where
  a block matches, sends a reference instead of the data. Tokens on the
  wire: a positive int is that many literal bytes following, `-(i + 1)`
  is block i, 0 ends the file; then the MD4 of the seed and the whole
  new file.
  """

  import Bitwise

  @block 700
  @chunk 32 * 1024

  # -- checksums ------------------------------------------------------------------------

  @doc "The rolling checksum of `data` as `{a, b}` (rsync's s1, s2)."
  def rolling(data), do: rolling(data, 0, 0)

  defp rolling(<<c::signed-8, rest::binary>>, a, b) do
    a = a + c
    rolling(rest, a, b + a)
  end

  defp rolling(<<>>, a, b), do: {a, b}

  def sum32({a, b}), do: (a &&& 0xFFFF) ||| ((b &&& 0xFFFF) <<< 16)

  @doc "A block's strong checksum: MD4 of the block then the seed."
  def strong(block, seed), do: md4([block, <<seed::little-signed-32>>])

  @doc "The whole-file checksum: MD4 of the seed then the data (`-c`: no seed)."
  def file_sum(data, nil), do: md4(data)
  def file_sum(data, seed), do: md4([<<seed::little-signed-32>>, data])

  @doc "MD4, from OpenSSL when it has it, else in Elixir."
  def md4(data) do
    if crypto_md4?(), do: :crypto.hash(:md4, data), else: Lepton.Rsync.MD4.hash(IO.iodata_to_binary(data))
  end

  defp crypto_md4? do
    case :persistent_term.get({__MODULE__, :md4}, nil) do
      nil ->
        ok = try do
          _ = :crypto.hash(:md4, "")
          true
        rescue
          _ -> false
        end

        :persistent_term.put({__MODULE__, :md4}, ok)
        ok

      ok ->
        ok
    end
  end

  # -- the receiver: block checksums -------------------------------------------------------

  @doc "Block length for a file of `len` bytes (rsync's: 700, growing with the square root)."
  def block_length(len) when len <= @block * @block, do: @block

  def block_length(len) do
    l = :math.sqrt(len) |> trunc()
    min(div(l, 8) * 8, 1 <<< 17)
  end

  @doc """
  The checksum header and block sums of `basis` (the receiver's copy):
  `{count, blength, s2length, remainder, sums}` with sums as
  `[{rolling, strong}]`.
  """
  def signature(basis, seed) do
    len = byte_size(basis)
    blength = block_length(len)
    count = div(len + blength - 1, blength)
    rem = rem(len, blength)

    sums =
      for i <- 0..(count - 1)//1 do
        block = binary_part(basis, i * blength, min(blength, len - i * blength))
        {sum32(rolling(block)), strong(block, seed)}
      end

    {count, blength, 16, rem, sums}
  end

  def encode_signature({count, blength, s2, rem, sums}) do
    alias Lepton.Rsync.Wire
    [Wire.int(count), Wire.int(blength), Wire.int(s2), Wire.int(rem) | for({r, s} <- sums, do: [Wire.int(r), binary_part(s, 0, s2)])]
  end

  # -- the sender: matching ---------------------------------------------------------------------

  @doc """
  The tokens turning the receiver's file (described by its block sums)
  into `data`: `[{:literal, binary} | {:block, index}]`.
  """
  def tokens(data, {0, _, _, _, _}, _seed), do: literal(data)

  def tokens(data, {count, blength, s2, rem, sums}, seed) do
    table =
      sums
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {{r, s}, i}, t -> Map.update(t, r, [{i, s}], &(&1 ++ [{i, s}])) end)

    size = fn i -> if i == count - 1 and rem != 0, do: rem, else: blength end
    scan(data, byte_size(data), 0, 0, nil, table, size, s2, seed, blength, [])
  end

  # pos: window start; lit: start of unsent literal data; ab: rolling sum of
  # the window [pos, pos + blength) or nil to recompute.
  defp scan(data, len, pos, lit, ab, table, size, s2, seed, blength, acc) do
    win = min(blength, len - pos)

    if win <= 0 do
      Enum.reverse(acc) ++ literal(binary_part(data, lit, len - lit))
    else
      ab = ab || rolling(binary_part(data, pos, win))

      case match(table, sum32(ab), data, pos, win, size, s2, seed) do
        {:ok, i, n} ->
          acc = [{:block, i} | Enum.reverse(literal(binary_part(data, lit, pos - lit)), acc)]
          scan(data, len, pos + n, pos + n, nil, table, size, s2, seed, blength, acc)

        :none ->
          # Slide the window by one byte.
          <<out::signed-8>> = binary_part(data, pos, 1)
          {a, b} = ab

          ab =
            if pos + win < len do
              <<in_::signed-8>> = binary_part(data, pos + win, 1)
              a = a - out + in_
              {a, b - win * out + a}
            else
              # Near the end the window shrinks: recompute.
              nil
            end

          scan(data, len, pos + 1, lit, ab, table, size, s2, seed, blength, acc)
      end
    end
  end

  defp match(table, r, data, pos, win, size, s2, seed) do
    case Map.get(table, r) do
      nil ->
        :none

      candidates ->
        Enum.find_value(candidates, :none, fn {i, s} ->
          n = size.(i)

          if n == win or (n < win and pos + n <= byte_size(data)) do
            block = binary_part(data, pos, n)
            if n == win and binary_part(strong(block, seed), 0, s2) == s, do: {:ok, i, n}
          end
        end)
    end
  end

  defp literal(""), do: []
  defp literal(data) when byte_size(data) <= @chunk, do: [{:literal, data}]
  defp literal(<<chunk::binary-size(@chunk), rest::binary>>), do: [{:literal, chunk} | literal(rest)]

  def encode_tokens(tokens) do
    alias Lepton.Rsync.Wire

    for t <- tokens do
      case t do
        {:literal, d} -> [Wire.int(byte_size(d)), d]
        {:block, i} -> Wire.int(-(i + 1))
      end
    end ++ [Wire.int(0)]
  end

  # -- compressed tokens (-z) ---------------------------------------------------------------
  #
  # rsync's -z wraps the token stream: literal data is raw deflate, flushed
  # (Z_SYNC_FLUSH, its trailing 00 00 ff ff left off) at each token, in
  # chunks headed 0x40 + 14-bit length; a token is 0x80 + its distance from
  # the end of the previous run (or 0x20 + a 32-bit number), a run of
  # consecutive tokens 0xc0/0x21 + a 16-bit count; 0 ends the file.

  @deflated 0x40
  @token_rel 0x80
  @max_data 16383

  @doc """
  A file sent whole, compressed (Lepton's sender never matches blocks
  under -z: that would take rsync's patched zlib).
  """
  def encode_compressed(data) do
    if data == "" do
      [<<0>>]
    else
      z = :zlib.open()
      :ok = :zlib.deflateInit(z, :default, :deflated, -15, 8, :default)
      out = z |> :zlib.deflate(data, :sync) |> IO.iodata_to_binary()
      :zlib.close(z)
      out = binary_part(out, 0, byte_size(out) - 4)
      [chunks(out), <<0>>]
    end
  end

  defp chunks(<<c::binary-size(@max_data), rest::binary>>), do: [header(c), c | chunks(rest)]
  defp chunks(""), do: []
  defp chunks(c), do: [header(c), c]

  defp header(c), do: <<@deflated + (byte_size(c) >>> 8), byte_size(c) &&& 0xFF>>

  @doc """
  Read one file's compressed tokens with `read` (`fn n -> binary end`),
  rebuilding it from `block` (`fn i -> binary end`, the receiver's copy).
  Returns the new file's contents as iodata.
  """
  def decode_compressed(read, block, protocol) do
    z = :zlib.open()
    :ok = :zlib.inflateInit(z, -15)

    try do
      decode(read, block, protocol, z, %{token: 0, pending: [], acc: []})
    after
      :zlib.close(z)
    end
  end

  defp decode(read, block, protocol, z, st) do
    <<flag>> = read.(1)

    if (flag &&& 0xC0) == @deflated do
      <<lo>> = read.(1)
      n = ((flag &&& 0x3F) <<< 8) + lo
      decode(read, block, protocol, z, %{st | pending: [st.pending, read.(n)]})
    else
      st = flush_data(z, st)

      cond do
        flag == 0 ->
          Enum.reverse(st.acc)

        true ->
          {token, flag} =
            if (flag &&& @token_rel) != 0,
              do: {st.token + (flag &&& 0x3F), flag >>> 6},
              else: (<<t::little-signed-32>> = read.(4); {t, flag})

          run = if (flag &&& 1) != 0, do: (<<r::little-16>> = read.(2); r), else: 0
          tokens = token..(token + run)
          acc = Enum.reduce(tokens, st.acc, fn t, acc -> (data = block.(t); see(z, data, protocol); [data | acc]) end)
          decode(read, block, protocol, z, %{st | token: token + run, acc: acc})
      end
    end
  end

  # The literal data before a token or the end: inflate it with the flush
  # marker the sender left off.
  defp flush_data(_z, %{pending: []} = st), do: st

  defp flush_data(z, st) do
    out = :zlib.inflate(z, [st.pending, <<0, 0, 0xFF, 0xFF>>])
    %{st | pending: [], acc: [out | st.acc]}
  end

  # A matched block goes into the inflater's history as stored blocks, as
  # rsync's see_deflate_token does. Before protocol 31 each stored block
  # repeats the start of the data (a bug both sides share).
  defp see(_z, "", _protocol), do: :ok

  defp see(z, data, protocol) do
    stored(z, data, data, protocol)
  end

  defp stored(_z, _buf, "", _protocol), do: :ok

  defp stored(z, buf, left, protocol) do
    n = min(byte_size(left), 0xFFFF)
    piece = if protocol >= 31, do: binary_part(left, 0, n), else: binary_part(buf, 0, n)
    _ = :zlib.inflate(z, [<<0, n &&& 0xFF, n >>> 8, bnot(n) &&& 0xFF, (bnot(n) >>> 8) &&& 0xFF>>, piece])
    rest = binary_part(left, n, byte_size(left) - n)
    stored(z, if(protocol >= 31, do: rest, else: buf), rest, protocol)
  end

  @doc false
  def chunk_size, do: @chunk
end

defmodule Lepton.Rsync.MD4 do
  @moduledoc """
  MD4 (RFC 1320), for when the crypto library has dropped it (as the
  image's OpenSSL has). The 48 steps are written out, for speed.
  """
  import Bitwise

  def hash(msg) do
    bits = byte_size(msg) * 8
    pad = rem(55 - rem(byte_size(msg), 64) + 64, 64)
    {a, b, c, d} = blocks(msg <> <<0x80>> <> :binary.copy(<<0>>, pad) <> <<bits::little-64>>, 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476)
    <<a::little-32, b::little-32, c::little-32, d::little-32>>
  end

  defp blocks(<<x0::little-32, x1::little-32, x2::little-32, x3::little-32, x4::little-32, x5::little-32, x6::little-32, x7::little-32, x8::little-32, x9::little-32, x10::little-32, x11::little-32, x12::little-32, x13::little-32, x14::little-32, x15::little-32, rest::binary>>, a0, b0, c0, d0) do
    {a, b, c, d} = {a0, b0, c0, d0}
    a = rot(a + f(b, c, d) + x0 + 0, 3)
    d = rot(d + f(a, b, c) + x1 + 0, 7)
    c = rot(c + f(d, a, b) + x2 + 0, 11)
    b = rot(b + f(c, d, a) + x3 + 0, 19)
    a = rot(a + f(b, c, d) + x4 + 0, 3)
    d = rot(d + f(a, b, c) + x5 + 0, 7)
    c = rot(c + f(d, a, b) + x6 + 0, 11)
    b = rot(b + f(c, d, a) + x7 + 0, 19)
    a = rot(a + f(b, c, d) + x8 + 0, 3)
    d = rot(d + f(a, b, c) + x9 + 0, 7)
    c = rot(c + f(d, a, b) + x10 + 0, 11)
    b = rot(b + f(c, d, a) + x11 + 0, 19)
    a = rot(a + f(b, c, d) + x12 + 0, 3)
    d = rot(d + f(a, b, c) + x13 + 0, 7)
    c = rot(c + f(d, a, b) + x14 + 0, 11)
    b = rot(b + f(c, d, a) + x15 + 0, 19)
    a = rot(a + g(b, c, d) + x0 + 0x5A827999, 3)
    d = rot(d + g(a, b, c) + x4 + 0x5A827999, 5)
    c = rot(c + g(d, a, b) + x8 + 0x5A827999, 9)
    b = rot(b + g(c, d, a) + x12 + 0x5A827999, 13)
    a = rot(a + g(b, c, d) + x1 + 0x5A827999, 3)
    d = rot(d + g(a, b, c) + x5 + 0x5A827999, 5)
    c = rot(c + g(d, a, b) + x9 + 0x5A827999, 9)
    b = rot(b + g(c, d, a) + x13 + 0x5A827999, 13)
    a = rot(a + g(b, c, d) + x2 + 0x5A827999, 3)
    d = rot(d + g(a, b, c) + x6 + 0x5A827999, 5)
    c = rot(c + g(d, a, b) + x10 + 0x5A827999, 9)
    b = rot(b + g(c, d, a) + x14 + 0x5A827999, 13)
    a = rot(a + g(b, c, d) + x3 + 0x5A827999, 3)
    d = rot(d + g(a, b, c) + x7 + 0x5A827999, 5)
    c = rot(c + g(d, a, b) + x11 + 0x5A827999, 9)
    b = rot(b + g(c, d, a) + x15 + 0x5A827999, 13)
    a = rot(a + h(b, c, d) + x0 + 0x6ED9EBA1, 3)
    d = rot(d + h(a, b, c) + x8 + 0x6ED9EBA1, 9)
    c = rot(c + h(d, a, b) + x4 + 0x6ED9EBA1, 11)
    b = rot(b + h(c, d, a) + x12 + 0x6ED9EBA1, 15)
    a = rot(a + h(b, c, d) + x2 + 0x6ED9EBA1, 3)
    d = rot(d + h(a, b, c) + x10 + 0x6ED9EBA1, 9)
    c = rot(c + h(d, a, b) + x6 + 0x6ED9EBA1, 11)
    b = rot(b + h(c, d, a) + x14 + 0x6ED9EBA1, 15)
    a = rot(a + h(b, c, d) + x1 + 0x6ED9EBA1, 3)
    d = rot(d + h(a, b, c) + x9 + 0x6ED9EBA1, 9)
    c = rot(c + h(d, a, b) + x5 + 0x6ED9EBA1, 11)
    b = rot(b + h(c, d, a) + x13 + 0x6ED9EBA1, 15)
    a = rot(a + h(b, c, d) + x3 + 0x6ED9EBA1, 3)
    d = rot(d + h(a, b, c) + x11 + 0x6ED9EBA1, 9)
    c = rot(c + h(d, a, b) + x7 + 0x6ED9EBA1, 11)
    b = rot(b + h(c, d, a) + x15 + 0x6ED9EBA1, 15)
    blocks(rest, (a + a0) &&& 0xFFFFFFFF, (b + b0) &&& 0xFFFFFFFF, (c + c0) &&& 0xFFFFFFFF, (d + d0) &&& 0xFFFFFFFF)
  end

  defp blocks(<<>>, a, b, c, d), do: {a, b, c, d}

  @compile {:inline, f: 3, g: 3, h: 3, rot: 2}
  defp f(x, y, z), do: (x &&& y) ||| (bxor(x, 0xFFFFFFFF) &&& z)
  defp g(x, y, z), do: (x &&& y) ||| (x &&& z) ||| (y &&& z)
  defp h(x, y, z), do: bxor(bxor(x, y), z)

  defp rot(v, s) do
    v = v &&& 0xFFFFFFFF
    ((v <<< s) ||| (v >>> (32 - s))) &&& 0xFFFFFFFF
  end
end
