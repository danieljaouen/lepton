defmodule Lepton.Wayland.Font do
  @moduledoc """
  The 8x16 bitmap font Photon draws text with: Terminus, regular and bold,
  read from PSF console fonts at compile time
  (`rootfs/usr/share/consolefonts`).

  `rows/4` renders a character as 16 rows of pixels in a given foreground
  and background colour (4-byte XRGB8888 pixels).
  """

  @dir Path.expand("../../../rootfs/usr/share/consolefonts", __DIR__)
  @regular Path.join(@dir, "ter-v16n.psf.gz")
  @bold Path.join(@dir, "ter-v16b.psf.gz")
  @external_resource @regular
  @external_resource @bold

  @width 8
  @height 16

  defmodule PSF do
    @moduledoc "PSF1/PSF2 console font files."

    @doc "Parse a (gzipped) PSF1 or PSF2 font: `{glyphs_tuple, %{codepoint => index}, height}`."
    def parse(data) do
      data = if match?(<<0x1F, 0x8B, _::binary>>, data), do: :zlib.gunzip(data), else: data

      case data do
        <<0x36, 0x04, mode, size, rest::binary>> ->
          count = if Bitwise.band(mode, 1) == 1, do: 512, else: 256
          <<glyphs::binary-size(^count * ^size), table::binary>> = rest
          map = if Bitwise.band(mode, 6) != 0, do: psf1_table(table, 0, %{}), else: identity(count)
          {split(glyphs, size), map, size}

        <<0x72, 0xB5, 0x4A, 0x86, _v::little-32, hsize::little-32, flags::little-32, count::little-32, size::little-32, h::little-32, _w::little-32, _::binary>> ->
          <<_::binary-size(^hsize), glyphs::binary-size(^count * ^size), table::binary>> = data
          map = if Bitwise.band(flags, 1) == 1, do: psf2_table(table, 0, %{}), else: identity(count)
          {split(glyphs, size), map, h}
      end
    end

    defp split(bin, size), do: for(<<g::binary-size(^size) <- bin>>, do: g) |> List.to_tuple()
    defp identity(n), do: Map.new(0..(n - 1), &{&1, &1})

    # PSF1: per glyph, UCS-2 codepoints ending in 0xFFFF (0xFFFE starts sequences, skipped).
    defp psf1_table(<<>>, _i, map), do: map
    defp psf1_table(<<0xFFFF::little-16, rest::binary>>, i, map), do: psf1_table(rest, i + 1, map)
    defp psf1_table(<<0xFFFE::little-16, rest::binary>>, i, map), do: psf1_table(skip_seq(rest), i + 1, map)
    defp psf1_table(<<cp::little-16, rest::binary>>, i, map), do: psf1_table(rest, i, Map.put_new(map, cp, i))

    defp skip_seq(<<0xFFFF::little-16, rest::binary>>), do: rest
    defp skip_seq(<<_::16, rest::binary>>), do: skip_seq(rest)
    defp skip_seq(<<>>), do: <<>>

    # PSF2: UTF-8 strings per glyph ending in 0xFF (0xFE starts sequences).
    defp psf2_table(<<>>, _i, map), do: map

    defp psf2_table(table, i, map) do
      [entry, rest] = String.split(table, <<0xFF>>, parts: 2) |> then(fn [e] -> [e, ""]; x -> x end)
      [singles | _] = String.split(entry, <<0xFE>>)
      map = singles |> String.to_charlist() |> Enum.reduce(map, &Map.put_new(&2, &1, i))
      psf2_table(rest, i + 1, map)
    end
  end

  def width, do: @width
  def height, do: @height

  {glyphs, map, 16} = PSF.parse(File.read!(@regular))
  {bold, bold_map, 16} = PSF.parse(File.read!(@bold))
  @glyphs glyphs
  @map map
  @bold_glyphs bold
  @bold_map bold_map

  @doc "The 16 bytes (one per row, MSB leftmost) of character `cp`."
  def bitmap(cp, bold? \\ false) do
    {glyphs, map} = if bold?, do: {@bold_glyphs, @bold_map}, else: {@glyphs, @map}

    case map do
      %{^cp => i} -> elem(glyphs, i)
      _ -> elem(glyphs, Map.get(map, 0xFFFD) || Map.get(map, ??, 0))
    end
  end

  def has?(cp), do: Map.has_key?(@map, cp)

  @doc "Character `cp` as 16 rows of 8 pixels."
  def rows(cp, fg, bg, bold? \\ false) do
    for <<byte <- bitmap(cp, bold?)>>, do: row(byte, fg, bg)
  end

  @doc "One row of a glyph: 8 pixels from the bits of `byte`."
  def row(byte, fg, bg) do
    for <<bit::1 <- <<byte>> >>, into: <<>>, do: if(bit == 1, do: fg, else: bg)
  end

  @doc """
  Draw `text` as 16 rows `width` pixels wide (clipped or padded with `bg`).
  """
  def text_rows(text, fg, bg, width) do
    cps = text |> String.to_charlist() |> Enum.take(div(width, @width))
    glyphs = Enum.map(cps, &rows(&1, fg, bg))
    pad = :binary.copy(bg, width - length(cps) * @width)

    for r <- 0..(@height - 1) do
      IO.iodata_to_binary([Enum.map(glyphs, &Enum.at(&1, r)), pad])
    end
  end
end
