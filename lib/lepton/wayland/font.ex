defmodule Lepton.Wayland.Font do
  @moduledoc """
  The 8x16 bitmap font Photon draws text with: Terminus, regular and bold,
  read from PSF console fonts at compile time
  (`rootfs/usr/share/consolefonts`), and for what Terminus lacks (Chinese,
  Japanese, Korean, Thai, Devanagari, ...) GNU Unifont's glyphs
  (`unifont.bin.gz`, made by `tools/unifont.exs`): 8 or, for wide
  characters, 16 pixels wide, 16 high. Unifont has no bold: bold is drawn
  one pixel wider.

  `rows/4` renders a character as 16 rows of pixels in a given foreground
  and background colour (4-byte XRGB8888 pixels).
  """

  import Bitwise

  @dir Path.expand("../../../rootfs/usr/share/consolefonts", __DIR__)
  @regular Path.join(@dir, "ter-v16n.psf.gz")
  @bold Path.join(@dir, "ter-v16b.psf.gz")
  @external_resource @regular
  @external_resource @bold
  @unifont_file Path.join(@dir, "unifont.bin.gz")
  @external_resource @unifont_file
  @unifont_gz File.read!(@unifont_file)

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

  @doc "The 16 bytes (one per row, MSB leftmost) of Terminus character `cp` (or its replacement)."
  def bitmap(cp, bold? \\ false) do
    {glyphs, map} = if bold?, do: {@bold_glyphs, @bold_map}, else: {@glyphs, @map}

    case map do
      %{^cp => i} -> elem(glyphs, i)
      _ -> elem(glyphs, Map.get(map, 0xFFFD) || Map.get(map, ??, 0))
    end
  end

  @doc "Is there a glyph for `cp` (Terminus's or Unifont's)?"
  def has?(cp), do: Map.has_key?(@map, cp) or Map.has_key?(unifont(), cp)

  @doc "Character `cp`'s glyph: `{width_in_pixels, rows}`, rows of 1 (8 pixels) or 2 (16) bytes."
  def glyph(cp, bold? \\ false) do
    cond do
      Map.has_key?(@map, cp) ->
        {8, bitmap(cp, bold?)}

      g = Map.get(unifont(), cp) ->
        {w, bits} = g
        {w, if(bold?, do: embolden(bits, w), else: bits)}

      true ->
        {8, bitmap(cp, bold?)}
    end
  end

  @doc "How many pixels wide character `cp` is drawn: 8, or 16 for a wide one."
  def char_width(cp), do: elem(glyph(cp), 0)

  # Bold for Unifont: each row ORed with itself one pixel to the right.
  defp embolden(bits, 8), do: for(<<b <- bits>>, into: <<>>, do: <<bor(b, b >>> 1)>>)
  defp embolden(bits, 16), do: for(<<b::16 <- bits>>, into: <<>>, do: <<bor(b, b >>> 1)::16>>)

  # Unifont's glyphs, unpacked on first use: %{codepoint => {width, rows}}.
  defp unifont do
    case :persistent_term.get({__MODULE__, :unifont}, nil) do
      nil ->
        map = unpack(:zlib.gunzip(@unifont_gz), %{})
        :persistent_term.put({__MODULE__, :unifont}, map)
        map

      map ->
        map
    end
  end

  defp unpack(<<>>, acc), do: acc
  defp unpack(<<cp::24, 8, rows::binary-size(16), rest::binary>>, acc), do: unpack(rest, Map.put(acc, cp, {8, rows}))
  defp unpack(<<cp::24, 16, rows::binary-size(32), rest::binary>>, acc), do: unpack(rest, Map.put(acc, cp, {16, rows}))

  @doc """
  A character with combining marks (Thai vowels and tones, accents) as
  one glyph: each mark's bitmap (Unifont draws them in place, to overlay
  the character before) ORed onto the character's.
  """
  def cluster([cp], bold?), do: glyph(cp, bold?)

  def cluster([cp | marks], bold?) do
    Enum.reduce(marks, glyph(cp, bold?), fn m, {w, bits} = acc ->
      case glyph(m, bold?) do
        {^w, mbits} when m != cp -> {w, or_bits(bits, mbits)}
        _ -> acc
      end
    end)
  end

  defp or_bits(a, b), do: for({x, y} <- Enum.zip(:binary.bin_to_list(a), :binary.bin_to_list(b)), into: <<>>, do: <<bor(x, y)>>)

  @doc "A grapheme (a character and its combining marks) as 16 rows of pixels."
  def grapheme_rows(g, fg, bg, bold? \\ false) do
    case String.to_charlist(g) do
      [cp] -> rows(cp, fg, bg, bold?)
      [_ | _] = cps -> bits_rows(cluster(cps, bold?), fg, bg)
      [] -> rows(?\s, fg, bg, bold?)
    end
  end

  defp bits_rows({8, bits}, fg, bg), do: for(<<byte <- bits>>, do: row(byte, fg, bg))
  defp bits_rows({16, bits}, fg, bg), do: for(<<a, b <- bits>>, do: row(a, fg, bg) <> row(b, fg, bg))

  @doc "Character `cp` as 16 rows of 8 (or, wide, 16) pixels."
  def rows(cp, fg, bg, bold? \\ false) do
    case glyph(cp, bold?) do
      {8, bits} -> for <<byte <- bits>>, do: row(byte, fg, bg)
      {16, bits} -> for <<a, b <- bits>>, do: row(a, fg, bg) <> row(b, fg, bg)
    end
  end

  @doc "One row of a glyph: 8 pixels from the bits of `byte`."
  def row(byte, fg, bg) do
    for <<bit::1 <- <<byte>> >>, into: <<>>, do: if(bit == 1, do: fg, else: bg)
  end

  @doc """
  Draw `text` as 16 rows `width` pixels wide (clipped or padded with `bg`).
  """
  def text_rows(text, fg, bg, width) do
    cps = fit(text, width)
    glyphs = Enum.map(cps, &rows(&1, fg, bg))
    pad = :binary.copy(bg, width - Enum.sum(Enum.map(cps, &char_width/1)))

    for r <- 0..(@height - 1) do
      IO.iodata_to_binary([Enum.map(glyphs, &Enum.at(&1, r)), pad])
    end
  end

  @doc "The characters of `text` that fit in `width` pixels (combining marks left out)."
  def fit(text, width) do
    text
    |> String.to_charlist()
    |> Enum.reject(&(&1 in 0x0300..0x036F or &1 in 0x200B..0x200F))
    |> Enum.reduce_while({[], 0}, fn cp, {acc, used} ->
      w = char_width(cp)
      if used + w > width, do: {:halt, {acc, used}}, else: {:cont, {[cp | acc], used + w}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @doc "How many pixels wide `text` is drawn."
  def text_width(text), do: text |> fit(1_000_000) |> Enum.map(&char_width/1) |> Enum.sum()
end
