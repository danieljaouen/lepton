defmodule Lepton.PGP.Crypto do
  @moduledoc """
  OpenPGP's building blocks over `:crypto`: the algorithm numbers, S2K
  (keys from passphrases), CFB (OpenPGP's, and plain), AES key wrap
  (RFC 3394, for ECDH), OCB (RFC 7253, for AEAD-encrypted data, which
  GnuPG 2.4 sends to keys that say they read it) and decompression.
  """

  import Bitwise

  # -- algorithms ---------------------------------------------------------------------------------------

  @ciphers %{7 => {:aes_128, 16}, 8 => {:aes_192, 24}, 9 => {:aes_256, 32}}
  @hashes %{2 => :sha, 8 => :sha256, 9 => :sha384, 10 => :sha512, 11 => :sha224, 3 => :ripemd160}

  def cipher(id), do: @ciphers[id]
  def key_size(id), do: elem(@ciphers[id] || {nil, nil}, 1)
  def hash(id), do: @hashes[id]
  def hash_id(algo), do: Enum.find_value(@hashes, fn {k, v} -> if v == algo, do: k end)
  def cipher_name(id), do: %{7 => "AES128", 8 => "AES192", 9 => "AES256"}[id] || "cipher #{id}"
  def hash_name(id), do: %{2 => "SHA1", 8 => "SHA256", 9 => "SHA384", 10 => "SHA512", 11 => "SHA224", 3 => "RIPEMD160"}[id] || "hash #{id}"

  defp cfb_cipher(id) do
    case @ciphers[id] do
      {:aes_128, _} -> :aes_128_cfb128
      {:aes_192, _} -> :aes_192_cfb128
      {:aes_256, _} -> :aes_256_cfb128
      nil -> raise ArgumentError, "unsupported cipher #{id} (AES only)"
    end
  end

  defp ecb_cipher(id) do
    case @ciphers[id] do
      {:aes_128, _} -> :aes_128_ecb
      {:aes_192, _} -> :aes_192_ecb
      {:aes_256, _} -> :aes_256_ecb
      nil -> raise ArgumentError, "unsupported cipher #{id} (AES only)"
    end
  end

  # -- S2K --------------------------------------------------------------------------------------------------

  @doc "Read an S2K specifier: `{%{type, hash, salt, count}, rest}`."
  def read_s2k(<<0, h, rest::binary>>), do: {%{type: 0, hash: h, salt: "", count: 0}, rest}
  def read_s2k(<<1, h, salt::binary-8, rest::binary>>), do: {%{type: 1, hash: h, salt: salt, count: 0}, rest}
  def read_s2k(<<3, h, salt::binary-8, c, rest::binary>>), do: {%{type: 3, hash: h, salt: salt, count: (16 + (c &&& 15)) <<< ((c >>> 4) + 6)}, rest}
  def read_s2k(<<101, _::binary>>), do: raise(ArgumentError, "a GnuPG-specific S2K (a key kept on a card, or without its secret)")
  def read_s2k(_), do: raise(ArgumentError, "an S2K this doesn't read")

  @doc "A new iterated and salted S2K (SHA-256, 65011712 octets: GnuPG's)."
  def new_s2k, do: %{type: 3, hash: 8, salt: :crypto.strong_rand_bytes(8), count: 65_011_712}

  def encode_s2k(%{type: 3} = s), do: <<3, s.hash>> <> s.salt <> <<encode_count(s.count)>>

  defp encode_count(count), do: Enum.find(0..255, 255, fn c -> (16 + (c &&& 15)) <<< ((c >>> 4) + 6) >= count end)

  @doc "The key `size` octets long that `passphrase` makes through `s2k`."
  def s2k(s2k, passphrase, size) do
    algo = hash(s2k.hash) || raise(ArgumentError, "an S2K hash this doesn't have")
    digest_len = byte_size(:crypto.hash(algo, ""))
    rounds = div(size + digest_len - 1, digest_len)

    for i <- 0..(rounds - 1), into: <<>> do
      ctx = :crypto.hash_init(algo) |> :crypto.hash_update(:binary.copy(<<0>>, i))
      data = s2k.salt <> passphrase

      ctx =
        case s2k.type do
          3 ->
            # The salt and passphrase again and again, `count` octets: hashed
            # 64 KiB at a time (a call for each copy was 6.5 million calls,
            # seconds for each key unlocked).
            count = max(s2k.count, byte_size(data))
            block = :binary.copy(data, max(div(65_536, byte_size(data)), 1))
            blocks = div(count, byte_size(block))
            ctx = Enum.reduce(1..blocks//1, ctx, fn _, c -> :crypto.hash_update(c, block) end)
            left = count - blocks * byte_size(block)
            whole = :binary.copy(data, div(left, byte_size(data)) + 1)
            :crypto.hash_update(ctx, binary_part(whole, 0, left))

          _ ->
            :crypto.hash_update(ctx, data)
        end

      :crypto.hash_final(ctx)
    end
    |> binary_part(0, size)
  end

  # -- CFB --------------------------------------------------------------------------------------------------

  def cfb_encrypt(cipher, key, iv, data), do: :crypto.crypto_one_time(cfb_cipher(cipher), key, iv, data, true)
  def cfb_decrypt(cipher, key, iv, data), do: :crypto.crypto_one_time(cfb_cipher(cipher), key, iv, data, false)

  # -- AES key wrap (RFC 3394) --------------------------------------------------------------------------

  @kw_iv <<0xA6A6A6A6A6A6A6A6::64>>

  def wrap(kek, plain) do
    cipher = kek_cipher(kek)
    n = div(byte_size(plain), 8)
    r = for <<b::binary-8 <- plain>>, do: b

    {a, r} =
      Enum.reduce(0..5, {@kw_iv, r}, fn j, {a, r} ->
        {a, r2} =
          Enum.reduce(Enum.with_index(r, 1), {a, []}, fn {ri, i}, {a, acc} ->
            <<msb::64, lsb::binary-8>> = :crypto.crypto_one_time(cipher, kek, a <> ri, true)
            {<<bxor(msb, n * j + i)::64>>, [lsb | acc]}
          end)

        {a, Enum.reverse(r2)}
      end)

    IO.iodata_to_binary([a | r])
  end

  def unwrap(kek, wrapped) do
    cipher = kek_cipher(kek)
    <<a::binary-8, rest::binary>> = wrapped
    r = for <<b::binary-8 <- rest>>, do: b
    n = length(r)

    {a, r} =
      Enum.reduce(5..0//-1, {a, r}, fn j, {a, r} ->
        {a, r2} =
          Enum.reduce(Enum.reverse(Enum.with_index(r, 1)), {a, []}, fn {ri, i}, {a, acc} ->
            <<av::64>> = a
            <<msb::binary-8, lsb::binary-8>> = :crypto.crypto_one_time(cipher, kek, <<bxor(av, n * j + i)::64>> <> ri, false)
            {msb, [lsb | acc]}
          end)

        {a, r2}
      end)

    if a == @kw_iv, do: {:ok, IO.iodata_to_binary(r)}, else: :error
  end

  defp kek_cipher(kek) do
    case byte_size(kek) do
      16 -> :aes_128_ecb
      24 -> :aes_192_ecb
      32 -> :aes_256_ecb
    end
  end

  # -- OCB (RFC 7253, 128-bit tags) -----------------------------------------------------------------------

  @doc "OCB decryption of `ct` (its 16-octet tag at the end): `{:ok, plain}` or `:error`."
  def ocb_decrypt(cipher, key, nonce, ad, ct_and_tag) do
    e = fn block -> :crypto.crypto_one_time(ecb_cipher(cipher), key, block, true) end
    d = fn block -> :crypto.crypto_one_time(ecb_cipher(cipher), key, block, false) end
    len = byte_size(ct_and_tag) - 16
    <<ct::binary-size(^len), tag::binary-16>> = ct_and_tag

    l_star = e.(<<0::128>>)
    l_dollar = dbl(l_star)
    l = Stream.iterate(dbl(l_dollar), &dbl/1)

    offset0 = ocb_offset0(e, nonce)
    full = div(len, 16)
    blocks = for <<b::binary-16 <- binary_part(ct, 0, full * 16)>>, do: b

    {plain_blocks, offset, checksum} =
      Enum.reduce(Enum.with_index(blocks, 1), {[], offset0, <<0::128>>}, fn {c, i}, {acc, off, sum} ->
        off = xor(off, Enum.at(l, ntz(i)))
        p = xor(off, d.(xor(c, off)))
        {[p | acc], off, xor(sum, p)}
      end)

    rest = binary_part(ct, full * 16, len - full * 16)

    {plain, offset, checksum} =
      if rest == <<>> do
        {IO.iodata_to_binary(Enum.reverse(plain_blocks)), offset, checksum}
      else
        off = xor(offset, l_star)
        pad = e.(off)
        p = xor(rest, binary_part(pad, 0, byte_size(rest)))
        padded = p <> <<0x80>> <> :binary.copy(<<0>>, 15 - byte_size(p))
        {IO.iodata_to_binary(Enum.reverse([p | plain_blocks])), off, xor(checksum, padded)}
      end

    expected = xor(e.(xor(xor(checksum, offset), l_dollar)), ocb_hash(e, l_star, l, ad))
    if :crypto.hash_equals(expected, tag), do: {:ok, plain}, else: :error
  end

  # Nonce = num2str(TAGLEN mod 128, 7) || zeros(120 - bitlen(N)) || 1 || N;
  # Ktop = ENCIPHER(K, Nonce[1..122] || zeros(6)); bottom = Nonce[123..128];
  # Stretch = Ktop || (Ktop[1..64] xor Ktop[9..72]); Offset_0 = Stretch[1+bottom..128+bottom].
  defp ocb_offset0(e, nonce) do
    nbits = bit_size(nonce)
    full = <<0::7, 0::size(120 - nbits), 1::1, nonce::bitstring>>
    <<top::bitstring-size(122), bottom::6>> = full
    ktop = e.(<<top::bitstring, 0::6>>)
    <<k1_64::64, _::64>> = ktop
    <<_::8, k9_72::64, _::56>> = ktop
    stretch = ktop <> <<bxor(k1_64, k9_72)::64>>
    <<_::size(^bottom), offset::bitstring-size(128), _::bitstring>> = stretch
    offset
  end

  defp ocb_hash(_e, _l_star, _l, <<>>), do: <<0::128>>

  defp ocb_hash(e, l_star, l, ad) do
    full = div(byte_size(ad), 16)
    blocks = for <<b::binary-16 <- binary_part(ad, 0, full * 16)>>, do: b

    {sum, off} =
      Enum.reduce(Enum.with_index(blocks, 1), {<<0::128>>, <<0::128>>}, fn {a, i}, {sum, off} ->
        off = xor(off, Enum.at(l, ntz(i)))
        {xor(sum, e.(xor(a, off))), off}
      end)

    rest = binary_part(ad, full * 16, byte_size(ad) - full * 16)

    if rest == <<>> do
      sum
    else
      off = xor(off, l_star)
      padded = rest <> <<0x80>> <> :binary.copy(<<0>>, 15 - byte_size(rest))
      xor(sum, e.(xor(padded, off)))
    end
  end

  defp dbl(<<top::1, rest::127>>), do: <<bxor(rest <<< 1, if(top == 1, do: 0x87, else: 0))::128>>

  defp ntz(i) when (i &&& 1) == 1, do: 0
  defp ntz(i), do: 1 + ntz(i >>> 1)

  def xor(a, b), do: :crypto.exor(a, b)

  # -- compression ----------------------------------------------------------------------------------------

  @doc "A compressed data packet's contents: 0 none, 1 ZIP (raw deflate), 2 ZLIB."
  def decompress(0, data), do: {:ok, data}
  def decompress(1, data), do: inflate(data, -15)
  def decompress(2, data), do: inflate(data, 15)
  def decompress(3, _), do: {:error, "BZip2-compressed data (this gpg reads ZIP and ZLIB)"}
  def decompress(a, _), do: {:error, "compression algorithm #{a}"}

  defp inflate(data, bits) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, bits)
      out = :zlib.inflate(z, data)
      {:ok, IO.iodata_to_binary(out)}
    rescue
      _ -> {:error, "damaged compressed data"}
    after
      :zlib.close(z)
    end
  end
end
