defmodule Lepton.Vault do
  @moduledoc """
  A password manager (in the manner of 1Password): logins, secure notes and
  cards in one encrypted file per user, `~/.vault/vault`, unlocked with a
  master password. The `vault` command and the classic desktop's Passwords
  window (`Lepton.Vault.UI`) are its two faces; both go through the vault
  agent (`Lepton.Vault.Agent`), so unlocking in one unlocks the other.

  ## The file

      "LPVAULT2" | memory MiB::16 | passes::8 | lanes::8 | salt::16 bytes
                 | key nonce::12 | wrapped key::32 | key tag::16
                 | body nonce::12 | body tag::16 | body

  The vault key is 32 random bytes made when the vault is created. It is
  stored wrapped (AES-256-GCM) with a key derived from the master password
  with Argon2id (`Lepton.Argon2`: 64 MiB, 3 passes, one lane, a random
  salt), which makes every guess at the password cost 64 MiB of memory as
  well as time. Vaults made before it, "LPVAULT1" with an iteration count
  in those four bytes, use PBKDF2-HMAC-SHA256 (600,000 iterations); they
  still open, and move to Argon2id when the master password is changed
  (or `vault upgrade`). Changing the master password rewraps the key and
  leaves the body alone. The body is
  the items as JSON, encrypted with the vault key (AES-256-GCM, a fresh
  nonce every write); everything before it is authenticated with it. A
  wrong password, or any change to the file, fails to decrypt.

  Each write replaces the file atomically and keeps the one before it as
  `vault.old`.

  ## Items

  An item is a map of string fields: `id`, `kind` (`login`, `note` or
  `card`), `title`, the kind's fields (`username`, `password`, `url`,
  `otp`, `notes`; `cardholder`, `number`, `expiry`, `code`), any others
  added, `tags`, `favorite`, `created`, `updated`, and `history` (earlier
  passwords, newest first).
  """

  import Bitwise
  alias Lepton.Vault.Agent

  @pbkdf2 "LPVAULT1"
  @argon2 "LPVAULT2"
  @header_size 8 + 4 + 16 + 12 + 32 + 16

  @kinds %{
    "login" => ~w(username password url otp notes),
    "note" => ~w(notes),
    "card" => ~w(cardholder number expiry code notes)
  }

  # Fields shown hidden (as dots) until revealed.
  @secret ~w(password code otp)
  @history 10

  def kinds, do: ~w(login note card)
  def fields(kind), do: Map.get(@kinds, kind, @kinds["login"])
  def known_fields, do: @kinds |> Map.values() |> Enum.concat() |> Enum.uniq()
  def secret?(field), do: field in @secret

  @doc "A user's vault: `$VAULT_FILE`, else `~/.vault/vault`."
  def path(home, env \\ %{}), do: env["VAULT_FILE"] || Path.join([home, ".vault", "vault"])

  def exists?(path), do: File.regular?(path)

  # -- the agent's API: unlocked vaults, by user and file --------------------------------------

  @doc "Make a new vault at `path`, owned by `user`, and unlock it."
  def create(user, path, password, opts \\ []) do
    cond do
      exists?(path) -> {:error, :exists}
      String.length(password) < 8 -> {:error, :short}
      true -> Agent.create(user, path, password, opts)
    end
  end

  @doc "Unlock: `:ok`, or `{:error, :wrong_password | :missing | :damaged}`. `timeout:` minutes idle until it locks itself (0: never)."
  def unlock(user, path, password, opts \\ []), do: Agent.unlock(user, path, password, opts)

  def lock(user, path), do: Agent.lock(user, path)
  def lock_all(user), do: Agent.lock_all(user)
  def unlocked?(user, path), do: Agent.unlocked?(user, path)

  @doc "The items, sorted by title: `{:ok, items}` or `{:error, :locked}`."
  def items(user, path) do
    with {:ok, data} <- Agent.read(user, path), do: {:ok, sort(data["items"])}
  end

  @doc """
  Change the items: `fun` gets them and returns `{:ok, items, reply}` (or
  an error, which changes nothing). Returns `{:ok, reply}`.
  """
  def update(user, path, fun), do: Agent.update(user, path, fun)

  def change_password(user, path, old, new) do
    if String.length(new) < 8, do: {:error, :short}, else: Agent.change_password(user, path, old, new)
  end

  @doc "Put `text` on the clipboard, and take it off again after `seconds` if it is still there."
  def copy(text, seconds \\ 45), do: Agent.copy(text, seconds)

  # -- the file --------------------------------------------------------------------------------

  @doc """
  How master passwords become keys for new vaults (and on a password
  change): `{:argon2id, mib, passes, lanes}`, or `{:pbkdf2, iterations}`.
  The `:vault_kdf` setting changes it (tests make it cheap).
  """
  def default_kdf, do: Application.get_env(:lepton, :vault_kdf, {:argon2id, 64, 3, 1})

  @doc "How the vault in `bin` turns its master password into a key."
  def kdf(<<@argon2, mib::16, t::8, p::8, _::binary>>), do: {:argon2id, mib, t, p}
  def kdf(<<@pbkdf2, iterations::32, _::binary>>), do: {:pbkdf2, iterations}
  def kdf(_), do: nil

  @doc "A KDF said in words, for `vault status`."
  def describe_kdf({:argon2id, mib, t, p}), do: "Argon2id, #{mib} MiB, #{t} passes#{if p > 1, do: ", #{p} lanes", else: ""}"
  def describe_kdf({:pbkdf2, n}), do: "PBKDF2-HMAC-SHA256, #{n} iterations"

  @doc false
  def new_file(password, data, kdf \\ default_kdf()) do
    key = :crypto.strong_rand_bytes(32)
    header = wrap(key, password, :crypto.strong_rand_bytes(16), kdf)
    {seal(header, key, data), key}
  end

  defp wrap(key, password, salt, kdf) do
    head = kdf_head(kdf) <> salt
    nonce = :crypto.strong_rand_bytes(12)
    {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, kek(kdf, password, salt), nonce, key, head, true)
    head <> nonce <> ct <> tag
  end

  defp kdf_head({:argon2id, mib, t, p}), do: @argon2 <> <<mib::16, t::8, p::8>>
  defp kdf_head({:pbkdf2, iterations}), do: @pbkdf2 <> <<iterations::32>>

  defp kek({:argon2id, mib, t, p}, password, salt), do: Lepton.Argon2.hash(password, salt, t: t, m: mib * 1024, p: p, length: 32)
  defp kek({:pbkdf2, iterations}, password, salt), do: :crypto.pbkdf2_hmac(:sha256, password, salt, iterations, 32)

  @doc false
  # The header with a new body.
  def seal(<<header::binary-size(@header_size), _::binary>>, key, data) do
    nonce = :crypto.strong_rand_bytes(12)
    {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, JSON.encode!(data), header, true)
    header <> nonce <> tag <> ct
  end

  @doc false
  # The vault key, from the master password.
  def unwrap(<<magic::binary-8, _::binary-4, salt::binary-16, nonce::binary-12, ct::binary-32, tag::binary-16, _::binary>> = bin, password) when magic in [@pbkdf2, @argon2] do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, kek(kdf(bin), password, salt), nonce, ct, binary_part(bin, 0, 28), tag, false) do
      key when is_binary(key) -> {:ok, key}
      :error -> {:error, :wrong_password}
    end
  end

  def unwrap(_, _), do: {:error, :damaged}

  @doc false
  def open(<<header::binary-size(@header_size), nonce::binary-12, tag::binary-16, ct::binary>>, key) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ct, header, tag, false) do
      json when is_binary(json) -> {:ok, JSON.decode!(json)}
      :error -> {:error, :damaged}
    end
  end

  def open(_, _), do: {:error, :damaged}

  @doc false
  # A new master password: the key wrapped again (new salt; and the KDF new
  # vaults get, so an old vault moves to Argon2id), and the body sealed again
  # under the new header.
  def rewrap(bin, key, password, kdf \\ default_kdf()) do
    with {:ok, data} <- open(bin, key), do: {:ok, seal(wrap(key, password, :crypto.strong_rand_bytes(16), kdf), key, data)}
  end

  @doc false
  # Write atomically, keeping the last version as `vault.old`; the user's own, readable by no one else.
  def write_file(path, bin, user) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    File.chmod(dir, 0o700)
    tmp = path <> ".new"
    File.write!(tmp, bin)
    File.chmod(tmp, 0o600)
    if exists?(path), do: File.rename(path, path <> ".old")
    :ok = File.rename(tmp, path)

    case Lepton.Users.get(user) do
      %Lepton.Users{uid: uid, gid: gid} when uid != 0 ->
        for p <- [dir, path, path <> ".old"], File.exists?(p), do: File.chown(p, uid) == :ok and File.chgrp(p, gid)

      _ ->
        :ok
    end

    :ok
  end

  # -- items -------------------------------------------------------------------------------------

  def sort(items), do: Enum.sort_by(items, &{!&1["favorite"], String.downcase(&1["title"] || "")})

  @doc "A new item from fields (`title` required)."
  def new_item(fields) do
    now = now()
    base = %{"id" => Base.encode16(:crypto.strong_rand_bytes(4), case: :lower), "kind" => "login", "tags" => [], "favorite" => false, "created" => now, "updated" => now, "history" => []}
    fields |> clean() |> then(&Map.merge(base, &1))
  end

  @doc "Set fields of an item (an empty value removes one); a changed password goes into its history."
  def set_fields(item, fields) do
    fields = clean(fields, false)
    old = item["password"]

    item =
      Enum.reduce(fields, item, fn
        {k, v}, item when v in ["", nil] and k not in ["title", "id", "kind"] -> Map.delete(item, k)
        {k, v}, item -> Map.put(item, k, v)
      end)

    item =
      if old not in [nil, ""] and item["password"] != old,
        do: Map.put(item, "history", Enum.take([%{"password" => old, "changed" => now()} | item["history"] || []], @history)),
        else: item

    Map.put(item, "updated", now())
  end

  defp clean(fields, drop_empty? \\ true) do
    fields
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.update("tags", nil, fn
      t when is_binary(t) -> t |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
      t -> t
    end)
    |> Map.update("favorite", nil, fn f -> f in [true, "true", "yes", "1", "TRUE"] end)
    |> Enum.reject(fn {_k, v} -> v == nil or (drop_empty? and v == "") end)
    |> Map.new()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  @doc """
  An item by reference: its id (or the start of it), its title, or a
  unique part of its title. `{:ok, item}`, `{:error, :not_found}` or
  `{:error, {:ambiguous, items}}`.
  """
  def find(items, ref) do
    down = String.downcase(ref)

    cond do
      i = Enum.find(items, &(&1["id"] == ref)) -> {:ok, i}
      (exact = Enum.filter(items, &(String.downcase(&1["title"] || "") == down))) != [] -> one(exact)
      (ids = Enum.filter(items, &String.starts_with?(&1["id"], down))) != [] and byte_size(down) >= 3 -> one(ids)
      true -> items |> Enum.filter(&String.contains?(String.downcase(&1["title"] || ""), down)) |> one()
    end
  end

  defp one([i]), do: {:ok, i}
  defp one([]), do: {:error, :not_found}
  defp one(many), do: {:error, {:ambiguous, many}}

  @doc "Items whose title, username, URL, tags or notes contain `query` (all of them for `\"\"`)."
  def search(items, query) do
    q = String.downcase(String.trim(query || ""))
    if q == "", do: items, else: Enum.filter(items, &(haystack(&1) =~ q))
  end

  defp haystack(item), do: [item["title"], item["username"], item["url"], item["notes"] | item["tags"] || []] |> Enum.reject(&is_nil/1) |> Enum.join("\n") |> String.downcase()

  def replace(items, item), do: Enum.map(items, &if(&1["id"] == item["id"], do: item, else: &1))
  def delete(items, id), do: Enum.reject(items, &(&1["id"] == id))

  @doc "The fields an item shows, in order: its kind's, then any others."
  def shown_fields(item) do
    known = fields(item["kind"])
    extra = item |> Map.keys() |> Enum.reject(&(&1 in known or &1 in ~w(id kind title tags favorite created updated history))) |> Enum.sort()
    Enum.filter(known, &Map.has_key?(item, &1)) ++ extra
  end

  # -- passwords ---------------------------------------------------------------------------------

  @lower ~c"abcdefghijklmnopqrstuvwxyz"
  @upper ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  @digits ~c"0123456789"
  @symbols ~c"!@#$%^&*-_=+?.:"

  @doc "A random password: `length:` (default 20), `symbols:` (default true), `digits:` (default true); every kind asked for appears."
  def generate(opts \\ []) do
    length = max(opts[:length] || 20, 4)
    classes = [@lower, @upper] ++ if(opts[:digits] != false, do: [@digits], else: []) ++ if(opts[:symbols] != false, do: [@symbols], else: [])
    chars = List.to_tuple(Enum.concat(classes))
    pw = for _ <- 1..length, into: "", do: <<elem(chars, random(tuple_size(chars)))>>
    if Enum.all?(classes, fn cl -> Enum.any?(String.to_charlist(pw), &(&1 in cl)) end), do: pw, else: generate(opts)
  end

  # Uniform in 0..n-1 (rejection sampling: no modulo bias).
  defp random(n) do
    <<x>> = :crypto.strong_rand_bytes(1)
    if x < 256 - rem(256, n), do: rem(x, n), else: random(n)
  end

  @doc "A password's strength: `{:weak | :fair | :good | :strong, bits}` (estimated from its length and the kinds of character in it)."
  def strength(pw) do
    cs = String.to_charlist(pw)
    pool = Enum.sum(for {cl, n} <- [{@lower, 26}, {@upper, 26}, {@digits, 10}], Enum.any?(cs, &(&1 in cl)), do: n) + if(Enum.any?(cs, &(&1 not in @lower ++ @upper ++ @digits)), do: 32, else: 0)
    # Repeated characters add little.
    distinct = cs |> Enum.uniq() |> length()
    bits = if pool == 0, do: 0, else: round(min(length(cs), distinct * 2) * :math.log2(pool))

    {cond do
       bits < 40 -> :weak
       bits < 60 -> :fair
       bits < 80 -> :good
       true -> :strong
     end, bits}
  end

  @doc "Weak and reused passwords (Watchtower): `[{item, [:weak | :reused]}]`."
  def audit(items) do
    counts = items |> Enum.map(& &1["password"]) |> Enum.reject(&(&1 in [nil, ""])) |> Enum.frequencies()

    for i <- items, pw = i["password"], pw not in [nil, ""],
        issues = (if elem(strength(pw), 0) == :weak, do: [:weak], else: []) ++ (if counts[pw] > 1, do: [:reused], else: []),
        issues != [],
        do: {i, issues}
  end

  # -- one-time passwords (TOTP, RFC 6238) --------------------------------------------------------

  @doc """
  The current code for a TOTP secret (base32) or `otpauth://totp/` URI:
  `{:ok, code, seconds_left}` or `{:error, :bad_secret}`.
  """
  def totp(secret, time \\ System.os_time(:second)) do
    with {:ok, key, digits, period, algo} <- otp_params(secret) do
      counter = div(time, period)
      mac = :crypto.mac(:hmac, algo, key, <<counter::64>>)
      offset = :binary.last(mac) &&& 0x0F
      <<_::binary-size(^offset), n::32, _::binary>> = mac
      code = rem(n &&& 0x7FFFFFFF, Integer.pow(10, digits))
      {:ok, code |> Integer.to_string() |> String.pad_leading(digits, "0"), period - rem(time, period)}
    end
  end

  defp otp_params("otpauth://" <> _ = uri) do
    q = URI.decode_query(URI.parse(uri).query || "")
    algo = %{"SHA1" => :sha, "SHA256" => :sha256, "SHA512" => :sha512}[String.upcase(q["algorithm"] || "SHA1")]

    with {:ok, key} <- base32(q["secret"] || ""),
         {digits, ""} when digits in 6..8 <- Integer.parse(q["digits"] || "6"),
         {period, ""} when period > 0 <- Integer.parse(q["period"] || "30"),
         true <- algo != nil do
      {:ok, key, digits, period, algo}
    else
      _ -> {:error, :bad_secret}
    end
  end

  defp otp_params(secret) do
    with {:ok, key} <- base32(secret), do: {:ok, key, 6, 30, :sha}
  end

  defp base32(s) do
    case s |> String.replace(~r/[\s=-]/, "") |> String.upcase() |> Base.decode32(padding: false) do
      {:ok, key} when key != "" -> {:ok, key}
      _ -> {:error, :bad_secret}
    end
  end

  # -- import and export -------------------------------------------------------------------------------

  # CSV columns of 1Password, Bitwarden, Chrome, Firefox, Safari, LastPass and KeePass exports.
  @columns %{
    "title" => "title", "name" => "title",
    "url" => "url", "website" => "url", "login_uri" => "url", "web site" => "url",
    "username" => "username", "login_username" => "username", "user name" => "username", "login" => "username",
    "password" => "password", "login_password" => "password",
    "otpauth" => "otp", "totp" => "otp", "login_totp" => "otp", "one-time password" => "otp", "otp" => "otp",
    "notes" => "notes", "note" => "notes", "extra" => "notes", "comments" => "notes",
    "tags" => "tags", "grouping" => "tags", "folder" => "tags", "group" => "tags",
    "favorite" => "favorite", "fav" => "favorite"
  }

  @doc "Items from a CSV export (the first row names the columns): `{:ok, [fields]}` or `{:error, reason}`."
  def from_csv(text) do
    case parse_csv(text) do
      [header | rows] ->
        cols = Enum.map(header, &@columns[String.downcase(String.trim(&1))])

        if "password" in cols or "notes" in cols do
          {:ok,
           for row <- rows, row != [""] do
             fields = for({c, v} <- Enum.zip(cols, row), c != nil, v != "", into: %{}, do: {c, v})
             fields = Map.update(fields, "favorite", false, &(&1 in ["1", "true", "TRUE", "yes"]))
             fields = Map.put_new_lazy(fields, "title", fn -> (fields["url"] && URI.parse(fields["url"]).host) || fields["url"] || "Untitled" end)
             if Map.has_key?(fields, "password") or Map.has_key?(fields, "username"), do: fields, else: Map.put(fields, "kind", "note")
           end}
        else
          {:error, "no password or notes column"}
        end

      _ ->
        {:error, "empty file"}
    end
  end

  @doc "Items from `vault export --json`: `{:ok, [items]}` or `{:error, reason}`."
  def from_json(text) do
    case JSON.decode(text) do
      {:ok, %{"items" => items}} when is_list(items) -> {:ok, items}
      {:ok, items} when is_list(items) -> {:ok, items}
      _ -> {:error, "not a vault export"}
    end
  end

  def to_json(items), do: JSON.encode!(%{"items" => items}) <> "\n"

  def to_csv(items) do
    cols = ~w(title url username password otp notes tags)
    rows = for i <- items, do: Enum.map(cols, fn "tags" -> Enum.join(i["tags"] || [], ","); c -> i[c] || "" end)
    Enum.map_join([cols | rows], "", fn row -> Enum.map_join(row, ",", &csv_field/1) <> "\n" end)
  end

  defp csv_field(v) do
    if String.contains?(v, [",", "\"", "\n", "\r"]), do: "\"" <> String.replace(v, "\"", "\"\"") <> "\"", else: v
  end

  @doc false
  # RFC 4180: rows of fields; quoted fields may hold commas, quotes ("") and newlines.
  def parse_csv(text), do: text |> String.replace_prefix("﻿", "") |> csv([], [], "") |> Enum.reject(&(&1 == [""]))

  defp csv("", row, rows, field), do: Enum.reverse([Enum.reverse([field | row]) | rows])
  defp csv("\"" <> rest, row, rows, ""), do: quoted(rest, row, rows, "")
  defp csv("," <> rest, row, rows, field), do: csv(rest, [field | row], rows, "")
  defp csv("\r\n" <> rest, row, rows, field), do: csv(rest, [], [Enum.reverse([field | row]) | rows], "")
  defp csv("\n" <> rest, row, rows, field), do: csv(rest, [], [Enum.reverse([field | row]) | rows], "")
  defp csv(<<c::utf8, rest::binary>>, row, rows, field), do: csv(rest, row, rows, field <> <<c::utf8>>)

  defp quoted("\"\"" <> rest, row, rows, field), do: quoted(rest, row, rows, field <> "\"")
  defp quoted("\"" <> rest, row, rows, field), do: csv(rest, row, rows, field)
  defp quoted("", row, rows, field), do: csv("", row, rows, field)
  defp quoted(<<c::utf8, rest::binary>>, row, rows, field), do: quoted(rest, row, rows, field <> <<c::utf8>>)

  @doc "A reason, for people."
  def describe(:wrong_password), do: "wrong master password"
  def describe(:locked), do: "the vault is locked (vault unlock)"
  def describe(:missing), do: "there is no vault yet (vault init)"
  def describe(:exists), do: "there is a vault already"
  def describe(:damaged), do: "the vault file is damaged (the previous version is vault.old)"
  def describe(:short), do: "the master password must be at least 8 characters"
  def describe(:not_found), do: "no such item"
  def describe({:ambiguous, items}), do: "which one? " <> Enum.map_join(items, ", ", &"#{&1["title"]} (#{&1["id"]})")
  def describe(other) when is_binary(other), do: other
  def describe(other), do: inspect(other)
