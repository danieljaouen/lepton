defmodule Lepton.ServicesTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.Services
  alias Lepton.Services.Unit

  setup do
    state = tmp_dir("svc-state")
    units = tmp_dir("svc-units")
    System.put_env("LEPTON_STATE_DIR", state)
    System.put_env("LEPTON_SERVICE_PATH", units)

    on_exit(fn ->
      for %{name: n, state: s} <- Services.list(), s != :inactive, do: Services.stop(n)
      System.delete_env("LEPTON_STATE_DIR")
      System.delete_env("LEPTON_SERVICE_PATH")
    end)

    %{units: units}
  end

  defp unit(units, name, body), do: File.write!(Path.join(units, name <> ".service"), body)

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(30); eventually(fun, tries - 1)
    end
  end

  defp running?(fragment), do: Enum.any?(Lepton.Proc.list(), &String.contains?(&1.cmd, fragment))

  test "unit files: systemd syntax, defaults and errors" do
    text = """
    # comment
    [Unit]
    Description=Demo
    [Service]
    ExecStart=echo a \\
      b
    Restart=always
    RestartSec=2s
    Environment=A=1 "B=two words"
    Environment=C=3
    Type=simple
    """

    assert {:ok, u} = Unit.parse("demo", "/x/demo.service", text)
    assert u.description == "Demo"
    assert u.exec_start =~ ~r/^echo a\s+b$/
    assert {u.restart, u.restart_sec, u.timeout_stop_sec} == {"always", 2.0, 5.0}
    assert u.environment == %{"A" => "1", "B" => "two words", "C" => "3"}
    assert u.ignored == ["Service.Type"]

    assert {:error, "d.service: ExecStart= is required"} = Unit.parse("d", "/x/d.service", "[Unit]\nDescription=x\n")
    assert {:error, "d.service:2: Restart= must be" <> _} = Unit.parse("d", "/x/d.service", "[Service]\nRestart=sometimes\n")
    assert {:error, "invalid service name" <> _} = Unit.load("../etc/passwd")
  end

  test "start, status, logs, stop - the whole process tree goes", %{units: units} do
    unit(units, "ticker", "[Unit]\nDescription=Ticks\n[Service]\nExecStart=i=0; while true; do echo tick $i; i=$((i+1)); sleep 0.05; done | cat\nEnvironment=X=1\n")

    assert {"● started ticker (PID " <> _, 0} = sh("svc start ticker")
    assert eventually(fn -> Enum.count(Services.logs("ticker", 100), &(&1 =~ "ticker[")) >= 3 end)
    assert %{state: :active, pid: pid} = Services.status("ticker")
    assert {out, 0} = sh("svc status ticker")
    assert out =~ "Active: active" and out =~ "tick 0"
    assert {"active\n", 0} = sh("svc is-active ticker")
    assert {"ticker is already running\n", 0} = sh("svc start ticker")
    assert running?("sleep 0.05") or running?("cat")
    # In ps, the service's own process is `svc NAME`, its command a child of it: not two alike.
    assert Lepton.Proc.lookup(pid).cmd == "svc ticker"
    {ps, 0} = sh("ps auxw")
    assert ps =~ ~r/^\s*#{pid}\s+1\s.*svc ticker$/m

    assert {"stopped ticker\n", 0} = sh("svc stop ticker")
    assert %{state: :inactive, result: :stopped} = Services.status("ticker")
    refute Lepton.Proc.lookup(pid)
    assert eventually(fn -> not running?("sleep 0.05") end)
    assert {"inactive\n", 3} = sh("svc is-active ticker")
    assert Enum.any?(Services.logs("ticker", 5), &(&1 =~ "svc: Stopped ticker."))
  end

  test "failures restart until the start limit; clean exits don't", %{units: units} do
    unit(units, "flaky", "[Service]\nExecStart=echo boom; exit 3\nRestart=on-failure\nRestartSec=0.05\n")
    {:ok, _} = Services.start("flaky")
    assert eventually(fn -> Services.status("flaky").state == :failed end)
    assert %{result: {:exited, 3}, restarts: 4} = Services.status("flaky")
    assert Enum.any?(Services.logs("flaky", 3), &(&1 =~ "start limit hit"))

    unit(units, "oneshot", "[Service]\nExecStart=echo done\nRestart=on-failure\n")
    {:ok, _} = Services.start("oneshot")
    assert eventually(fn -> Services.status("oneshot").state == :inactive end)
    assert %{result: {:exited, 0}, restarts: 0} = Services.status("oneshot")

    unit(units, "crash", "[Service]\nExecStart=exit 1\n")
    assert {out, 1} = sh("svc start crash")
    assert out =~ "crash exited with status 1"
    assert %{state: :failed} = Services.status("crash")

    # A manual start clears the failure and the start limit.
    unit(units, "flaky", "[Service]\nExecStart=sleep 5\n")
    assert {:ok, _} = Services.start("flaky")
    assert %{state: :active, restarts: 4} = Services.status("flaky")
  end

  test "logs -f follows new lines", %{units: units} do
    unit(units, "chatty", "[Service]\nExecStart=while true; do echo chat; sleep 0.05; done\n")
    {:ok, _} = Services.start("chatty")
    :ok = Services.follow("chatty")
    assert_receive {:svc_log, line}, 2000
    assert line =~ "chatty["
  end

  test "svc new, cat, enable, boot and disable", %{units: units} do
    assert {out, 0} = sh("svc new greeter 'echo hi; sleep 30'")
    assert out =~ "created"
    assert File.read!(Path.join(units, "greeter.service")) =~ "ExecStart=echo hi; sleep 30"
    assert {out, 0} = sh("svc cat greeter")
    assert out =~ "Restart=on-failure"
    assert {_, 1} = sh("svc new greeter 'true'")

    assert {"enabled greeter (starts at boot)\n", 0} = sh("svc enable greeter")
    assert {"enabled\n", 0} = sh("svc is-enabled greeter")
    :ok = Services.boot()
    assert %{state: :active} = Services.status("greeter")
    assert eventually(fn -> Enum.any?(Services.logs("greeter", 5), &(&1 =~ "greeter[")) end)
    assert {out, 0} = sh("journalctl -u greeter -n 5")
    assert out =~ ": hi"

    assert {_, 0} = sh("svc disable --now greeter")
    assert %{state: :inactive, enabled: false} = Services.status("greeter")
    assert {_, 1} = sh("svc enable nosuch")
  end

  test "httpd serves files as a service and frees its port when stopped", %{units: units} do
    pub = tmp_dir("pub")
    File.write!(Path.join(pub, "index.html"), "hello from svc\n")
    port = 20_000 + :rand.uniform(20_000)
    unit(units, "web", "[Service]\nExecStart=httpd -p #{port} #{pub}\n")

    assert {_, 0} = sh("svc start web")
    assert {"hello from svc\n", 0} = sh("curl -s http://127.0.0.1:#{port}/")
    assert {_, 0} = sh("svc restart web")
    assert {"hello from svc\n", 0} = sh("curl -s http://127.0.0.1:#{port}/")
    assert {_, 0} = sh("svc stop web")
    assert {:error, _} = :gen_tcp.connect(~c"127.0.0.1", port, [], 500)
  end

  test "stop_all stops every service (power-off)", %{units: units} do
    unit(units, "a", "[Service]\nExecStart=sleep 30\n")
    unit(units, "b", "[Service]\nExecStart=sleep 30\nRestart=always\n")
    {:ok, _} = Services.start("a")
    {:ok, _} = Services.start("b")
    :ok = Services.stop_all()
    assert %{state: :inactive} = Services.status("a")
    assert %{state: :inactive} = Services.status("b")
  end
end
