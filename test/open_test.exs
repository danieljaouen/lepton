defmodule Lepton.OpenTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.Commands.Desktop

  test "open (xdg-open): text in le; images, PDFs, folders and web addresses in Firefox" do
    dir = tmp_dir("open")
    write = fn name, data -> File.write!(Path.join(dir, name), data) end
    write.("notes.txt", "hello\n")
    write.("README", "plain text, no extension: é\n")
    write.("empty", "")
    write.("photo.jpg", <<0xFF, 0xD8, 0xFF, 0xE0>>)
    write.("picture", <<0x89, "PNG", 13, 10, 26, 10>>)
    write.("paper.pdf", "%PDF-1.4\n")
    write.("scan", "%PDF-1.7\n")
    write.("my file.md", "# hi\n")
    write.("blob.bin", <<0, 1, 2, 3, 255>>)
    File.mkdir_p!(Path.join(dir, "sub"))
    ctx = %Lepton.Ctx{cwd: dir, env: %{"HOME" => dir}}

    {:ok, plan} = Desktop.open_plan(~w(notes.txt README empty photo.jpg picture paper.pdf scan . sub https://trylepton.app), ctx)
    assert plan.editor == Enum.map(~w(notes.txt README empty), &Path.join(dir, &1))

    assert plan.browser ==
             Enum.map(~w(photo.jpg picture paper.pdf scan), &("file://" <> Path.join(dir, &1))) ++
               ["file://#{dir}/", "file://#{dir}/sub/", "https://trylepton.app"]

    assert {:ok, %{editor: [path]}} = Desktop.open_plan(["my file.md"], ctx)
    assert path == Path.join(dir, "my file.md")
    assert {:ok, %{browser: ["file://" <> url]}} = Desktop.open_plan([Path.join(dir, "sub")], %{ctx | cwd: "/"})
    assert url == dir <> "/sub/"
    assert {:error, "nope.txt: no such file or directory"} = Desktop.open_plan(~w(notes.txt nope.txt), ctx)
    assert {:error, "blob.bin: don't know" <> _} = Desktop.open_plan(~w(blob.bin), ctx)
    # Videos and music: the media player (play, in a Media Player window on the desktop).
    for f <- ~w(clip.mpg movie.MP4 song.flac), do: write.(f, <<0, 0, 1, 0xBA>>)
    assert {:ok, %{player: media, browser: [], editor: []}} = Desktop.open_plan(~w(clip.mpg movie.MP4 song.flac), ctx)
    assert media == Enum.map(~w(clip.mpg movie.MP4 song.flac), &Path.join(dir, &1))
    # Torrents: .torrent files and magnet links go to Torrents (torrent open).
    write.("film.torrent", "d4:infoe")
    magnet = "magnet:?xt=urn:btih:" <> String.duplicate("ab", 20)
    assert {:ok, %{torrent: [t, ^magnet], browser: []}} = Desktop.open_plan(["film.torrent", magnet], ctx)
    assert t == Path.join(dir, "film.torrent")
    {:ok, err} = StringIO.open("")
    {out, _} = Lepton.TestHelpers.sh("open film.torrent", cwd: dir, home: dir, stderr: err)
    assert out =~ "Torrents: not a torrent"
    # No desktop here: it plays where it's typed (play: FFmpeg, if it's there).
    {:ok, err} = StringIO.open("")
    {_, status} = Lepton.TestHelpers.sh("open clip.mpg", cwd: dir, stderr: err)
    unless Lepton.FFmpeg.installed?(), do: assert(status == 1 and elem(StringIO.contents(err), 1) =~ "ffmpeg")
    assert {:ok, %{browser: ["file://" <> spaced]}} = Desktop.open_plan(["my dir"], (File.mkdir_p!(Path.join(dir, "my dir")); ctx))
    assert spaced =~ "my%20dir/"

    # The command: usage, errors, and le without a terminal or a desktop.
    assert {_, 2} = sh("open", cwd: dir)
    assert {_, 1} = sh("xdg-open nope.txt", cwd: dir)
    unless Process.whereis(Lepton.Photon), do: assert({_, 1} = sh("open notes.txt", cwd: dir))
  end
end
