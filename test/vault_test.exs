defmodule Lepton.VaultTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.Vault
  alias Lepton.Vault.UI

  # A cheap Argon2id for the vaults made here (the real one, 64 MiB and
  # three passes, takes seconds: test/argon2_test.exs checks the algorithm).
  setup_all do
    old = Application.get_env(:lepton, :vault_kdf)
    Application.put_env(:lepton, :vault_kdf, {:argon2id, 1, 1, 1})
    on_exit(fn -> if old, do: Application.put_env(:lepton, :vault_kdf, old), else: Application.delete_env(:lepton, :vault_kdf) end)
    :ok
  end

  # An older vault (PBKDF2) where the test makes it itself.
  defp vault(items \\ []) do
    path = Path.join(tmp_dir("vault"), ".vault/vault")
    :ok = Vault.create("root", path, "master password", iterations: 1000)
    if items != [], do: {:ok, _} = Vault.update("root", path, &{:ok, Enum.map(items, fn f -> Vault.new_item(f) end) ++ &1, nil})
    on_exit(fn -> Vault.lock("root", path) end)
    path
  end

  test "Argon2id: new vaults use it (the header says how), vault upgrade moves an older one, status tells" do
    home = tmp_dir("vaultkdf")
    path = Path.join(home, ".vault/vault")
    :ok = Vault.create("root", path, "master password")
    on_exit(fn -> Vault.lock("root", path) end)
    assert <<"LPVAULT2", 1::16, 1::8, 1::8, _::binary>> = File.read!(path)
    Vault.lock("root", path)
    assert {:error, :wrong_password} = Vault.unlock("root", path, "guess")
    assert :ok = Vault.unlock("root", path, "master password")
    assert Vault.describe_kdf({:argon2id, 64, 3, 1}) == "Argon2id, 64 MiB, 3 passes"

    # An older vault: status says so, upgrade moves it (the password kept).
    old = Path.join(home, "old/vault")
    :ok = Vault.create("root", old, "master password", iterations: 1000)
    on_exit(fn -> Vault.lock("root", old) end)
    run = fn cmd, stdin -> sh(cmd, home: home, env: %{"VAULT_FILE" => old}, stdin: stdin && elem(StringIO.open(stdin), 1)) end
    {out, 0} = run.("vault status", nil)
    assert out =~ "PBKDF2-HMAC-SHA256, 1000 iterations (`vault upgrade` moves it to Argon2id)"
    {out, 0} = run.("vault upgrade", "master password\n")
    assert out =~ "Done"
    assert "LPVAULT2" <> _ = File.read!(old)
    Vault.lock("root", old)
    assert :ok = Vault.unlock("root", old, "master password")
    {out, 0} = run.("vault upgrade", nil)
    assert out =~ "already uses Argon2id"
    {out, 0} = run.("vault status", nil)
    assert out =~ "Master password key: Argon2id, 1 MiB, 1 passes"
  end

  test "the file: master password, wrong password, tampering, a new master password, the previous version" do
    path = vault([%{"title" => "GitHub", "username" => "dan", "password" => "hunter22"}])
    bin = File.read!(path)
    assert "LPVAULT1" <> _ = bin
    refute bin =~ "hunter22" or bin =~ "GitHub"
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    assert File.stat!(Path.dirname(path)).mode |> Bitwise.band(0o777) == 0o700
    assert File.exists?(path <> ".old")

    Vault.lock("root", path)
    assert {:error, :locked} = Vault.items("root", path)
    assert {:error, :wrong_password} = Vault.unlock("root", path, "guess")
    assert :ok = Vault.unlock("root", path, "master password")
    assert {:ok, [%{"title" => "GitHub"}]} = Vault.items("root", path)
    # Unlocked for root, not for another user.
    assert {:error, :locked} = Vault.items("alice", path)

    # A flipped byte in the body: the key unwraps, the body doesn't decrypt.
    <<head::binary-size(120), b, rest::binary>> = bin
    File.write!(path, <<head::binary, Bitwise.bxor(b, 1), rest::binary>>)
    assert {:error, :damaged} = Vault.items("root", path)
    File.write!(path, bin)

    assert {:error, :short} = Vault.change_password("root", path, "master password", "short")
    assert {:error, :wrong_password} = Vault.change_password("root", path, "nope", "a new password")
    assert :ok = Vault.change_password("root", path, "master password", "a new password")
    # A new master password moves an older vault to Argon2id.
    assert "LPVAULT2" <> _ = File.read!(path)
    assert Vault.kdf(File.read!(path)) == {:argon2id, 1, 1, 1}
    Vault.lock("root", path)
    assert {:error, :wrong_password} = Vault.unlock("root", path, "master password")
    assert :ok = Vault.unlock("root", path, "a new password")
    assert {:ok, [%{"password" => "hunter22"}]} = Vault.items("root", path)
    assert {:error, :exists} = Vault.create("root", path, "whatever123")
  end

  test "it locks itself when idle, and copied passwords leave the clipboard" do
    path = vault()
    :ok = Vault.unlock("root", path, "master password", timeout: 0)
    send(Lepton.Vault.Agent, {:idle, {"root", path}, make_ref()})
    assert Vault.unlocked?("root", path), "a stale timer doesn't lock it; timeout 0 never does"

    :ok = Vault.unlock("root", path, "master password")
    %{timer: {_, ref}} = :sys.get_state(Lepton.Vault.Agent).sessions[{"root", path}]
    send(Lepton.Vault.Agent, {:idle, {"root", path}, ref})
    refute Vault.unlocked?("root", path)

    Vault.copy("s3cret", 0)
    Process.sleep(50)
    assert Lepton.Clipboard.get() == ""
    Vault.copy("s3cret", 30)
    Lepton.Clipboard.put("something else")
    send(Lepton.Vault.Agent, :clear_clipboard)
    :sys.get_state(Lepton.Vault.Agent)
    assert Lepton.Clipboard.get() == "something else", "only what it copied is cleared"
  end

  test "items: finding, searching, changes and password history" do
    items = Enum.map([%{"title" => "GitHub", "username" => "dan"}, %{"title" => "GitLab"}, %{"title" => "Bank", "kind" => "card", "number" => "4111111111111111", "tags" => "money, home"}], &Vault.new_item/1)
    [gh, _gl, bank] = items
    assert {:ok, ^gh} = Vault.find(items, "github")
    assert {:ok, ^gh} = Vault.find(items, gh["id"])
    assert {:ok, ^bank} = Vault.find(items, "ban")
    assert {:error, {:ambiguous, [_, _]}} = Vault.find(items, "git")
    assert {:error, :not_found} = Vault.find(items, "nothing")
    assert bank["tags"] == ["money", "home"]
    assert [^bank] = Vault.search(items, "MONEY")
    assert [^gh] = Vault.search(items, "dan")
    assert length(Vault.search(items, "")) == 3

    gh = Vault.set_fields(Map.put(gh, "password", "first"), %{"password" => "second", "url" => "github.com"})
    gh = Vault.set_fields(gh, %{"password" => "third", "url" => ""})
    assert gh["password"] == "third" and not Map.has_key?(gh, "url")
    assert Enum.map(gh["history"], & &1["password"]) == ["second", "first"]
    assert Vault.shown_fields(Map.put(gh, "pin", "1234")) == ["username", "password", "pin"]
    assert [%{"title" => "Bank"}, %{"title" => "GitHub"}, _] = Vault.sort(items)
  end

  test "passwords: generated, their strength, and the audit" do
    pw = Vault.generate()
    assert String.length(pw) == 20
    assert pw =~ ~r/[a-z]/ and pw =~ ~r/[A-Z]/ and pw =~ ~r/[0-9]/ and pw =~ ~r/[^a-zA-Z0-9]/
    assert Vault.generate(length: 32, symbols: false) =~ ~r/^[a-zA-Z0-9]{32}$/
    assert Vault.generate() != Vault.generate()
    assert {:weak, _} = Vault.strength("password")
    assert {:weak, _} = Vault.strength("aaaaaaaaaaaaaaaaaaaa")
    assert {:strong, _} = Vault.strength(pw)

    items = Enum.map([%{"title" => "a", "password" => "password"}, %{"title" => "b", "password" => pw}, %{"title" => "c", "password" => pw}, %{"title" => "d"}], &Vault.new_item/1)
    assert [{%{"title" => "a"}, [:weak]}, {%{"title" => "b"}, [:reused]}, {%{"title" => "c"}, [:reused]}] = Vault.audit(items)
  end

  test "one-time passwords: RFC 6238's test vectors, base32 secrets and otpauth URIs" do
    uri = fn key, algo -> "otpauth://totp/x?secret=#{Base.encode32(key, padding: false)}&digits=8&algorithm=#{algo}" end
    sha1 = "12345678901234567890"
    sha256 = String.duplicate(sha1, 2) |> binary_part(0, 32)
    sha512 = String.duplicate(sha1, 4) |> binary_part(0, 64)

    for {t, [c1, c256, c512]} <- [{59, ~w(94287082 46119246 90693936)}, {1_111_111_109, ~w(07081804 68084774 25091201)}, {20_000_000_000, ~w(65353130 77737706 47863826)}] do
      assert {:ok, ^c1, _} = Vault.totp(uri.(sha1, "SHA1"), t)
      assert {:ok, ^c256, _} = Vault.totp(uri.(sha256, "SHA256"), t)
      assert {:ok, ^c512, _} = Vault.totp(uri.(sha512, "SHA512"), t)
    end

    assert {:ok, code, 30} = Vault.totp("jbsw y3dp ehpk 3pxp", 0)
    assert code =~ ~r/^\d{6}$/
    assert {:error, :bad_secret} = Vault.totp("not base32!")
    assert {:error, :bad_secret} = Vault.totp("otpauth://totp/x?secret=JBSWY3DP&algorithm=MD5")
  end

  test "import and export: 1Password, Bitwarden, Chrome and Firefox CSV, and JSON" do
    {:ok, [a]} = Vault.from_csv("Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes\r\nMail,https://mail.example,me,\"p,w\"\"x\",,true,false,work,\"two\nlines\"\r\n")
    assert a == %{"title" => "Mail", "url" => "https://mail.example", "username" => "me", "password" => "p,w\"x", "favorite" => true, "tags" => "work", "notes" => "two\nlines"}
    {:ok, [b]} = Vault.from_csv("folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n,,login,Bank,,,0,https://bank,u,pw,JBSWY3DP\n")
    assert %{"title" => "Bank", "otp" => "JBSWY3DP", "password" => "pw", "favorite" => false} = b
    {:ok, [c]} = Vault.from_csv("﻿url,username,password,httpRealm\nhttps://forum.example.org/login,fan,pw,\n")
    assert c["title"] == "forum.example.org"
    {:ok, [n]} = Vault.from_csv("name,notes\nWi-Fi,the code is 1234\n")
    assert n["kind"] == "note"
    assert {:error, _} = Vault.from_csv("a,b\n1,2\n")

    items = [Vault.new_item(Map.put(a, "tags", "work,home"))]
    {:ok, [back]} = Vault.from_csv(Vault.to_csv(items))
    assert Map.take(back, ~w(title url username password notes)) == Map.take(a, ~w(title url username password notes))
    assert back["tags"] == "work,home"
    assert {:ok, ^items} = Vault.from_json(Vault.to_json(items))
  end

  describe "the vault command" do
    setup do
      home = tmp_dir("vaulthome")
      run = fn cmd, stdin -> sh(cmd, home: home, stdin: stdin && elem(StringIO.open(stdin), 1)) end
      on_exit(fn -> Vault.lock_all("root") end)
      %{home: home, run: run, path: Path.join(home, ".vault/vault")}
    end

    test "init, add, list, show, get, copy, otp, edit, rm, lock and unlock", %{run: run, path: path} do
      assert {"No vault yet" <> _, 1} = run.("vault", nil)
      assert {out, 1} = run.("vault init", "short\nshort\n")
      refute out =~ "Made"
      assert {_, 1} = run.("vault init", "long enough 1\nlong enough 2\n")
      assert {out, 0} = run.("vault init", "my master pw\nmy master pw\n")
      assert out =~ "Made #{path}"
      assert {_, 1} = run.("vault init", nil)

      assert {out, 0} = run.("vault add GitHub username=dan url=https://github.com otp=JBSWY3DPEHPK3PXP tags=work,code", nil)
      assert out =~ "with a generated password"
      assert {_, 0} = run.("vault add -k note Wi-Fi notes='the code is 1234'", nil)
      assert {_, 0} = run.("vault add -p Bank username=me", "bank pass 1\n")
      assert {_, 1} = run.("vault add -k car Thing", nil)

      assert {out, 0} = run.("vault list", nil)
      assert [header | rows] = String.split(out, "\n", trim: true)
      assert header =~ ~r/^ID\s+TITLE\s+USERNAME\s+URL$/
      assert Enum.map(rows, &(String.split(&1) |> Enum.at(1))) == ["Bank", "GitHub", "Wi-Fi"]
      assert {out, 0} = run.("vault ls -t work", nil)
      assert out =~ "GitHub" and not (out =~ "Bank")

      assert {"bank pass 1\n", 0} = run.("vault get bank", nil)
      assert {"me\n", 0} = run.("vault get Bank username", nil)
      assert {code, 0} = run.("vault otp github", nil)
      assert code =~ ~r/^\d{6}\n$/
      assert {_, 1} = run.("vault get bank otp", nil)
      assert {_, 1} = run.("vault get nothing", nil)

      assert {out, 0} = run.("vault show github", nil)
      assert out =~ ~r/GitHub  \(login, [0-9a-f]{8}\)/
      assert out =~ ~r/password   \*{8}/ and out =~ "tags       work, code"
      {pw, 0} = run.("vault get github", nil)
      assert {out, 0} = run.("vault show -r github", nil)
      assert out =~ String.trim(pw)

      assert {out, 0} = run.("vault copy github", nil)
      assert out =~ "cleared in 45 seconds"
      assert Lepton.Clipboard.get() == String.trim(pw)

      assert {_, 0} = run.("vault edit github username=daniel url=", nil)
      assert {out, 0} = run.("vault edit -g -n 32 github", nil)
      assert out =~ "history"
      {new_pw, 0} = run.("vault get github", nil)
      assert String.length(String.trim(new_pw)) == 32
      assert {:ok, items} = Vault.items("root", path)
      gh = Enum.find(items, &(&1["title"] == "GitHub"))
      assert gh["username"] == "daniel" and gh["url"] == nil and hd(gh["history"])["password"] == String.trim(pw)

      assert {_, 0} = run.("vault rm wi-fi", nil)
      assert {_, 1} = run.("vault rm wi-fi", nil)

      assert {"Locked.\n", 0} = run.("vault lock", nil)
      assert {out, 0} = run.("vault", nil)
      assert out =~ "locked"
      # Locked: the master password is asked for first.
      assert {_, 1} = run.("vault get bank", "wrong one\n")
      assert {"bank pass 1\n", 0} = run.("vault get bank", "my master pw\n")
      assert {_, 0} = run.("vault unlock -t 5", "my master pw\n")
      assert {out, 0} = run.("vault status", nil)
      assert out =~ "unlocked, 2 items"
    end

    test "generate, audit, passwd, import and export", %{run: run, path: path, home: home} do
      assert {pw, 0} = run.("vault generate -n 12 -S", nil)
      assert pw =~ ~r/^[a-zA-Z0-9]{12}\n$/
      assert {_, 0} = run.("vault gen -c", nil)
      assert String.length(Lepton.Clipboard.get()) == 20

      {_, 0} = run.("vault init", "my master pw\nmy master pw\n")
      File.write!(Path.join(home, "export.csv"), "name,url,username,password\nOld,https://old.example,me,password\nAlso,,me,password\n")
      assert {out, 0} = sh("vault import export.csv", home: home, cwd: home)
      assert out =~ "Imported 2 items"
      assert {out, 1} = run.("vault audit", nil)
      assert out =~ "Old" and out =~ "weak, reused"

      assert {json, 0} = run.("vault export", nil)
      assert {:ok, [_, _]} = Vault.from_json(json)
      assert {csv, 0} = run.("vault export --csv", nil)
      assert csv =~ "Old,https://old.example,me,password"

      assert {_, 1} = run.("vault passwd", "wrong\nnew master pw\nnew master pw\n")
      assert {"The master password is changed.\n", 0} = run.("vault passwd", "my master pw\nnew master pw\nnew master pw\n")
      Vault.lock("root", path)
      assert {_, 0} = run.("vault unlock", "new master pw\n")
      assert {_, 1} = run.("vault gui", nil)
      assert {_, 2} = run.("vault frobnicate", nil)
    end
  end

  describe "the Passwords window" do
    defp keys(st, text), do: text |> String.graphemes() |> Enum.reduce(st, &UI.handle(&2, {:key, if(&1 == " ", do: "SPC", else: &1), 0}))
    defp key(st, k, mods \\ 0), do: UI.handle(st, {:key, k, mods})

    # What the app does with an unlock or create the window asks for (it
    # runs it in a task, the window saying so meanwhile).
    defp job(st) do
      assert st.job != nil and st.message in ["Unlocking...", "Making your vault..."]
      UI.handle(st, {:job_done, st.job, UI.run_job(st, st.job)})
    end

    # Click the region whose action is `action` (as the window last drew it).
    defp click(st, action) do
      {_, st} = UI.render(st)
      {x, y, _, _, _} = Enum.find(st.regions, &(elem(&1, 4) == action)) || flunk("nothing to click for #{inspect(action)}")
      UI.handle(st, {:click, x + 1, y + 1})
    end

    test "make a vault, add, find, copy, edit, delete, generate, lock and unlock" do
      path = Path.join(tmp_dir("vaultui"), ".vault/vault")
      on_exit(fn -> Vault.lock("root", path) end)
      st = UI.new(user: "root", path: path)
      assert st.screen == :setup
      {_, st} = UI.render(st)

      # Mismatched passwords, then matching ones.
      st = st |> keys("one password") |> key("TAB") |> keys("another one") |> key("RET")
      assert st.error =~ "match" and st.screen == :setup
      assert st.focus == :again and st.text.again == ""
    st = st |> keys("one password") |> key("RET") |> job()
      assert st.screen == :main and Vault.exists?(path)

      # New (Ctrl+N): a login with a generated password.
      st = st |> key("C-n") |> keys("Example Mail") |> key("TAB") |> keys("me@example.com")
      assert String.length(st.draft["password"]) == 20
      st = key(st, "RET")
      assert st.mode == :view
    assert [%{"title" => "Example Mail", "username" => "me@example.com"}] = st.items

      # A note, by the buttons.
      st = st |> click(:new) |> click({:kind, "note"}) |> keys("Alarm code") |> click({:focus, {:draft, "notes"}}) |> keys("1234") |> key("RET") |> keys("ring twice") |> click(:save)
      assert %{"kind" => "note", "notes" => "1234\nring twice"} = Enum.find(st.items, &(&1["title"] == "Alarm code"))
      assert st.message == "Added Alarm code."

      # Search narrows the list; Escape clears it.
      st = keys(st, "mail")
      assert [%{"title" => "Example Mail"}] = UI.shown(st)
      assert UI.selected(st)["title"] == "Example Mail"
      st = key(st, "ESC")
      assert length(UI.shown(st)) == 2

      # Copy, Show and Return.
      st = st |> key("<up>") |> key("<down>")
      st = click(st, {:select, Enum.find(st.items, &(&1["title"] == "Example Mail"))["id"]})
      st = click(st, {:copy, "username"})
      assert Lepton.Clipboard.get() == "me@example.com"
      st = key(st, "RET")
      assert Lepton.Clipboard.get() == UI.selected(st)["password"]
      st = click(st, {:reveal, "password"})
      assert "password" in st.reveal

      # Edit (Ctrl+E): a new password, kept in the history.
      old = UI.selected(st)["password"]
      st = st |> key("C-e") |> click(:generate_into) |> click(:save)
      assert UI.selected(st)["password"] != old and hd(UI.selected(st)["history"])["password"] == old
      # An empty title isn't saved.
      st = st |> key("C-e") |> key("C-u") |> key("C-s")
      assert st.error =~ "title" and st.mode == :edit
      st = key(st, "ESC")
      assert st.mode == :view

      # Delete asks first.
      st = click(st, :delete)
      assert st.mode == :confirm
      st = click(st, :confirm_delete)
      assert [%{"title" => "Alarm code"}] = st.items

      # The generator.
      st = click(st, :generator)
      st = st |> click({:gen_length, 1}) |> click(:gen_symbols)
      assert st.gen.value =~ ~r/^[a-zA-Z0-9]{21}$/
      st = click(st, :gen_copy)
      assert Lepton.Clipboard.get() == st.gen.value

      # The vault changed elsewhere (`vault` in a terminal): the window follows.
      {:ok, _} = Vault.update("root", path, &{:ok, [Vault.new_item(%{"title" => "From the shell"}) | &1], nil})
      File.touch!(path, System.os_time(:second) + 5)
      st = st |> click(:cancel) |> UI.handle(:tick)
      assert length(st.items) == 2

      # Lock, a wrong password, the right one; and locking from the shell.
      st = click(st, :lock)
      assert st.screen == :locked and st.items == []
      st = st |> keys("wrong password") |> key("RET") |> job()
      assert st.error == "Wrong master password" and st.screen == :locked
      st = st |> keys("one password") |> click(:unlock) |> job()
      assert st.screen == :main and length(st.items) == 2
      Vault.lock("root", path)
      st = UI.handle(st, :tick)
      assert st.screen == :locked and st.message =~ "Locked"
      {canvas, _} = UI.render(%{st | w: 500, h: 340})
      assert {canvas.w, canvas.h} == {500, 340}
    end

    test "a window on the desktop, opened from the classic Start menu" do
      alias Lepton.Photon
      dir = "/tmp/lpv-#{System.unique_integer([:positive])}"
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      out = Photon.Output.file(Path.join(dir, "fb"), 800, 500)
      {:ok, ph} = Photon.start(output: out, socket: Path.join(dir, "wayland-0"), wm: "classic")
      on_exit(fn -> if Process.alive?(ph), do: Photon.stop(ph) end)
      home = tmp_dir("vaultwin")
      path = Path.join(home, ".vault/vault")
      :ok = Vault.create("root", path, "master password", iterations: 1000)
      Vault.lock("root", path)
      on_exit(fn -> Vault.lock("root", path) end)

      {:ok, app} = Lepton.Vault.App.start(env: %{"XDG_RUNTIME_DIR" => dir, "WAYLAND_DISPLAY" => "wayland-0", "HOME" => home}, user: "root")
      assert eventually(fn -> match?([%{app_id: "lepton.vault", title: "Passwords", width: 640, height: 420}], Photon.info(ph).windows) end)
      assert Lepton.Vault.App.ui(app).screen == :locked

      # Typed through the compositor: the master password, Return.
      for k <- String.graphemes("master password") do
        code = if k == " ", do: 57, else: Enum.find(1..60, &(Lepton.Wayland.Keymap.text(&1, 0) == k))
        Photon.input(ph, {:key, code, true})
        Photon.input(ph, {:key, code, false})
      end

      Photon.input(ph, {:key, 28, true})
      Photon.input(ph, {:key, 28, false})
      assert eventually(fn -> Lepton.Vault.App.ui(app).screen == :main end)

      # The New button, clicked with the mouse.
      [%{x: x, y: y}] = Photon.info(ph).windows
      {dx, dy} = Photon.WM.Classic.content_offset()
      Photon.input(ph, {:abs_px, x + dx + 10, y + dy + 10, 0})
      Photon.input(ph, {:button, 0x110, true})
      Photon.input(ph, {:button, 0x110, false})
      assert eventually(fn -> Lepton.Vault.App.ui(app).mode == :new end)
      # The form's white title field is on the screen (once the app has drawn it: a slow machine, a while).
      assert eventually(fn -> Photon.sync(ph); Photon.Output.read(out, x + dx + 400, y + dy + 108, 1, 1) == Photon.Render.rgb("#ffffff") end)
    end
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(100); eventually(fun, tries - 1)
    end
  end
end
