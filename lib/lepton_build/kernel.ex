defmodule LeptonBuild.Kernel do
  @moduledoc """
  Unwraps an arm64 `EFI_ZBOOT` kernel (a small PE decompressor carrying a
  compressed `Image`) into the raw `Image`, which every bootloader can load.
  """

  def unwrap(<<"MZ", _::binary-size(2), "zimg", offset::little-32, size::little-32, _::binary-size(8),
               type::binary-size(8), _::binary>> = bin) do
    payload = binary_part(bin, offset, size)

    case String.trim_trailing(type, <<0>>) do
      "gzip" -> :zlib.gunzip(payload)
      "zstd" -> :zstd.decompress(payload) |> IO.iodata_to_binary()
      other -> raise "unsupported zboot compression #{inspect(other)}"
    end
  end

  def unwrap(<<0x1F, 0x8B, _::binary>> = gz), do: :zlib.gunzip(gz)
  def unwrap(image), do: image
end
