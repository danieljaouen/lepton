defmodule Lepton.PGP.Keyring do
  @moduledoc """
  Keys as gpg keeps them: transferable keys (a primary key, its user IDs
  and subkeys, each with its signatures), in `$GNUPGHOME` (by default
  `~/.gnupg`): `pubring.gpg` (public keys) and `secring.gpg` (secret
  keys, protected by their passphrases), GnuPG 1's files, concatenated
  OpenPGP packets.

  On import, self-signatures are checked: a user ID or subkey without a
  good one is left out, and a key with no user ID left isn't imported.
  """

  alias Lepton.PGP.{Key, Packet, Sig}

  defstruct [:primary, uids: [], subkeys: [], direct: [], secret: false]

  # -- files ------------------------------------------------------------------------------------------------

  def home(ctx) do
    case ctx.env["GNUPGHOME"] do
      dir when is_binary(dir) and dir != "" -> Path.expand(dir, ctx.cwd || "/")
      _ -> Path.join(Lepton.Ctx.home(ctx), ".gnupg")
    end
  end

  defp file(ctx, :public), do: Path.join(home(ctx), "pubring.gpg")
  defp file(ctx, :secret), do: Path.join(home(ctx), "secring.gpg")

  @doc "The keys in the keyring (`:public` or `:secret`)."
  def load(ctx, which) do
    case File.read(file(ctx, which)) do
      {:ok, bin} ->
        case Packet.parse(bin) do
          {:ok, pkts} -> group(pkts, false)
          _ -> []
        end

      _ ->
        []
    end
  end

  def save(ctx, which, keys) do
    dir = home(ctx)
    path = file(ctx, which)

    Lepton.Users.own_new_in_home(dir, fn ->
      File.mkdir_p(dir)
      File.chmod(dir, 0o700)
      tmp = path <> ".tmp"
      File.write!(tmp, keys |> Enum.map(&packets/1) |> IO.iodata_to_binary())
      File.chmod(tmp, 0o600)
      File.rename!(tmp, path)
    end)
  end

  # -- structure -----------------------------------------------------------------------------------------------

  @doc "Packets (`[{tag, body}]`) grouped into transferable keys, self-signatures checked when `check`."
  def group(pkts, check \\ true) do
    pkts
    |> Enum.chunk_while(nil, fn
      {tag, _} = p, acc when tag in [5, 6] -> if acc, do: {:cont, Enum.reverse(acc), [p]}, else: {:cont, [p]}
      p, nil -> _ = p; {:cont, nil}
      p, acc -> {:cont, [p | acc]}
    end, fn
      nil -> {:cont, nil}
      acc -> {:cont, Enum.reverse(acc), nil}
    end)
    |> Enum.flat_map(fn block ->
      case build(block) do
        {:ok, k} -> if check, do: List.wrap(checked(k)), else: [k]
        _ -> []
      end
    end)
  end

  defp build([{tag, body} | rest]) do
    secret = tag == 5
    parsed = if secret, do: Key.parse_secret(body), else: Key.parse_public(body)

    with {:ok, primary} <- parsed do
      k =
        Enum.reduce(rest, %__MODULE__{primary: primary, secret: secret}, fn
          {13, uid}, k -> %{k | uids: k.uids ++ [%{uid: uid, sigs: []}]}
          {tag, body}, k when tag in [7, 14] ->
            case if(tag == 7, do: Key.parse_secret(body), else: Key.parse_public(body)) do
              {:ok, sub} -> %{k | subkeys: k.subkeys ++ [%{key: sub, sigs: []}]}
              _ -> k
            end

          {2, body}, k ->
            case Sig.parse(body) do
              {:ok, s} -> attach(k, s)
              _ -> k
            end

          _, k ->
            k
        end)

      {:ok, k}
    end
  end

  # A signature belongs to what came last: a subkey, a user ID, or the key itself.
  defp attach(%{subkeys: [_ | _] = subs} = k, s), do: %{k | subkeys: List.update_at(subs, -1, &%{&1 | sigs: &1.sigs ++ [s]})}
  defp attach(%{uids: [_ | _] = uids} = k, s), do: %{k | uids: List.update_at(uids, -1, &%{&1 | sigs: &1.sigs ++ [s]})}
  defp attach(k, s), do: %{k | direct: k.direct ++ [s]}

  # Only what the key itself vouches for.
  defp checked(k) do
    p = k.primary

    uids =
      for u <- k.uids,
          sigs = Enum.filter(u.sigs, &(Sig.issuer(&1) == p.keyid and &1.type in 0x10..0x13 and Sig.verify(&1, p, Sig.key_bytes(p) <> Sig.uid_bytes(u.uid)))),
          sigs != [],
          do: %{u | sigs: sigs}

    subkeys =
      for s <- k.subkeys,
          sigs = Enum.filter(s.sigs, &(Sig.issuer(&1) == p.keyid and &1.type in [0x18, 0x28] and Sig.verify(&1, p, Sig.key_bytes(p) <> Sig.key_bytes(s.key)))),
          Enum.any?(sigs, &(&1.type == 0x18)),
          do: %{s | sigs: sigs}

    direct = Enum.filter(k.direct, &(Sig.issuer(&1) == p.keyid and &1.type in [0x1F, 0x20] and Sig.verify(&1, p, Sig.key_bytes(p))))
    if uids == [], do: nil, else: %{k | uids: uids, subkeys: subkeys, direct: direct}
  end

  @doc "The packets of a key, as `[{tag, body}]` (`public: true`: without its secret parts)."
  def packets(k, opts \\ []) do
    secret = k.secret and !opts[:public]
    pt = if secret, do: 5, else: 6
    st = if secret, do: 7, else: 14
    body = fn key -> if secret, do: key.raw || key.body, else: key.body end

    [{pt, body.(k.primary)}] ++
      Enum.map(k.direct, &{2, &1.body}) ++
      Enum.flat_map(k.uids, fn u -> [{13, u.uid} | Enum.map(u.sigs, &{2, &1.body})] end) ++
      Enum.flat_map(k.subkeys, fn s -> [{st, body.(s.key)} | Enum.map(s.sigs, &{2, &1.body})] end)
    |> Enum.map(fn {t, b} -> Packet.encode(t, b) end)
    |> IO.iodata_to_binary()
    |> then(fn bin -> if opts[:list], do: elem(Packet.parse(bin), 1), else: bin end)
  end

  # -- facts -----------------------------------------------------------------------------------------------------

  def primary_uid(k), do: List.first(k.uids) |> then(&(&1 && &1.uid))

  def revoked?(k), do: Enum.any?(k.direct, &(&1.type == 0x20))

  @doc "When it expires (Unix time), from its newest user ID self-signature, or nil."
  def expires(k) do
    sig = k.uids |> Enum.flat_map(& &1.sigs) |> Enum.max_by(&Sig.created/1, fn -> nil end)
    case sig && Sig.key_expiry(sig) do
      nil -> nil
      t -> k.primary.created + t
    end
  end

  def expired?(k, now \\ System.os_time(:second)), do: (e = expires(k)) != nil and e < now

  @doc "What a key (or subkey) is for: its key flags, else its algorithm's abilities."
  def usage(k, key \\ nil)

  def usage(k, nil) do
    flags = k.uids |> Enum.flat_map(& &1.sigs) |> Enum.find_value(&Sig.key_flags/1)
    flags || default_flags(k.primary)
  end

  def usage(_k, %{key: key, sigs: sigs}), do: Enum.find_value(sigs, &(&1.type == 0x18 && Sig.key_flags(&1))) || default_flags(key)

  defp default_flags(key), do: if(Key.can_sign_algo?(key), do: 0x03, else: 0) + if(Key.can_encrypt_algo?(key), do: 0x0C, else: 0)

  def subkey_revoked?(s), do: Enum.any?(s.sigs, &(&1.type == 0x28))

  def subkey_expired?(s, now \\ System.os_time(:second)) do
    case Enum.find_value(s.sigs, &(&1.type == 0x18 && Sig.key_expiry(&1))) do
      nil -> false
      t -> s.key.created + t < now
    end
  end

  @doc "The key to encrypt to: its newest usable encryption subkey, else the primary key if it can."
  def encryption_key(k) do
    subs =
      for s <- k.subkeys, Bitwise.band(usage(k, s), 0x0C) != 0, not subkey_revoked?(s), not subkey_expired?(s), Key.can_encrypt_algo?(s.key), do: s.key

    case Enum.max_by(subs, & &1.created, fn -> nil end) do
      nil -> if Bitwise.band(usage(k), 0x0C) != 0 and Key.can_encrypt_algo?(k.primary), do: k.primary
      key -> key
    end
  end

  @doc "The key to sign with: the primary key, if it can sign (else none)."
  def signing_key(k), do: if(Bitwise.band(usage(k), 0x02) != 0 and Key.can_sign_algo?(k.primary), do: k.primary)

  @doc "Every key (primary and subkeys) of `k`."
  def all_keys(k), do: [k.primary | Enum.map(k.subkeys, & &1.key)]

  # -- finding ---------------------------------------------------------------------------------------------

  @doc """
  The keys `query` names: a fingerprint, a key ID (long or short, `0x`
  allowed), `<email>`, or part of a user ID (case aside).
  """
  def find(keys, query) do
    q = query |> String.trim() |> String.trim_leading("0x") |> String.trim_leading("0X")
    hex = String.upcase(String.replace(q, " ", ""))

    cond do
      hex =~ ~r/^[0-9A-F]{40}$/ -> Enum.filter(keys, fn k -> Enum.any?(all_keys(k), &(Key.fingerprint(&1) == hex)) end)
      hex =~ ~r/^[0-9A-F]{16}$/ -> Enum.filter(keys, fn k -> Enum.any?(all_keys(k), &(Key.keyid(&1) == hex)) end)
      hex =~ ~r/^[0-9A-F]{8}$/ -> Enum.filter(keys, fn k -> Enum.any?(all_keys(k), &String.ends_with?(Key.keyid(&1), hex)) end)
      String.starts_with?(q, "<") -> Enum.filter(keys, fn k -> Enum.any?(k.uids, &String.contains?(String.downcase(&1.uid), String.downcase(q))) end)
      true -> Enum.filter(keys, fn k -> Enum.any?(k.uids, &String.contains?(String.downcase(&1.uid), String.downcase(q))) end)
    end
  end

  @doc "The key whose primary or subkey has this key ID (8 bytes)."
  def by_keyid(keys, keyid), do: Enum.find_value(keys, fn k -> Enum.find_value(all_keys(k), &(&1.keyid == keyid && {k, &1})) end)

  # -- merging -------------------------------------------------------------------------------------------------------

  @doc "Add `new` to `keys` (the same key: its new user IDs, subkeys and signatures joined)."
  def merge(keys, new) do
    case Enum.split_with(keys, &(&1.primary.fpr == new.primary.fpr)) do
      {[], rest} ->
        {rest ++ [new], :new}

      {[old], _rest} ->
        uids =
          Enum.reduce(new.uids, old.uids, fn u, acc ->
            case Enum.find_index(acc, &(&1.uid == u.uid)) do
              nil -> acc ++ [u]
              i -> List.update_at(acc, i, &%{&1 | sigs: Enum.uniq_by(&1.sigs ++ u.sigs, fn s -> s.body end)})
            end
          end)

        subkeys =
          Enum.reduce(new.subkeys, old.subkeys, fn s, acc ->
            case Enum.find_index(acc, &(&1.key.fpr == s.key.fpr)) do
              nil -> acc ++ [s]
              i -> List.update_at(acc, i, &%{&1 | sigs: Enum.uniq_by(&1.sigs ++ s.sigs, fn x -> x.body end)})
            end
          end)

        direct = Enum.uniq_by(old.direct ++ new.direct, & &1.body)
        merged = %{old | uids: uids, subkeys: subkeys, direct: direct}
        changed = merged != old
        {Enum.map(keys, &(if &1.primary.fpr == new.primary.fpr, do: merged, else: &1)), if(changed, do: :changed, else: :unchanged)}
    end
  end
end