end

defmodule Lepton.Vault.Agent do
  @moduledoc """
  The vault agent: holds the keys of unlocked vaults (by user and file)
  in memory, does every read and write of them (one at a time), locks
  each after it has been idle for its timeout (10 minutes unless `vault
  unlock -t` said otherwise), and clears copied passwords off the
  clipboard. Locking forgets the key.
  """

  use GenServer
  alias Lepton.Vault

  @timeout_min 10

  def start_link(_ \\ []), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  # (The master password's key is worked out here, in the caller's process:
  # Argon2id takes seconds, and the agent serves everyone meanwhile.)
  def create(user, path, password, opts) do
    kdf = opts[:kdf] || (opts[:iterations] && {:pbkdf2, opts[:iterations]}) || Vault.default_kdf()
    {bin, key} = Vault.new_file(password, %{"version" => 1, "items" => []}, kdf)
    call({:create, user, path, bin, key, opts})
  end

  def unlock(user, path, password, opts) do
    with {:ok, bin} <- read_file(path), {:ok, key} <- Vault.unwrap(bin, password), do: call({:unlock, user, path, key, opts})
  end

  def lock(user, path), do: call({:lock, {user, path}})
  def lock_all(user), do: call({:lock_all, user})
  def unlocked?(user, path), do: call({:unlocked?, {user, path}})
  def read(user, path), do: call({:read, {user, path}})
  def update(user, path, fun), do: call({:update, {user, path}, fun})
  def change_password(user, path, old, new) do
    with {:ok, bin} <- read_file(path),
         {:ok, key} <- Vault.unwrap(bin, old),
         {:ok, new_bin} <- Vault.rewrap(bin, key, new),
         do: call({:change_password, {user, path}, bin, new_bin, key})
  end
  def copy(text, seconds), do: call({:copy, text, seconds})

  # Started on demand where the application didn't (mix tasks, scripts).
  defp call(msg) do
    pid =
      Process.whereis(__MODULE__) ||
        case GenServer.start(__MODULE__, nil, name: __MODULE__) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

    GenServer.call(pid, msg, 60_000)
  catch
    :exit, {:noproc, _} -> call(msg)
  end

  @impl true
  def init(_), do: {:ok, %{sessions: %{}, clip: nil}}

  @impl true
  def handle_call({:create, user, path, bin, key, opts}, _from, st) do
    :ok = Vault.write_file(path, bin, user)
    {:reply, :ok, open_session(st, {user, path}, key, opts)}
  end

  def handle_call({:unlock, user, path, key, opts}, _from, st) do
    with {:ok, bin} <- read_file(path),
         {:ok, _} <- Vault.open(bin, key) do
      {:reply, :ok, open_session(st, {user, path}, key, opts)}
    else
      err -> {:reply, err, st}
    end
  end

  def handle_call({:lock, id}, _from, st), do: {:reply, :ok, close_session(st, id)}

  def handle_call({:lock_all, user}, _from, st) do
    {:reply, :ok, st.sessions |> Map.keys() |> Enum.filter(&(elem(&1, 0) == user)) |> Enum.reduce(st, &close_session(&2, &1))}
  end

  def handle_call({:unlocked?, id}, _from, st), do: {:reply, Map.has_key?(st.sessions, id), st}

  def handle_call({:read, id}, _from, st) do
    with {:ok, s} <- session(st, id), {:ok, bin} <- read_file(elem(id, 1)), {:ok, data} <- Vault.open(bin, s.key) do
      {:reply, {:ok, data}, touch(st, id)}
    else
      err -> {:reply, err, st}
    end
  end

  def handle_call({:update, {user, path} = id, fun}, _from, st) do
    with {:ok, s} <- session(st, id),
         {:ok, bin} <- read_file(path),
         {:ok, data} <- Vault.open(bin, s.key),
         {:ok, items, reply} <- fun.(data["items"]) do
      :ok = Vault.write_file(path, Vault.seal(bin, s.key, Map.put(data, "items", items)), user)
      {:reply, {:ok, reply}, touch(st, id)}
    else
      err -> {:reply, err, st}
    end
  end

  # (only if the file is still the one the new header was made from)
  def handle_call({:change_password, {user, path} = id, old_bin, new_bin, key}, _from, st) do
    case read_file(path) do
      {:ok, ^old_bin} ->
        :ok = Vault.write_file(path, new_bin, user)
        {:reply, :ok, if(Map.has_key?(st.sessions, id), do: st, else: open_session(st, id, key, []))}

      {:ok, _} ->
        {:reply, {:error, "the vault changed meanwhile: try again"}, st}

      err ->
        {:reply, err, st}
    end
  end

  def handle_call({:copy, text, seconds}, _from, st) do
    if st.clip, do: Process.cancel_timer(elem(st.clip, 1))
    Lepton.Clipboard.put(text)
    {:reply, :ok, %{st | clip: {text, Process.send_after(self(), :clear_clipboard, seconds * 1000)}}}
  end

  @impl true
  def handle_info({:idle, id, ref}, st) do
    case st.sessions[id] do
      %{timer: {_, ^ref}} -> {:noreply, close_session(st, id)}
      _ -> {:noreply, st}
    end
  end

  # Only if it is still what was copied.
  def handle_info(:clear_clipboard, %{clip: {text, _}} = st) do
    if Lepton.Clipboard.get() == text, do: Lepton.Clipboard.put("")
    {:noreply, %{st | clip: nil}}
  end

  def handle_info(_, st), do: {:noreply, st}

  defp read_file(path) do
    case File.read(path) do
      {:ok, bin} -> {:ok, bin}
      {:error, :enoent} -> {:error, :missing}
      {:error, reason} -> {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end

  defp session(st, id), do: if(s = st.sessions[id], do: {:ok, s}, else: {:error, :locked})

  defp open_session(st, id, key, opts) do
    st = close_session(st, id)
    minutes = if is_integer(opts[:timeout]), do: opts[:timeout], else: @timeout_min
    touch(%{st | sessions: Map.put(st.sessions, id, %{key: key, minutes: minutes, timer: nil})}, id)
  end

  defp close_session(st, id) do
    case st.sessions[id] do
      %{timer: {t, _}} -> Process.cancel_timer(t)
      _ -> :ok
    end

    %{st | sessions: Map.delete(st.sessions, id)}
  end

  # Each use restarts the idle timer.
  defp touch(st, id) do
    s = st.sessions[id]
    if s.timer, do: Process.cancel_timer(elem(s.timer, 0))
    ref = make_ref()
    timer = if s.minutes > 0, do: {Process.send_after(self(), {:idle, id, ref}, s.minutes * 60_000), ref}
    %{st | sessions: Map.put(st.sessions, id, %{s | timer: timer})}
  end
end
