defmodule Lepton.SSHFSTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.{SSH, SSHD, SSHFS, Users}

  setup do
    state = tmp_dir("sshfsstate")
    homes = "/tmp/lepton-sshfshomes-#{System.unique_integer([:positive])}"
    File.mkdir_p!(homes)
    System.put_env("LEPTON_STATE_DIR", state)
    System.put_env("LEPTON_HOME_ROOT", homes)
    on_exit(fn -> System.delete_env("LEPTON_STATE_DIR"); System.delete_env("LEPTON_HOME_ROOT"); File.rm_rf(homes) end)
    {:ok, _} = Users.create("alice", "pw", home_root: homes, skel: tmp_dir("skel"))
    home = Path.join(homes, "alice")
    File.write!(Path.join(home, "a.txt"), "hello")
    File.mkdir_p!(Path.join(home, "docs"))
    File.write!(Path.join(home, "docs/b.txt"), "bee")

    client = tmp_dir("sshfsclient")
    key = SSH.generate()
    File.mkdir_p!(Path.join(client, ".ssh"))
    File.write!(Path.join(client, ".ssh/id_ed25519"), SSH.encode_private(key, "t"))
    File.chmod!(Path.join(client, ".ssh/id_ed25519"), 0o600)
    File.mkdir_p!(Path.join(home, ".ssh"))
    File.write!(Path.join(home, ".ssh/authorized_keys"), SSH.public_line(SSH.public(key), "t") <> "\n")
    File.chmod!(Path.join(home, ".ssh/authorized_keys"), 0o600)

    {:ok, d} = SSHD.start(0, host_key: Path.join(state, "hostkey"), home: &Path.join(homes, &1.name))
    {:ok, info} = :ssh.daemon_info(d)
    on_exit(fn -> SSHD.stop(d) end)
    %{home: home, client: client, port: info[:port]}
  end

  defp opts(ctx), do: [home: ctx.client, port: ctx.port, strict: "no", uid: 1000, gid: 1000]

  # A FUSE request as the kernel writes it.
  defp req(op, node, body) do
    <<40 + byte_size(body)::little-32, op::little-32, 7::little-64, node::little-64, 0::32, 0::32, 0::32, 0::32>> <> body
  end

  defp call(st, op, node, body \\ "") do
    {reply, st} = SSHFS.handle(req(op, node, body), st)
    <<len::little-32, err::little-signed-32, 7::little-64, data::binary>> = IO.iodata_to_binary(reply)
    assert len == 16 + byte_size(data)
    {err, data, st}
  end

  defp attr(<<_ino::little-64, size::little-64, _blocks::little-64, _a::little-64, mtime::little-64, _c::little-64, _::binary-12, mode::little-32, _nlink::little-32, uid::little-32, _::binary>>),
    do: %{size: size, mtime: mtime, mode: mode, uid: uid}

  defp entry(<<node::little-64, _gen::little-64, _ev::little-64, _av::little-64, _::binary-8, a::binary-88, rest::binary>>), do: {node, attr(a), rest}

  test "SFTP on Lepton's sshd: each account in its home", ctx do
    {:ok, conn, _} = SSH.connect("alice@127.0.0.1", opts(ctx))
    {:ok, ch} = :ssh_sftp.start_channel(conn)
    {:ok, names} = :ssh_sftp.list_dir(ch, ~c"/")
    assert ~c"a.txt" in names and ~c"docs" in names
    assert {:ok, "bee"} = :ssh_sftp.read_file(ch, ~c"/docs/b.txt")
    # no way out of the home
    {:ok, up} = :ssh_sftp.list_dir(ch, ~c"/../..")
    assert Enum.sort(up) == Enum.sort(names)
    SSH.close(conn)
  end

  test "the FUSE requests, answered over SFTP", ctx do
    {:ok, st} = SSHFS.connect("alice@127.0.0.1", "", opts(ctx))

    # INIT: protocol 7.x, writes of 32 KiB
    {0, <<7::little-32, _minor::little-32, _::binary-12, 32_768::little-32, _::binary>>, st} = call(st, 26, 0, <<7::little-32, 40::little-32, 131_072::little-32, 0::little-32>>)

    # LOOKUP, GETATTR: owned by the mounting account
    {0, data, st} = call(st, 1, 1, "a.txt\0")
    {a, %{size: 5, mode: mode, uid: 1000}, ""} = entry(data)
    assert Bitwise.band(mode, 0o170000) == 0o100000
    assert {-2, "", st} = call(st, 1, 1, "missing\0")

    # OPEN, READ, WRITE
    {0, <<fh::little-64, _::binary>>, st} = call(st, 14, a, <<2::little-32, 0::little-32>>)
    {0, "hello", st} = call(st, 15, a, <<fh::little-64, 0::little-64, 100::little-32, 0::size(160)>>)
    {0, <<5::little-32, 0::little-32>>, st} = call(st, 16, a, <<fh::little-64, 5::little-64, 5::little-32, 0::little-32, 0::little-64, 0::little-32, 0::little-32>> <> "world")
    {0, "", st} = call(st, 18, a, <<fh::little-64>>)
    assert File.read!(Path.join(ctx.home, "a.txt")) == "helloworld"

    # CREATE in a directory looked up first, then MKDIR, READDIR
    {0, data, st} = call(st, 1, 1, "docs\0")
    {docs, %{mode: dmode}, ""} = entry(data)
    assert Bitwise.band(dmode, 0o170000) == 0o040000
    {0, data, st} = call(st, 35, docs, <<0o101::little-32, 0o644::little-32, 0::little-32, 0::little-32>> <> "new.txt\0")
    {_new, _, <<nfh::little-64, _::binary>>} = entry(data)
    {0, _, st} = call(st, 16, docs, <<nfh::little-64, 0::little-64, 3::little-32, 0::size(160)>> <> "new")
    {0, "", st} = call(st, 18, docs, <<nfh::little-64>>)
    assert File.read!(Path.join(ctx.home, "docs/new.txt")) == "new"

    {0, _, st} = call(st, 9, docs, <<0o755::little-32, 0::little-32>> <> "sub\0")
    assert File.dir?(Path.join(ctx.home, "docs/sub"))
    {0, <<dfh::little-64, _::binary>>, st} = call(st, 27, docs)
    {0, listing, st} = call(st, 28, docs, <<dfh::little-64, 0::little-64, 4096::little-32, 0::size(160)>>)
    for n <- [".", "..", "b.txt", "new.txt", "sub"], do: assert(listing =~ n)

    # RENAME (replacing, as POSIX does), SYMLINK, READLINK, UNLINK, RMDIR
    {0, "", st} = call(st, 12, docs, <<docs::little-64>> <> "new.txt\0b.txt\0")
    assert File.read!(Path.join(ctx.home, "docs/b.txt")) == "new"
    refute File.exists?(Path.join(ctx.home, "docs/new.txt"))
    {0, data, st} = call(st, 6, 1, "link\0a.txt\0")
    {link, _, ""} = entry(data)
    # (OTP's SFTP server shows link targets inside its root, as /a.txt)
    {0, target, st} = call(st, 5, link)
    assert String.ends_with?(target, "a.txt")
    assert File.read_link!(Path.join(ctx.home, "link")) |> String.ends_with?("a.txt")
    {0, "", st} = call(st, 10, 1, "link\0")
    {0, "", st} = call(st, 11, docs, "sub\0")
    refute File.exists?(Path.join(ctx.home, "docs/sub"))

    # SETATTR: size (truncate), mode and modification time
    body = <<(8 + 1 + 32)::little-32, 0::little-32, 0::little-64, 2::little-64, 0::little-64, 0::little-64, 1_700_000_000::little-64, 0::little-64, 0::size(96), 0o600::little-32, 0::size(128)>>
    {0, data, st} = call(st, 4, a, body)
    <<_valid::binary-16, a2::binary>> = data
    assert %{size: 2, mtime: 1_700_000_000} = attr(a2)
    assert File.read!(Path.join(ctx.home, "a.txt")) == "he"
    assert Bitwise.band(File.stat!(Path.join(ctx.home, "a.txt")).mode, 0o777) == 0o600

    # what isn't implemented says so; FORGET has no reply
    assert {-38, "", st} = call(st, 999, 1)
    assert {nil, _} = SSHFS.handle(req(2, a, <<1::little-64>>), st)
  end

  @tag :native
  test "a real mount: the kernel's FUSE, files read and written through it", ctx do
    mnt = tmp_dir("sshfsmnt")
    {:ok, pid} = SSHFS.mount("alice@127.0.0.1:", mnt, opts(ctx))
    on_exit(fn -> SSHFS.unmount(mnt) end)
    assert File.read!(Path.join(mnt, "a.txt")) == "hello"
    assert "docs" in File.ls!(mnt)
    File.write!(Path.join(mnt, "docs/from-fuse.txt"), "through the kernel")
    assert File.read!(Path.join(ctx.home, "docs/from-fuse.txt")) == "through the kernel"
    {out, 0} = sh("ls -l #{mnt}/docs")
    assert out =~ "from-fuse.txt"
    ref = Process.monitor(pid)
    assert :ok = SSHFS.unmount(mnt)
    assert_receive {:DOWN, ^ref, _, _, _}, 5000
    refute File.exists?(Path.join(mnt, "a.txt"))
  end
end
