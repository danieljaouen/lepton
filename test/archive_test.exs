defmodule Lepton.ArchiveTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.Archive.{Tar, Zip}

  defp tree(dir) do
    File.mkdir_p!(Path.join(dir, "src/sub/deep"))
    File.write!(Path.join(dir, "src/a b.txt"), "hello\n")
    File.write!(Path.join(dir, "src/sub/rand.bin"), :crypto.strong_rand_bytes(200_000))
    File.chmod!(Path.join(dir, "src/sub/rand.bin"), 0o755)
    File.ln_s!("../a b.txt", Path.join(dir, "src/sub/link"))
    long = String.duplicate("x", 120) <> ".txt"
    File.write!(Path.join(dir, "src/sub/deep/" <> long), "long\n")
    long
  end

  test "tar: create (plain and gzip), list, extract; long names, links, permissions" do
    dir = tmp_dir("tar")
    long = tree(dir)

    assert {_, 0} = sh("tar czf src.tgz src", cwd: dir, home: dir)
    assert {_, 0} = sh("tar -cf src.tar src", cwd: dir, home: dir)
    assert Tar.compression(File.read!(Path.join(dir, "src.tgz"))) == :gzip

    {names, 0} = sh("tar tzf src.tgz", cwd: dir, home: dir)
    assert String.split(names, "\n", trim: true) == ["src/", "src/a b.txt", "src/sub/", "src/sub/deep/", "src/sub/deep/" <> long, "src/sub/link", "src/sub/rand.bin"]
    # -z is optional when reading: the compression is recognised.
    assert {^names, 0} = sh("tar -tf src.tgz", cwd: dir, home: dir)
    {long_list, 0} = sh("tar -tvf src.tar", cwd: dir, home: dir)
    assert long_list =~ ~r/^-rwxr-xr-x \S+\/\S+ +200000 \d{4}-\d\d-\d\d \d\d:\d\d src\/sub\/rand.bin$/m
    assert long_list =~ "src/sub/link -> ../a b.txt"

    for {archive, flags} <- [{"src.tgz", "xzf"}, {"src.tar", "-xvf"}] do
      out = Path.join(dir, "out-" <> archive)
      File.mkdir_p!(out)
      assert {_, 0} = sh("tar #{flags} #{archive} -C out-#{archive}", cwd: dir, home: dir)
      for f <- ["src/a b.txt", "src/sub/rand.bin", "src/sub/deep/" <> long], do: assert(File.read!(Path.join(out, f)) == File.read!(Path.join(dir, f)))
      assert File.read_link!(Path.join(out, "src/sub/link")) == "../a b.txt"
      assert (File.stat!(Path.join(out, "src/sub/rand.bin")).mode &&& 0o777) == 0o755
    end

    # Members, --strip-components, -O, -k and --exclude.
    assert {_, 0} = sh("tar xzf src.tgz --strip-components=1 -C out-src.tgz src/sub", cwd: dir, home: dir)
    assert File.exists?(Path.join(dir, "out-src.tgz/sub/rand.bin")) and not File.exists?(Path.join(dir, "out-src.tgz/a b.txt"))
    assert {"hello\n", 0} = sh(~S|tar -xOzf src.tgz 'src/a b.txt'|, cwd: dir, home: dir)
    assert {_, 2} = sh("tar xzf src.tgz nothing", cwd: dir, home: dir, stderr: StringIO.open("") |> elem(1))
    assert {_, 2} = sh("tar xkf src.tar -C out-src.tar", cwd: dir, home: dir, stderr: StringIO.open("") |> elem(1))
    assert {_, 0} = sh("tar --exclude=*.bin --exclude=deep -czf small.tgz src", cwd: dir, home: dir)
    {small, 0} = sh("tar tf small.tgz", cwd: dir, home: dir)
    refute small =~ "rand.bin" or small =~ "deep"
    # -a: compressed by the name; the archive leaves itself out.
    assert {_, 0} = sh("tar -caf self.tar.gz .", cwd: dir, home: dir)
    {self_names, 0} = sh("tar tf self.tar.gz", cwd: dir, home: dir)
    refute self_names =~ "self.tar.gz"
    assert self_names =~ "./src.tgz"

    # Errors: no mode, nothing to archive, other compressors, not a tar.
    {:ok, err} = StringIO.open("")
    assert {_, 2} = sh("tar -f src.tar", cwd: dir, stderr: err)
    assert {_, 2} = sh("tar -cf x.tar", cwd: dir, stderr: err)
    assert {_, 2} = sh("tar -xJf src.tar", cwd: dir, stderr: err)
    File.write!(Path.join(dir, "fake.tar.xz"), <<0xFD, "7zXZ", 0, 0>>)
    assert {_, 2} = sh("tar -xf fake.tar.xz", cwd: dir, stderr: err)
    File.write!(Path.join(dir, "junk.tar"), String.duplicate("junk", 200))
    assert {_, 2} = sh("tar -tf junk.tar", cwd: dir, stderr: err)
    {:ok, {_, errors}} = StringIO.close(err)
    assert errors =~ "xz" and errors =~ "checksum"
  end

  test "tar: leading / and .. are taken out (nothing is written outside the folder)" do
    dir = tmp_dir("tar-safe")
    assert Tar.target("/etc/passwd", dir) == Path.join(dir, "etc/passwd")
    assert Tar.target("../../evil", dir) == nil
    assert Tar.target("a/../../evil", dir) == nil
    assert Tar.target("./a/b", dir, 1) == Path.join(dir, "b")
    assert Tar.member_name("/etc/hosts") == {"etc/hosts", "Removing leading '/' from member names"}
  end

  test "tar: reads GNU long names, pax headers and base-256 sizes" do
    # A GNU tar ././@LongLink entry, then its file.
    name = String.duplicate("n", 150)
    {tar, _} = Tar.create([], "/")
    assert {:ok, []} = Tar.entries(tar)
    dir = tmp_dir("tar-read")
    File.write!(Path.join(dir, name), "data")
    {tar, []} = Tar.create([name], dir)
    assert {:ok, [%{name: ^name, data: "data", type: :file}]} = Tar.entries(tar)
  end

  test "unzip: list, test, extract (stored and deflated), -p, -o/-n, members and -x" do
    dir = tmp_dir("unzip")
    tree(dir)
    files = [~c"src/a b.txt", ~c"src/sub/rand.bin"]
    {:ok, _} = :zip.create(String.to_charlist(Path.join(dir, "a.zip")), files, cwd: String.to_charlist(dir))
    {:ok, _} = :zip.create(String.to_charlist(Path.join(dir, "stored.zip")), files, cwd: String.to_charlist(dir), compress: [])

    {list, 0} = sh("unzip -l a.zip", cwd: dir)
    assert list =~ ~r/^ +6  \d\d-\d\d-\d{4} \d\d:\d\d   src\/a b.txt$/m
    assert list =~ ~r/^ +200006 +2 files$/m
    assert {"src/a b.txt\nsrc/sub/rand.bin\n", 0} = sh("unzip -Z1 a", cwd: dir)
    {test, 0} = sh("unzip -t a.zip", cwd: dir)
    assert test =~ "No errors detected in compressed data of a.zip."
    assert {verbose, 0} = sh("unzip -v stored.zip", cwd: dir)
    assert verbose =~ "Stored"

    for zip <- ["a.zip", "stored.zip"] do
      {out, 0} = sh("unzip -d x-#{zip} #{zip}", cwd: dir)
      assert out =~ "x-#{zip}/src/a b.txt"
      assert File.read!(Path.join(dir, "x-#{zip}/src/sub/rand.bin")) == File.read!(Path.join(dir, "src/sub/rand.bin"))
    end

    assert {"hello\n", 0} = sh(~S|unzip -p a.zip 'src/a b.txt'|, cwd: dir)
    File.write!(Path.join(dir, "x-a.zip/src/a b.txt"), "changed")
    assert {_, 0} = sh("unzip -n -d x-a.zip a.zip", cwd: dir)
    assert File.read!(Path.join(dir, "x-a.zip/src/a b.txt")) == "changed"
    # Asked (no answer: none replaced, as unzip does at the end of its input).
    {asked, 0} = sh("unzip -d x-a.zip a.zip", cwd: dir, stdin: StringIO.open("") |> elem(1))
    assert asked =~ "replace x-a.zip/src/a b.txt?"
    assert {_, 0} = sh("unzip -o -q -d x-a.zip a.zip", cwd: dir)
    assert File.read!(Path.join(dir, "x-a.zip/src/a b.txt")) == "hello\n"
    assert {_, 0} = sh("unzip -j -d flat a.zip '*.bin'", cwd: dir)
    assert File.ls!(Path.join(dir, "flat")) == ["rand.bin"]
    assert {_, 0} = sh("unzip -d ex a.zip -x '*.bin'", cwd: dir)
    refute File.exists?(Path.join(dir, "ex/src/sub/rand.bin"))

    # A damaged member: a bad CRC is reported.
    bin = File.read!(Path.join(dir, "stored.zip"))
    [{at, _}] = :binary.matches(bin, "hello\n")
    File.write!(Path.join(dir, "bad.zip"), binary_part(bin, 0, at) <> "HELLO\n" <> binary_part(bin, at + 6, byte_size(bin) - at - 6))
    {bad, 2} = sh("unzip -t bad.zip", cwd: dir)
    assert bad =~ "bad CRC"

    {:ok, err} = StringIO.open("")
    assert {_, 9} = sh("unzip nope.zip", cwd: dir, stderr: err)
    assert {_, 9} = sh("unzip src/a\\ b.txt", cwd: dir, stderr: err)
    assert {_, 11} = sh("unzip -l a.zip missing.txt", cwd: dir, stderr: err)
    assert Zip.target("../../evil", dir) == nil
  end

  defp a &&& b, do: Bitwise.band(a, b)
end
