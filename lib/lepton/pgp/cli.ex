defmodule Lepton.PGP.CLI do
  @moduledoc """
  `gpg`: GnuPG's command line over `Lepton.PGP`: keys (generate, list,
  import, export, delete, fetch from keys.openpgp.org, change a
  passphrase), encrypting and decrypting (to keys, with a passphrase),
  signing and verifying (inline, detached, clearsigned), with gpg's
  options, file naming (`FILE.gpg`, `.asc`, `.sig`), messages and exit
  statuses (0, 1 for a bad signature, 2 for an error).
  """

  alias Lepton.{IO, TTY}
  alias Lepton.PGP.{Key, Keyring, Message, Packet, Sig}

  @commands %{
    "--gen-key" => :gen_key, "--generate-key" => :gen_key, "--full-gen-key" => :gen_key, "--full-generate-key" => :gen_key,
    "--quick-gen-key" => :quick_gen_key, "--quick-generate-key" => :quick_gen_key,
    "-k" => :list, "--list-keys" => :list, "--list-public-keys" => :list, "--fingerprint" => :list,
    "-K" => :list_secret, "--list-secret-keys" => :list_secret,
    "--import" => :import, "--export" => :export, "--export-secret-keys" => :export_secret,
    "--delete-key" => :delete, "--delete-keys" => :delete, "--delete-secret-key" => :delete_secret, "--delete-secret-keys" => :delete_secret,
    "--delete-secret-and-public-key" => :delete_both, "--delete-secret-and-public-keys" => :delete_both,
    "-e" => :encrypt, "--encrypt" => :encrypt, "-c" => :symmetric, "--symmetric" => :symmetric,
    "-s" => :sign, "--sign" => :sign, "--clearsign" => :clearsign, "--clear-sign" => :clearsign,
    "-b" => :detach, "--detach-sign" => :detach, "-d" => :decrypt, "--decrypt" => :decrypt,
    "--verify" => :verify, "--passwd" => :passwd, "--change-passphrase" => :passwd,
    "--recv-keys" => :recv, "--receive-keys" => :recv, "--locate-keys" => :locate, "--locate-external-keys" => :locate,
    "--version" => :version, "-h" => :help, "--help" => :help
  }

  @with_arg ~w(-r --recipient -u --local-user --default-key -o --output --passphrase --passphrase-file --passphrase-fd --homedir --trust-model --pinentry-mode --keyserver --compress-algo -z --cipher-algo --digest-algo --status-fd --logger-fd --default-recipient --hidden-recipient -R)
  @ignored ~w(--batch --no-tty --quiet -q -v --verbose --always-trust --no-default-keyring --use-agent --no-use-agent --no-greeting --no-permission-warning --with-fingerprint --with-subkey-fingerprint --with-keygrip --keyid-format --with-colons --no-auto-key-locate --no-auto-key-retrieve --sign-with --throw-keyids --no-emit-version --expert --openpgp --rfc4880)

  def run(args, ctx) do
    case parse(args, %{cmds: [], rest: [], armor: false, output: nil, recipients: [], signer: nil, passphrase: nil, yes: false, batch: false, text: false}) do
      {:error, msg} ->
        IO.err(ctx, "gpg: " <> msg)
        2

      o ->
        ctx = if o[:homedir], do: %{ctx | env: Map.put(ctx.env, "GNUPGHOME", o.homedir)}, else: ctx
        o = Map.put(o, :ctx, ctx)

        try do
          dispatch(o)
        catch
          {:fail, msg} -> IO.err(ctx, "gpg: " <> msg); 2
        end
    end
  end

  defp fail(msg), do: throw({:fail, msg})

  # -- options ----------------------------------------------------------------------------------------------

  defp parse([], o), do: o

  defp parse(["--" | rest], o), do: %{o | rest: o.rest ++ rest}

  defp parse(["--" <> _ = flag | rest], o) do
    {flag, inline} = case String.split(flag, "=", parts: 2) do
      [f, v] -> {f, v}
      [f] -> {f, nil}
    end

    cond do
      Map.has_key?(@commands, flag) -> parse(rest, %{o | cmds: o.cmds ++ [@commands[flag]]})
      flag in @with_arg -> with_arg(flag, inline, rest, o)
      flag in ["--armor", "--armour"] -> parse(rest, %{o | armor: true})
      flag in ["--textmode"] -> parse(rest, %{o | text: true})
      flag == "--yes" -> parse(rest, %{o | yes: true})
      flag == "--batch" -> parse(rest, %{o | batch: true})
      flag in @ignored -> parse(rest, o)
      true -> {:error, "invalid option \"#{flag}\""}
    end
  end

  # Short options, alone or together (-sea, -ao file).
  defp parse(["-" <> shorts = arg | rest], o) when shorts != "" do
    if Map.has_key?(@commands, arg) or arg in @with_arg do
      if arg in @with_arg, do: with_arg(arg, nil, rest, o), else: parse(rest, %{o | cmds: o.cmds ++ [@commands[arg]]})
    else
      case String.graphemes(shorts) do
        [_] -> short(arg, rest, o)
        letters -> parse(Enum.map(letters, &("-" <> &1)) ++ rest, o)
      end
    end
  end

  defp parse([arg | rest], o), do: parse(rest, %{o | rest: o.rest ++ [arg]})

  defp short("-a", rest, o), do: parse(rest, %{o | armor: true})
  defp short("-t", rest, o), do: parse(rest, %{o | text: true})
  defp short(f, rest, o) when f in ["-q", "-v", "-n"], do: parse(rest, o)
  defp short(f, _rest, _o), do: {:error, "invalid option \"#{f}\""}

  defp with_arg(flag, nil, [v | rest], o), do: with_arg(flag, v, rest, o)
  defp with_arg(flag, nil, [], _o), do: {:error, "option \"#{flag}\" needs an argument"}

  defp with_arg(flag, v, rest, o) do
    o =
      case flag do
        f when f in ["-r", "--recipient", "-R", "--hidden-recipient", "--default-recipient"] -> %{o | recipients: o.recipients ++ [v]}
        f when f in ["-u", "--local-user", "--default-key"] -> %{o | signer: v}
        f when f in ["-o", "--output"] -> %{o | output: v}
        "--passphrase" -> %{o | passphrase: v}
        "--passphrase-file" -> Map.put(o, :passphrase_file, v)
        "--passphrase-fd" -> Map.put(o, :passphrase_fd, v)
        "--homedir" -> Map.put(o, :homedir, v)
        _ -> o
      end

    parse(rest, o)
  end

  defp dispatch(o) do
    cmds = Enum.uniq(o.cmds)

    case cmds do
      [] -> if o.rest == [], do: dispatch(%{o | cmds: [:help]}), else: dispatch(%{o | cmds: [:decrypt]})
      [:version] -> version(o)
      [:help] -> help(o)
      [:gen_key] -> gen_key(o)
      [:quick_gen_key] -> quick_gen_key(o)
      [:list] -> list(o, :public)
      [:list_secret] -> list(o, :secret)
      [:import] -> import_cmd(o)
      [:export] -> export(o, :public)
      [:export_secret] -> export(o, :secret)
      [:delete] -> delete(o, :public)
      [:delete_secret] -> delete(o, :secret)
      [:delete_both] -> delete(o, :both)
      [:passwd] -> passwd(o)
      [:recv] -> recv(o, :fpr)
      [:locate] -> recv(o, :email)
      [:decrypt] -> decrypt(o)
      [:verify] -> verify(o)
      [:clearsign] -> clearsign(o)
      [:detach] -> detach(o)
      cs -> combined(o, MapSet.new(cs))
    end
  end

  # -e, -c, -s and their combinations (-se, -ce, -sc).
  defp combined(o, cs) do
    unless MapSet.subset?(cs, MapSet.new([:encrypt, :symmetric, :sign])), do: fail("conflicting commands")
    encrypt_or_sign(o, MapSet.member?(cs, :encrypt), MapSet.member?(cs, :symmetric), MapSet.member?(cs, :sign))
  end

  # -- input and output ----------------------------------------------------------------------------------------

  defp input(o) do
    case o.rest do
      [] -> {"", IO.read_all(o.ctx.stdin)}
      ["-"] -> {"", IO.read_all(o.ctx.stdin)}
      [f | _] ->
        case File.read(Lepton.Ctx.path(o.ctx, f)) do
          {:ok, d} -> {f, d}
          {:error, r} -> fail("can't open '#{f}': #{:file.format_error(r)}")
        end
    end
  end

  # Where output goes: -o, else FILE + suffix (a file given), else standard output.
  defp output(o, name, suffix, data) do
    target = o.output || if(name != "" and suffix, do: name <> suffix)

    case target do
      nil ->
        IO.write(o.ctx, data)

      "-" ->
        IO.write(o.ctx, data)

      path ->
        full = Lepton.Ctx.path(o.ctx, path)

        if File.exists?(full) and not o.yes and not confirm(o, "File '#{path}' exists. Overwrite? (y/N) ") do
          fail("'#{path}' exists (--yes overwrites it)")
        end

        Lepton.Users.own_new(o.ctx, full, fn -> File.write!(full, data) end)
    end
  end

  defp armored(o, type, bin), do: if(o.armor, do: Packet.armor(type, bin), else: bin)

  defp tty(o), do: (t = o.ctx.tty) && is_pid(t) && Process.alive?(t) && t

  defp confirm(o, prompt) do
    case !o.batch && tty(o) do
      false -> false
      nil -> false
      t ->
        TTY.write(t, prompt)
        line(o, t, true) |> String.trim() |> String.downcase() |> String.starts_with?("y")
    end
  end

  # A line from the terminal (`echo` false: a passphrase, not shown).
  defp line(_o, tty, echo) do
    TTY.set_mode(tty, :raw)

    try do
      read_line(tty, "", echo)
    after
      TTY.set_mode(tty, :cooked)
      TTY.write(tty, "\r\n")
    end
  end

  defp read_line(tty, acc, echo) do
    case TTY.read_key(tty) do
      "RET" -> acc
      k when k in ["C-c", "C-d"] -> fail("cancelled")
      "DEL" -> if(echo and acc != "", do: TTY.write(tty, "\b \b")); read_line(tty, String.slice(acc, 0..-2//1), echo)
      "SPC" -> if(echo, do: TTY.write(tty, " ")); read_line(tty, acc <> " ", echo)
      {:paste, p} -> if(echo, do: TTY.write(tty, p)); read_line(tty, acc <> p, echo)
      k when is_binary(k) -> if String.length(k) == 1, do: (if(echo, do: TTY.write(tty, k)); read_line(tty, acc <> k, echo)), else: read_line(tty, acc, echo)
      _ -> read_line(tty, acc, echo)
    end
  end

  # The passphrase: --passphrase, --passphrase-file, --passphrase-fd 0, else asked.
  defp passphrase(o, what) do
    cond do
      o.passphrase != nil -> {:ok, o.passphrase}
      o[:passphrase_file] -> {:ok, File.read!(Lepton.Ctx.path(o.ctx, o.passphrase_file)) |> String.split("\n") |> hd()}
      o[:passphrase_fd] == "0" -> {:ok, o.ctx.stdin |> IO.read_all() |> String.split("\n") |> hd()}
      t = !o.batch && tty(o) -> TTY.write(t, "Passphrase for #{what}: "); {:ok, line(o, t, false)}
      true -> :error
    end
  end

  defp passphrase_fun(o) do
    cache = :ets.new(:pass, [:set])

    fn what ->
      case :ets.lookup(cache, what) do
        [{_, p}] -> {:ok, p}
        [] ->
          r = passphrase(o, what)
          with {:ok, p} <- r, do: :ets.insert(cache, {what, p})
          r
      end
    end
  end

  # -- keys -------------------------------------------------------------------------------------------------

  defp pub(o), do: Keyring.load(o.ctx, :public)
  defp sec(o), do: Keyring.load(o.ctx, :secret)

  defp one(keys, query, what) do
    case Keyring.find(keys, query) do
      [k] -> k
      [] -> fail("#{what} \"#{query}\": No #{if what == "secret key", do: "secret key", else: "public key"}")
      [k | _] -> k
    end
  end

  defp signer(o) do
    secret = sec(o)

    k =
      cond do
        o.signer -> one(secret, o.signer, "secret key")
        secret != [] -> hd(secret)
        true -> fail("no default secret key: No secret key (gpg --quick-gen-key makes one)")
      end

    key = Keyring.signing_key(k) || fail("#{Keyring.primary_uid(k)}: the key can't sign")
    unlock!(o, k, key)
  end

  defp unlock!(o, k, key) do
    if Key.locked?(key) do
      case passphrase(o, "\"#{Keyring.primary_uid(k)}\" (#{Key.algo_name(key)}, ID #{Key.keyid(key)})") do
        {:ok, p} -> case Key.unlock(key, p) do
            {:ok, key} -> key
            {:error, why} -> fail(why)
          end

        :error -> fail("a passphrase is needed (--passphrase, or a terminal)")
      end
    else
      key
    end
  end

  # -- generating keys ------------------------------------------------------------------------------------------

  defp gen_key(o) do
    t = tty(o) || fail("--gen-key asks questions: use a terminal, or --quick-gen-key \"Name <email>\"")
    IO.puts(o.ctx, "Lepton's gpg: an Ed25519 key for signing, with a Curve25519 subkey for encryption.\n")
    TTY.write(t, "Real name: ")
    name = String.trim(line(o, t, true))
    TTY.write(t, "Email address: ")
    email = String.trim(line(o, t, true))
    uid = Enum.join(Enum.reject([name, if(email != "", do: "<#{email}>")], &(&1 in [nil, ""])), " ")
    if uid == "", do: fail("a name or an email address is needed")
    make_key(o, uid, :ed25519, nil)
  end

  defp quick_gen_key(o) do
    case o.rest do
      [uid | more] ->
        algo = case Enum.at(more, 0) do
          a when a in [nil, "default", "future-default", "ed25519", "ed25519/cert,sign+cv25519/encr"] -> :ed25519
          "rsa" -> {:rsa, 3072}
          "rsa" <> bits -> {:rsa, String.to_integer(bits)}
          other -> fail("algorithm \"#{other}\" (ed25519, rsa2048, rsa3072 or rsa4096)")
        end

        expire = expiry(Enum.at(more, 2))
        make_key(o, uid, algo, expire)

      [] ->
        fail("usage: gpg --quick-gen-key USER-ID [ALGO [USAGE [EXPIRE]]]")
    end
  end

  # never, 0, Nd/w/m/y, or a date (YYYY-MM-DD); default: 3 years, as gpg.
  defp expiry(nil), do: 3 * 365 * 86400
  defp expiry("default"), do: 3 * 365 * 86400
  defp expiry(e) when e in ["never", "none", "0", "-"], do: nil

  defp expiry(e) do
    case Regex.run(~r/^(\d+)([dwmy]?)$/, e, capture: :all_but_first) do
      [n, u] -> String.to_integer(n) * %{"" => 86400, "d" => 86400, "w" => 7 * 86400, "m" => 30 * 86400, "y" => 365 * 86400}[u]
      _ ->
        case Date.from_iso8601(e) do
          {:ok, d} -> max(DateTime.to_unix(DateTime.new!(d, ~T[00:00:00])) - System.os_time(:second), 86400)
          _ -> fail("invalid expiration \"#{e}\" (never, 2y, 6m, 30d or YYYY-MM-DD)")
        end
    end
  end

  defp make_key(o, uid, algo, expire) do
    if Keyring.find(pub(o), "<" <> (Regex.run(~r/<([^>]+)>/, uid, capture: :all_but_first) |> then(&(&1 && hd(&1)) || uid)) <> ">") != [] and String.contains?(uid, "<") and not o.yes do
      unless confirm(o, "A key for \"#{uid}\" already exists. Make another? (y/N) "), do: fail("a key for \"#{uid}\" already exists (--yes makes another)")
    end

    pass =
      cond do
        o.passphrase != nil -> o.passphrase
        t = !o.batch && tty(o) ->
          TTY.write(t, "Passphrase to protect the new key (empty: none): ")
          p1 = line(o, t, false)
          TTY.write(t, "Repeat it: ")
          p2 = line(o, t, false)
          if p1 != p2, do: fail("the passphrases don't match")
          p1

        true -> ""
      end

    now = System.os_time(:second)
    {primary, sub} =
      case algo do
        :ed25519 -> {Key.generate(:ed25519, now), Key.generate(:cv25519, now)}
        {:rsa, bits} -> {Key.generate({:rsa, bits}, now), Key.generate({:rsa, bits}, now)}
      end

    cert = Sig.sign(primary, Sig.positive_cert(), Sig.key_bytes(primary) <> Sig.uid_bytes(uid), Sig.self_subs(0x03, expire) ++ [{25, <<1>>}], now)
    bind = Sig.sign(primary, Sig.subkey_binding(), Sig.key_bytes(primary) <> Sig.key_bytes(sub), [{27, <<0x0C>>}] ++ if(expire, do: [{9, <<expire::32>>}], else: []), now)
    {:ok, cert} = Sig.parse(cert)
    {:ok, bind} = Sig.parse(bind)

    primary = %{primary | raw: Key.secret_body(primary, pass)}
    sub = %{sub | raw: Key.secret_body(sub, pass)}
    k = %Keyring{primary: primary, uids: [%{uid: uid, sigs: [cert]}], subkeys: [%{key: sub, sigs: [bind]}], secret: true}

    {pubs, _} = Keyring.merge(pub(o), %{k | secret: false})
    {secs, _} = Keyring.merge(sec(o), k)
    Keyring.save(o.ctx, :public, pubs)
    Keyring.save(o.ctx, :secret, secs)
    IO.err(o.ctx, "gpg: key #{Key.keyid(primary)} marked as ultimately trusted")
    IO.puts(o.ctx, "public and secret key created and signed.\n")
    print_key(o, k, :public, MapSet.new([primary.fpr]))
    0
  end

  # -- listing -------------------------------------------------------------------------------------------------

  defp list(o, which) do
    keys = if which == :secret, do: sec(o), else: pub(o)
    keys = if o.rest == [], do: keys, else: Enum.flat_map(o.rest, &Keyring.find(keys, &1)) |> Enum.uniq_by(& &1.primary.fpr)
    secret_fprs = MapSet.new(sec(o), & &1.primary.fpr)

    if keys != [] and o.rest == [] do
      path = Path.join(Keyring.home(o.ctx), if(which == :secret, do: "secring.gpg", else: "pubring.gpg"))
      IO.puts(o.ctx, Lepton.Ctx.tildify(o.ctx, path) <> "\n" <> String.duplicate("-", String.length(Lepton.Ctx.tildify(o.ctx, path))))
    end

    for k <- keys, do: print_key(o, k, which, secret_fprs)
    if keys == [] and o.rest != [], do: (IO.err(o.ctx, "gpg: error reading key: No #{if which == :secret, do: "secret", else: "public"} key"); 2), else: 0
  end

  defp print_key(o, k, which, secret_fprs) do
    p = k.primary
    exp = Keyring.expires(k)
    status = cond do
      Keyring.revoked?(k) -> " [revoked]"
      Keyring.expired?(k) -> " [expired: #{date(exp)}]"
      exp -> " [expires: #{date(exp)}]"
      true -> ""
    end

    trust = cond do
      Keyring.revoked?(k) -> "revoked"
      Keyring.expired?(k) -> "expired"
      MapSet.member?(secret_fprs, p.fpr) -> "ultimate"
      true -> "unknown"
    end

    IO.puts(o.ctx, "#{if which == :secret, do: "sec", else: "pub"}   #{Key.algo_name(p)} #{date(p.created)} [#{flags(Keyring.usage(k))}]#{status}")
    IO.puts(o.ctx, "      " <> Key.fingerprint(p))
    for u <- k.uids, do: IO.puts(o.ctx, "uid           [#{String.pad_leading(trust, 8)}] #{u.uid}")

    for s <- k.subkeys do
      sexp = Enum.find_value(s.sigs, &(&1.type == 0x18 && Sig.key_expiry(&1)))
      tag = cond do
        Keyring.subkey_revoked?(s) -> " [revoked]"
        sexp && s.key.created + sexp < System.os_time(:second) -> " [expired: #{date(s.key.created + sexp)}]"
        sexp -> " [expires: #{date(s.key.created + sexp)}]"
        true -> ""
      end

      IO.puts(o.ctx, "#{if which == :secret, do: "ssb", else: "sub"}   #{Key.algo_name(s.key)} #{date(s.key.created)} [#{flags(Keyring.usage(k, s))}]#{tag}")
    end

    IO.puts(o.ctx, "")
  end

  defp flags(f) do
    import Bitwise
    Enum.join(for {bit, l} <- [{0x02, "S"}, {0x01, "C"}, {0x0C, "E"}, {0x20, "A"}], (f &&& bit) != 0, do: l)
  end

  defp date(nil), do: ""
  defp date(t), do: t |> DateTime.from_unix!() |> DateTime.to_date() |> Date.to_iso8601()

  # -- import and export ------------------------------------------------------------------------------------------

  defp import_cmd(o) do
    datas = if o.rest == [], do: [IO.read_all(o.ctx.stdin)], else: Enum.map(o.rest, &File.read!(Lepton.Ctx.path(o.ctx, &1)))
    import_data(o, Enum.join(datas))
  end

  defp import_data(o, data) do
    bin = case Packet.unarmor(data) do
      {:ok, b} -> b
      {:error, why} -> fail(why)
    end

    pkts = case Packet.parse(bin) do
      {:ok, p} -> p
      {:error, why} -> fail("no valid OpenPGP data found (#{why})")
    end

    found = Keyring.group(pkts)
    if found == [], do: fail("no valid OpenPGP data found")

    {pubs, secs, n_new, n_unchanged, n_secret} =
      Enum.reduce(found, {pub(o), sec(o), 0, 0, 0}, fn k, {pubs, secs, nn, nu, ns} ->
        public = %{k | secret: false}
        {pubs, how} = Keyring.merge(pubs, public)
        {secs, ns} = if k.secret, do: {elem(Keyring.merge(secs, k), 0), ns + 1}, else: {secs, ns}
        label = Keyring.primary_uid(k)

        case how do
          :new -> IO.err(o.ctx, "gpg: key #{Key.keyid(k.primary)}: public key \"#{label}\" imported")
          :changed -> IO.err(o.ctx, "gpg: key #{Key.keyid(k.primary)}: \"#{label}\" updated")
          :unchanged -> IO.err(o.ctx, "gpg: key #{Key.keyid(k.primary)}: \"#{label}\" not changed")
        end

        if k.secret, do: IO.err(o.ctx, "gpg: key #{Key.keyid(k.primary)}: secret key imported")
        {pubs, secs, nn + if(how == :new, do: 1, else: 0), nu + if(how == :unchanged, do: 1, else: 0), ns}
      end)

    Keyring.save(o.ctx, :public, pubs)
    if n_secret > 0, do: Keyring.save(o.ctx, :secret, secs)
    IO.err(o.ctx, "gpg: Total number processed: #{length(found)}")
    if n_new > 0, do: IO.err(o.ctx, "gpg:               imported: #{n_new}")
    if n_unchanged > 0, do: IO.err(o.ctx, "gpg:              unchanged: #{n_unchanged}")
    if n_secret > 0, do: IO.err(o.ctx, "gpg:       secret keys read: #{n_secret}")
    0
  end

  defp export(o, which) do
    keys = if which == :secret, do: sec(o), else: pub(o)
    keys = if o.rest == [], do: keys, else: Enum.flat_map(o.rest, &Keyring.find(keys, &1)) |> Enum.uniq_by(& &1.primary.fpr)

    if keys == [] do
      IO.err(o.ctx, "gpg: WARNING: nothing exported")
      2
    else
      bin = keys |> Enum.map(&Keyring.packets/1) |> :erlang.iolist_to_binary()
      output(o, "", nil, armored(o, if(which == :secret, do: "PRIVATE KEY BLOCK", else: "PUBLIC KEY BLOCK"), bin))
      0
    end
  end

  defp delete(o, which) do
    if o.rest == [], do: fail("usage: gpg --delete-keys NAME")

    Enum.reduce(o.rest, 0, fn q, status ->
      pubs = pub(o)
      secs = sec(o)
      targets = Keyring.find(if(which == :secret, do: secs, else: pubs), q)

      case targets do
        [] ->
          IO.err(o.ctx, "gpg: key \"#{q}\" not found: Not found")
          2

        [k | _] ->
          has_secret = Enum.any?(secs, &(&1.primary.fpr == k.primary.fpr))

          cond do
            which == :public and has_secret ->
              IO.err(o.ctx, "gpg: there is a secret key for public key \"#{q}\"!\ngpg: use option \"--delete-secret-keys\" to delete it first.")
              2

            not o.yes and not confirm(o, "Delete #{if which == :public, do: "this key", else: "the secret key"} (#{Key.keyid(k.primary)} #{Keyring.primary_uid(k)}) from the keyring? (y/N) ") ->
              IO.err(o.ctx, "gpg: not deleted (--yes deletes without asking)")
              2

            true ->
              if which in [:secret, :both], do: Keyring.save(o.ctx, :secret, Enum.reject(secs, &(&1.primary.fpr == k.primary.fpr)))
              if which in [:public, :both], do: Keyring.save(o.ctx, :public, Enum.reject(pubs, &(&1.primary.fpr == k.primary.fpr)))
              status
          end
      end
    end)
  end

  defp passwd(o) do
    [q | _] = o.rest ++ [nil]
    if q == nil, do: fail("usage: gpg --passwd USER-ID")
    secs = sec(o)
    k = one(secs, q, "secret key")
    keys = Enum.map(Keyring.all_keys(k), &unlock!(o, k, &1))

    t = tty(o)
    new =
      cond do
        o[:new_passphrase] -> o.new_passphrase
        t && !o.batch ->
          TTY.write(t, "New passphrase (empty: none): ")
          p1 = line(o, t, false)
          TTY.write(t, "Repeat it: ")
          if p1 != line(o, t, false), do: fail("the passphrases don't match")
          p1

        true -> fail("--passwd asks for the new passphrase: use a terminal")
      end

    [primary | subs] = Enum.map(keys, &%{&1 | raw: Key.secret_body(&1, new)})
    k = %{k | primary: primary, subkeys: Enum.zip_with(k.subkeys, subs, fn s, key -> %{s | key: key} end)}
    Keyring.save(o.ctx, :secret, Enum.map(secs, &(if &1.primary.fpr == k.primary.fpr, do: k, else: &1)))
    IO.err(o.ctx, "gpg: passphrase changed")
    0
  end

  # keys.openpgp.org (VKS): by fingerprint, key ID or email.
  defp recv(o, how) do
    if o.rest == [], do: fail("usage: gpg --recv-keys FINGERPRINT (or --locate-keys EMAIL)")

    Enum.reduce(o.rest, 0, fn q, status ->
      path =
        case how do
          :email -> "by-email/" <> URI.encode_www_form(q |> String.trim_leading("<") |> String.trim_trailing(">"))
          :fpr ->
            hex = q |> String.trim_leading("0x") |> String.replace(" ", "") |> String.upcase()
            if byte_size(hex) == 40, do: "by-fingerprint/" <> hex, else: "by-keyid/" <> hex
        end

      case Lepton.Alpine.get("https://keys.openpgp.org/vks/v1/" <> path) do
        {:ok, body} -> import_data(o, body); status
        {:error, {:http, 404, _}} -> IO.err(o.ctx, "gpg: keyserver: no key for \"#{q}\" on keys.openpgp.org"); 2
        {:error, why} -> IO.err(o.ctx, "gpg: keyserver receive failed: #{inspect(why)}"); 2
      end
    end)
  end

  # -- encrypting and signing ---------------------------------------------------------------------------------------

  defp encrypt_or_sign(o, encrypt?, symmetric?, sign?) do
    {name, data} = input(o)

    recipients =
      if encrypt? do
        if o.recipients == [], do: fail("no recipients (-r NAME)")
        keys = pub(o)

        Enum.map(o.recipients, fn r ->
          k = one(keys, r, "public key")
          if Keyring.revoked?(k), do: fail("\"#{r}\": the key is revoked")
          if Keyring.expired?(k), do: fail("\"#{r}\": the key expired on #{date(Keyring.expires(k))}")
          Keyring.encryption_key(k) || fail("\"#{r}\": the key can't encrypt (no usable encryption subkey)")
        end)
      else
        []
      end

    pass =
      if symmetric? do
        cond do
          o.passphrase != nil -> o.passphrase
          o[:passphrase_file] -> passphrase(o, "") |> elem(1)
          t = !o.batch && tty(o) ->
            TTY.write(t, "Passphrase to encrypt with: ")
            p1 = line(o, t, false)
            TTY.write(t, "Repeat it: ")
            if p1 != line(o, t, false), do: fail("the passphrases don't match")
            p1

          true -> fail("a passphrase is needed (--passphrase, or a terminal)")
        end
      end

    base = Path.basename(name)
    inner = if sign?, do: Message.sign_inline(data, signer(o), base, o.text), else: Message.literal(data, base, if(o.text, do: ?t, else: ?b))

    {bin, type} =
      if encrypt? or symmetric?, do: {Message.encrypt(inner, recipients, pass), "MESSAGE"}, else: {inner, "MESSAGE"}

    output(o, name, if(o.armor, do: ".asc", else: ".gpg"), armored(o, type, bin))
    0
  end

  defp clearsign(o) do
    {name, data} = input(o)
    output(o, name, ".asc", Message.clearsign(data, signer(o)))
    0
  end

  defp detach(o) do
    {name, data} = input(o)
    sig = Message.detach_sign(data, signer(o), o.text)
    output(o, name, if(o.armor, do: ".asc", else: ".sig"), armored(o, "SIGNATURE", sig))
    0
  end

  # -- decrypting and verifying ---------------------------------------------------------------------------------------

  defp decrypt(o) do
    {_name, data} = input(o)

    if String.contains?(data, "-----BEGIN PGP SIGNED MESSAGE-----") do
      verify_clearsigned(o, data, true)
    else
      bin = case Packet.unarmor(data) do
        {:ok, b} -> b
        {:error, why} -> fail(why)
      end

      case Message.read(bin, secret: sec(o), public: pub(o), passphrase: passphrase_fun(o)) do
        {:ok, r} ->
          report_encryption(o, r)
          status = report_sigs(o, r.sigs)
          output(o, "", nil, r.data)
          status

        {:error, why} ->
          fail("decryption failed: #{why}")
      end
    end
  end

  defp report_encryption(o, %{encrypted: {:key, k, key}}) do
    IO.err(o.ctx, "gpg: encrypted with #{Key.algo_name(key)} key, ID #{Key.keyid(key)}, created #{date(key.created)}\n      \"#{Keyring.primary_uid(k)}\"")
  end

  defp report_encryption(o, %{encrypted: :passphrase}), do: IO.err(o.ctx, "gpg: AES256.CFB encrypted data (a passphrase)")
  defp report_encryption(_, _), do: :ok

  defp verify(o) do
    case o.rest do
      [] -> verify_data(o, IO.read_all(o.ctx.stdin), nil)
      [sigfile] ->
        data = File.read!(Lepton.Ctx.path(o.ctx, sigfile))
        # A detached signature beside its file (FILE.sig, FILE.asc): that file.
        signed = Enum.find([Path.rootname(sigfile)], &(&1 != sigfile and File.regular?(Lepton.Ctx.path(o.ctx, &1))))

        if signed && !String.contains?(data, "-----BEGIN PGP SIGNED MESSAGE-----") && detached?(data) do
          verify_detached(o, data, File.read!(Lepton.Ctx.path(o.ctx, signed)))
        else
          verify_data(o, data, nil)
        end

      [sigfile, file | _] ->
        verify_detached(o, File.read!(Lepton.Ctx.path(o.ctx, sigfile)), if(file == "-", do: IO.read_all(o.ctx.stdin), else: File.read!(Lepton.Ctx.path(o.ctx, file))))
    end
  end

  defp detached?(data) do
    with {:ok, bin} <- Packet.unarmor(data), {:ok, pkts} <- Packet.parse(bin) do
      Enum.all?(pkts, &(elem(&1, 0) == 2))
    else
      _ -> false
    end
  end

  defp verify_data(o, data, _) do
    if String.contains?(data, "-----BEGIN PGP SIGNED MESSAGE-----") do
      verify_clearsigned(o, data, false)
    else
      bin = case Packet.unarmor(data) do
        {:ok, b} -> b
        {:error, why} -> fail(why)
      end

      case Message.read(bin, public: pub(o), passphrase: fn _ -> :error end) do
        {:ok, %{sigs: []}} -> fail("no signature found")
        {:ok, r} -> report_sigs(o, r.sigs)
        {:error, why} -> fail("verify failed: #{why}")
      end
    end
  end

  defp verify_clearsigned(o, data, print?) do
    case Message.parse_clearsigned(data) do
      {:ok, text, sigbin} ->
        {:ok, pkts} = Packet.parse(sigbin)
        signed = Message.clear_signed_bytes(text)
        # (a clearsigned text's bytes are already canonical)
        results = for {2, b} <- pkts, {:ok, s} <- [Sig.parse(b)], do: Message.check(s, signed, pub(o))
        status = report_sigs(o, results)
        if print?, do: output(o, "", nil, text <> "\n")
        status

      {:error, why} ->
        fail(why)
    end
  end

  defp verify_detached(o, sigdata, data) do
    bin = case Packet.unarmor(sigdata) do
      {:ok, b} -> b
      {:error, why} -> fail(why)
    end

    {:ok, pkts} = Packet.parse(bin)
    results = for {2, b} <- pkts, {:ok, s} <- [Sig.parse(b)], do: Message.check(s, data, pub(o))
    if results == [], do: fail("no signature found")
    report_sigs(o, results)
  end

  # gpg's lines; the status: 0 all good, 1 a bad one, 2 one not checked.
  defp report_sigs(_o, []), do: 0

  defp report_sigs(o, results) do
    secret = MapSet.new(sec(o), & &1.primary.fpr)

    Enum.reduce(results, 0, fn r, status ->
      made = r.sig |> Sig.created() |> DateTime.from_unix!() |> Calendar.strftime("%a %b %d %H:%M:%S %Y UTC")
      IO.err(o.ctx, "gpg: Signature made #{made}")
      algo = %{1 => "RSA", 3 => "RSA", 19 => "ECDSA", 22 => "EDDSA", 27 => "ED25519"}[r.sig.algo] || "algo #{r.sig.algo}"

      case r.status do
        :good ->
          k = r.keyring_key
          trust = if MapSet.member?(secret, k.primary.fpr), do: "ultimate", else: "unknown"
          IO.err(o.ctx, "gpg:                using #{algo} key #{Key.fingerprint(r.key)}")
          IO.err(o.ctx, "gpg: Good signature from \"#{Keyring.primary_uid(k)}\" [#{trust}]")
          status

        :bad ->
          IO.err(o.ctx, "gpg:                using #{algo} key #{Key.fingerprint(r.key)}")
          IO.err(o.ctx, "gpg: BAD signature from \"#{Keyring.primary_uid(r.keyring_key)}\" [unknown]")
          max(status, 1)

        :no_key ->
          IO.err(o.ctx, "gpg:                using #{algo} key #{if r.keyid, do: Base.encode16(r.keyid), else: "?"}")
          IO.err(o.ctx, "gpg: Can't check signature: No public key")
          2
      end
    end)
  end

  # -- the rest --------------------------------------------------------------------------------------------------------

  defp version(o) do
    IO.puts(o.ctx, "gpg (Lepton) 1.0\nOpenPGP (RFC 9580, RFC 4880), in Elixir, written for Lepton\nHome: #{Lepton.Ctx.tildify(o.ctx, Keyring.home(o.ctx))}\nSupported algorithms:\nPubkey: RSA, EDDSA (Ed25519), ECDH (Curve25519, NIST P-256/384/521), ECDSA\nCipher: AES, AES192, AES256\nAEAD: OCB (reading)\nHash: SHA1, SHA224, SHA256, SHA384, SHA512\nCompression: Uncompressed, ZIP, ZLIB (reading)")
    0
  end

  defp help(o) do
    IO.puts(o.ctx, """
    Usage: gpg [OPTIONS] [FILES]   (man gpg for all of it)

    Keys:  --quick-gen-key "Name <email>"   --gen-key   -k / --list-keys   -K / --list-secret-keys
           --import [FILE]   --export [-a] [NAME]   --export-secret-keys [-a] [NAME]
           --delete-keys NAME   --delete-secret-keys NAME   --passwd NAME
           --recv-keys FINGERPRINT   --locate-keys EMAIL   (keys.openpgp.org)
    Data:  -e -r NAME [FILE]   -c [FILE]   -s [FILE]   --clearsign [FILE]   -b [FILE]
           -d [FILE]   --verify FILE.sig [FILE]
    Options: -a (armor)  -o FILE  -u NAME (signer)  --yes  --batch  --passphrase P
    """)

    0
  end
end
