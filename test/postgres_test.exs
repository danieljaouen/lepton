defmodule Lepton.PostgresTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.{Postgres, Services}
  alias Lepton.Postgres.Psql

  test "the app: Alpine's PostgreSQL 18, its client and contrib" do
    app = Lepton.Apps.get("postgresql")
    assert app.packages == ["postgresql18", "postgresql18-client", "postgresql18-contrib"]
    assert app.main == "postgresql18" and app.exe == nil
    assert "postgresql" in Lepton.Apps.names()
  end

  test "Lepton's settings: this machine only, the socket in /run/postgresql, the log to the service" do
    conf = Postgres.conf()
    assert conf =~ "listen_addresses = 'localhost'"
    assert conf =~ "port = 5432"
    assert conf =~ "unix_socket_directories = '/run/postgresql'"
    assert conf =~ "logging_collector = off"
  end

  test "its programs run with their libraries, ICU's data, and the socket" do
    prefix = tmp_dir("pgprefix")
    File.mkdir_p!(Path.join(prefix, "usr/share/icu/78.1"))
    env = Postgres.env(prefix)
    assert env["LD_LIBRARY_PATH"] == "#{prefix}/usr/lib:#{prefix}/lib"
    assert env["ICU_DATA"] == Path.join(prefix, "usr/share/icu/78.1")
    assert env["PGHOST"] == "/run/postgresql" and env["PGPORT"] == "5432"
  end

  test "its tools go on PATH as links, and come off again" do
    bin = tmp_dir("pgbin")
    dir = tmp_dir("pglinks")
    for t <- ["createdb", "pg_dump", "postgres"], do: File.write!(Path.join(bin, t), "")

    Postgres.link_tools(dir, bin)
    assert File.read_link(Path.join(dir, "createdb")) == {:ok, Path.join(bin, "createdb")}
    assert File.read_link(Path.join(dir, "pg_dump")) == {:ok, Path.join(bin, "pg_dump")}
    # Only the tools (not the server), and only those there are.
    refute File.exists?(Path.join(dir, "postgres"))
    refute File.exists?(Path.join(dir, "dropdb"))

    File.write!(Path.join(dir, "mine"), "")
    Postgres.unlink_tools(dir)
    assert File.ls!(dir) == ["mine"]
  end

  test "the postgresql service runs the server, and is off until set up" do
    {:ok, unit} = Lepton.Services.Unit.load("postgresql")
    assert unit.exec_start == "postgresql server"
    assert unit.restart == "on-failure"
    assert unit.timeout_stop_sec == 30.0
    refute "postgresql" in Services.defaults()
  end

  test "the postgres account is in /etc/passwd and /etc/group, and can't be taken" do
    etc = tmp_dir("pgetc")
    Lepton.Users.sync_etc(etc)
    assert File.read!(Path.join(etc, "passwd")) =~ "postgres:x:70:70:PostgreSQL:/var/lib/lepton/postgresql:/bin/false\n"
    assert File.read!(Path.join(etc, "group")) =~ "postgres:x:70:"
    refute Lepton.Users.valid_name?("postgres")
    assert Lepton.Users.names_by_id().users[70] == "postgres"
  end

  test "psql: the postgres role through the socket, unless told otherwise" do
    env = Psql.env(%{"HOME" => "/root"})
    assert env["PGUSER"] == "postgres" and env["PGHOST"] == "/run/postgresql" and env["PGPORT"] == "5432"
    env = Psql.env(%{"PGUSER" => "alice", "PGHOST" => "localhost"})
    assert env["PGUSER"] == "alice" and env["PGHOST"] == "localhost"
  end

  test "psql: a statement is sent at a ; ending it outside quotes, a backslash command at once" do
    assert Psql.complete?("select 1;")
    assert Psql.complete?("select 1\nfrom t;")
    assert Psql.complete?("\\dt")
    assert Psql.complete?("select 1 \\gx")
    refute Psql.complete?("select 1")
    refute Psql.complete?("select 'a;")
    assert Psql.complete?("select 'a;';")
    refute Psql.complete?("create function f() returns int as $$ select 1;")
    assert Psql.complete?("create function f() returns int as $$ select 1; $$ language sql;")
  end

  test "psql: without PostgreSQL it says how to set it up" do
    state = tmp_dir("pgstate")
    System.put_env("LEPTON_STATE_DIR", state)

    try do
      {out, status} = sh("psql -c 'select 1' 2>&1")
      assert status == 1
      assert out =~ "sudo postgresql setup"
      {out, 1} = sh("postgresql")
      assert out =~ "PostgreSQL isn't installed"
    after
      System.delete_env("LEPTON_STATE_DIR")
    end
  end
end
