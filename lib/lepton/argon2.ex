defmodule Lepton.Argon2 do
  @moduledoc """
  Argon2id (RFC 9106, version 0x13), the memory-hard password hash: the
  vault's key derivation (`Lepton.Vault`), so a guessed master password
  costs an attacker its memory (64 MiB) as well as its time, which GPUs
  and custom chips don't make cheap.

  In Elixir: Erlang's crypto has BLAKE2b but not Argon2. The 64-bit words
  of its blocks are worked on as two 32-bit halves, which keeps every
  number a small integer (about four times faster than 64-bit ones). The
  1 KiB blocks are binaries in an ETS table; whole-block XORs are
  `:crypto.exor/2`.
  """

  import Bitwise

  @version 0x13
  @argon2id 2
  @block 1024

  @doc """
  Argon2id of `password` with `salt`: `opts` are `:t` (passes), `:m`
  (memory in KiB), `:p` (lanes), `:length` (of the tag, in bytes),
  `:secret` and `:ad` (associated data). Returns the tag.
  """
  def hash(password, salt, opts) do
    t = Keyword.fetch!(opts, :t)
    m = Keyword.fetch!(opts, :m)
    p = Keyword.get(opts, :p, 1)
    len = Keyword.get(opts, :length, 32)
    secret = Keyword.get(opts, :secret, "")
    ad = Keyword.get(opts, :ad, "")
    true = t >= 1 and p >= 1 and m >= 8 * p

    h0 =
      :crypto.hash(:blake2b, [
        le32(p), le32(len), le32(m), le32(t), le32(@version), le32(@argon2id),
        le32(byte_size(password)), password, le32(byte_size(salt)), salt,
        le32(byte_size(secret)), secret, le32(byte_size(ad)), ad
      ])

    # m' blocks, q columns per lane, four slices of a lane in each pass.
    q = div(m, 4 * p) * 4
    seg = div(q, 4)
    mem = :ets.new(:argon2, [:set, :private])

    try do
      for l <- 0..(p - 1), c <- 0..1, do: :ets.insert(mem, {l * q + c, hprime(@block, [h0, le32(c), le32(l)])})
      ctx = %{mem: mem, p: p, q: q, seg: seg, m: p * q, t: t}

      for pass <- 0..(t - 1), slice <- 0..3, lane <- 0..(p - 1), do: segment(ctx, pass, slice, lane)

      last = Enum.reduce(1..(p - 1)//1, get(mem, q - 1), fn l, acc -> :crypto.exor(acc, get(mem, l * q + q - 1)) end)
      hprime(len, last)
    after
      :ets.delete(mem)
    end
  end

  defp segment(ctx, pass, slice, lane) do
    %{mem: mem, q: q, seg: seg} = ctx
    independent = pass == 0 and slice < 2
    first = if pass == 0 and slice == 0, do: 2, else: 0

    Enum.reduce(first..(seg - 1)//1, nil, fn i, addresses ->
      col = slice * seg + i
      at = lane * q + col
      prev = get(mem, lane * q + if(col == 0, do: q - 1, else: col - 1))

      # J1, J2: from the address blocks (data-independent: the first half of
      # the first pass), else from the previous block.
      {j1, j2, addresses} =
        if independent do
          addresses = if addresses == nil or rem(i, 128) == 0, do: address_block(ctx, pass, lane, slice, div(i, 128) + 1), else: addresses
          off = rem(i, 128) * 8
          <<_::binary-size(^off), lo::little-32, hi::little-32, _::binary>> = addresses
          {lo, hi, addresses}
        else
          <<lo::little-32, hi::little-32, _::binary>> = prev
          {lo, hi, nil}
        end

      ref_lane = if pass == 0 and slice == 0, do: lane, else: rem(j2, ctx.p)
      ref = lane_index(ctx, pass, slice, i, ref_lane == lane, j1)
      block = compress(prev, get(mem, ref_lane * q + ref))
      # (version 0x13: passes after the first XOR into what was there)
      block = if pass == 0, do: block, else: :crypto.exor(block, get(mem, at))
      :ets.insert(mem, {at, block})
      addresses
    end)
  end

  # Which block of the reference lane (RFC 9106 3.4.1.2).
  defp lane_index(ctx, pass, slice, i, same_lane, j1) do
    %{q: q, seg: seg} = ctx

    area =
      cond do
        pass == 0 and slice == 0 -> i - 1
        pass == 0 and same_lane -> slice * seg + i - 1
        pass == 0 -> slice * seg + if(i == 0, do: -1, else: 0)
        same_lane -> q - seg + i - 1
        true -> q - seg + if(i == 0, do: -1, else: 0)
      end

    x = j1 * j1 >>> 32
    rel = area - 1 - (area * x >>> 32)
    start = if pass == 0 or slice == 3, do: 0, else: (slice + 1) * seg
    rem(start + rel, q)
  end

  # The pseudo-random numbers of the data-independent half: G(0, G(0, input)).
  defp address_block(ctx, pass, lane, slice, counter) do
    zero = :binary.copy(<<0>>, @block)
    input = [le64(pass), le64(lane), le64(slice), le64(ctx.m), le64(ctx.t), le64(@argon2id), le64(counter), :binary.copy(<<0>>, @block - 56)] |> IO.iodata_to_binary()
    compress(zero, compress(zero, input))
  end

  defp get(mem, i), do: :ets.lookup_element(mem, i, 2)

  # -- the compression function G ------------------------------------------------------------

  @doc false
  # G(X, Y): R = X xor Y, P on its eight rows, then on its eight columns, xor R.
  def compress(x, y) do
    r = :crypto.exor(x, y)
    # The rows of R, each P'd; then Q's columns (words 2j and 2j+1 of each
    # row: 16 bytes at 128k + 16j), each P'd and put back in their places.
    rows = for i <- 0..7, do: binary_part(r, 128 * i, 128) |> words() |> perm() |> unwords()
    qb = IO.iodata_to_binary(rows)
    cols = for j <- 0..7, do: column(qb, j) |> words() |> perm() |> unwords()
    :crypto.exor(transpose(cols), r)
  end

  defp column(qb, j) do
    o = 16 * j
    <<_::binary-size(^o), a::binary-16, _::binary-112, b::binary-16, _::binary-112, c::binary-16, _::binary-112, d::binary-16,
      _::binary-112, e::binary-16, _::binary-112, f::binary-16, _::binary-112, g::binary-16, _::binary-112, h::binary-16, _::binary>> = qb
    <<a::binary, b::binary, c::binary, d::binary, e::binary, f::binary, g::binary, h::binary>>
  end

  # The columns back into rows: chunk k of each column makes row k.
  defp transpose(cols) do
    parts = Enum.map(cols, fn col -> for <<chunk::binary-16 <- col>>, do: chunk end)
    parts |> Enum.zip() |> Enum.map(&Tuple.to_list/1) |> IO.iodata_to_binary()
  end

  # 16 words as 32 halves: {lo0, hi0, lo1, hi1, ...}.
  defp words(<<l0::little-32, h0::little-32, l1::little-32, h1::little-32, l2::little-32, h2::little-32, l3::little-32, h3::little-32,
               l4::little-32, h4::little-32, l5::little-32, h5::little-32, l6::little-32, h6::little-32, l7::little-32, h7::little-32,
               l8::little-32, h8::little-32, l9::little-32, h9::little-32, l10::little-32, h10::little-32, l11::little-32, h11::little-32,
               l12::little-32, h12::little-32, l13::little-32, h13::little-32, l14::little-32, h14::little-32, l15::little-32, h15::little-32>>),
       do: {l0, h0, l1, h1, l2, h2, l3, h3, l4, h4, l5, h5, l6, h6, l7, h7, l8, h8, l9, h9, l10, h10, l11, h11, l12, h12, l13, h13, l14, h14, l15, h15}

  defp unwords({l0, h0, l1, h1, l2, h2, l3, h3, l4, h4, l5, h5, l6, h6, l7, h7, l8, h8, l9, h9, l10, h10, l11, h11, l12, h12, l13, h13, l14, h14, l15, h15}),
       do: <<l0::little-32, h0::little-32, l1::little-32, h1::little-32, l2::little-32, h2::little-32, l3::little-32, h3::little-32,
             l4::little-32, h4::little-32, l5::little-32, h5::little-32, l6::little-32, h6::little-32, l7::little-32, h7::little-32,
             l8::little-32, h8::little-32, l9::little-32, h9::little-32, l10::little-32, h10::little-32, l11::little-32, h11::little-32,
             l12::little-32, h12::little-32, l13::little-32, h13::little-32, l14::little-32, h14::little-32, l15::little-32, h15::little-32>>

  # P: BLAKE2b's round (with Argon2's multiplications) on 16 words.
  defp perm({l0, h0, l1, h1, l2, h2, l3, h3, l4, h4, l5, h5, l6, h6, l7, h7, l8, h8, l9, h9, l10, h10, l11, h11, l12, h12, l13, h13, l14, h14, l15, h15}) do
    {h0, l0, h4, l4, h8, l8, h12, l12} = gb(h0, l0, h4, l4, h8, l8, h12, l12)
    {h1, l1, h5, l5, h9, l9, h13, l13} = gb(h1, l1, h5, l5, h9, l9, h13, l13)
    {h2, l2, h6, l6, h10, l10, h14, l14} = gb(h2, l2, h6, l6, h10, l10, h14, l14)
    {h3, l3, h7, l7, h11, l11, h15, l15} = gb(h3, l3, h7, l7, h11, l11, h15, l15)
    {h0, l0, h5, l5, h10, l10, h15, l15} = gb(h0, l0, h5, l5, h10, l10, h15, l15)
    {h1, l1, h6, l6, h11, l11, h12, l12} = gb(h1, l1, h6, l6, h11, l11, h12, l12)
    {h2, l2, h7, l7, h8, l8, h13, l13} = gb(h2, l2, h7, l7, h8, l8, h13, l13)
    {h3, l3, h4, l4, h9, l9, h14, l14} = gb(h3, l3, h4, l4, h9, l9, h14, l14)
    {l0, h0, l1, h1, l2, h2, l3, h3, l4, h4, l5, h5, l6, h6, l7, h7, l8, h8, l9, h9, l10, h10, l11, h11, l12, h12, l13, h13, l14, h14, l15, h15}
  end

  @compile {:inline, fbla: 4}
  # a + b + 2 * lo32(a) * lo32(b), mod 2^64, in halves.
  defp fbla(ah, al, bh, bl) do
    prod = 2 * al * bl
    lo = al + bl + (prod &&& 0xFFFFFFFF)
    {(ah + bh + (prod >>> 32) + (lo >>> 32)) &&& 0xFFFFFFFF, lo &&& 0xFFFFFFFF}
  end

  defp gb(ah, al, bh, bl, ch, cl, dh, dl) do
    {ah, al} = fbla(ah, al, bh, bl)
    # d = (d xor a) rotr 32: the halves swap
    {dh, dl} = {bxor(dl, al), bxor(dh, ah)}
    {ch, cl} = fbla(ch, cl, dh, dl)
    xh = bxor(bh, ch)
    xl = bxor(bl, cl)
    {bh, bl} = {(xh >>> 24 ||| xl <<< 8) &&& 0xFFFFFFFF, (xl >>> 24 ||| xh <<< 8) &&& 0xFFFFFFFF}
    {ah, al} = fbla(ah, al, bh, bl)
    xh = bxor(dh, ah)
    xl = bxor(dl, al)
    {dh, dl} = {(xh >>> 16 ||| xl <<< 16) &&& 0xFFFFFFFF, (xl >>> 16 ||| xh <<< 16) &&& 0xFFFFFFFF}
    {ch, cl} = fbla(ch, cl, dh, dl)
    xh = bxor(bh, ch)
    xl = bxor(bl, cl)
    # rotr 63 = rotl 1
    {bh, bl} = {(xh <<< 1 ||| xl >>> 31) &&& 0xFFFFFFFF, (xl <<< 1 ||| xh >>> 31) &&& 0xFFFFFFFF}
    {ah, al, bh, bl, ch, cl, dh, dl}
  end

  # -- H' and BLAKE2b ------------------------------------------------------------------------

  @doc false
  # H': BLAKE2b to any length (RFC 9106 3.3).
  def hprime(len, input) when len <= 64, do: blake2b([le32(len), input], len)

  def hprime(len, input) do
    r = div(len + 31, 32) - 2
    v1 = :crypto.hash(:blake2b, [le32(len), input])

    {vs, last} =
      Enum.reduce(2..r//1, {[v1], v1}, fn _, {acc, v} ->
        n = :crypto.hash(:blake2b, v)
        {[n | acc], n}
      end)

    tail = blake2b(last, len - 32 * r)
    IO.iodata_to_binary(Enum.map(Enum.reverse(vs), &binary_part(&1, 0, 32)) ++ [tail])
  end

  @doc "BLAKE2b with a digest of `len` bytes (1..64), unkeyed (RFC 7693)."
  def blake2b(data, 64), do: :crypto.hash(:blake2b, data)
  def blake2b(data, len), do: Lepton.Argon2.Blake2b.hash(IO.iodata_to_binary(data), len)

  defp le32(n), do: <<n::little-32>>
  defp le64(n), do: <<n::little-64>>
end

defmodule Lepton.Argon2.Blake2b do
  @moduledoc false
  # BLAKE2b (RFC 7693) for the digest lengths Erlang's crypto doesn't give
  # (it has only 64 bytes). Small inputs only: Argon2's final tag.

  import Bitwise

  @m 0xFFFFFFFFFFFFFFFF
  @iv {0x6A09E667F3BCC908, 0xBB67AE8584CAA73B, 0x3C6EF372FE94F82B, 0xA54FF53A5F1D36F1,
       0x510E527FADE682D1, 0x9B05688C2B3E6C1F, 0x1F83D9ABFB41BD6B, 0x5BE0CD19137E2179}
  @sigma {
    {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
    {14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3},
    {11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4},
    {7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8},
    {9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13},
    {2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9},
    {12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11},
    {13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10},
    {6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5},
    {10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0}
  }

  def hash(data, len) when len in 1..64 do
    h = put_elem(@iv, 0, bxor(elem(@iv, 0), 0x01010000 ||| len))
    blocks = chunks(data)
    last = length(blocks) - 1

    {h, _} =
      Enum.reduce(Enum.with_index(blocks), {h, 0}, fn {block, i}, {h, t} ->
        t = t + if(i == last, do: byte_size(data) - 128 * last, else: 128)
        {compress(h, pad(block), t, i == last), t}
      end)

    h |> Tuple.to_list() |> Enum.map(&<<&1::little-64>>) |> IO.iodata_to_binary() |> binary_part(0, len)
  end

  defp chunks(<<>>), do: [<<>>]
  defp chunks(data), do: for(<<c::binary-size(128) <- data>>, do: c) ++ (case rem(byte_size(data), 128) do
    0 -> []
    n -> [binary_part(data, byte_size(data) - n, n)]
  end)

  defp pad(b), do: b <> :binary.copy(<<0>>, 128 - byte_size(b))

  defp compress(h, block, t, final) do
    m = List.to_tuple(for <<w::little-64 <- block>>, do: w)
    v = Tuple.to_list(h) ++ Tuple.to_list(@iv)
    v = List.to_tuple(v)
    v = put_elem(v, 12, bxor(elem(v, 12), t &&& @m))
    v = put_elem(v, 13, bxor(elem(v, 13), t >>> 64))
    v = if final, do: put_elem(v, 14, bxor(elem(v, 14), @m)), else: v

    v =
      Enum.reduce(0..11, v, fn r, v ->
        s = elem(@sigma, rem(r, 10))
        mw = fn k -> elem(m, elem(s, k)) end

        v
        |> g(0, 4, 8, 12, mw.(0), mw.(1))
        |> g(1, 5, 9, 13, mw.(2), mw.(3))
        |> g(2, 6, 10, 14, mw.(4), mw.(5))
        |> g(3, 7, 11, 15, mw.(6), mw.(7))
        |> g(0, 5, 10, 15, mw.(8), mw.(9))
        |> g(1, 6, 11, 12, mw.(10), mw.(11))
        |> g(2, 7, 8, 13, mw.(12), mw.(13))
        |> g(3, 4, 9, 14, mw.(14), mw.(15))
      end)

    for i <- 0..7, reduce: h do
      h -> put_elem(h, i, bxor(bxor(elem(h, i), elem(v, i)), elem(v, i + 8)))
    end
  end

  defp g(v, a, b, c, d, x, y) do
    va = (elem(v, a) + elem(v, b) + x) &&& @m
    vd = rotr(bxor(elem(v, d), va), 32)
    vc = (elem(v, c) + vd) &&& @m
    vb = rotr(bxor(elem(v, b), vc), 24)
    va = (va + vb + y) &&& @m
    vd = rotr(bxor(vd, va), 16)
    vc = (vc + vd) &&& @m
    vb = rotr(bxor(vb, vc), 63)
    v |> put_elem(a, va) |> put_elem(b, vb) |> put_elem(c, vc) |> put_elem(d, vd)
  end

  defp rotr(x, n), do: (x >>> n ||| x <<< (64 - n)) &&& @m
end
