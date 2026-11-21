defmodule Lepton.UsersTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.{Ctx, Users}

  setup do
    state = tmp_dir("usersstate")
    homes = tmp_dir("homes")
    skel = tmp_dir("skel")
    File.write!(Path.join(skel, ".lshrc"), "# from skel\n")
    System.put_env("LEPTON_STATE_DIR", state)
    System.put_env("LEPTON_HOME_ROOT", homes)
    on_exit(fn -> System.delete_env("LEPTON_STATE_DIR"); System.delete_env("LEPTON_HOME_ROOT") end)
    {:ok, alice} = Users.create("alice", "wonderland", gecos: "Alice", home_root: homes, skel: skel)
    %{state: state, homes: homes, alice: alice}
  end

  # A directory outside every user's home and the temp directories.
  defp outside do
    base = if Lepton.Sys.native?(), do: "/srv", else: System.tmp_dir!()
    dir = Path.join(base, "lepton-outside-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp run(cmd, opts \\ []) do
    {:ok, err} = StringIO.open("")
    {out, status} = sh(cmd, Keyword.put(opts, :stderr, err))
    {out, StringIO.flush(err), status}
  end

  defp stdin(text), do: elem(StringIO.open(text), 1)

  test "accounts: passwd, group and a 600 shadow with salted PBKDF2 hashes", %{state: state, homes: homes, alice: alice} do
    assert %Users{name: "alice", uid: 1000, gid: 1000, gecos: "Alice", home: "/home/alice", shell: "/bin/lsh"} = alice
    assert File.read!(Path.join(state, "passwd")) == "alice:x:1000:1000:Alice:/home/alice:/bin/lsh\n"
    assert File.read!(Path.join(state, "group")) =~ "sudo:x:27:alice\n"
    assert File.stat!(Path.join(state, "shadow")).mode |> Bitwise.band(0o777) == 0o600
    shadow = File.read!(Path.join(state, "shadow"))
    assert shadow =~ ~r/^alice:\$pbkdf2-sha512\$100000\$[A-Za-z0-9+\/]{22}\$[A-Za-z0-9+\/]{86}\n$/
    refute shadow =~ "wonderland"

    assert Users.verify("alice", "wonderland")
    refute Users.verify("alice", "Wonderland")
    refute Users.verify("nobody", "wonderland")
    assert Users.sudoer?("alice") and Users.sudoer?("root")
    assert File.read!(Path.join([homes, "alice", ".lshrc"])) == "# from skel\n"

    # Two salts, two hashes; the second user gets the next uid.
    refute Users.hash_password("x") == Users.hash_password("x")
    {:ok, bob} = Users.create("bob", "builder", sudo: false, home_root: homes, skel: "/nonexistent")
    assert bob.uid == 1001 and not Users.sudoer?("bob")
    assert {:error, "user 'bob' already exists"} = Users.create("bob", "x", home_root: homes)
    assert {:error, "invalid user name" <> _} = Users.create("root", "x", home_root: homes)
    assert {:error, "invalid user name" <> _} = Users.create("Bad Name", "x", home_root: homes)

    :ok = Users.set_password("bob", "fixer")
    assert Users.verify("bob", "fixer") and not Users.verify("bob", "builder")
    :ok = Users.delete("bob", remove_home: true, home_root: homes)
    assert Enum.map(Users.list(), & &1.name) == ["alice"]
    refute File.exists?(Path.join(homes, "bob"))

    etc = tmp_dir("etc")
    Users.sync_etc(etc)
    # (and the daemons' accounts: PostgreSQL's)
    assert File.read!(Path.join(etc, "passwd")) ==
             "root:x:0:0:root:/root:/bin/lsh\npostgres:x:70:70:PostgreSQL:/var/lib/lepton/postgresql:/bin/false\nalice:x:1000:1000:Alice:/home/alice:/bin/lsh\n"

    assert File.read!(Path.join(etc, "group")) == "root:x:0:\nsudo:x:27:alice\npostgres:x:70:\nalice:x:1000:\n"
  end

  test "users write in their home and the temp directories, not elsewhere; root writes anywhere", %{alice: alice} do
    ctx = Users.as(%Ctx{env: %{}}, alice)
    assert ctx.user == "alice" and ctx.env["HOME"] == "/home/alice" and ctx.env["USER"] == "alice"
    assert Users.check_write(ctx, "/home/alice/notes.txt") == :ok
    assert Users.check_write(ctx, "/tmp/x") == :ok
    assert Users.check_write(ctx, "/home/alicex/notes.txt") == {:error, :eacces}
    assert Users.check_write(ctx, "/etc/hosts") == {:error, :eacces}
    assert Users.check_write(%Ctx{}, "/etc/hosts") == :ok
    assert Users.check_read(ctx, Path.join(Lepton.Persist.state_dir(), "shadow")) == {:error, :eacces}
  end

  test "commands as a user: identity, refusals, file permissions" do
    dir = outside()
    assert {"alice\n", _, 0} = run("whoami", user: "alice")
    assert {"uid=1000(alice) gid=1000(alice) groups=1000(alice),27(sudo)\n", _, 0} = run("id", user: "alice")
    # The USER variable is not who you are.
    assert {"alice\n", _, 0} = run("USER=root whoami", user: "alice")

    assert {_, err, 1} = run("touch #{dir}/f", user: "alice")
    assert err =~ "touch: cannot touch '#{dir}/f': permission denied"
    assert {_, err, 1} = run("echo hi > #{dir}/g", user: "alice")
    assert err =~ "permission denied"
    assert {_, _, 1} = run("mkdir #{dir}/d", user: "alice")
    refute File.exists?(Path.join(dir, "f")) or File.exists?(Path.join(dir, "g")) or File.exists?(Path.join(dir, "d"))

    for cmd <- ["poweroff", "reboot", "modprobe loop", "umount /x", "lpm install jason", "svc start hello", "wifi forget", "useradd eve"] do
      assert {_, err, 1} = run(cmd, user: "alice")
      assert err =~ "permission denied: this needs root. Run it with sudo", "#{cmd}: #{err}"
    end

    # Reading and listing stay open.
    assert {_, _, 0} = run("mount", user: "alice")
    assert {_, _, 0} = run("svc list", user: "alice")
  end

  test "sudo asks for the user's password, then runs the command as root" do
    dir = outside()
    assert {"root\n", err, 0} = run("sudo -S whoami", user: "alice", stdin: stdin("wonderland\n"))
    assert err =~ "[sudo] password for alice: "
    assert {_, _, 0} = run("sudo -S touch #{dir}/made-by-sudo", user: "alice", stdin: stdin("wonderland\n"))
    assert File.exists?(Path.join(dir, "made-by-sudo"))

    assert {"", err, 1} = run("sudo -S whoami", user: "alice", stdin: stdin("no\nnope\nnein\n"))
    assert err =~ "Sorry, try again." and err =~ "sudo: 3 incorrect password attempts"

    assert {_, err, 1} = run("sudo whoami", user: "alice")
    assert err =~ "a terminal is required"
    assert {_, err, 1} = run("sudo -n whoami", user: "alice")
    assert err =~ "a password is required"

    {:ok, _} = Users.create("bob", "builder", sudo: false, home_root: tmp_dir("h"))
    assert {_, err, 1} = run("sudo -S whoami", user: "bob", stdin: stdin("builder\n"))
    assert err =~ "bob is not allowed to run sudo"
    assert {"User alice may run any command as root" <> _, _, 0} = run("sudo -l", user: "alice")
    assert {"root\n", _, 0} = run("sudo whoami")

    # The password is remembered per terminal for five minutes; -k forgets it.
    Users.sudo_touch("alice", :term1)
    assert Users.sudo_fresh?("alice", :term1)
    refute Users.sudo_fresh?("alice", :term2)
    Users.sudo_reset("alice")
    refute Users.sudo_fresh?("alice", :term1)
  end

  test "su: root becomes anyone; users need the target's password; root has none, so: sudo su" do
    assert {"alice\n", _, 0} = run("su alice -c whoami")
    assert {"/home/alice\n", _, 0} = run("su - alice -c pwd")
    assert {"", err, 1} = run("su -c whoami", user: "alice")
    assert err =~ "use: sudo su -"
    assert {"root\n", _, 0} = run("sudo -S su - -c whoami", user: "alice", stdin: stdin("wonderland\n"))
    assert {"/root\n", _, 0} = run("sudo -S su - -c pwd", user: "alice", stdin: stdin("wonderland\n"))
  end

  test "sudo su - opens a root shell; C-d returns to the user's shell" do
    alias Lepton.TTY
    {:ok, tty} = TTY.start(backend: {Lepton.TTY.Capture, nil})
    out = Path.join("/tmp", "lepton-su-#{System.unique_integer([:positive])}")
    File.mkdir_p!(out)
    on_exit(fn -> File.rm_rf(out) end)

    env = %{"HOME" => "/home/alice", "USER" => "alice", "TERM" => "dumb", "NO_COLOR" => "1", "PATH" => "/bin"}
    ctx = %Ctx{cwd: out, env: env, stdin: tty, stdout: tty, stderr: tty, tty: tty, user: "alice"}
    # alice typed her password a moment ago.
    Users.sudo_touch("alice", tty)
    shell = Task.async(fn -> Lepton.Shell.interactive(ctx) end)

    type = fn text -> Process.sleep(300); TTY.input(tty, text) end
    type.("sudo su -\r")
    type.("whoami > #{out}/in-su\r")
    type.(<<4>>)
    type.("whoami > #{out}/after\r")
    type.("exit\r")
    Task.await(shell, 10_000)

    assert File.read!(Path.join(out, "in-su")) == "root\n"
    assert File.read!(Path.join(out, "after")) == "alice\n"
  end

  test "root manages accounts: useradd, passwd, userdel" do
    assert {out, _, 0} = run("useradd --sudo -c 'Carol C' --password-stdin carol", stdin: stdin("secret1\n"))
    assert out =~ "Created carol (uid 1001, home /home/carol), allowed to use sudo."
    assert Users.verify("carol", "secret1") and Users.sudoer?("carol")
    assert {_, _, 0} = run("passwd --stdin carol", stdin: stdin("secret2\n"))
    assert Users.verify("carol", "secret2")
    assert {_, err, 1} = run("passwd carol", user: "alice")
    assert err =~ "permission denied"
    assert {_, _, 0} = run("userdel carol")
    assert Users.get("carol") == nil
  end
end
