defmodule Lepton.ImageMagickTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.ImageMagick

  test "the commands: magick and its tools, each a command; without the app, how to install it" do
    for t <- ["magick" | ImageMagick.tools()], do: assert({:ok, _} = Lepton.Commands.builtin_lookup(t))

    unless ImageMagick.installed?() do
      {:ok, err} = StringIO.open("")
      assert {_, 1} = sh("identify x.png", cwd: tmp_dir("im"), stderr: err)
      {:ok, {_, text}} = StringIO.close(err)
      assert text =~ "sudo app install imagemagick"
    end
  end

  test "with ImageMagick: make, crop, resize, convert, identify, mogrify; text; errors on stderr; binary to stdout" do
    if ImageMagick.installed?() do
      dir = tmp_dir("im-run")
      assert {"", 0} = sh("magick -size 300x200 gradient:red-blue photo.png", cwd: dir)
      assert {"", 0} = sh("magick photo.png -crop 100x80+50+40 +repage cropped.jpg", cwd: dir)
      assert {"cropped.jpg 100x80 JPEG\n", 0} = sh(~S|identify -format '%f %wx%h %m\n' cropped.jpg|, cwd: dir)
      assert {"", 0} = sh("convert photo.png -resize 50% -rotate 90 small.webp", cwd: dir)
      assert {"100x150\n", 0} = sh(~S|magick identify -format '%wx%h\n' small.webp|, cwd: dir)
      # mogrify: in place, here a new format beside it
      assert {"", 0} = sh("mogrify -format tiff -resize 30x20! cropped.jpg", cwd: dir)
      assert {"30x20 TIFF\n", 0} = sh(~S|identify -format '%wx%h %m\n' cropped.tiff|, cwd: dir)
      # Text, in DejaVu
      assert {"", 0} = sh("magick -size 200x50 xc:white -fill black -pointsize 20 -annotate +10+30 Lepton text.png", cwd: dir)
      {colors, 0} = sh(~S|identify -format '%k\n' text.png|, cwd: dir)
      assert String.to_integer(String.trim(colors)) > 2
      # SVG in (librsvg); PDF out and back in (Ghostscript).
      File.write!(Path.join(dir, "logo.svg"), ~s(<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80"><rect width="120" height="80" fill="#36c"/><circle cx="60" cy="40" r="30" fill="yellow"/></svg>))
      assert {"", 0} = sh("magick logo.svg logo.png", cwd: dir)
      assert {"120x80 srgb(255,255,0)\n", 0} = sh(~S|identify -format '%wx%h %[pixel:p{60,40}]\n' logo.png|, cwd: dir)
      assert {"", 0} = sh("magick logo.png logo.pdf", cwd: dir)
      assert "%PDF" <> _ = File.read!(Path.join(dir, "logo.pdf"))
      assert {"", 0} = sh("magick -density 72 logo.pdf page.png", cwd: dir)
      assert {"PNG\n", 0} = sh(~S|identify -format '%m\n' page.png|, cwd: dir)
      # An image on standard output, unmixed with messages.
      {png, 0} = sh("magick photo.png -resize 10x10 png:-", cwd: dir)
      assert <<0x89, "PNG", _::binary>> = png
      {:ok, err} = StringIO.open("")
      assert {"", 1} = sh("magick nope.png out.png", cwd: dir, stderr: err)
      {:ok, {_, text}} = StringIO.close(err)
      assert text =~ "nope.png"
    end
  end
end
