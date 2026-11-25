defmodule Lepton.PGP.Key do
  @moduledoc """
  OpenPGP key packets (version 4): public keys and secret keys (their
  secret part protected by a passphrase, S2K usage 254, or not), their
  fingerprints and key IDs, and new keys.

  Algorithms: RSA (1, 2, 3); EdDSA (22, with Ed25519) and ECDH (18,
  with Curve25519), as GnuPG makes them; Ed25519 (27) and X25519 (25),
  RFC 9580's; ECDSA and ECDH on the NIST curves (P-256, P-384, P-521).
  """

  alias Lepton.PGP.{Crypto, Packet}

  # (raw: a secret key packet's body, as read or written: exported as it is)
  defstruct [:version, :created, :algo, :material, :body, :fpr, :keyid, secret: nil, raw: nil]

  @oids %{
    <<0x2B, 0x06, 0x01, 0x04, 0x01, 0xDA, 0x47, 0x0F, 0x01>> => :ed25519,
    <<0x2B, 0x06, 0x01, 0x04, 0x01, 0x97, 0x55, 0x01, 0x05, 0x01>> => :x25519,
    <<0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07>> => :secp256r1,
    <<0x2B, 0x81, 0x04, 0x00, 0x22>> => :secp384r1,
    <<0x2B, 0x81, 0x04, 0x00, 0x23>> => :secp521r1
  }

  def oid(curve), do: Enum.find_value(@oids, fn {k, v} -> if v == curve, do: k end)

  # -- parsing ------------------------------------------------------------------------------------------

  @doc "A public key packet's body (tags 6 and 14)."
  def parse_public(body) do
    with {:ok, key, _rest} <- parse_public_part(body), do: {:ok, key}
  end

  @doc "A secret key packet's body (tags 5 and 7): the key, its secret part still locked if protected."
  def parse_secret(body) do
    with {:ok, key, rest} <- parse_public_part(body) do
      {:ok, %{key | secret: parse_secret_part(rest, key), raw: body}}
    end
  end

  defp parse_public_part(<<4, created::32, algo, rest::binary>> = body) do
    try do
      {material, rest} = public_material(algo, rest)
      pub = binary_part(body, 0, byte_size(body) - byte_size(rest))
      fpr = :crypto.hash(:sha, <<0x99, byte_size(pub)::16>> <> pub)
      {:ok, %__MODULE__{version: 4, created: created, algo: algo, material: material, body: pub, fpr: fpr, keyid: binary_part(fpr, 12, 8)}, rest}
    rescue
      _ -> {:error, "a key this doesn't read (algorithm #{algo})"}
    end
  end

  defp parse_public_part(<<v, _::binary>>), do: {:error, "a version #{v} key (this reads version 4)"}
  defp parse_public_part(_), do: {:error, "a damaged key packet"}

  defp public_material(algo, rest) when algo in [1, 2, 3] do
    {[n, e], rest} = Packet.read_mpis(rest, 2)
    {%{n: n, e: e}, rest}
  end

  defp public_material(algo, <<len, oid::binary-size(len), rest::binary>>) when algo in [18, 19, 22] do
    curve = @oids[oid] || raise ArgumentError, "an unknown curve"
    {point, rest} = Packet.read_mpi(rest)

    case algo do
      18 ->
        <<3, 1, kdf_hash, kdf_cipher, rest::binary>> = rest
        {%{curve: curve, point: point, kdf_hash: kdf_hash, kdf_cipher: kdf_cipher}, rest}

      _ ->
        {%{curve: curve, point: point}, rest}
    end
  end

  defp public_material(27, <<pub::binary-32, rest::binary>>), do: {%{curve: :ed25519, point: <<0x40>> <> pub, native: true}, rest}
  defp public_material(25, <<pub::binary-32, rest::binary>>), do: {%{curve: :x25519, point: <<0x40>> <> pub, native: true}, rest}

  # The secret part: kept as found; unlock/2 reads it.
  defp parse_secret_part(<<0, rest::binary>>, key), do: %{usage: 0, data: rest, key: secret_material(key, rest)}

  defp parse_secret_part(<<usage, rest::binary>>, _key) when usage in [254, 255] do
    <<cipher, rest::binary>> = rest
    {s2k, rest} = Crypto.read_s2k(rest)
    <<iv::binary-16, data::binary>> = rest
    %{usage: usage, cipher: cipher, s2k: s2k, iv: iv, data: data, key: nil}
  end

  defp parse_secret_part(<<usage, _::binary>>, _key), do: %{usage: usage, unsupported: true, key: nil}

  # The secret numbers: RSA's d, p, q, u; the curves' scalar.
  defp secret_material(%{algo: algo}, data) when algo in [1, 2, 3] do
    {[d, p, q, u], _} = Packet.read_mpis(data, 4)
    %{d: d, p: p, q: q, u: u}
  end

  defp secret_material(%{algo: algo}, <<s::binary-32, _::binary>>) when algo in [25, 27], do: %{scalar: s}

  defp secret_material(%{algo: algo, material: m}, data) when algo in [18, 19, 22] do
    {s, _} = Packet.read_mpi(data)
    size = %{ed25519: 32, x25519: 32, secp256r1: 32, secp384r1: 48, secp521r1: 66}[m.curve]
    s = pad(s, size)
    # (Curve25519's scalar is stored big-endian, the reverse of its native order)
    %{scalar: if(m.curve == :x25519, do: reverse(s), else: s)}
  end

  defp pad(s, size) when byte_size(s) >= size, do: s
  defp pad(s, size), do: :binary.copy(<<0>>, size - byte_size(s)) <> s
  defp reverse(bin), do: bin |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()

  @doc "Is its secret part locked (a passphrase needed)?"
  def locked?(%__MODULE__{secret: %{key: nil}}), do: true
  def locked?(_), do: false

  @doc "Unlock the secret part with `passphrase`: `{:ok, key}` or `{:error, why}`."
  def unlock(%__MODULE__{secret: %{key: k}} = key, _passphrase) when k != nil, do: {:ok, key}
  def unlock(%__MODULE__{secret: %{unsupported: true, usage: u}}, _), do: {:error, "the secret key is protected in a way this doesn't read (S2K usage #{u}): export it from GnuPG again, or with --export-options backup"}

  def unlock(%__MODULE__{secret: %{usage: usage} = s} = key, passphrase) when usage in [254, 255] do
    size = Crypto.key_size(s.cipher) || throw({:error, "a secret key protected with an algorithm this doesn't have (#{s.cipher})"})
    kek = Crypto.s2k(s.s2k, passphrase, size)
    plain = Crypto.cfb_decrypt(s.cipher, kek, s.iv, s.data)

    ok? =
      case usage do
        254 ->
          n = byte_size(plain) - 20
          <<m::binary-size(^n), check::binary-20>> = plain
          if :crypto.hash(:sha, m) == check, do: {:ok, m}, else: :bad

        255 ->
          n = byte_size(plain) - 2
          <<m::binary-size(^n), check::16>> = plain
          if rem(Enum.sum(:binary.bin_to_list(m)), 65536) == check, do: {:ok, m}, else: :bad
      end

    case ok? do
      {:ok, m} -> {:ok, %{key | secret: %{s | key: secret_material(key, m)}}}
      :bad -> {:error, "Bad passphrase"}
    end
  catch
    {:error, _} = e -> e
  end

  def unlock(%__MODULE__{}, _), do: {:error, "no secret key"}

  # -- writing ------------------------------------------------------------------------------------------

  @doc """
  The secret key packet's body for `key` (its secret part unlocked):
  protected with `passphrase` (S2K usage 254, AES-256, iterated SHA-256),
  or not, for an empty one.
  """
  def secret_body(%__MODULE__{secret: %{key: k}} = key, passphrase) when k != nil do
    m = secret_mpis(key)

    if passphrase in [nil, ""] do
      key.body <> <<0>> <> m <> <<rem(Enum.sum(:binary.bin_to_list(m)), 65536)::16>>
    else
      s2k = Crypto.new_s2k()
      iv = :crypto.strong_rand_bytes(16)
      kek = Crypto.s2k(s2k, passphrase, 32)
      enc = Crypto.cfb_encrypt(9, kek, iv, m <> :crypto.hash(:sha, m))
      key.body <> <<254, 9>> <> Crypto.encode_s2k(s2k) <> iv <> enc
    end
  end

  defp secret_mpis(%{algo: algo, secret: %{key: k}}) when algo in [1, 2, 3], do: Packet.mpi(k.d) <> Packet.mpi(k.p) <> Packet.mpi(k.q) <> Packet.mpi(k.u)
  defp secret_mpis(%{algo: algo, secret: %{key: k}}) when algo in [25, 27], do: k.scalar
  defp secret_mpis(%{material: %{curve: :x25519}, secret: %{key: k}}), do: Packet.mpi(reverse(k.scalar))
  defp secret_mpis(%{secret: %{key: k}}), do: Packet.mpi(k.scalar)

  @doc "The public key packet's body alone (a secret key's public part)."
  def public(%__MODULE__{} = key), do: %{key | secret: nil}

  # -- new keys -------------------------------------------------------------------------------------------

  @doc """
  A new key: `:ed25519` (EdDSA, for signing and certifying), `:cv25519`
  (ECDH on Curve25519, for encrypting), `{:rsa, bits}`. Made now.
  """
  def generate(kind, created \\ System.os_time(:second))

  def generate(:ed25519, created) do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    body = <<4, created::32, 22>> <> <<9>> <> oid(:ed25519) <> Packet.mpi(<<0x40>> <> pub)
    finish(body, %{scalar: priv})
  end

  def generate(:cv25519, created) do
    {pub, priv} = :crypto.generate_key(:ecdh, :x25519)
    o = oid(:x25519)
    body = <<4, created::32, 18, byte_size(o)>> <> o <> Packet.mpi(<<0x40>> <> pub) <> <<3, 1, 8, 7>>
    finish(body, %{scalar: priv})
  end

  def generate({:rsa, bits}, created) do
    {:RSAPrivateKey, _, n, e, d, p, q, _, _, _, _} = :public_key.generate_key({:rsa, bits, 65_537})
    # (OpenPGP's u is p^-1 mod q, with p < q)
    {p, q} = if p < q, do: {p, q}, else: {q, p}
    u = :crypto.mod_pow(p, q - 2, q) |> :binary.decode_unsigned()
    body = <<4, created::32, 1>> <> Packet.mpi(n) <> Packet.mpi(e)
    finish(body, %{d: :binary.encode_unsigned(d), p: :binary.encode_unsigned(p), q: :binary.encode_unsigned(q), u: :binary.encode_unsigned(u)})
  end

  defp finish(body, secret) do
    {:ok, key} = parse_public(body)
    %{key | secret: %{usage: 0, key: secret}}
  end

  # -- naming -----------------------------------------------------------------------------------------------

  def fingerprint(%__MODULE__{fpr: f}), do: Base.encode16(f)
  def keyid(%__MODULE__{keyid: k}), do: Base.encode16(k)

  @doc "Its algorithm as gpg names it: rsa3072, ed25519, cv25519, nistp256..."
  def algo_name(%__MODULE__{algo: a, material: m}) do
    case {a, m} do
      {a, %{n: n}} when a in [1, 2, 3] -> "rsa#{bits(n)}"
      {_, %{curve: :ed25519}} -> "ed25519"
      {_, %{curve: :x25519}} -> "cv25519"
      {_, %{curve: :secp256r1}} -> "nistp256"
      {_, %{curve: :secp384r1}} -> "nistp384"
      {_, %{curve: :secp521r1}} -> "nistp521"
      _ -> "algo#{a}"
    end
  end

  defp bits(n), do: div(byte_size(n) * 8 + 7, 8) * 8 |> min(byte_size(n) * 8) |> round_bits()
  defp round_bits(b), do: Enum.find([1024, 2048, 3072, 4096, 8192], b, &(&1 >= b))

  def can_encrypt_algo?(%__MODULE__{algo: a}), do: a in [1, 2, 18, 25]
  def can_sign_algo?(%__MODULE__{algo: a}), do: a in [1, 3, 19, 22, 27]
end
