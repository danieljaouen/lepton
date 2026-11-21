# Generate rootfs/usr/share/consolefonts/unifont.bin.gz: GNU Unifont's
# glyphs for what Terminus lacks (Chinese, Japanese, Korean, Thai, ...),
# for Lepton.Wayland.Font.
#
#   elixir tools/unifont.exs UNIFONT_PCF_GZ
#
# UNIFONT_PCF_GZ is usr/share/fonts/X11/misc/unifont.pcf.gz from Alpine's
# font-unifont. Unifont: GPL-2.0-or-later with the font embedding
# exception, or SIL OFL 1.1 (https://unifoundry.com/unifont/).
#
# The output, gzipped: records <<codepoint::24, width::8, rows>>, sorted,
# width 8 (16 rows of one byte) or 16 (16 rows of two bytes).

import Bitwise

[pcf_gz, terminus] =
  case System.argv() do
    [p] -> [p, "rootfs/usr/share/consolefonts/ter-v16n.psf.gz"]
    [p, t] -> [p, t]
  end

pcf = :zlib.gunzip(File.read!(pcf_gz))
<<1, "fcp", count::little-32, rest::binary>> = pcf

tables =
  for <<type::little-32, format::little-32, size::little-32, offset::little-32 <- binary_part(rest, 0, count * 16)>>,
      into: %{},
      # (the last table can run past the end: only the ones read here matter)
      do: {type, {format, binary_part(pcf, offset, min(size, byte_size(pcf) - offset))}}

int = fn format, bits ->
  if (format &&& 4) != 0, do: fn <<v::big-unsigned-size(^bits), r::binary>> -> {v, r} end, else: fn <<v::little-unsigned-size(^bits), r::binary>> -> {v, r} end
end

# Metrics: left/right bearing and width per glyph.
{mformat, mdata} = tables[4]
<<_f::little-32, mbody::binary>> = mdata

metrics =
  if (mformat &&& 0x100) != 0 do
    {n, rest} = int.(mformat, 16).(mbody)
    for <<l, r, w, a, d <- binary_part(rest, 0, n * 5)>>, do: {l - 0x80, r - 0x80, w - 0x80, a - 0x80, d - 0x80}
  else
    {n, rest} = int.(mformat, 32).(mbody)
    for <<chunk::binary-size(12) <- binary_part(rest, 0, n * 12)>> do
      {vals, _} = Enum.map_reduce(1..6, chunk, fn _, r -> int.(mformat, 16).(r) end)
      [l, r, w, a, d, _] = vals
      {l, r, w, a, d}
    end
  end

# Bitmaps.
{bformat, bdata} = tables[8]
<<_f::little-32, bbody::binary>> = bdata
{nglyphs, rest} = int.(bformat, 32).(bbody)
{offsets, rest} = Enum.map_reduce(1..nglyphs, rest, fn _, r -> int.(bformat, 32).(r) end)
{sizes, rest} = Enum.map_reduce(1..4, rest, fn _, r -> int.(bformat, 32).(r) end)
data = binary_part(rest, 0, Enum.at(sizes, bformat &&& 3))
pad = 1 <<< (bformat &&& 3)
msbit? = (bformat &&& 8) != 0

# Encodings: code point => glyph index.
{eformat, edata} = tables[32]
<<_f::little-32, ebody::binary>> = edata
{[min2, max2, min1, max1, _default], rest} = Enum.map_reduce(1..5, ebody, fn _, r -> int.(eformat, 16).(r) end)
cols = max2 - min2 + 1

{indices, _} = Enum.map_reduce(1..(cols * (max1 - min1 + 1)), rest, fn _, r -> int.(eformat, 16).(r) end)

# What Terminus has stays Terminus's (its PSF parser is Lepton's own).
{_, terminus_map, _} =
  (Code.ensure_loaded?(Lepton.Wayland.Font.PSF) || Code.require_file("lib/lepton/wayland/font.ex"))
  |> then(fn _ -> Lepton.Wayland.Font.PSF.parse(File.read!(terminus)) end)

terminus_has = terminus_map |> Map.keys() |> MapSet.new()

reverse_bits = fn byte -> for(<<b::1 <- <<byte>> >>, do: b) |> Enum.reverse() |> then(&for(b <- &1, into: <<>>, do: <<b::1>>)) |> then(fn <<v>> -> v end) end

records =
  for {idx, i} <- Enum.with_index(indices), idx != -1 and idx != 0xFFFF, cp = (div(i, cols) + min1) * 256 + rem(i, cols) + min2,
      cp >= 0x20 and not MapSet.member?(terminus_has, cp) do
    {l, r, _w, a, d} = Enum.at(metrics, idx)
    w = r - l
    h = a + d
    bytes_per_row = div(w + 7, 8)
    stride = div(bytes_per_row + pad - 1, pad) * pad
    glyph = binary_part(data, Enum.at(offsets, idx), stride * h)

    rows =
      for row <- 0..(h - 1), into: <<>> do
        bin = binary_part(glyph, row * stride, bytes_per_row)
        if msbit?, do: bin, else: for(<<b <- bin>>, into: <<>>, do: <<reverse_bits.(b)>>)
      end

    # Unifont's cells are 16 pixels high: anything else is padded (or cut) to 16.
    width = if w > 8, do: 16, else: 8
    bpr = div(width, 8)
    rows = if byte_size(rows) >= 16 * bpr, do: binary_part(rows, 0, 16 * bpr), else: rows <> :binary.copy(<<0>>, 16 * bpr - byte_size(rows))
    {cp, width, rows}
  end
  |> Enum.sort()

out = for {cp, w, rows} <- records, into: <<>>, do: <<cp::24, w, rows::binary>>
path = "rootfs/usr/share/consolefonts/unifont.bin.gz"
File.write!(path, :zlib.gzip(out))
IO.puts("wrote #{path}: #{length(records)} glyphs, #{byte_size(:zlib.gzip(out))} bytes")
