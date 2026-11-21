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
    assert {:ok, %{browser: ["file://" <> spaced]}} = Desktop.open_plan(["my dir"], (File.mkdir_p!(Path.join(dir, "my dir")); ctx))
    assert spaced =~ "my%20dir/"

    # The command: usage, errors, and le without a terminal or a desktop.
    assert {_, 2} = sh("open", cwd: dir)
    assert {_, 1} = sh("xdg-open nope.txt", cwd: dir)
    unless Process.whereis(Lepton.Photon), do: assert({_, 1} = sh("open notes.txt", cwd: dir))
  end
end
