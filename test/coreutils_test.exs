defmodule Lepton.CoreutilsTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  setup do
    dir = tmp_dir("core")
    File.write!(Path.join(dir, "fruits.txt"), "banana\napple\ncherry\napple\n")
    File.write!(Path.join(dir, "nums.txt"), "10\n9\n100\n")
    File.mkdir_p!(Path.join(dir, "d/e"))
    File.write!(Path.join(dir, "d/e/deep.ex"), "defmodule Deep do\nend\n")
    {:ok, dir: dir}
  end

  test "ls, mkdir, touch, rm", %{dir: dir} do
    assert {out, 0} = sh("ls", cwd: dir)
    assert out == "d\nfruits.txt\nnums.txt\n"
    assert {"", 0} = sh("mkdir -p x/y/z && touch x/y/z/f", cwd: dir)
    assert File.exists?(Path.join(dir, "x/y/z/f"))
    assert {_, 1} = sh("rm x", cwd: dir)
    assert {"", 0} = sh("rm -r x", cwd: dir)
    refute File.exists?(Path.join(dir, "x"))
  end

  test "cat, cp, mv", %{dir: dir} do
    assert {"banana\napple\ncherry\napple\n", 0} = sh("cat fruits.txt", cwd: dir)
    assert {"", 0} = sh("cp fruits.txt copy.txt && mv copy.txt moved.txt", cwd: dir)
    assert File.read!(Path.join(dir, "moved.txt")) =~ "cherry"
    assert {"", 0} = sh("cp -r d d2", cwd: dir)
    assert File.exists?(Path.join(dir, "d2/e/deep.ex"))
  end

  test "grep", %{dir: dir} do
    assert {"apple\napple\n", 0} = sh("grep apple fruits.txt", cwd: dir)
    assert {"2\n", 0} = sh("grep -c apple fruits.txt", cwd: dir)
    assert {"2:apple\n4:apple\n", 0} = sh("grep -n app fruits.txt", cwd: dir)
    assert {"banana\ncherry\n", 0} = sh("grep -v apple fruits.txt", cwd: dir)
    assert {"BANANA\n", 0} = sh("echo BANANA | grep -i banana", cwd: dir)
    assert {_, 1} = sh("grep kiwi fruits.txt", cwd: dir)
    assert {out, 0} = sh("grep -r defmodule .", cwd: dir)
    assert out =~ "d/e/deep.ex:defmodule Deep do"
  end

  test "grep with colour enabled", %{dir: dir} do
    # Colour is on by default (unlike the other tests); matches are only
    # highlighted on a terminal, so piped output stays plain.
    assert {"BANANA\n", 0} = sh("echo BANANA | grep -i banana", cwd: dir, color: true)
    assert {"apple\napple\n", 0} = sh("grep apple fruits.txt | cat", cwd: dir, color: true)
    assert {"banana\ncherry\n", 0} = sh("grep -v apple fruits.txt", cwd: dir, color: true)
    assert {"1:banana\n", 0} = sh("grep -n ban fruits.txt", cwd: dir, color: true)
  end

  test "sort, uniq, head, tail, wc", %{dir: dir} do
    assert {"apple\napple\nbanana\ncherry\n", 0} = sh("sort fruits.txt", cwd: dir)
    assert {"      2 apple\n      1 banana\n      1 cherry\n", 0} = sh("sort fruits.txt | uniq -c", cwd: dir)
    assert {"100\n10\n9\n", 0} = sh("sort -rn nums.txt", cwd: dir)
    assert {"banana\napple\n", 0} = sh("head -n 2 fruits.txt", cwd: dir)
    assert {"apple\n", 0} = sh("tail -n 1 fruits.txt", cwd: dir)
    assert {"4\n", 0} = sh("wc -l < fruits.txt | tr -d ' '", cwd: dir)
  end

  test "cut, tr, sed, awk", %{dir: dir} do
    assert {"b\n", 0} = sh("echo a:b:c | cut -d : -f 2", cwd: dir)
    assert {"HELLO\n", 0} = sh("echo hello | tr a-z A-Z", cwd: dir)
    assert {"hexxo worxd\n", 0} = sh("echo hello world | sed s/l/x/g", cwd: dir)
    assert {"world hello\n", 0} = sh("echo hello world | awk '{print $2, $1}'", cwd: dir)
    assert {"apple\napple\n", 0} = sh("awk '/app/' fruits.txt", cwd: dir)
  end

  test "find and tree", %{dir: dir} do
    assert {"./d/e/deep.ex\n", 0} = sh("find . -name '*.ex'", cwd: dir)
    # -user and -group: by name or number; nothing of a user who owns none.
    me = File.lstat!(dir).uid
    {all, 0} = sh("find .", cwd: dir)
    assert {^all, 0} = sh("find . -user #{me}", cwd: dir)
    assert {^all, 0} = sh("find . -xdev -group #{File.lstat!(dir).gid}", cwd: dir)
    if me != 0, do: assert({"", 0} = sh("find . -user root", cwd: dir))
    # Something it doesn't know is an error, not a reason to list everything.
    assert {"", 1} = sh("find . -newer x", cwd: dir)

    # -print0 and xargs -0: names with spaces stay whole.
    sp = Path.join(dir, "sp")
    File.mkdir_p!(sp)
    for n <- ["two words.txt", "plain.txt"], do: File.write!(Path.join(sp, n), "x")
    assert {out, 0} = sh("find sp -type f -print0", cwd: dir)
    assert out == "sp/plain.txt\0sp/two words.txt\0"
    assert {"2\n", 0} = sh("find sp -type f -print0 | xargs -0 -n 1 echo | wc -l | tr -d ' '", cwd: dir)
    assert {"sp/two words.txt\n", 0} = sh("find sp -name 'two*' -print0 | xargs -0 ls", cwd: dir)
    # Without -0: blanks split, quotes and a backslash keep one together; -I: once a line.
    assert {"a\nmy file\nit s\n", 0} = sh(~S<printf 'a "my file" it\\ s' | xargs -n 1 echo>, cwd: dir)
    assert {"<one two>\n<three>\n", 0} = sh("printf 'one two\\nthree\\n' | xargs -I @ echo '<@>'", cwd: dir)
    assert {"", 1} = sh("find . -user nosuchuser", cwd: dir)
    assert {out, 0} = sh("tree d", cwd: dir)
    assert out =~ "└── deep.ex"
  end

  test "printf, seq, test, expr, basename" do
    assert {"x=  5|", 0} = sh("printf 'x=%3d|' 5")
    assert {"1\n2\n3\n", 0} = sh("seq 3")
    assert {"", 0} = sh("test -d /")
    assert {"7\n", 0} = sh("expr 3 + 4")
    assert {"file.txt\n", 0} = sh("basename /a/b/file.txt")
  end

  test "checksums and base64" do
    assert {"5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03  -\n", 0} = sh("echo hello | sha256sum")
    assert {"aGVsbG8K\n", 0} = sh("echo hello | base64")
    assert {"hello\n", 0} = sh("echo aGVsbG8K | base64 -d")
  end

  test "diff and xargs", %{dir: dir} do
    File.write!(Path.join(dir, "a"), "1\n2\n3\n")
    File.write!(Path.join(dir, "b"), "1\nTWO\n3\n")
    assert {out, 1} = sh("diff a b", cwd: dir)
    assert out =~ "-2\n+TWO"
    assert {"", 0} = sh("diff a a", cwd: dir)
    assert {"a b c\n", 0} = sh("printf 'a\\nb\\nc\\n' | xargs echo", cwd: dir)
  end

  test "process table and kill" do
    {pid, beam} = Lepton.Proc.spawn("sleeper", fn _ -> Process.sleep(:infinity) end)
    ref = Process.monitor(beam)
    assert {out, 0} = sh("ps")
    assert out =~ "sleeper"
    assert {"", 0} = sh("kill -9 #{pid}")
    assert_receive {:DOWN, ^ref, :process, _, :killed}, 1000
  end

  test "help lists commands from every set" do
    {out, 0} = sh("help")
    for c <- ~w(ls grep git gh le tmux iex lepton-test www), do: assert(out =~ c, "missing #{c}")
  end
end
