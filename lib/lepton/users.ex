defmodule Lepton.Users do
  @moduledoc """
  User accounts and `sudo`.

  Accounts live in Lepton's state directory (`/var/lib/lepton`, kept on the
  data partition of an installed system), in the classic formats:

    * `passwd` - `name:x:uid:gid:full name:/home/name:/bin/lsh`
    * `group`  - `name:x:gid:member,member` (members of `sudo` may use sudo)
    * `shadow` - `name:HASH` (mode 600), where HASH is
      `$pbkdf2-sha512$ITERATIONS$SALT$KEY` (base64, 16-byte random salt)

  `/etc/passwd` and `/etc/group` are regenerated from them at boot (`/etc`
  is rebuilt every boot). Homes are `/home/NAME`, seeded from `/etc/skel`
  (the image's dotfiles).

  Who a process is lives in its context (`Lepton.Ctx` `user`), not in the
  `USER` variable, so changing the environment doesn't change identity.
  Commands marked `root: true`, and the checks below, refuse privileged
  actions to other users; `sudo` runs a command as root after asking for
  the user's password.

  This is Lepton-level separation, not a kernel-enforced boundary: the
  whole userland is one Erlang VM running as root, so code run through
  `iex`, `elixir` or `mix` can do anything.
  """

  alias Lepton.{Ctx, IO, Persist}
  require Logger

  defstruct [:name, :uid, :gid, :gecos, :home, :shell]

  # Accounts for daemons (not people): in /etc/passwd, so their programs
  # can look themselves up, but not in `list/0`. PostgreSQL refuses root.
  @system_accounts [%{__struct__: __MODULE__, name: "postgres", uid: 70, gid: 70, gecos: "PostgreSQL", home: "/var/lib/lepton/postgresql", shell: "/bin/false"}]

  @first_uid 1000
  @sudo_gid 27
  @iterations 100_000
  @sudo_timeout_ms 5 * 60 * 1000
  @reserved ~w(root daemon bin sys adm nobody sudo wheel admin users lepton postgres)

  # -- storage ------------------------------------------------------------------------------

  @doc false
  # LEPTON_HOME_ROOT relocates homes for tests, as LEPTON_STATE_DIR does state.
  def dirs(opts \\ []), do: %{state: opts[:state_dir] || Persist.state_dir(), homes: opts[:home_root] || System.get_env("LEPTON_HOME_ROOT") || "/home"}

  defp file(dirs, name), do: Path.join(dirs.state, name)

  defp read_lines(path) do
    case File.read(path) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      _ -> []
    end
  end

  defp write_lines(path, lines, mode \\ 0o644) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map_join(lines, &(&1 <> "\n")))
    File.chmod(path, mode)
  end

  @doc "Every account (not root)."
  def list(opts \\ []) do
    for line <- read_lines(file(dirs(opts), "passwd")),
        [name, _, uid, gid, gecos, home, shell] <- [String.split(line, ":")] do
      %__MODULE__{name: name, uid: String.to_integer(uid), gid: String.to_integer(gid), gecos: gecos, home: home, shell: shell}
    end
  end

  def any?, do: list() != []

  def get("root"), do: %__MODULE__{name: "root", uid: 0, gid: 0, gecos: "root", home: "/root", shell: "/bin/lsh"}
  def get(name), do: Enum.find(list(), &(&1.name == name))

  @doc "Groups as `%{name => {gid, [member]}}`."
  def groups(opts \\ []) do
    for line <- read_lines(file(dirs(opts), "group")),
        [name, _, gid, members] <- [String.split(line, ":")],
        into: %{} do
      {name, {String.to_integer(gid), String.split(members, ",", trim: true)}}
    end
  end

  @doc "`%{users: %{uid => name}, groups: %{gid => name}}`, root included (for `ls -l`)."
  def names_by_id do
    %{
      users: Map.new([{0, "root"} | Enum.map(@system_accounts ++ list(), &{&1.uid, &1.name})]),
      groups: Map.new([{0, "root"} | Enum.map(@system_accounts, &{&1.gid, &1.name}) ++ for({name, {gid, _}} <- groups(), do: {gid, name})])
    }
  end

  def groups_of(name), do: for({g, {gid, members}} <- groups(), name in members or g == name, do: {g, gid})

  def sudoer?("root"), do: true
  def sudoer?(name) do
    case groups()["sudo"] do
      {_, members} -> name in members
      nil -> false
    end
  end

  def valid_name?(name), do: Regex.match?(~r/^[a-z_][a-z0-9_-]{0,31}$/, name) and name not in @reserved

  # -- creating and changing accounts ------------------------------------------------------------

  @doc """
  Create an account. Options: `:gecos` (full name), `:sudo` (add to the sudo
  group, default true), `:state_dir` and `:home_root` (write somewhere else,
  as the installer does for the new disk), `:skel` (default `/etc/skel`).
  """
  def create(name, password, opts \\ []) do
    d = dirs(opts)
    users = list(opts)

    cond do
      not valid_name?(name) -> {:error, "invalid user name '#{name}' (use lowercase letters, digits, - and _; not a system name)"}
      Enum.any?(users, &(&1.name == name)) -> {:error, "user '#{name}' already exists"}
      password == "" -> {:error, "the password must not be empty"}
      true ->
        uid = Enum.max([@first_uid - 1 | Enum.map(users, & &1.uid)]) + 1
        user = %__MODULE__{name: name, uid: uid, gid: uid, gecos: opts[:gecos] || name, home: "/home/#{name}", shell: "/bin/lsh"}

        write_lines(file(d, "passwd"), read_lines(file(d, "passwd")) ++ [passwd_line(user)])
        set_password(name, password, opts)

        groups = groups(opts) |> Map.put(name, {uid, []})
        groups = if Keyword.get(opts, :sudo, true), do: Map.update(groups, "sudo", {@sudo_gid, [name]}, fn {g, m} -> {g, Enum.uniq(m ++ [name])} end), else: groups
        write_groups(d, groups)

        make_home(Path.join(d.homes, name), opts[:skel] || "/etc/skel", uid)
        {:ok, user}
    end
  end

  defp passwd_line(u), do: Enum.join([u.name, "x", u.uid, u.gid, u.gecos, u.home, u.shell], ":")

  defp write_groups(d, groups) do
    lines = for {name, {gid, members}} <- Enum.sort_by(groups, fn {_, {gid, _}} -> gid end), do: "#{name}:x:#{gid}:#{Enum.join(members, ",")}"
    write_lines(file(d, "group"), lines)
  end

  defp make_home(home, skel, uid) do
    File.mkdir_p!(home)
    if File.dir?(skel), do: File.cp_r!(skel, home)
    File.chmod(home, 0o750)

    for path <- [home | Path.wildcard(Path.join(home, "**"), match_dot: true)] do
      File.chown(path, uid)
      File.chgrp(path, uid)
    end
  end

  def delete(name, opts \\ []) do
    d = dirs(opts)

    if Enum.any?(list(opts), &(&1.name == name)) do
      write_lines(file(d, "passwd"), Enum.reject(read_lines(file(d, "passwd")), &String.starts_with?(&1, name <> ":")))
      write_lines(file(d, "shadow"), Enum.reject(read_lines(file(d, "shadow")), &String.starts_with?(&1, name <> ":")), 0o600)
      groups = for {g, {gid, m}} <- groups(opts), g != name, into: %{}, do: {g, {gid, m -- [name]}}
      write_groups(d, groups)
      if opts[:remove_home], do: File.rm_rf(Path.join(d.homes, name))
      :ok
    else
      {:error, "user '#{name}' does not exist"}
    end
  end

  def set_password(name, password, opts \\ []) do
    d = dirs(opts)
    others = Enum.reject(read_lines(file(d, "shadow")), &String.starts_with?(&1, name <> ":"))
    write_lines(file(d, "shadow"), others ++ ["#{name}:#{hash_password(password)}"], 0o600)
    :ok
  end

  # -- passwords ----------------------------------------------------------------------------------

  def hash_password(password, salt \\ :crypto.strong_rand_bytes(16), iterations \\ @iterations) do
    key = :crypto.pbkdf2_hmac(:sha512, password, salt, iterations, 64)
    "$pbkdf2-sha512$#{iterations}$#{Base.encode64(salt, padding: false)}$#{Base.encode64(key, padding: false)}"
  end

  def check_hash(password, "$pbkdf2-sha512$" <> rest) do
    with [iter, salt, key] <- String.split(rest, "$"),
         {iterations, ""} <- Integer.parse(iter),
         {:ok, salt} <- Base.decode64(salt, padding: false),
         {:ok, key} <- Base.decode64(key, padding: false) do
      :crypto.hash_equals(:crypto.pbkdf2_hmac(:sha512, password, salt, iterations, byte_size(key)), key)
    else
      _ -> false
    end
  end

  def check_hash(_password, _hash), do: false

  @doc "Is `password` right for `name`? (Takes as long whether or not the user exists.)"
  def verify(name, password) do
    hash = Enum.find_value(read_lines(file(dirs(), "shadow")), fn line ->
      case String.split(line, ":", parts: 2) do
        [^name, h] -> h
        _ -> nil
      end
    end)

    if hash, do: check_hash(password, hash), else: (check_hash(password, hash_password("x")); false)
  end

  # -- /etc ----------------------------------------------------------------------------------------

  @doc "Write /etc/passwd and /etc/group from the accounts (at boot, and after changes); `/etc` only on Lepton itself."
  def sync_etc(etc \\ nil) do
    case etc || if(Lepton.Sys.native?(), do: "/etc") do
      nil -> :ok
      dir -> write_etc(dir)
    end
  end

  defp write_etc(etc) do
    root = get("root")
    write_lines(Path.join(etc, "passwd"), [passwd_line(root) | Enum.map(@system_accounts ++ list(), &passwd_line/1)])
    groups = groups() |> Map.put("root", {0, []}) |> Map.merge(Map.new(@system_accounts, &{&1.name, {&1.gid, []}}))
    lines = for {name, {gid, members}} <- Enum.sort_by(groups, fn {_, {gid, _}} -> gid end), do: "#{name}:x:#{gid}:#{Enum.join(members, ",")}"
    write_lines(Path.join(etc, "group"), lines)
  end

  # -- sessions ---------------------------------------------------------------------------------------

  @doc "A context for `user`, based on `ctx` (environment, home, identity)."
  def as(ctx, %__MODULE__{} = user, opts \\ []) do
    env = Map.merge(ctx.env, %{"USER" => user.name, "LOGNAME" => user.name, "HOME" => user.home, "SHELL" => user.shell})
    cwd = if opts[:login], do: user.home, else: ctx.cwd
    %{ctx | user: user.name, env: env, cwd: cwd}
  end

  # -- permissions ---------------------------------------------------------------------------------------

  def root?(%Ctx{user: user}), do: user == "root"
  # No context: the system itself (boot, services, internal callers).
  def root?(nil), do: true

  @doc "Print the standard refusal for a command that needs root; returns exit status 1."
  def denied(ctx, command) do
    IO.err(ctx, "#{command}: permission denied: this needs root. Run it with sudo: sudo #{command} ...")
    1
  end

  @doc "May `ctx` write (create, change or remove) `path`? `:ok` or `{:error, :eacces}`."
  def check_write(nil, _path), do: :ok
  def check_write(%Ctx{user: "root"}, _path), do: :ok

  def check_write(ctx, path) do
    user = get(ctx.user)
    allowed = [user && user.home, "/tmp", "/var/tmp", "/dev/null"] |> Enum.reject(&is_nil/1)

    cond do
      Enum.any?(allowed, &(path == &1 or String.starts_with?(path, &1 <> "/"))) -> :ok
      owner(path) != nil and user != nil and owner(path) == user.uid -> :ok
      true -> {:error, :eacces}
    end
  end

  # -- ownership ------------------------------------------------------------------------------------
  #
  # Lepton runs as root, so what it creates for a user would be root's:
  # programs running as the user (Firefox, through Lepton.RunAs) couldn't
  # change it, and `ls -l`, rsync and sshfs would show root. What a user's
  # command creates is made theirs.

  @doc """
  Run `fun`, which creates `path` (a file, a directory, `mkdir -p`'s
  parents): if it didn't exist before, it and everything new under or
  above it is made `ctx`'s user's. Returns what `fun` returns.
  """
  def own_new(ctx, path, fun) do
    first_new = first_missing(Path.expand(path))
    result = fun.()
    if first_new && match?({:ok, _}, File.lstat(first_new)), do: give(ctx, first_new, :all)
    result
  end

  @doc """
  `own_new/3` without a session: what `fun` creates at `path` (and the
  parents it makes) becomes the user's who owns the nearest folder above
  it that exists, their home (`~/.ssh/known_hosts`, written where ssh has
  no session at hand). Under root's folders, root's.
  """
  def own_new_in_home(path, fun) do
    path = Path.expand(path)

    case ancestor_owner(path) do
      nil -> fun.()
      user -> own_new(%Ctx{user: user.name}, path, fun)
    end
  end

  defp ancestor_owner(path) do
    case File.lstat(path) do
      {:ok, %{uid: 0}} -> nil
      {:ok, %{uid: uid}} -> Enum.find(list(), &(&1.uid == uid))
      _ -> if Path.dirname(path) == path, do: nil, else: ancestor_owner(Path.dirname(path))
    end
  end

  @doc """
  Once, at boot: what is root's in each user's home becomes theirs. Lepton
  writes as root, and before 1.10 or so (and `ssh`'s known hosts until
  1.25.2) some of what it wrote there stayed root's, so programs running as
  the user (`mix phx.new`, `ssh`) couldn't write or read it. `chown -R` by
  hand does the same.
  """
  def repair_homes do
    for u <- list(), u.uid >= 1000, u.home != "/", File.dir?(u.home) do
      repair_home(u, u.home)
      u.name
    end
  end

  @doc "What is root's under `dir` (`user`'s home) becomes `user`'s."
  def repair_home(%__MODULE__{} = user, dir), do: give(%Ctx{user: user.name}, dir, :all)

  @doc false
  def repair_homes_once do
    unless Persist.flag?("homes-reowned") do
      done = repair_homes()
      Persist.set_flag("homes-reowned")
      if done != [], do: Logger.info("users: what was root's in #{Enum.join(done, ", ")}'s home is theirs again")
    end
  end

  # The highest of `path` and its parents that doesn't exist yet (nil: it all does).
  defp first_missing(path) do
    parent = Path.dirname(path)

    cond do
      match?({:ok, _}, File.lstat(path)) -> nil
      parent == path -> path
      first_missing(parent) == nil -> path
      true -> first_missing(parent)
    end
  end

  @doc """
  Make root's files under `path` (and `path` itself) that changed at or
  after `since` (Unix seconds) `ctx`'s user's: for commands that write
  trees (git, `cp -r`, rsync). Older files, such as ones made with sudo,
  are left as they are.
  """
  def adopt(ctx, path, since), do: give(ctx, Path.expand(path), {:since, since})

  @doc "Make `path` (a file Lepton wrote for `ctx`'s user, new or replaced) theirs."
  def own(ctx, path), do: give(ctx, Path.expand(path), :all)

  defp give(%Ctx{user: name}, path, which) when is_binary(name) and name != "root" do
    case get(name) do
      %__MODULE__{uid: uid, gid: gid} when uid != 0 -> walk(path, uid, gid, which)
      _ -> :ok
    end
  end

  defp give(_ctx, _path, _which), do: :ok

  defp walk(path, uid, gid, which) do
    case File.lstat(path, time: :posix) do
      {:ok, %{uid: 0} = st} ->
        if which == :all or st.mtime >= elem(which, 1) or st.ctime >= elem(which, 1), do: lchown(path, uid, gid)
        if st.type == :directory, do: walk_dir(path, uid, gid, which)

      {:ok, %{type: :directory}} ->
        walk_dir(path, uid, gid, which)

      _ ->
        :ok
    end
  end

  defp walk_dir(path, uid, gid, which) do
    case File.ls(path) do
      {:ok, names} -> Enum.each(names, &walk(Path.join(path, &1), uid, gid, which))
      _ -> :ok
    end
  end

  @doc "Change the owner of `path` itself (a symlink: the link, not what it points at). True if it worked."
  def lchown(path, uid, gid) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> match?({_, 0}, Lepton.Sys.shim("chown", ["-h", "#{uid}:#{gid}", path]))
      {:ok, _} -> File.chown(path, uid) == :ok and File.chgrp(path, gid) == :ok
      _ -> false
    end
  end

  defp owner(path) do
    case File.lstat(path) do
      {:ok, %{uid: uid}} -> uid
      _ -> nil
    end
  end

  @doc "May `ctx` read `path`? Only the password hashes are off limits."
  def check_read(nil, _path), do: :ok
  def check_read(%Ctx{user: "root"}, _path), do: :ok
  def check_read(_ctx, path), do: if(Path.expand(path) == Path.join(Persist.state_dir(), "shadow"), do: {:error, :eacces}, else: :ok)

  # -- sudo -------------------------------------------------------------------------------------------------

  @doc false
  def start_link(_), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @doc false
  def child_spec(arg), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}}

  @doc "Did `user` authenticate for sudo on this terminal in the last 5 minutes?"
  def sudo_fresh?(user, terminal) do
    case Process.whereis(__MODULE__) && Agent.get(__MODULE__, &Map.get(&1, {user, terminal})) do
      t when is_integer(t) -> System.monotonic_time(:millisecond) - t < @sudo_timeout_ms
      _ -> false
    end
  end

  def sudo_touch(user, terminal) do
    if Process.whereis(__MODULE__), do: Agent.update(__MODULE__, &Map.put(&1, {user, terminal}, System.monotonic_time(:millisecond)))
    :ok
  end

  def sudo_reset(user) do
    if Process.whereis(__MODULE__), do: Agent.update(__MODULE__, &Map.reject(&1, fn {{u, _}, _} -> u == user end))
    :ok
  end
end
