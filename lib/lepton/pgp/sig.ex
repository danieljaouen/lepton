defmodule Lepton.PGP.Sig do
  @moduledoc """
  OpenPGP signatures (version 4): what's hashed for each kind (a
  document, text with CRLF line ends, a user ID's certification, a
  subkey's binding), the subpackets (creation time, issuer, key flags,
  preferences, expiry), and making and checking them (RSA, EdDSA,
  Ed25519, ECDSA).
  """

  alias Lepton.PGP.{Crypto, Key, Packet}

  defstruct [:version, :type, :algo, :hash, :hashed, :unhashed, :left16, :values, :body, :subs]

  # signature types
  def binary, do: 0x00
  def text, do: 0x01
  def positive_cert, do: 0x13
  def subkey_binding, do: 0x18
  def primary_binding, do: 0x19
  def key_revocation, do: 0x20
  def subkey_revocation, do: 0x28

  @doc "A signature packet's body (tag 2)."
  def parse(<<4, type, algo, hash, hlen::16, hashed::binary-size(hlen), ulen::16, unhashed::binary-size(ulen), left16::binary-2, rest::binary>> = body) do
    values =
      case algo do
        a when a in [1, 3] -> elem(Packet.read_mpis(rest, 1), 0)
        a when a in [19, 22] -> elem(Packet.read_mpis(rest, 2), 0)
        27 -> [binary_part(rest, 0, 64)]
        _ -> []
      end

    {:ok, %__MODULE__{version: 4, type: type, algo: algo, hash: hash, hashed: hashed, unhashed: unhashed, left16: left16, values: values, body: body, subs: subpackets(hashed) ++ Enum.map(subpackets(unhashed), &{:unhashed, &1})}}
  rescue
    _ -> {:error, "a damaged signature"}
  end

  def parse(<<v, _::binary>>), do: {:error, "a version #{v} signature (this reads version 4)"}
  def parse(_), do: {:error, "a damaged signature"}

  # [{type, data}]
  defp subpackets(<<>>), do: []

  defp subpackets(bin) do
    {len, rest} =
      case bin do
        <<l, r::binary>> when l < 192 -> {l, r}
        <<l1, l2, r::binary>> when l1 < 255 -> {Bitwise.bsl(l1 - 192, 8) + l2 + 192, r}
        <<255, l::32, r::binary>> -> {l, r}
      end

    dlen = len - 1
    <<type, data::binary-size(^dlen), more::binary>> = rest
    [{Bitwise.band(type, 0x7F), data} | subpackets(more)]
  end

  @doc "A hashed subpacket's value (`type`), or nil."
  def sub(%__MODULE__{subs: subs}, type), do: Enum.find_value(subs, fn {t, d} -> if t == type, do: d end)
  def unhashed_sub(%__MODULE__{subs: subs}, type), do: Enum.find_value(subs, fn {:unhashed, {t, d}} -> if t == type, do: d; _ -> nil end)

  def created(s), do: (case sub(s, 2) do
    <<t::32>> -> t
    _ -> 0
  end)

  @doc "The issuer's key ID (subpacket 16) or fingerprint's (33)."
  def issuer(s) do
    case sub(s, 33) || unhashed_sub(s, 33) do
      <<4, fpr::binary-20>> -> binary_part(fpr, 12, 8)
      _ -> sub(s, 16) || unhashed_sub(s, 16)
    end
  end

  def key_flags(s), do: (case sub(s, 27) do
    <<f, _::binary>> -> f
    _ -> nil
  end)

  @doc "Seconds after the key's creation it expires (subpacket 9), or nil."
  def key_expiry(s), do: (case sub(s, 9) do
    <<t::32>> when t > 0 -> t
    _ -> nil
  end)

  # -- what's hashed -------------------------------------------------------------------------------------

  def key_bytes(%Key{body: b}), do: <<0x99, byte_size(b)::16>> <> b
  def uid_bytes(uid), do: <<0xB4, byte_size(uid)::32>> <> uid

  @doc "Text as a text signature hashes it: CRLF line ends, trailing blanks kept off nothing else."
  def canonical(text), do: String.replace(text, ~r/\r?\n/, "\r\n")

  defp trailer(type, algo, hash, hashed), do: <<4, type, algo, hash, byte_size(hashed)::16>> <> hashed <> <<4, 0xFF, 6 + byte_size(hashed)::32>>

  defp digest(hash, data, type, algo, hashed) do
    h = Crypto.hash(hash) || raise ArgumentError, "a signature made with a hash this doesn't have (#{hash})"
    :crypto.hash(h, [data, trailer(type, algo, hash, hashed)])
  end

  # -- checking -----------------------------------------------------------------------------------------------

  @doc "Does `sig` hold over `data` (already the bytes its type hashes) for `key`?"
  def verify(%__MODULE__{} = sig, %Key{} = key, data) do
    d = digest(sig.hash, data, sig.type, sig.algo, sig.hashed)

    binary_part(d, 0, 2) == sig.left16 and
      case {sig.algo, key.material, sig.values} do
        {a, %{n: n, e: e}, [s]} when a in [1, 3] ->
          :crypto.verify(:rsa, Crypto.hash(sig.hash), {:digest, d}, pad(s, byte_size(n)), [e, n])

        {22, %{curve: :ed25519, point: <<0x40, pub::binary-32>>}, [r, s]} ->
          :crypto.verify(:eddsa, :none, d, pad(r, 32) <> pad(s, 32), [pub, :ed25519])

        {27, %{point: <<0x40, pub::binary-32>>}, [rs]} ->
          :crypto.verify(:eddsa, :none, d, rs, [pub, :ed25519])

        {19, %{curve: curve, point: point}, [r, s]} ->
          der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", :binary.decode_unsigned(r), :binary.decode_unsigned(s)})
          :crypto.verify(:ecdsa, Crypto.hash(sig.hash), {:digest, d}, der, [point, curve])

        _ ->
          false
      end
  rescue
    _ -> false
  end

  defp pad(s, size) when byte_size(s) >= size, do: s
  defp pad(s, size), do: :binary.copy(<<0>>, size - byte_size(s)) <> s

  # -- making --------------------------------------------------------------------------------------------------

  @doc """
  A signature packet's body: `type` over `data` (the bytes it hashes) by
  `key` (unlocked). `subs`: extra hashed subpackets `[{type, data}]`
  (creation time and the issuer's fingerprint are added).
  """
  def sign(%Key{} = key, type, data, subs \\ [], now \\ System.os_time(:second)) do
    hash = if key.algo in [22, 27], do: 10, else: 8
    hashed = encode_subs([{2, <<now::32>>}, {33, <<4>> <> key.fpr}] ++ subs)
    unhashed = encode_subs([{16, key.keyid}])
    d = digest(hash, data, type, key.algo, hashed)

    values =
      case {key.algo, key.material, key.secret.key} do
        {a, %{n: n, e: e}, %{d: dd}} when a in [1, 3] ->
          Packet.mpi(:crypto.sign(:rsa, Crypto.hash(hash), {:digest, d}, [e, n, dd]))

        {22, _, %{scalar: s}} ->
          <<r::binary-32, ss::binary-32>> = :crypto.sign(:eddsa, :none, d, [s, :ed25519])
          Packet.mpi(r) <> Packet.mpi(ss)

        {27, _, %{scalar: s}} ->
          :crypto.sign(:eddsa, :none, d, [s, :ed25519])

        {19, %{curve: curve}, %{scalar: s}} ->
          der = :crypto.sign(:ecdsa, Crypto.hash(hash), {:digest, d}, [s, curve])
          {:"ECDSA-Sig-Value", r, ss} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
          Packet.mpi(r) <> Packet.mpi(ss)
      end

    <<4, type, key.algo, hash, byte_size(hashed)::16>> <> hashed <> <<byte_size(unhashed)::16>> <> unhashed <> binary_part(d, 0, 2) <> values
  end

  def encode_subs(subs), do: subs |> Enum.map(fn {t, d} -> Packet.len(byte_size(d) + 1) <> <<t>> <> d end) |> IO.iodata_to_binary()

  @doc "A user ID's self-signature subpackets: key flags, preferences, features (and expiry)."
  def self_subs(flags, expires \\ nil) do
    [
      {27, <<flags>>},
      {11, <<9, 8, 7>>},
      {21, <<10, 9, 8, 11>>},
      {22, <<2, 1, 0>>},
      {30, <<0x01>>},
      {23, <<0x80>>}
    ] ++ if(expires, do: [{9, <<expires::32>>}], else: [])
  end
end
