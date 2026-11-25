defmodule Lepton.SSHDTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.{SSH, SSHD, Users}

  # A daemon on a free port, with alice's home in a temporary directory and
  # a client key of hers in its authorized_keys.
  setup do
    state = tmp_dir("sshdstate")
    homes = tmp_dir("sshdhomes")
    System.put_env("LEPTON_STATE_DIR", state)
    System.put_env("LEPTON_HOME_ROOT", homes)
    on_exit(fn -> System.delete_env("LEPTON_STATE_DIR"); System.delete_env("LEPTON_HOME_ROOT") end)
    {:ok, _} = Users.create("alice", "wonderland", home_root: homes, skel: tmp_dir("skel"))
    home = fn account -> Path.join(homes, account.name) end

    client = tmp_dir("sshdclient")
    key = SSH.generate()
    File.mkdir_p!(Path.join(client, ".ssh"))
    File.write!(Path.join(client, ".ssh/id_ed25519"), SSH.encode_private(key, "me@mac"))
    File.chmod!(Path.join(client, ".ssh/id_ed25519"), 0o600)

    auth = Path.join(homes, "alice/.ssh/authorized_keys")
    File.mkdir_p!(Path.dirname(auth))
    File.write!(auth, "# my Mac\nno-pty,from=\"10.0.0.0/8\" " <> SSH.public_line(SSH.public(key), "me@mac") <> "\n")
    File.chmod!(auth, 0o600)

    {:ok, daemon} = SSHD.start(0, host_key: Path.join(state, "ssh/ssh_host_ed25519_key"), home: home, log: self())
    {:ok, info} = :ssh.daemon_info(daemon)
    on_exit(fn -> SSHD.stop(daemon) end)
    %{port: info[:port], client: client, auth: auth, state: state, homes: homes}
  end

  defp connect(%{port: port, client: client}, user \\ "alice") do
    SSH.connect("#{user}@127.0.0.1", home: client, port: port, strict: "no")
  end

  defp run(conn, command, input \\ nil) do
    {:ok, ch} = SSH.exec(conn, command)

    if input do
      :ssh_connection.send(conn, ch, input)
      :ssh_connection.send_eof(conn, ch)
    end

    SSH.recv_all(conn, ch, 20_000)
  end

  test "a key in authorized_keys logs in; commands run as the account, with their exit status", ctx do
    assert {:ok, conn, _} = connect(ctx)
    assert {"alice\n" <> home, "", 0} = run(conn, "whoami; pwd")
    assert home == Path.join(ctx.homes, "alice") <> "\n"
    assert {"", "oops\n", 3} = run(conn, "echo oops >&2; exit 3")
    assert {"hello from the mac\n", "", 0} = run(conn, "cat", "hello from the mac\n")
    SSH.close(conn)
    assert_receive {:sshd_log, "accepted publickey for alice from 127.0.0.1"}, 2000
  end

  test "the host key is made once, kept, and offered as ed25519", ctx do
    path = Path.join(ctx.state, "ssh/ssh_host_ed25519_key")
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    assert File.read!(path <> ".pub") =~ ~r/^ssh-ed25519 /
    {:ok, key} = SSHD.host_key(path)
    assert {:ok, [scanned]} = SSH.scan("127.0.0.1", ctx.port)
    assert SSH.blob(scanned) == SSH.blob(SSH.public(key))
  end

  # OpenSSH 10 warns about a connection without it. Lepton's crypto has
  # ML-KEM from OpenSSL 3.5 (Ubuntu 26.04's, which the image ships).
  test "the key exchange is post-quantum: mlkem768x25519-sha256", ctx do
    assert hd(:ssh.default_algorithms()[:kex]) == :"mlkem768x25519-sha256"
    assert {:ok, conn, _} = connect(ctx)
    assert :ssh.connection_info(conn, [:algorithms])[:algorithms][:kex] == :"mlkem768x25519-sha256"
    SSH.close(conn)
  end

  test "passwords never work, and neither do other keys, other accounts or a writable authorized_keys", ctx do
    # The right password, but the daemon offers public keys only.
    assert {:error, _} =
             :ssh.connect(~c"127.0.0.1", ctx.port,
               user: ~c"alice", password: ~c"wonderland", auth_methods: ~c"password,keyboard-interactive",
               silently_accept_hosts: true, user_interaction: false, save_accepted_host: false, quiet_mode: true)

    assert {:error, msg} = connect(ctx, "bob")
    assert msg =~ "Permission denied (publickey)"
    assert {:error, _} = connect(ctx, "root")

    other = tmp_dir("sshdother")
    File.mkdir_p!(Path.join(other, ".ssh"))
    File.write!(Path.join(other, ".ssh/id_ed25519"), SSH.encode_private(SSH.generate(), "x"))
    File.chmod!(Path.join(other, ".ssh/id_ed25519"), 0o600)
    assert {:error, _} = connect(%{ctx | client: other})

    File.chmod!(ctx.auth, 0o620)
    assert {:error, _} = connect(ctx)
    assert_receive {:sshd_log, "refused key SHA256:" <> _}, 2000
  end

  test "a terminal session: login shell, the client's TERM and size, resizes, exit", ctx do
    {:ok, conn, _} = connect(ctx)
    {:ok, ch} = :ssh_connection.session_channel(conn, 10_000)
    :success = :ssh_connection.ptty_alloc(conn, ch, [term: ~c"xterm-256color", width: 100, height: 30], 10_000)
    :ok = :ssh_connection.shell(conn, ch)
    # Type once the prompt is up, as a person would.
    assert {:ok, _} = SSH.recv_until(conn, ch, &(&1 =~ "❯" or &1 =~ ">"), 20_000)
    :ssh_connection.send(conn, ch, "echo T=$TERM; stty size\r")
    assert {:ok, out} = SSH.recv_until(conn, ch, &(&1 =~ "30 100"), 20_000)
    assert out =~ "T=xterm-256color"

    :ssh_connection.window_change(conn, ch, 90, 40)
    Process.sleep(100)
    :ssh_connection.send(conn, ch, "stty size; exit 7\r")
    assert {:closed, out, _, 7} = SSH.recv_until(conn, ch, fn _ -> false end, 20_000)
    assert out =~ "40 90"

    # A client without a terminal of its own reports 0x0.
    {:ok, ch} = :ssh_connection.session_channel(conn, 10_000)
    :success = :ssh_connection.ptty_alloc(conn, ch, [term: ~c"dumb", width: 0, height: 0], 10_000)
    :success = :ssh_connection.exec(conn, ch, ~c"stty size", 10_000)
    assert {:closed, "24 80\r\n", _, 0} = SSH.recv_until(conn, ch, fn _ -> false end, 20_000)
    SSH.close(conn)
  end

  test "the daemon goes with the process that started it, even killed (svc restart: port 22 free again)", ctx do
    me = self()

    owner =
      spawn(fn ->
        {:ok, d} = SSHD.start(0, host_key: Path.join(ctx.state, "ssh/ssh_host_ed25519_key"), home: &Path.join(ctx.homes, &1.name))
        SSHD.bind_to(d)
        {:ok, info} = :ssh.daemon_info(d)
        send(me, {:port, info[:port]})
        Process.sleep(:infinity)
      end)

    assert_receive {:port, port}, 5000
    assert {:ok, s} = :gen_tcp.connect(~c"127.0.0.1", port, [], 1000)
    :gen_tcp.close(s)
    Process.exit(owner, :kill)
    free = fn -> match?({:error, :econnrefused}, :gen_tcp.connect(~c"127.0.0.1", port, [], 1000)) end
    assert Enum.any?(1..50, fn _ -> free.() || (Process.sleep(100) && false) end)
  end

  test "authorized_keys: comments, options and unreadable lines" do
    key = SSH.public(SSH.generate())
    text = "# c\n\ngarbage\ncommand=\"ls\",no-pty #{SSH.public_line(key, "x")}\nssh-ed25519 AAAAnotbase64!!\n"
    assert [k] = SSHD.authorized_keys(text)
    assert SSH.blob(k) == SSH.blob(key)
  end

  test "sshd is a root command, and its service ships disabled" do
    {_, status} = sh("sshd", user: "alice")
    assert status == 1

    unit = if Lepton.Sys.native?(), do: "/etc/lepton/services/sshd.service", else: "rootfs/etc/lepton/services/sshd.service"
    assert File.read!(unit) =~ "ExecStart=sshd"
    refute Lepton.Services.enabled?("sshd")
  end
end
