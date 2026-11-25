defmodule Lepton.PGP.Message do
  @moduledoc """
  OpenPGP messages: literal data, compression, encryption (to keys:
  ECDH on Curve25519 or the NIST curves, RSA; and with a passphrase) and
  signatures (inline, with one-pass signature packets; detached; and
  clearsigned text).

  Writes: AES-256 in SEIPD version 1 (CFB with a modification detection
  code: what every OpenPGP program reads), signatures over SHA-512
  (EdDSA) or SHA-256 (RSA). Reads that, and GnuPG 2.4's AEAD packets
  (tag 20, OCB), which it sends to keys that say they read them. Data
  without integrity protection (tag 9) is refused, as GnuPG does.
  """

  alias Lepton.PGP.{Crypto, Key, Keyring, Packet, Sig}

  @sym 9

  # -- literal data -------------------------------------------------------------------------------------

  def literal(data, name \\ "", mode \\ ?b) do
    name = if byte_size(name) > 255, do: binary_part(name, 0, 255), else: name
    Packet.encode(11, <<mode, byte_size(name)>> <> name <> <<System.os_time(:second)::32>> <> data)
  end

  defp parse_literal(<<mode, nlen, name::binary-size(nlen), date::32, data::binary>>), do: %{mode: mode, name: name, date: date, data: data}

  # -- encrypting ------------------------------------------------------------------------------------------

  @doc """
  Encrypt `plain` (packets: a literal, signed or not) to `recipients`
  (encryption keys) and/or with `passphrase`. Returns the message's bytes.
  """
  def encrypt(plain, recipients, passphrase \\ nil) do
    sk = :crypto.strong_rand_bytes(32)

    {sk, esks} =
      cond do
        recipients == [] and passphrase ->
          # A passphrase alone: the session key is the S2K's output.
          s2k = Crypto.new_s2k()
          {Crypto.s2k(s2k, passphrase, 32), [Packet.encode(3, <<4, @sym>> <> Crypto.encode_s2k(s2k))]}

        true ->
          pk = Enum.map(recipients, &pkesk(&1, sk))

          sym =
            if passphrase do
              s2k = Crypto.new_s2k()
              kek = Crypto.s2k(s2k, passphrase, 32)
              esk = Crypto.cfb_encrypt(@sym, kek, <<0::128>>, <<@sym>> <> sk)
              [Packet.encode(3, <<4, @sym>> <> Crypto.encode_s2k(s2k) <> esk)]
            else
              []
            end

          {sk, pk ++ sym}
      end

    IO.iodata_to_binary([esks, seipd(sk, plain)])
  end

  # SEIPD v1: a random block, its last two octets again, the data, an MDC packet (SHA-1).
  defp seipd(sk, plain) do
    prefix = :crypto.strong_rand_bytes(16)
    prefix = prefix <> binary_part(prefix, 14, 2)
    data = prefix <> plain <> <<0xD3, 0x14>>
    mdc = :crypto.hash(:sha, data)
    Packet.encode(18, <<1>> <> Crypto.cfb_encrypt(@sym, sk, <<0::128>>, data <> mdc))
  end

  defp checksum(bin), do: <<rem(Enum.sum(:binary.bin_to_list(bin)), 65536)::16>>

  # A public-key encrypted session key, for one recipient key.
  defp pkesk(%Key{algo: algo, material: m} = key, sk) when algo in [1, 2] do
    c = :crypto.public_encrypt(:rsa, <<@sym>> <> sk <> checksum(sk), [m.e, m.n], :rsa_pkcs1_padding)
    Packet.encode(1, <<3>> <> key.keyid <> <<1>> <> Packet.mpi(c))
  end

  defp pkesk(%Key{algo: 18, material: m} = key, sk) do
    {eph_point, shared} = ecdh_send(m)
    kek = ecdh_kek(key, shared)
    padded = pkcs5(<<@sym>> <> sk <> checksum(sk))
    wrapped = Crypto.wrap(kek, padded)
    Packet.encode(1, <<3>> <> key.keyid <> <<18>> <> Packet.mpi(eph_point) <> <<byte_size(wrapped)>> <> wrapped)
  end

  defp pkesk(%Key{algo: a}, _), do: raise(ArgumentError, "can't encrypt to an algorithm #{a} key")

  defp ecdh_send(%{curve: :x25519, point: <<0x40, pub::binary-32>>}) do
    {eph_pub, eph_priv} = :crypto.generate_key(:ecdh, :x25519)
    {<<0x40>> <> eph_pub, :crypto.compute_key(:ecdh, pub, eph_priv, :x25519)}
  end

  defp ecdh_send(%{curve: curve, point: point}) do
    {eph_pub, eph_priv} = :crypto.generate_key(:ecdh, curve)
    {eph_pub, :crypto.compute_key(:ecdh, point, eph_priv, curve)}
  end

  # RFC 6637's KDF: the hash of 00000001 || shared || the parameters.
  defp ecdh_kek(%Key{material: m, fpr: fpr}, shared) do
    oid = Key.oid(m.curve)
    param = <<byte_size(oid)>> <> oid <> <<18, 3, 1, m.kdf_hash, m.kdf_cipher>> <> "Anonymous Sender    " <> fpr
    h = :crypto.hash(Crypto.hash(m.kdf_hash), <<0, 0, 0, 1>> <> shared <> param)
    binary_part(h, 0, Crypto.key_size(m.kdf_cipher))
  end

  defp pkcs5(bin) do
    n = 8 - rem(byte_size(bin), 8)
    bin <> :binary.copy(<<n>>, n)
  end

  # -- signing ------------------------------------------------------------------------------------------------

  @doc "An inline-signed message: one-pass signature, literal data, signature."
  def sign_inline(data, %Key{} = signer, name \\ "", text \\ false) do
    type = if text, do: Sig.text(), else: Sig.binary()
    hashed_data = if text, do: Sig.canonical(data), else: data
    sig = Sig.sign(signer, type, hashed_data)
    {:ok, s} = Sig.parse(sig)
    ops = Packet.encode(4, <<3, type, s.hash, signer.algo>> <> signer.keyid <> <<1>>)
    IO.iodata_to_binary([ops, literal(data, name, if(text, do: ?t, else: ?b)), Packet.encode(2, sig)])
  end

  @doc "A detached signature packet over `data`."
  def detach_sign(data, %Key{} = signer, text \\ false) do
    if text, do: Packet.encode(2, Sig.sign(signer, Sig.text(), Sig.canonical(data))), else: Packet.encode(2, Sig.sign(signer, Sig.binary(), data))
  end

  @doc "A clearsigned text (RFC 9580 §7): the text, dash-escaped, then its armored signature."
  def clearsign(text, %Key{} = signer) do
    lines = text |> String.split(~r/\r?\n/) |> drop_last_empty()
    signed = lines |> Enum.map(&String.trim_trailing(&1, " ")) |> Enum.map(&String.trim_trailing(&1, "\t")) |> Enum.join("\r\n")
    sig = Packet.encode(2, Sig.sign(signer, Sig.text(), signed))
    # (the hash Sig.sign uses: SHA-512 for EdDSA, SHA-256 else)
    hash = if signer.algo in [22, 27], do: 10, else: 8
    escaped = Enum.map_join(lines, "\n", fn l -> if String.starts_with?(l, "-"), do: "- " <> l, else: l end)
    "-----BEGIN PGP SIGNED MESSAGE-----\nHash: #{Crypto.hash_name(hash)}\n\n" <> escaped <> "\n" <> Packet.armor("SIGNATURE", sig)
  end

  defp drop_last_empty(lines), do: if(List.last(lines) == "", do: Enum.drop(lines, -1), else: lines)

  @doc "A clearsigned message's text and signature bytes: `{:ok, text, sig}`."
  def parse_clearsigned(data) do
    case Regex.run(~r/-----BEGIN PGP SIGNED MESSAGE-----\r?\n((?:[^\r\n]+\r?\n)*)\r?\n(.*?)\r?\n(-----BEGIN PGP SIGNATURE-----.*?-----END PGP SIGNATURE-----)/s, data, capture: :all_but_first) do
      [_headers, body, sigblock] ->
        text = body |> String.split(~r/\r?\n/) |> Enum.map(&String.replace_prefix(&1, "- ", "")) |> Enum.join("\n")

        case Packet.dearmor(sigblock) do
          {:ok, [{_, sig}]} -> {:ok, text, sig}
          err -> err
        end

      _ ->
        {:error, "not a clearsigned message"}
    end
  end

  @doc "The bytes a clearsigned text's signature covers."
  def clear_signed_bytes(text), do: text |> String.split("\n") |> Enum.map(&String.trim_trailing(&1, " ")) |> Enum.map(&String.trim_trailing(&1, "\t")) |> Enum.join("\r\n")

  # -- reading ------------------------------------------------------------------------------------------------

  @doc """
  Read a message (its packets' bytes). `opts`: `:secret` (secret keys),
  `:public` (public keys, to check signatures), `:passphrase` (a function
  `(prompt -> {:ok, pass} | :error)`). Returns `{:ok, %{data, name,
  mode, encrypted, sigs}}` (`sigs`: `[%{status: :good | :bad | :no_key,
  keyid, key, sig}]`) or `{:error, why}`.
  """
  def read(bin, opts) do
    with {:ok, pkts} <- Packet.parse(bin) do
      read_packets(pkts, opts, %{encrypted: nil})
    end
  end

  defp read_packets(pkts, opts, info) do
    {esks, rest} = Enum.split_while(pkts, fn {t, _} -> t in [1, 3] end)

    case rest do
      [{tag, body} | _] when tag in [18, 20] and esks != [] ->
        with {:ok, sk, algo, how} <- session_key(esks, opts),
             {:ok, plain} <- decrypt_data(tag, body, sk, algo),
             {:ok, inner} <- Packet.parse(plain) do
          read_packets(inner, opts, %{info | encrypted: how})
        end

      [{9, _} | _] ->
        {:error, "data encrypted without integrity protection (refused, as GnuPG refuses it)"}

      [{8, <<algo, data::binary>>} | _] ->
        with {:ok, plain} <- Crypto.decompress(algo, data), {:ok, inner} <- Packet.parse(plain), do: read_packets(inner, opts, info)

      _ ->
        signed(rest, opts, info)
    end
  end

  # One-pass signature packets, a literal, signatures (or signatures, then a literal: older style).
  defp signed(pkts, opts, info) do
    lit = Enum.find_value(pkts, fn {t, b} -> t == 11 && parse_literal(b) end)
    sigs = for {2, b} <- pkts, {:ok, s} <- [Sig.parse(b)], do: s

    case lit do
      nil -> {:error, "no data in the message"}
      lit -> {:ok, Map.merge(info, %{data: lit.data, name: lit.name, mode: lit.mode, sigs: Enum.map(sigs, &check(&1, lit.data, opts[:public] || []))})}
    end
  end

  @doc "A signature's check over `data` with the keys there are: `%{status, keyid, key, keyring_key, sig}`."
  def check(%Sig{} = s, data, keys) do
    keyid = Sig.issuer(s)
    hashed = if s.type == 0x01, do: Sig.canonical(data), else: data

    case keyid && Keyring.by_keyid(keys, keyid) do
      {k, key} -> %{status: if(Sig.verify(s, key, hashed), do: :good, else: :bad), keyid: keyid, key: key, keyring_key: k, sig: s}
      _ -> %{status: :no_key, keyid: keyid, key: nil, keyring_key: nil, sig: s}
    end
  end

  # -- decrypting ---------------------------------------------------------------------------------------------

  defp session_key(esks, opts) do
    secret = opts[:secret] || []

    # Public-key ones first, for keys we have the secret of; then passphrases.
    pk =
      Enum.find_value(esks, fn
        {1, <<3, keyid::binary-8, algo, data::binary>>} ->
          case Keyring.by_keyid(secret, keyid) do
            {k, key} -> {k, key, algo, data}
            nil -> nil
          end

        _ ->
          nil
      end)

    cond do
      pk ->
        {k, key, algo, data} = pk

        with {:ok, key} <- unlock(key, k, opts),
             {:ok, sk, sym} <- pk_decrypt(algo, key, data) do
          {:ok, sk, sym, {:key, k, key}}
        end

      skesk = Enum.find(esks, &match?({3, _}, &1)) ->
        {3, body} = skesk
        sym_decrypt(body, opts)

      true ->
        ids = for {1, <<3, keyid::binary-8, _::binary>>} <- esks, do: Base.encode16(keyid)
        {:error, "no secret key for it (encrypted to #{Enum.join(ids, ", ")})"}
    end
  end

  defp unlock(key, k, opts) do
    if Key.locked?(key) do
      prompt = "the secret key for \"#{Keyring.primary_uid(k)}\" (#{Key.algo_name(key)}, ID #{Key.keyid(key)})"

      case opts[:passphrase] && opts[:passphrase].(prompt) do
        {:ok, pass} -> Key.unlock(key, pass)
        _ -> {:error, "a passphrase is needed for #{prompt}"}
      end
    else
      {:ok, key}
    end
  end

  defp pk_decrypt(algo, %Key{material: m, secret: %{key: s}}, data) when algo in [1, 2] do
    {c, _} = Packet.read_mpi(data)
    c = :binary.copy(<<0>>, max(byte_size(m.n) - byte_size(c), 0)) <> c

    case :crypto.private_decrypt(:rsa, c, [m.e, m.n, s.d], :rsa_pkcs1_padding) do
      <<sym, rest::binary>> -> split_sk(sym, rest)
    end
  rescue
    _ -> {:error, "decryption failed (the wrong key?)"}
  end

  defp pk_decrypt(18, %Key{material: m, secret: %{key: s}} = key, data) do
    {eph, rest} = Packet.read_mpi(data)
    <<len, wrapped::binary-size(len), _::binary>> = rest

    shared =
      case m.curve do
        :x25519 -> <<0x40, e::binary-32>> = eph; :crypto.compute_key(:ecdh, e, s.scalar, :x25519)
        curve -> :crypto.compute_key(:ecdh, eph, s.scalar, curve)
      end

    with {:ok, padded} <- Crypto.unwrap(ecdh_kek(key, shared), wrapped) do
      n = :binary.last(padded)
      <<sym, rest::binary>> = binary_part(padded, 0, byte_size(padded) - n)
      split_sk(sym, rest)
    else
      :error -> {:error, "decryption failed (the wrong key?)"}
    end
  rescue
    _ -> {:error, "decryption failed (the wrong key?)"}
  end

  defp pk_decrypt(algo, _, _), do: {:error, "a session key for an algorithm #{algo} key"}

  defp split_sk(sym, rest) do
    n = byte_size(rest) - 2
    <<sk::binary-size(^n), sum::binary-2>> = rest
    if checksum(sk) == sum, do: {:ok, sk, sym}, else: {:error, "decryption failed (the wrong key?)"}
  end

  defp sym_decrypt(<<4, cipher, rest::binary>>, opts) do
    {s2k, esk} = Crypto.read_s2k(rest)

    case opts[:passphrase] && opts[:passphrase].("the passphrase it was encrypted with") do
      {:ok, pass} ->
        kek = Crypto.s2k(s2k, pass, Crypto.key_size(cipher))

        if esk == <<>> do
          {:ok, kek, cipher, :passphrase}
        else
          <<sym, sk::binary>> = Crypto.cfb_decrypt(cipher, kek, <<0::128>>, esk)
          {:ok, sk, sym, :passphrase}
        end

      _ ->
        {:error, "a passphrase is needed"}
    end
  end

  defp sym_decrypt(<<v, _::binary>>, _), do: {:error, "a version #{v} passphrase packet (this reads version 4)"}

  defp decrypt_data(18, <<1, ct::binary>>, sk, sym) do
    plain = Crypto.cfb_decrypt(sym, sk, <<0::128>>, ct)
    n = byte_size(plain) - 22

    case plain do
      <<prefix::binary-18, _::binary>> when n >= 18 ->
        <<data::binary-size(^n), 0xD3, 0x14, mdc::binary-20>> = plain
        <<_::binary-14, a::binary-2, b::binary-2>> = prefix

        cond do
          a != b -> {:error, "decryption failed (a bad passphrase or key)"}
          :crypto.hash(:sha, data <> <<0xD3, 0x14>>) != mdc -> {:error, "the message has been changed (its integrity check fails)"}
          true -> {:ok, binary_part(data, 18, byte_size(data) - 18)}
        end

      _ ->
        {:error, "decryption failed"}
    end
  rescue
    _ -> {:error, "decryption failed (a bad passphrase or key)"}
  end

  defp decrypt_data(18, <<v, _::binary>>, _, _), do: {:error, "a version #{v} encrypted packet (this reads version 1, and GnuPG's AEAD packets)"}

  # GnuPG's AEAD packet (tag 20): version 1, cipher, mode 2 (OCB), chunk
  # size, a 15-octet IV; chunks with their tags, then a final tag.
  defp decrypt_data(20, <<1, cipher, 2, c, iv::binary-15, data::binary>>, sk, _sym) do
    size = Bitwise.bsl(1, c + 6)
    header = <<0xD4, 1, cipher, 2, c>>
    total = byte_size(data) - 16
    <<body::binary-size(^total), final::binary-16>> = data
    chunks = chunk(body, size + 16)

    result =
      chunks
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {ch, i}, {:ok, acc} ->
        case Crypto.ocb_decrypt(cipher, sk, nonce(iv, i), header <> <<i::64>>, ch) do
          {:ok, p} -> {:cont, {:ok, [p | acc]}}
          :error -> {:halt, {:error, "decryption failed (a bad key, or a changed message)"}}
        end
      end)

    with {:ok, parts} <- result do
      plain = parts |> Enum.reverse() |> IO.iodata_to_binary()
      n = length(chunks)

      case Crypto.ocb_decrypt(cipher, sk, nonce(iv, n), header <> <<n::64, byte_size(plain)::64>>, final) do
        {:ok, ""} -> {:ok, plain}
        _ -> {:error, "the message has been changed (its final check fails)"}
      end
    end
  end

  defp decrypt_data(20, <<v, _c, mode, _::binary>>, _, _), do: {:error, "an AEAD packet (version #{v}, mode #{mode}) this doesn't read (OCB only)"}

  defp chunk(<<>>, _), do: []
  defp chunk(bin, n) when byte_size(bin) <= n, do: [bin]
  defp chunk(bin, n), do: [binary_part(bin, 0, n) | chunk(binary_part(bin, n, byte_size(bin) - n), n)]

  defp nonce(<<head::binary-7, tail::64>>, i), do: head <> <<Bitwise.bxor(tail, i)::64>>
end
