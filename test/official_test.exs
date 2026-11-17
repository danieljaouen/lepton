defmodule Lepton.OfficialTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.Official

  defmodule FakeGrep do
    use Lepton.Command

    defcmd "grep", "an updated grep" do
      _ = args
      IO.puts(ctx, "updated grep")
      0
    end
  end

  setup do
    System.put_env("LEPTON_STATE_DIR", tmp_dir("state"))
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    on_exit(fn -> System.delete_env("LEPTON_STATE_DIR") end)
    %{pub: pub, priv: priv}
  end

  defp signed(priv, serial, apps \\ []) do
    json = JSON.encode!(%{"schema" => 1, "serial" => serial, "issued" => "2026-11-16", "maintainers" => %{"hex_organization" => "lepton"}, "apps" => apps})
    {json, Base.encode64(:crypto.sign(:eddsa, :none, json, [priv, :ed25519]))}
  end

  @app %{"package" => "lepton_grep", "version" => "1.2.0", "checksum" => String.duplicate("ab", 32), "replaces" => ["grep", "egrep"]}

  test "the list must be signed by the Lepton key", %{pub: pub, priv: priv} do
    {json, sig} = signed(priv, 1, [@app])
    assert {:ok, %{serial: 1, maintainers: "lepton", apps: [%{package: "lepton_grep", replaces: ["grep", "egrep"]}]} = m} = Official.verify(json, sig, pub)
    assert Official.find(m, "egrep").package == "lepton_grep"
    assert Official.find(m, "lepton_grep").version == "1.2.0"
    refute Official.find(m, "sed")

    # Tampering (e.g. pointing grep at a look-alike package) breaks the signature.
    evil = String.replace(json, "lepton_grep", "lepton_grepp")
    assert {:error, "bad signature" <> _} = Official.verify(evil, sig, pub)

    # So does signing with any other key.
    {_, other} = :crypto.generate_key(:eddsa, :ed25519)
    {json2, sig2} = signed(other, 1, [@app])
    assert {:error, "bad signature" <> _} = Official.verify(json2, sig2, pub)
    assert {:error, _} = Official.verify(json, sig, nil)
  end

  test "entries must pin a version and a SHA-256", %{pub: pub, priv: priv} do
    {json, sig} = signed(priv, 1, [Map.put(@app, "checksum", "not-a-hash")])
    assert {:error, "official list has a malformed entry"} = Official.verify(json, sig, pub)
  end

  test "an older list is refused once a newer one was accepted; the cache works offline", %{pub: pub, priv: priv} do
    {json2, sig2} = signed(priv, 2, [@app])
    assert {:ok, %{serial: 2}} = Official.accept(json2, sig2, pub)
    {json1, sig1} = signed(priv, 1)
    assert {:error, "official list serial 1 is older" <> _} = Official.accept(json1, sig1, pub)
    assert {:ok, %{serial: 2, apps: [_]}} = Official.cached(pub)
  end

  test "packages cannot take over built-in commands; official updates can, and revert" do
    assert {:ok, %{fun: {Lepton.Commands.Text, _}}} = Lepton.Commands.lookup("grep")

    try do
      # An ordinary package: the name is skipped.
      assert ["grep"] = Lepton.Commands.register_module(FakeGrep)
      assert {"x\n", 0} = sh("echo x | grep x")

      # An official update allowed to replace grep.
      assert [] = Lepton.Commands.register_module(FakeGrep, ["grep"])
      assert {"updated grep\n", 0} = sh("echo x | grep x")
      # The built-in is still there.
      assert {"x\n", 0} = sh("echo x | builtin grep x")
    after
      Lepton.Commands.unregister_module(FakeGrep)
    end

    assert {"x\n", 0} = sh("echo x | grep x")
  end

  test "official installs refuse anything the list does not pin" do
    {:ok, sink} = StringIO.open("")
    ctx = %Lepton.Ctx{cwd: "/", env: %{}, stdout: sink, stderr: sink}
    assert {:error, "decimal is not pinned by the official list" <> _} = Lepton.Pkg.install(ctx, "decimal", nil, true, %{pins: %{}})
  end

  @tag :network
  test "pinned installs check the tarball against the pinned SHA-256" do
    {:ok, sink} = StringIO.open("")
    ctx = %Lepton.Ctx{cwd: "/", env: %{}, stdout: sink, stderr: sink}
    {:ok, body} = Lepton.Pkg.get("https://hex.pm/api/packages/decimal/releases/2.3.0")
    good = JSON.decode!(body)["checksum"]

    bad = %{pins: %{"decimal" => %{version: "2.3.0", checksum: String.duplicate("0", 64)}}}
    assert {:error, "checksum mismatch" <> _} = Lepton.Pkg.install(ctx, "decimal", "== 2.3.0", true, bad)
    refute Map.has_key?(Lepton.Pkg.installed(), "decimal")

    ok = %{pins: %{"decimal" => %{version: "2.3.0", checksum: good}}, official: %{replaces: [], serial: 1}}
    assert {:ok, %{version: "2.3.0"}} = Lepton.Pkg.install(ctx, "decimal", "== 2.3.0", true, ok)
    assert %{official: %{serial: 1}} = Lepton.Pkg.installed()["decimal"]
  end

    describe "lpm (local packages)" do
    setup do
      {:ok, sink} = StringIO.open("")
      %{ctx: %Lepton.Ctx{cwd: "/", env: %{}, stdout: sink, stderr: sink}}
    end

    defp project(app, source) do
      proj = tmp_dir("pkg")
      File.write!(Path.join(proj, "mix.exs"), ~s|defmodule P.MixProject do\n  use Mix.Project\n  def project, do: [app: :#{app}, version: "0.1.0"]\nend\n|)
      File.mkdir_p!(Path.join(proj, "lib"))
      File.write!(Path.join(proj, "lib/p.ex"), source)
      proj
    end

    test "a package's command named like a built-in is skipped", %{ctx: ctx} do
      proj = project(:lepton_lookalike, """
      defmodule LeptonLookalike do
        use Lepton.Command
        defcmd "grep", "not really grep" do
          _ = args
          IO.puts(ctx, "hijacked")
          0
        end
        defcmd "lookalike-ok", "a new command" do
          _ = args
          IO.puts(ctx, "fine")
          0
        end
      end
      """)

      try do
        assert {:ok, _} = Lepton.Pkg.install_local(ctx, proj)
        assert {"x\n", 0} = sh("echo x | grep x")
        assert {"fine\n", 0} = sh("lookalike-ok")
      after
        Lepton.Pkg.remove(ctx, "lepton_lookalike", false)
      end

      assert {_, 127} = sh("lookalike-ok")
    end

    test "a module installed by another package store is not a system module", %{ctx: ctx} do
      src = "defmodule LeptonTwice do\n  def hi, do: :ok\nend\n"
      assert {:ok, _} = Lepton.Pkg.install_local(ctx, project(:lepton_twice, src))
      System.put_env("LEPTON_STATE_DIR", tmp_dir("state2"))
      assert {:ok, _} = Lepton.Pkg.install_local(ctx, project(:lepton_twice, src))
      refute Lepton.Pkg.reserved_module?(LeptonTwice)
      assert Lepton.Pkg.reserved_module?(Logger)
      assert Lepton.Pkg.reserved_module?(:lists)
    end

    test "a package may not define Lepton or system modules", %{ctx: ctx} do
      original = Lepton.Commands.Text.module_info(:md5)

      for {app, mod} <- [{:evil_lepton, "Lepton.Commands.Text"}, {:evil_logger, "Logger"}, {:evil_nested, "Lepton"}] do
        src = if mod == "Lepton", do: "defmodule Lepton do\n  defmodule Shell do\n  end\nend\n", else: "defmodule #{mod} do\n  def hi, do: :evil\nend\n"
        assert {:error, "refusing to install: it defines system modules" <> _} = Lepton.Pkg.install_local(ctx, project(app, src))
        refute Map.has_key?(Lepton.Pkg.installed(), to_string(app))
      end

      assert Lepton.Commands.Text.module_info(:md5) == original
    end
  end
end
