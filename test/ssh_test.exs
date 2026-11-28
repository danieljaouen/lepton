defmodule Lepton.SSHTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.{Git, SSH}
  alias Lepton.Git.{Object, Pack, Remote, Repo}

  # A git server for the tests: OTP's SSH daemon running git-upload-pack and
  # git-receive-pack (protocol v0, side-band-64k) on Lepton's own git store,
  # plus `echo` and a GitHub-style "no shell access" greeting.
  defmodule Server do
    @behaviour :ssh_server_channel

    @impl true
    def init([root]), do: {:ok, %{root: root, cm: nil, ch: nil, service: nil, repo: nil, buf: "", pty: nil}}

    @impl true
    def handle_msg({:ssh_channel_up, ch, cm}, st), do: {:ok, %{st | ch: ch, cm: cm}}
    def handle_msg(_, st), do: {:ok, st}

    @impl true
    def handle_ssh_msg({:ssh_cm, cm, {:exec, ch, reply, cmd}}, st) do
      :ssh_connection.reply_request(cm, reply, :success, ch)

      case Regex.run(~r/^(git-upload-pack|git-receive-pack) '(.+)'$/, to_string(cmd)) do
        [_, service, path] ->
          dir = Path.join(st.root, path |> String.trim_leading("/") |> String.replace_suffix(".git", ""))

          if File.dir?(Path.join(dir, ".git")) do
            repo = Repo.open(dir)
            :ssh_connection.send(cm, ch, advertise(repo, service))
            {:ok, %{st | service: service, repo: repo}}
          else
            :ssh_connection.send(cm, ch, 1, "ERROR: Repository not found.\n")
            finish(cm, ch, 1, st)
          end

        nil ->
          case to_string(cmd) do
            "echo " <> text -> :ssh_connection.send(cm, ch, text <> "\n"); finish(cm, ch, 0, st)
            "cat" -> {:ok, %{st | service: :cat}}
            _ -> :ssh_connection.send(cm, ch, 1, "command not found\n"); finish(cm, ch, 127, st)
          end
      end
    end

    def handle_ssh_msg({:ssh_cm, cm, {:pty, ch, reply, {term, cols, rows, _, _, _}}}, st) do
      :ssh_connection.reply_request(cm, reply, :success, ch)
      {:ok, %{st | pty: "#{term} #{cols}x#{rows}"}}
    end

    def handle_ssh_msg({:ssh_cm, cm, {:window_change, ch, cols, rows, _, _}}, st) do
      :ssh_connection.send(cm, ch, "size #{cols}x#{rows}\r\n")
      {:ok, st}
    end

    # With a terminal: an echoing "shell" that ends at `exit`.
    def handle_ssh_msg({:ssh_cm, cm, {:shell, ch, reply}}, %{pty: pty} = st) when pty != nil do
      :ssh_connection.reply_request(cm, reply, :success, ch)
      :ssh_connection.send(cm, ch, "remote ready #{pty}\r\n")
      {:ok, %{st | service: :shell}}
    end

    def handle_ssh_msg({:ssh_cm, cm, {:shell, ch, reply}}, st) do
      :ssh_connection.reply_request(cm, reply, :success, ch)
      :ssh_connection.send(cm, ch, 1, "Hi tester! You've successfully authenticated, but there is no shell access.\n")
      finish(cm, ch, 1, st)
    end

    def handle_ssh_msg({:ssh_cm, cm, {:data, ch, 0, data}}, %{service: :shell} = st) do
      :ssh_connection.adjust_window(cm, ch, byte_size(data))
      :ssh_connection.send(cm, ch, data)
      st = %{st | buf: st.buf <> data}
      if String.ends_with?(st.buf, "exit\r"), do: finish(cm, ch, 3, st), else: {:ok, st}
    end

    def handle_ssh_msg({:ssh_cm, cm, {:data, ch, 0, data}}, %{service: service} = st) when is_binary(service) do
      :ssh_connection.adjust_window(cm, ch, byte_size(data))
      st = %{st | buf: st.buf <> data}

      cond do
        st.buf == "0000" -> finish(cm, ch, 0, st)
        st.service == "git-upload-pack" and String.ends_with?(st.buf, "0009done\n") -> upload(cm, ch, st)
        true -> {:ok, st}
      end
    end

    def handle_ssh_msg({:ssh_cm, cm, {:data, ch, 0, data}}, %{service: :cat} = st) do
      :ssh_connection.adjust_window(cm, ch, byte_size(data))
      :ssh_connection.send(cm, ch, data)
      {:ok, st}
    end

    def handle_ssh_msg({:ssh_cm, cm, {:eof, ch}}, %{service: "git-receive-pack", buf: buf} = st) when buf != "", do: receive_pack(cm, ch, st)
    def handle_ssh_msg({:ssh_cm, cm, {:eof, ch}}, st), do: finish(cm, ch, 0, st)
    def handle_ssh_msg(_, st), do: {:ok, st}

    @impl true
    def terminate(_, _), do: :ok

    defp finish(cm, ch, status, st) do
      :ssh_connection.exit_status(cm, ch, status)
      :ssh_connection.send_eof(cm, ch)
      {:stop, ch, st}
    end

    defp advertise(repo, service) do
      heads = for b <- Git.branches(repo), do: {"refs/heads/" <> b, Git.resolve_ref(repo, "refs/heads/" <> b)}
      refs = if service == "git-upload-pack" and heads != [], do: [{"HEAD", Git.head_sha(repo)} | heads], else: heads
      caps = if service == "git-upload-pack", do: "side-band-64k ofs-delta symref=HEAD:refs/heads/#{Git.current_branch(repo)}", else: "report-status side-band-64k"

      lines =
        case refs do
          [] -> [Remote.pkt(String.duplicate("0", 40) <> " capabilities^{}\0" <> caps <> "\n")]
          [{ref, sha} | rest] -> [Remote.pkt("#{sha} #{ref}\0#{caps}\n") | for({r, s} <- rest, do: Remote.pkt("#{s} #{r}\n"))]
        end

      IO.iodata_to_binary([lines, Remote.flush()])
    end

    defp upload(cm, ch, st) do
      lines = Remote.parse_pkts(st.buf) |> Enum.filter(&is_binary/1)
      wants = for "want " <> rest <- lines, do: binary_part(rest, 0, 40)
      haves = for "have " <> rest <- lines, Object.exists?(st.repo, String.trim(rest)), do: String.trim(rest)
      have = reachable(st.repo, haves, MapSet.new())
      shas = st.repo |> reachable(wants, MapSet.new()) |> MapSet.difference(have)
      pack = Pack.encode(Enum.map(shas, &Object.read!(st.repo, &1)))
      chunks = for <<chunk::binary-size(1000) <- pack>>, do: Remote.pkt(<<1>> <> chunk)
      tail = binary_part(pack, length(chunks) * 1000, byte_size(pack) - length(chunks) * 1000)
      :ssh_connection.send(st.cm, ch, IO.iodata_to_binary([Remote.pkt("NAK\n"), chunks, Remote.pkt(<<1>> <> tail), Remote.flush()]))
      finish(cm, ch, 0, st)
    end

    defp receive_pack(cm, ch, st) do
      {commands, pack} = split_commands(st.buf, [])
      objects = Pack.decode(pack, fn sha -> case Object.read(st.repo, sha) do
        {:ok, obj} -> obj
        _ -> nil
      end end)

      for {_sha, type, content} <- objects, do: Object.write(st.repo, type, content)

      results =
        for cmd <- commands do
          [_old, new, ref] = cmd |> String.split(<<0>>) |> hd() |> String.trim() |> String.split(" ")
          Git.update_ref(st.repo, ref, new)
          Remote.pkt("ok #{ref}\n")
        end

      report = IO.iodata_to_binary([Remote.pkt("unpack ok\n"), results, Remote.flush()])
      :ssh_connection.send(cm, ch, Remote.pkt(<<1>> <> report) <> Remote.flush())
      finish(cm, ch, 0, st)
    end

    defp split_commands(<<"0000", pack::binary>>, acc), do: {Enum.reverse(acc), pack}

    defp split_commands(<<len::binary-size(4), rest::binary>>, acc) do
      n = String.to_integer(len, 16) - 4
      <<line::binary-size(^n), rest::binary>> = rest
      split_commands(rest, [line | acc])
    end

    defp reachable(_repo, [], acc), do: acc

    defp reachable(repo, [sha | rest], acc) do
      if MapSet.member?(acc, sha) do
        reachable(repo, rest, acc)
      else
        acc = MapSet.put(acc, sha)

        case Object.read!(repo, sha) do
          {:commit, c} -> c = Object.parse_commit(c); reachable(repo, [c.tree | c.parents] ++ rest, acc)
          {:tree, t} -> reachable(repo, (for {_, _, s} <- Object.parse_tree(t), do: s) ++ rest, acc)
          _ -> reachable(repo, rest, acc)
        end
      end
    end
  end

  # Host key, and public keys read from ROOT/authorized_keys at login.
  defmodule ServerKeys do
    @behaviour :ssh_server_key_api

    @impl true
    def host_key(alg, opts) do
      key = opts[:key_cb_private][:host_key]
      if SSH.signs?(key, alg), do: {:ok, key}, else: {:error, :no_key}
    end

    @impl true
    def is_auth_key(pub, _user, opts) do
      case File.read(Path.join(opts[:key_cb_private][:root], "authorized_keys")) do
        {:ok, text} -> Enum.any?(:ssh_file.decode(text, :openssh_key), fn {k, _} -> k == pub end)
        _ -> false
      end
    end
  end

  defp daemon(root) do
    {:ok, _} = Application.ensure_all_started(:ssh)
    host_key = SSH.generate()

    {:ok, d} =
      :ssh.daemon({127, 0, 0, 1}, 0,
        key_cb: {ServerKeys, [host_key: host_key, root: root]},
        ssh_cli: {Server, [root]},
        auth_methods: ~c"publickey",
        subsystems: [],
        disconnectfun: fn _ -> :ok end
      )

    {:ok, info} = :ssh.daemon_info(d)
    on_exit(fn -> :ssh.stop_daemon(d) end)
    {info[:port], SSH.public(host_key)}
  end

  defp run(cmd, home, cwd) do
    {:ok, err} = StringIO.open("")
    {out, status} = sh(cmd, home: home, cwd: cwd, stderr: err)
    {out, StringIO.flush(err), status}
  end

  # -- keys ------------------------------------------------------------------------------------

  test "ssh-keygen writes an OpenSSH ed25519 key pair; -l, -y and refusals" do
    home = tmp_dir("sshkg")
    {_, err, 0} = run("ssh-keygen -q -C me@lepton", home, home)
    assert err == ""
    key = Path.join(home, ".ssh/id_ed25519")
    assert File.stat!(key).mode |> Bitwise.band(0o777) == 0o600
    assert File.read!(key) =~ ~r/\A-----BEGIN OPENSSH PRIVATE KEY-----\n([A-Za-z0-9+\/=]{1,70}\n)+-----END OPENSSH PRIVATE KEY-----\n\z/
    {:ok, priv} = SSH.load_key(key)
    pub_line = File.read!(key <> ".pub")
    assert pub_line == SSH.public_line(SSH.public(priv), "me@lepton") <> "\n"
    assert pub_line =~ ~r/^ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA\S+ me@lepton\n$/

    assert {^pub_line, _, 0} = run("ssh-keygen -y -f ~/.ssh/id_ed25519", home, home)
    assert {out, _, 0} = run("ssh-keygen -l -f ~/.ssh/id_ed25519", home, home)
    assert out == "256 #{SSH.fingerprint(SSH.public(priv))} me@lepton (ED25519)\n"

    # Without a terminal an existing key is never overwritten.
    assert {_, err, 1} = run("ssh-keygen -q", home, home)
    assert err =~ "already exists"
    assert {:ok, ^priv} = SSH.load_key(key)

    assert {_, err, 1} = run("ssh-keygen -t rsa -f other", home, home)
    assert err =~ "only ed25519"
    assert {_, err, 1} = run("ssh-keygen -N secret -f other", home, home)
    assert err =~ "passphrases are not supported"

    # OpenSSH itself reads the key, where it is installed (the host).
    if (keygen = System.find_executable("ssh-keygen")) && !Lepton.Sys.native?() do
      assert {^pub_line, 0} = System.cmd(keygen, ["-y", "-f", key])
    end
  end

  test "passphrase-protected keys are reported, not misread" do
    dir = tmp_dir("sshpp")
    # The header of an `ssh-keygen -N secret` key: aes256-ctr with bcrypt.
    data = "openssh-key-v1\0" <> <<10::32>> <> "aes256-ctr" <> <<6::32>> <> "bcrypt" <> <<0::32>> <> <<1::32>>
    File.write!(Path.join(dir, "k"), "-----BEGIN OPENSSH PRIVATE KEY-----\n#{Base.encode64(data)}\n-----END OPENSSH PRIVATE KEY-----\n")
    assert {:error, msg} = SSH.load_key(Path.join(dir, "k"))
    assert msg =~ "passphrase"
  end

  # -- known hosts and config --------------------------------------------------------------------

  test "known hosts: GitHub's keys built in, plain, hashed and [host]:port entries, ssh-keygen -R" do
    [_, _, b64] = SSH.pinned() |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "github.com ssh-ed25519")) |> String.split()
    github = :ssh_file.decode(Base.decode64!(b64), :ssh2_pubkey)
    assert SSH.fingerprint(github) == "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"
    assert SSH.host_key_status("github.com", 22, github, []) == :known

    other = SSH.public(SSH.generate())
    assert SSH.host_key_status("github.com", 22, other, []) == :changed
    assert SSH.host_key_status("example.org", 22, other, []) == :unknown

    home = tmp_dir("sshkh")
    file = Path.join(home, ".ssh/known_hosts")
    SSH.add_known_host(file, "10.0.0.5", 2222, other)
    assert File.read!(file) == "[10.0.0.5]:2222 #{SSH.public_line(other)}\n"
    assert SSH.host_key_status("10.0.0.5", 2222, other, [file]) == :known
    assert SSH.host_key_status("10.0.0.5", 22, other, [file]) == :unknown

    salt = :crypto.strong_rand_bytes(20)
    hashed = "|1|#{Base.encode64(salt)}|#{Base.encode64(:crypto.mac(:hmac, :sha, salt, "git.example.com"))}"
    File.write!(file, "#{hashed} #{SSH.public_line(other)}\n", [:append])
    assert SSH.host_key_status("git.example.com", 22, other, [file]) == :known
    assert SSH.host_key_status("www.example.com", 22, other, [file]) == :unknown

    assert {out, _, 0} = run("ssh-keygen -R git.example.com", home, home)
    assert out =~ "updated"
    assert SSH.host_key_status("git.example.com", 22, other, [file]) == :unknown
    assert SSH.host_key_status("10.0.0.5", 2222, other, [file]) == :known
  end

  test "~/.ssh/config: Host patterns, first value wins, IdentityFile adds up" do
    home = tmp_dir("sshcfg")
    File.mkdir_p!(Path.join(home, ".ssh"))

    File.write!(Path.join(home, ".ssh/config"), """
    # personal
    Host gh github.com
      HostName github.com
      User git
      IdentityFile ~/.ssh/github_ed25519

    Host *.internal !secret.internal
      Port 2222
      StrictHostKeyChecking accept-new

    Host *
      User nobody
      IdentityFile=~/.ssh/id_ed25519
    """)

    gh = SSH.config("gh", home)
    assert gh.hostname == "github.com" and gh.user == "git" and gh.port == 22
    assert gh.identity_files == [Path.join(home, ".ssh/github_ed25519"), Path.join(home, ".ssh/id_ed25519")]

    box = SSH.config("box.internal", home)
    assert box.hostname == "box.internal" and box.port == 2222 and box.strict == "accept-new" and box.user == "nobody"
    assert SSH.config("secret.internal", home).port == 22
    assert SSH.config("other", home).known_hosts == [Path.join(home, ".ssh/known_hosts")]
  end

  test "SSH remote URLs and url.<base>.insteadOf" do
    assert Remote.ssh_url("git@github.com:danieljaouen/lepton.git") == {"git@github.com", nil, "danieljaouen/lepton.git"}
    assert Remote.ssh_url("ssh://git@example.com:2222/srv/repo.git") == {"git@example.com", 2222, "/srv/repo.git"}
    assert Remote.ssh_url("ssh://host/~me/repo") == {"host", nil, "~me/repo"}
    assert Remote.ssh_url("gh:me/repo") == {"gh", nil, "me/repo"}
    assert Remote.ssh_url("https://github.com/me/repo.git") == nil
    assert Remote.ssh_url("/srv/repo.git") == nil

    cfg = %{
      ~s(url "git@github.com:") => %{"insteadof" => "https://github.com/"},
      ~s(url "ssh://git@example.com/") => %{"pushinsteadof" => "https://example.com/"}
    }

    assert Remote.rewrite_url("https://github.com/me/repo.git", cfg) == "git@github.com:me/repo.git"
    assert Remote.rewrite_url("https://example.com/r.git", cfg) == "https://example.com/r.git"
    assert Remote.rewrite_url("https://example.com/r.git", cfg, :push) == "ssh://git@example.com/r.git"
  end

  # -- end to end -----------------------------------------------------------------------------------

  test "ssh, ssh-keyscan and git clone / push / pull / ls-remote over SSH" do
    root = tmp_dir("sshsrv")
    {port, host_key} = daemon(root)

    origin = Path.join(root, "proj")
    repo = Repo.init(origin, "main")
    File.write!(Path.join(origin, "README.md"), "hello over ssh\n")
    Git.add(repo, [origin])
    {:ok, _} = Git.commit(repo, "first")

    home = tmp_dir("sshhome")
    File.mkdir_p!(Path.join(home, ".ssh"))
    File.write!(Path.join(home, ".ssh/config"), "Host srv\n  HostName 127.0.0.1\n  Port #{port}\n  User git\n")
    work = tmp_dir("sshwork")

    # An unknown host is refused, with its fingerprint.
    assert {_, err, 128} = run("git clone srv:proj c1", home, work)
    assert err =~ "[127.0.0.1]:#{port} is not a known host"
    assert err =~ SSH.fingerprint(host_key)
    refute File.exists?(Path.join(work, "c1"))

    assert {line, _, 0} = run("ssh-keyscan -p #{port} -t ed25519 127.0.0.1", home, work)
    assert line == "[127.0.0.1]:#{port} #{SSH.public_line(host_key)}\n"
    File.write!(Path.join(home, ".ssh/known_hosts"), line)

    # Known host, but no key yet.
    assert {_, err, 128} = run("git clone srv:proj c1", home, work)
    assert err =~ "git@127.0.0.1: Permission denied (publickey)"
    assert err =~ "ssh-keygen"

    {_, _, 0} = run("ssh-keygen -q", home, work)
    File.write!(Path.join(root, "authorized_keys"), File.read!(Path.join(home, ".ssh/id_ed25519.pub")))

    assert {out, _, 0} = run("git clone srv:proj c1", home, work)
    assert out =~ "checked out 'main'"
    c1 = Path.join(work, "c1")
    assert File.read!(Path.join(c1, "README.md")) == "hello over ssh\n"
    assert {"srv:proj\n", _, 0} = run("git config remote.origin.url", home, c1)

    assert {out, _, 0} = run("git ls-remote ssh://git@127.0.0.1:#{port}/proj", home, work)
    assert out =~ "#{Git.head_sha(repo)}\trefs/heads/main"

    # Push a commit; the server's branch moves to it.
    File.write!(Path.join(c1, "NEW.md"), "pushed\n")
    {_, _, 0} = run("git add NEW.md && git commit -m 'from lepton'", home, c1)
    assert {out, _, 0} = run("git push", home, c1)
    assert out =~ "main -> main"
    local = Git.head_sha(Repo.open(c1))
    assert Git.resolve_ref(repo, "refs/heads/main") == local
    assert {"Everything up-to-date\n", _, 0} = run("git push", home, c1)

    # A commit made on the server arrives with pull.
    Git.checkout(repo, "main")
    File.write!(Path.join(origin, "SERVER.md"), "from the server\n")
    Git.add(repo, [origin])
    {:ok, _} = Git.commit(repo, "server side")
    assert {_, _, 0} = run("git pull", home, c1)
    assert File.read!(Path.join(c1, "SERVER.md")) == "from the server\n"

    # le's magit (P p, F p) pushes and pulls with the user's key, in the
    # user's home, not the system's (/root on Lepton).
    File.write!(Path.join(c1, "LE.md"), "from le\n")
    {_, _, 0} = run("git add LE.md && git commit -m 'from le'", home, c1)
    ctx = %Lepton.Ctx{cwd: c1, env: %{"HOME" => home}, tty: nil}
    st = Lepton.Editor.init([Path.join(c1, "README.md")], ctx)
    st = Enum.reduce(Lepton.Keys.parse("SPC g s P p"), st, &Lepton.Editor.handle_key(&2, &1))
    refute st.message_error, st.message
    assert Git.resolve_ref(repo, "refs/heads/main") == Git.head_sha(Repo.open(c1))
    st = Enum.reduce(Lepton.Keys.parse("F p"), st, &Lepton.Editor.handle_key(&2, &1))
    refute st.message_error, st.message

    assert {_, err, 128} = run("git clone srv:missing c2", home, work)
    assert err =~ "Repository not found."

    # ssh runs commands and shows what a shell-less server says.
    assert {"hello there\n", _, 0} = run("ssh srv echo hello there", home, work)
    assert {"piped in\n", _, 0} = run("echo piped in | ssh srv cat", home, work)
    assert {"", err, 1} = run("ssh -T srv", home, work)
    assert err =~ "successfully authenticated"
    assert {_, err, 255} = run("ssh -p 1 127.0.0.1 true", home, work)
    assert err =~ "Connection refused"
  end

  test "StrictHostKeyChecking accept-new records a new host" do
    root = tmp_dir("sshsrv2")
    {port, host_key} = daemon(root)
    home = tmp_dir("sshhome2")
    {_, _, 0} = run("ssh-keygen -q", home, home)
    File.write!(Path.join(root, "authorized_keys"), File.read!(Path.join(home, ".ssh/id_ed25519.pub")))

    assert {"ok\n", _, 0} = run("ssh -o StrictHostKeyChecking=accept-new -p #{port} git@127.0.0.1 echo ok", home, home)
    assert File.read!(Path.join(home, ".ssh/known_hosts")) == "[127.0.0.1]:#{port} #{SSH.public_line(host_key)}\n"
    assert {"again\n", _, 0} = run("ssh -p #{port} git@127.0.0.1 echo again", home, home)
  end

  test "interactive ssh: host prompt, terminal size and resize, keys, ~. to disconnect" do
    alias Lepton.TTY
    alias Lepton.TTY.Capture

    root = tmp_dir("sshsrv3")
    {port, _} = daemon(root)
    home = tmp_dir("sshhome3")
    {_, _, 0} = run("ssh-keygen -q", home, home)
    File.write!(Path.join(root, "authorized_keys"), File.read!(Path.join(home, ".ssh/id_ed25519.pub")))

    {:ok, tty} = TTY.start(backend: {Capture, nil}, auto_probe: true, probe_interval: 30)
    %{backend: {_, agent}} = :sys.get_state(tty)
    ctx = %Lepton.Ctx{cwd: home, env: %{"HOME" => home}, stdin: tty, stdout: tty, stderr: tty, tty: tty}
    session = Task.async(fn -> Lepton.SSH.CLI.ssh(["-p", "#{port}", "git@127.0.0.1"], ctx) end)

    assert eventually(fn -> Capture.output(agent) =~ "Are you sure you want to continue connecting (yes/no)?" end)
    TTY.input(tty, "yes\r")
    assert eventually(fn -> Capture.output(agent) =~ "remote ready xterm-256color 80x24" end)
    assert File.read!(Path.join(home, ".ssh/known_hosts")) =~ "[127.0.0.1]:#{port} ssh-ed25519 "

    # Keys reach the server as bytes and its output comes back.
    TTY.input(tty, "echo hi\e[A")
    assert eventually(fn -> Capture.output(agent) =~ "echo hi\e[A" end)

    # A terminal resize is passed on.
    assert eventually(fn -> :sys.get_state(tty).probe_sent != nil end)
    TTY.input(tty, "\e[50;160R")
    assert eventually(fn -> Capture.output(agent) =~ "size 160x50" end)

    # ~. at the start of a line disconnects; a ~ elsewhere is sent.
    TTY.input(tty, "a~b\r")
    assert eventually(fn -> Capture.output(agent) =~ "a~b" end)
    TTY.input(tty, "~.")
    assert Task.await(session, 5000) == 255
    assert Capture.output(agent) =~ "Connection to 127.0.0.1 closed."
    assert TTY.mode(tty) == :cooked
  end

  test "interactive ssh ends with the remote shell's exit status" do
    alias Lepton.TTY
    alias Lepton.TTY.Capture

    root = tmp_dir("sshsrv4")
    {port, host_key} = daemon(root)
    home = tmp_dir("sshhome4")
    {_, _, 0} = run("ssh-keygen -q", home, home)
    File.write!(Path.join(root, "authorized_keys"), File.read!(Path.join(home, ".ssh/id_ed25519.pub")))
    File.write!(Path.join(home, ".ssh/known_hosts"), "[127.0.0.1]:#{port} #{SSH.public_line(host_key)}\n")

    {:ok, tty} = TTY.start(backend: {Capture, nil})
    %{backend: {_, agent}} = :sys.get_state(tty)
    ctx = %Lepton.Ctx{cwd: home, env: %{"HOME" => home}, stdin: tty, stdout: tty, stderr: tty, tty: tty}
    session = Task.async(fn -> Lepton.SSH.CLI.ssh(["-p", "#{port}", "git@127.0.0.1"], ctx) end)
    assert eventually(fn -> Capture.output(agent) =~ "remote ready" end)
    TTY.input(tty, "exit\r")
    assert Task.await(session, 5000) == 3
  end

  # (5 s: an emulated machine, a while)
  defp eventually(fun, tries \\ 250) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20); eventually(fun, tries - 1)
    end
  end

  @tag :network
  test "GitHub: the pinned host key verifies and an unregistered key is refused" do
    home = tmp_dir("sshgh")
    {_, _, 0} = run("ssh-keygen -q", home, home)
    assert {"", err, 255} = run("ssh -T git@github.com", home, home)
    assert err =~ "git@github.com: Permission denied (publickey)."
    refute err =~ "known host"
  end
end
