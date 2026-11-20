defmodule Lepton.CronTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.{Cron, Services, Users}

  setup do
    state = tmp_dir("cronstate")
    homes = "/tmp/lepton-cronhomes-#{System.unique_integer([:positive])}"
    File.mkdir_p!(homes)
    System.put_env("LEPTON_STATE_DIR", state)
    System.put_env("LEPTON_HOME_ROOT", homes)
    on_exit(fn -> System.delete_env("LEPTON_STATE_DIR"); System.delete_env("LEPTON_HOME_ROOT"); File.rm_rf(homes) end)
    {:ok, _} = Users.create("alice", "pw", home_root: homes, skel: tmp_dir("skel"))
    %{state: state, homes: homes}
  end

  defp job!(line) do
    {:ok, [job]} = Cron.parse(line)
    job
  end

  defp at(date, {h, m}), do: {Date.to_erl(date), {h, m, 0}}

  describe "the syntax" do
    test "fields: lists, ranges, steps and names" do
      j = job!("*/15 9-17 * jan,jul mon-fri  echo hi")
      assert MapSet.to_list(j.minute) |> Enum.sort() == [0, 15, 30, 45]
      assert MapSet.to_list(j.hour) |> Enum.sort() == Enum.to_list(9..17)
      assert MapSet.to_list(j.month) |> Enum.sort() == [1, 7]
      assert MapSet.to_list(j.dow) |> Enum.sort() == [1, 2, 3, 4, 5]
      assert j.command == "echo hi"

      assert MapSet.to_list(job!("5/20 * * * * x").minute) |> Enum.sort() == [5, 25, 45]
      assert MapSet.to_list(job!("0 0 * * 7 x").dow) == [0]
      assert job!("@daily backup") |> Map.take([:command]) == %{command: "backup"}
      assert job!("@reboot start").reboot
    end

    test "environment lines and % for standard input" do
      {:ok, [a, b]} = Cron.parse("A=1\n* * * * * one\nB='two words'\n* * * * * cat%line 1%line 2 has \\% in it\n")
      assert a.env == %{"A" => "1"}
      assert b.env == %{"A" => "1", "B" => "two words"}
      assert b.command == "cat"
      assert b.input == "line 1\nline 2 has % in it\n"
    end

    test "mistakes are reported with their line numbers" do
      assert {:error, errors} = Cron.parse("# fine\n61 * * * * x\n* * * *\n@sometimes x\n* * * * * \n0-5/0 * * * * y\n")
      assert [{2, "minute: 61 is out of range (0-59)"}, {3, "expected five" <> _}, {4, "unknown schedule @sometimes" <> _}, {5, _}, {6, "minute: bad step" <> _}] = errors
    end

    test "when: both day fields restricted means either day" do
      friday13 = ~D[2026-11-13]
      assert Cron.due?(job!("30 4 13 * 5 x"), at(friday13, {4, 30}))
      assert Cron.due?(job!("30 4 13 * 1 x"), at(friday13, {4, 30}))
      assert Cron.due?(job!("30 4 1 * 5 x"), at(friday13, {4, 30}))
      refute Cron.due?(job!("30 4 1 * 1 x"), at(friday13, {4, 30}))
      # one restricted: both must match
      refute Cron.due?(job!("30 4 * * 1 x"), at(friday13, {4, 30}))
      refute Cron.due?(job!("31 4 * * * x"), at(friday13, {4, 30}))
      assert Cron.next(job!("0 0 1 1 * x"), {{2026, 11, 20}, {12, 0, 0}}) == ~N[2027-01-01 00:00:00]
    end
  end

  describe "crontab" do
    test "install from a file or standard input, list, remove; bad tables are refused" do
      dir = tmp_dir("crontabfile")
      File.write!(Path.join(dir, "tab"), "0 * * * * date\n")
      assert {"", 1} = sh("crontab -l", user: "alice")
      assert {"", 0} = sh("crontab #{dir}/tab", user: "alice")
      assert {"0 * * * * date\n", 0} = sh("crontab -l", user: "alice")
      assert {"", 0} = sh("crontab -", user: "alice", stdin: elem(StringIO.open("@hourly echo hi\n"), 1))
      assert {"@hourly echo hi\n", 0} = sh("crontab -l", user: "alice")
      assert {"", 1} = sh("crontab -", user: "alice", stdin: elem(StringIO.open("not a cron line\n"), 1))
      assert {"@hourly echo hi\n", 0} = sh("crontab -l", user: "alice")
      assert {"", 0} = sh("crontab -r", user: "alice")
      assert {"", 1} = sh("crontab -l", user: "alice")
      # -e opens the editor, so it needs a terminal
      assert {"", 1} = sh("crontab -e", user: "alice")
    end

    test "only root may manage someone else's" do
      assert {"", 1} = sh("crontab -u root -l", user: "alice")
      assert {"", 0} = sh("crontab -u alice -", stdin: elem(StringIO.open("@daily true\n"), 1))
      assert {"@daily true\n", 0} = sh("crontab -l", user: "alice")
      assert File.stat!(Cron.path("alice")).mode |> Bitwise.band(0o777) == 0o600
    end
  end

  describe "running jobs" do
    test "due jobs run as their owner, in their home, with % input; output and failures are logged", %{homes: homes} do
      :ok = Cron.install("alice", "GREETING=hi\n15 10 * * * echo $GREETING $USER; whoami > ran.txt; pwd >> ran.txt\n15 10 * * * cat > input.txt%a%b\n16 10 * * * echo not now\n15 10 * * * exit 3\n")
      me = self()
      log = fn line -> send(me, {:log, line}) end
      home = &Path.join(homes, &1.name)
      beams = Cron.run_due({{2026, 11, 20}, {10, 15, 0}}, log, home: home)
      assert length(beams) == 3
      for b <- beams, ref = Process.monitor(b), do: assert_receive({:DOWN, ^ref, _, _, _}, 5000)

      assert File.read!(Path.join(homes, "alice/ran.txt")) == "alice\n" <> Path.join(homes, "alice") <> "\n"
      assert File.read!(Path.join(homes, "alice/input.txt")) == "a\nb\n"
      assert_received {:log, "(alice) CMD (echo $GREETING $USER; whoami > ran.txt; pwd >> ran.txt)"}
      assert_received {:log, "(alice) hi alice"}
      assert_received {:log, "(alice) exited with status 3: exit 3"}
      refute_received {:log, "(alice) not now"}
    end

    test "the cron service is on by default, and stays off once disabled" do
      assert "cron" in Services.defaults()
      assert Services.enabled?("cron")
      refute Services.enabled?("sshd")
      Services.set_enabled("cron", false)
      refute Services.enabled?("cron")
      Services.set_enabled("sshd", true)
      assert Services.enabled?("sshd")
      Services.set_enabled("cron", true)
      assert Services.enabled?("cron")
    end

    test "crond logs that it started and stops on a terminate signal" do
      me = self()
      pid = spawn(fn -> send(me, {:done, Cron.daemon(&send(me, {:log, &1}))}) end)
      assert_receive {:log, "crond started; " <> _}, 2000
      send(pid, {:signal, :term})
      assert_receive {:done, 0}, 2000
    end
  end
end
