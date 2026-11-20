defmodule Lepton.TimeTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.{NTP, TZ}

  setup do
    state = tmp_dir("timestate")
    System.put_env("LEPTON_STATE_DIR", state)
    on_exit(fn -> System.delete_env("LEPTON_STATE_DIR") end)
    %{state: state}
  end

  # 2026-07-01 12:00 UTC and 2027-01-15 12:00 UTC
  @summer 1_782_907_200
  @winter 1_800_014_400

  describe "time zones" do
    test "POSIX rules: northern, southern and inverted daylight saving, half hours" do
      ny = TZ.parse_rule("EST5EDT,M3.2.0,M11.1.0")
      assert TZ.rule_period(ny, @summer) == {-14_400, true, "EDT"}
      assert TZ.rule_period(ny, @winter) == {-18_000, false, "EST"}
      # 2026-03-08 06:59:59 UTC is 01:59:59 EST; a second later, 03:00 EDT
      assert TZ.rule_period(ny, 1_772_953_199) == {-18_000, false, "EST"}
      assert TZ.rule_period(ny, 1_772_953_200) == {-14_400, true, "EDT"}

      sydney = TZ.parse_rule("AEST-10AEDT,M10.1.0,M4.1.0/3")
      assert TZ.rule_period(sydney, @summer) == {36_000, false, "AEST"}
      assert TZ.rule_period(sydney, @winter) == {39_600, true, "AEDT"}

      dublin = TZ.parse_rule("IST-1GMT0,M10.5.0,M3.5.0/1")
      assert TZ.rule_period(dublin, @summer) == {3600, false, "IST"}
      assert TZ.rule_period(dublin, @winter) == {0, true, "GMT"}

      assert TZ.rule_period(TZ.parse_rule("<+0530>-5:30"), @summer) == {19_800, false, "+0530"}
    end

    test "zone files" do
      assert TZ.period("Europe/Paris", @summer) == {7200, true, "CEST"}
      assert TZ.period("Europe/Paris", @winter) == {3600, false, "CET"}
      assert TZ.period("Asia/Kolkata", @summer) == {19_800, false, "IST"}
      assert {-14_400, true, "EDT"} = TZ.period("America/New_York", @summer)
      # far past the files' last transition: the rule
      assert {-18_000, false, "EST"} = TZ.period("America/New_York", 4_102_444_800)
      assert TZ.period("No/Such_Zone", @summer) == {0, false, "UTC"}
      assert TZ.exists?("Europe/Paris")
      refute TZ.exists?("../../etc/passwd")
      assert "Europe/Paris" in TZ.zones()
    end
  end

  describe "local time" do
    test "the zone: UTC until set, kept, and a command's TZ wins" do
      assert Lepton.Time.setting() == {"UTC", :auto}
      assert :ok = Lepton.Time.set_zone("Asia/Tokyo", :manual)
      assert Lepton.Time.setting() == {"Asia/Tokyo", :manual}
      assert {:error, _} = Lepton.Time.set_zone("Mars/Olympus", :manual)

      dt = Lepton.Time.local(@summer)
      assert {dt.hour, dt.zone_abbr, Lepton.Time.offset(dt), DateTime.to_unix(dt)} == {21, "JST", "+0900", @summer}

      {out, 0} = sh("date +%Z%z")
      assert out == "JST+0900\n"
      {out, 0} = sh("TZ=Europe/Paris date +%Z")
      assert out in ["CET\n", "CEST\n"]
      {out, 0} = sh("date -u +%Z")
      assert out == "UTC\n"
    end

    test "timedatectl: status, set-timezone (root), list-timezones" do
      {out, 0} = sh("timedatectl")
      assert out =~ "Time zone: UTC"
      assert out =~ "Universal time:"

      assert {_, 1} = sh("timedatectl set-timezone Europe/Paris", user: "nobody")
      assert {"", 0} = sh("timedatectl set-timezone Europe/Paris")
      {out, 0} = sh("timedatectl status")
      assert out =~ ~r/Time zone: Europe\/Paris \(CES?T, \+0[12]00\), set with timedatectl/
      assert {_, 1} = sh("timedatectl set-timezone Atlantis/Lost")

      {out, 0} = sh("timedatectl list-timezones kolkata")
      assert out == "Asia/Kolkata\n"
    end

    test "ntpd and cron are on by default" do
      assert "ntpd" in Lepton.Services.defaults()
      assert "cron" in Lepton.Services.defaults()
    end
  end

  describe "NTP" do
    # A server on this machine that answers `offset` seconds ahead.
    defp fake_server(offset, opts \\ []) do
      {:ok, sock} = :gen_udp.open(0, [:binary, active: false])
      {:ok, port} = :inet.port(sock)

      spawn_link(fn ->
        {:ok, {ip, p, <<_::binary-40, t1::binary-8>>}} = :gen_udp.recv(sock, 0, 5000)
        now = System.os_time(:nanosecond) / 1.0e9 + offset
        s = trunc(now) + 2_208_988_800
        f = trunc((now - trunc(now)) * 4_294_967_296)
        origin = if opts[:spoof], do: <<0::64>>, else: t1
        stratum = Keyword.get(opts, :stratum, 2)
        :gen_udp.send(sock, ip, p, <<0::2, 4::3, 4::3, stratum, 6, -20::signed, 0::32, 0::32, 0::32, 0::64, origin::binary, s::32, f::32, s::32, f::32>>)
      end)

      {{127, 0, 0, 1}, port}
    end

    test "the offset and round trip of a server's answer" do
      assert {:ok, a} = NTP.query(fake_server(100.0))
      assert_in_delta a.offset, 100.0, 0.05
      assert a.delay >= 0 and a.delay < 0.5
      assert {:ok, b} = NTP.query(fake_server(-2.5))
      assert_in_delta b.offset, -2.5, 0.05
    end

    test "answers that aren't to our question, or from an unsynchronised server, are refused" do
      assert {:error, :reply_to_something_else} = NTP.query(fake_server(5.0, spoof: true))
      assert {:error, :unsynchronised} = NTP.query(fake_server(5.0, stratum: 0))
    end

    test "servers from ntp.conf" do
      dir = tmp_dir("ntpconf")
      File.write!(Path.join(dir, "ntp.conf"), "# comment\nserver a.example\npool b.example iburst\n")
      assert NTP.servers(Path.join(dir, "ntp.conf")) == ["a.example", "b.example"]
      assert NTP.servers(Path.join(dir, "missing")) == ["pool.ntp.org", "time.cloudflare.com"]
    end

    test "the time zone from a GeoIP lookup; an unknown zone is ignored" do
      {:ok, l} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(l)

      spawn_link(fn ->
        for body <- ["Europe/Paris\n", "Nowhere/Land"] do
          {:ok, c} = :gen_tcp.accept(l)
          {:ok, _} = :gen_tcp.recv(c, 0, 5000)
          :gen_tcp.send(c, "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}")
          :gen_tcp.close(c)
        end
      end)

      url = "http://127.0.0.1:#{port}/tz"
      assert NTP.geo_zone([{url, :text}]) == {:ok, "Europe/Paris"}
      assert NTP.geo_zone([{url, :text}]) == {:error, :no_answer}
    end
  end
end
