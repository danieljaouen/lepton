defmodule Lepton.RsyncTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.Rsync
  alias Lepton.Rsync.{Delta, MD4}

  # Under /tmp, which every account may write to (the test's own temp
  # directory on a Mac is not).
  defp base do
    dir = "/tmp/lepton-rsync-#{System.unique_integer([:positive])}"
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp tree(dir) do
    File.mkdir_p!(Path.join(dir, "sub/deep"))
    File.write!(Path.join(dir, "a.txt"), "hello\n")
    File.write!(Path.join(dir, "sub/b.txt"), String.duplicate("bee ", 2000))
    File.write!(Path.join(dir, "sub/deep/c.bin"), :crypto.strong_rand_bytes(50_000))
    File.ln_s!("a.txt", Path.join(dir, "link"))
    File.touch!(Path.join(dir, "a.txt"), 1_700_000_000)
  end

  # Every file, link and directory below `dir`, with contents.
  defp snapshot(dir) do
    for p <- Path.wildcard(Path.join(dir, "**"), match_dot: true), into: %{} do
      rel = Path.relative_to(p, dir)

      value =
        case File.lstat!(p).type do
          :symlink -> {:link, File.read_link!(p)}
          :directory -> :dir
          :regular -> File.read!(p)
        end

      {rel, value}
    end
  end

  describe "the delta algorithm" do
    test "MD4 in Elixir: RFC 1320's test vectors, and the crypto library's where it has MD4" do
      vectors = [
        {"", "31d6cfe0d16ae931b73c59d7e0c089c0"},
        {"a", "bde52cb31de33e46245e05fbdbd6fb24"},
        {"abc", "a448017aaf21d8525fc10ae87aa6729d"},
        {"message digest", "d9130a8164549fe818874806e1c7014b"},
        {"abcdefghijklmnopqrstuvwxyz", "d79e1c308aa5bbcdeea8ed63df412da9"},
        {String.duplicate("1234567890", 8), "e33b4ddc9c38f2199c3e7b164fcc0536"}
      ]

      for {m, hex} <- vectors, do: assert(Base.encode16(MD4.hash(m), case: :lower) == hex)

      crypto? = try do
        :crypto.hash(:md4, "")
        true
      rescue
        _ -> false
      end

      if crypto? do
        for n <- [55, 56, 63, 64, 65, 1000], m = :crypto.strong_rand_bytes(n), do: assert(MD4.hash(m) == :crypto.hash(:md4, m))
      end
    end

    test "rolling checksums count bytes as signed, as rsync does" do
      assert Delta.rolling(<<1, 2, 3>>) == {6, 10}
      assert Delta.rolling(<<255>>) == {-1, -1}
    end

    test "a changed file is rebuilt from blocks and a little literal data" do
      old = :crypto.strong_rand_bytes(20_000)
      new = binary_part(old, 0, 7000) <> "inserted" <> binary_part(old, 7000, 13_000)
      sig = Delta.signature(old, 42)
      tokens = Delta.tokens(new, sig, 42)
      {_, blength, _, _, _} = sig
      rebuilt = Enum.map_join(tokens, fn {:literal, d} -> d; {:block, i} -> binary_part(old, i * blength, min(blength, 20_000 - i * blength)) end)
      assert rebuilt == new
      assert (for {:literal, d} <- tokens, reduce: 0, do: (n -> n + byte_size(d))) < 1500
    end

    test "-z tokens: compressed literal data and matched blocks seen by the inflater" do
      data = String.duplicate("compress me ", 10_000) <> :crypto.strong_rand_bytes(3000)
      wire = IO.iodata_to_binary(Delta.encode_compressed(data))
      assert byte_size(wire) < byte_size(data)
      {:ok, dev} = StringIO.open(wire)
      read = fn n -> IO.binread(dev, n) end
      assert IO.iodata_to_binary(Delta.decode_compressed(read, fn _ -> raise "no blocks" end, 27)) == data
    end
  end

  describe "local copies" do
    test "dir/ copies the contents, dir copies the directory; links, times, -v" do
      b = base()
      tree(Path.join(b, "src"))
      {out, 0} = sh("rsync -av #{b}/src/ #{b}/dst")
      assert snapshot(Path.join(b, "dst")) == snapshot(Path.join(b, "src"))
      assert File.lstat!(Path.join(b, "dst/a.txt"), time: :posix).mtime == 1_700_000_000
      for line <- ["a.txt", "sub/", "sub/deep/c.bin", "link -> a.txt"], do: assert(out =~ line)
      assert out =~ ~r/sent \d+ bytes  received \d+ bytes/

      {_, 0} = sh("rsync -a #{b}/src #{b}/into")
      assert snapshot(Path.join(b, "into/src")) == snapshot(Path.join(b, "src"))

      {_, 0} = sh("rsync #{b}/src/a.txt #{b}/renamed.txt")
      assert File.read!(Path.join(b, "renamed.txt")) == "hello\n"
    end

    test "a second run sends only what changed; --delete and --exclude" do
      b = base()
      tree(Path.join(b, "src"))
      {_, 0} = sh("rsync -a #{b}/src/ #{b}/dst/")
      File.write!(Path.join(b, "src/sub/b.txt"), String.duplicate("bee ", 2000) <> "more")
      File.write!(Path.join(b, "dst/stale.txt"), "old")
      File.write!(Path.join(b, "dst/keep.log"), "excluded, so kept")

      {out, 0} = sh("rsync -av --delete --exclude '*.log' #{b}/src/ #{b}/dst/")
      assert out =~ "sub/b.txt"
      refute out =~ "a.txt\n"
      assert out =~ "deleting stale.txt"
      refute File.exists?(Path.join(b, "dst/stale.txt"))
      assert File.exists?(Path.join(b, "dst/keep.log"))
      assert File.read!(Path.join(b, "dst/sub/b.txt")) == File.read!(Path.join(b, "src/sub/b.txt"))
    end

    test "-n changes nothing; -u keeps newer files; -c compares contents" do
      b = base()
      tree(Path.join(b, "src"))
      {out, 0} = sh("rsync -avn #{b}/src/ #{b}/dst/")
      assert out =~ "sub/b.txt" and out =~ "DRY RUN"
      refute File.exists?(Path.join(b, "dst"))

      {_, 0} = sh("rsync -a #{b}/src/ #{b}/dst/")
      File.write!(Path.join(b, "dst/a.txt"), "newer\n")
      {_, 0} = sh("rsync -au #{b}/src/ #{b}/dst/")
      assert File.read!(Path.join(b, "dst/a.txt")) == "newer\n"

      # Same size and time, different contents: only -c notices.
      File.write!(Path.join(b, "dst/a.txt"), "HELLO\n")
      File.touch!(Path.join(b, "dst/a.txt"), 1_700_000_000)
      {_, 0} = sh("rsync -a #{b}/src/ #{b}/dst/")
      assert File.read!(Path.join(b, "dst/a.txt")) == "HELLO\n"
      {_, 0} = sh("rsync -ac #{b}/src/ #{b}/dst/")
      assert File.read!(Path.join(b, "dst/a.txt")) == "hello\n"
    end

    test "options and operands it can't honour are refused" do
      assert {_, 1} = sh("rsync -H /tmp/x /tmp/y")
      assert {_, 1} = sh("rsync onlyone")
      assert Rsync.locate("me@mac:dir/") == {:remote, "me@mac", "dir/"}
      assert Rsync.locate("/abs:path") == {:local, "/abs:path"}
      assert Rsync.server_command(%Rsync.Opts{recursive: true, times: true, delete: true}, true, ["a b"]) == "rsync --server --sender -tr --delete . 'a b'"
    end
  end

  describe "over SSH, with Lepton at both ends" do
    setup do
      b = base()
      System.put_env("LEPTON_STATE_DIR", Path.join(b, "state"))
      System.put_env("LEPTON_HOME_ROOT", Path.join(b, "homes"))
      on_exit(fn -> System.delete_env("LEPTON_STATE_DIR"); System.delete_env("LEPTON_HOME_ROOT") end)
      {:ok, _} = Lepton.Users.create("alice", "pw", home_root: Path.join(b, "homes"), skel: tmp_dir("skel"))
      home = Path.join(b, "homes/alice")

      client = Path.join(b, "client")
      key = Lepton.SSH.generate()
      File.mkdir_p!(Path.join(client, ".ssh"))
      File.write!(Path.join(client, ".ssh/id_ed25519"), Lepton.SSH.encode_private(key, "t"))
      File.chmod!(Path.join(client, ".ssh/id_ed25519"), 0o600)
      File.write!(Path.join(client, ".ssh/id_ed25519.pub"), Lepton.SSH.public_line(Lepton.SSH.public(key), "t") <> "\n")
      File.mkdir_p!(Path.join(home, ".ssh"))
      File.cp!(Path.join(client, ".ssh/id_ed25519.pub"), Path.join(home, ".ssh/authorized_keys"))
      File.chmod!(Path.join(home, ".ssh/authorized_keys"), 0o600)

      {:ok, d} = Lepton.SSHD.start(0, host_key: Path.join(b, "state/hostkey"), home: &Path.join(Path.join(b, "homes"), &1.name))
      {:ok, info} = :ssh.daemon_info(d)
      on_exit(fn -> Lepton.SSHD.stop(d) end)
      tree(Path.join(b, "src"))
      %{b: b, home: home, client: client, port: info[:port]}
    end

    test "push and pull", %{b: b, home: home, client: client, port: port} do
      e = "-e 'ssh -p #{port} -o StrictHostKeyChecking=no'"
      {out, 0} = sh("rsync -av #{e} #{b}/src/ alice@127.0.0.1:copy/", home: client)
      assert out =~ "sub/deep/c.bin"
      assert snapshot(Path.join(home, "copy")) == snapshot(Path.join(b, "src"))

      File.write!(Path.join(home, "copy/sub/new.txt"), "made on the server")
      {_, 0} = sh("rsync -a #{e} alice@127.0.0.1:copy/ #{b}/back/", home: client)
      assert File.read!(Path.join(b, "back/sub/new.txt")) == "made on the server"
      assert snapshot(Path.join(b, "back")) == snapshot(Path.join(home, "copy"))
    end
  end

  describe "with the real rsync" do
    @describetag :interop

    setup do
      case System.find_executable("rsync") do
        nil -> {:ok, skip: true}
        path -> {:ok, rsync: path}
      end
    end

    test "Lepton as the client: push to and pull from rsync --server", ctx do
      if ctx[:skip], do: :ok, else: interop_client(ctx.rsync)
    end

    test "rsync as the client, with Lepton's sshd and rsync --server (-z too)", ctx do
      ssh = System.find_executable("ssh")
      if ctx[:skip] || ssh == nil || Lepton.Sys.native?(), do: :ok, else: interop_server(ctx.rsync)
    end
  end

  defp interop_client(rsync) do
    b = base()
    tree(Path.join(b, "src"))
    io = Process.group_leader()
    ctx = %Lepton.Ctx{cwd: b, env: %{"HOME" => b}, stdout: elem(StringIO.open(""), 1), stderr: io}
    open = fn _host, command -> Rsync.port(command, ctx) end
    path = "--rsync-path=#{rsync}"

    assert Rsync.run(["-a", path, "src/", "mac:#{b}/pushed/"], ctx, open) == 0
    assert snapshot(Path.join(b, "pushed")) == snapshot(Path.join(b, "src"))
    assert Rsync.run(["-a", path, "--delete", "mac:#{b}/src/", "pulled"], ctx, open) == 0
    assert snapshot(Path.join(b, "pulled")) == snapshot(Path.join(b, "src"))

    File.write!(Path.join(b, "src/sub/deep/c.bin"), "x" <> File.read!(Path.join(b, "src/sub/deep/c.bin")))
    assert Rsync.run(["-a", path, "src/", "mac:#{b}/pushed/"], ctx, open) == 0
    assert snapshot(Path.join(b, "pushed")) == snapshot(Path.join(b, "src"))
  end

  defp interop_server(rsync) do
    b = base()
    System.put_env("LEPTON_STATE_DIR", Path.join(b, "state"))
    System.put_env("LEPTON_HOME_ROOT", Path.join(b, "homes"))
    on_exit(fn -> System.delete_env("LEPTON_STATE_DIR"); System.delete_env("LEPTON_HOME_ROOT") end)
    {:ok, _} = Lepton.Users.create("alice", "pw", home_root: Path.join(b, "homes"), skel: tmp_dir("skel"))
    home = Path.join(b, "homes/alice")
    key = Path.join(b, "id")
    {_, 0} = System.cmd("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key])
    File.mkdir_p!(Path.join(home, ".ssh"))
    File.cp!(key <> ".pub", Path.join(home, ".ssh/authorized_keys"))
    File.chmod!(Path.join(home, ".ssh/authorized_keys"), 0o600)
    {:ok, d} = Lepton.SSHD.start(0, host_key: Path.join(b, "state/hostkey"), home: &Path.join(Path.join(b, "homes"), &1.name))
    {:ok, info} = :ssh.daemon_info(d)
    on_exit(fn -> Lepton.SSHD.stop(d) end)
    tree(Path.join(b, "src"))
    e = "ssh -p #{info[:port]} -i #{key} -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR"
    clients = Enum.uniq(Enum.filter([rsync, "/usr/bin/rsync", "/opt/homebrew/bin/rsync"], &File.exists?/1))

    for {client, i} <- Enum.with_index(clients), flags <- ["-av", "-avz"] do
      dir = "c#{i}#{flags}"
      {out, st} = System.cmd(client, ["-e", e, flags, "#{b}/src/", "alice@127.0.0.1:#{dir}/"], stderr_to_stdout: true)
      assert st == 0, "#{client} #{flags} push: #{out}"
      assert snapshot(Path.join(home, dir)) == snapshot(Path.join(b, "src"))
      {out, st} = System.cmd(client, ["-e", e, flags, "alice@127.0.0.1:#{dir}/", "#{b}/back-#{dir}/"], stderr_to_stdout: true)
      assert st == 0, "#{client} #{flags} pull: #{out}"
      assert snapshot(Path.join(b, "back-#{dir}")) == snapshot(Path.join(b, "src"))
    end
  end
end
