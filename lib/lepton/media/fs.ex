defmodule Lepton.Media.FS do
  @moduledoc """
  What filesystem a partition holds, and its label, from its first
  sectors (what `blkid` does): FAT12/16/32, exFAT, NTFS, ext2/3/4 and
  ISO 9660.

  `detect/1` takes a function `read.(offset, length)` returning the
  device's bytes there (shorter at the end of the device), and returns
  `{type, label}` with `type` the kernel's filesystem name (`"vfat"`,
  `"exfat"`, `"ntfs3"`, `"ext4"`, `"iso9660"`), or `nil` when there's
  nothing it knows (an empty card or partition).

  It also knows what Lepton doesn't mount but must not take for empty
  (the installer looks for empty partitions): `"apfs"` and `"hfsplus"`
  (macOS), `"bitlocker"`, `"crypto_LUKS"`, `"LVM2_member"`, `"btrfs"`,
  `"xfs"` and `"swap"`. `mountable?/1` tells them apart.
  """

  @mountable ~w(vfat exfat ntfs3 ext4 iso9660)

  @doc "Whether Lepton mounts filesystems of `type`."
  def mountable?(type), do: type in @mountable

  import Bitwise

  def detect(read) do
    boot = read.(0, 512)
    super = read.(1024, 1024)
    iso = read.(32768, 2048)

    cond do
      # (filesystems Lepton doesn't mount, first: an APFS container's boot
      # sector can look like nothing else, but must never look empty)
      match?(<<_::binary-32, "NXSB", _::binary>>, boot) -> {"apfs", nil}
      match?(<<c1, c2, _::binary>> when <<c1, c2>> in ["H+", "HX"], super) -> {"hfsplus", nil}
      match?(<<_::binary-3, "-FVE-FS-", _::binary>>, boot) -> {"bitlocker", nil}
      match?(<<"LUKS", 0xBA, 0xBE, _::binary>>, boot) -> {"crypto_LUKS", nil}
      match?(<<"XFSB", _::binary>>, boot) -> {"xfs", nil}
      binary_part(read.(512, 8) <> <<0::64>>, 0, 8) == "LABELONE" -> {"LVM2_member", nil}
      binary_part(read.(65_600, 8) <> <<0::64>>, 0, 8) == "_BHRfS_M" -> {"btrfs", nil}
      Enum.any?([4086, 16_374, 65_526], &(binary_part(read.(&1, 10) <> <<0::80>>, 0, 10) in ["SWAPSPACE2", "SWAP-SPACE"])) -> {"swap", nil}
      match?(<<_::binary-3, "EXFAT   ", _::binary>>, boot) -> {"exfat", exfat_label(boot, read)}
      match?(<<_::binary-3, "NTFS    ", _::binary>>, boot) -> {"ntfs3", nil}
      ext?(super) -> {"ext4", text(binary_part(super, 120, 16))}
      fat?(boot) -> {"vfat", fat_label(boot)}
      match?(<<1, "CD001", _::binary>>, iso) -> {"iso9660", text(binary_part(iso, 40, 32))}
      true -> {nil, nil}
    end
  end

  @doc "Detect the filesystem of a device or image file at `path`."
  def probe(path) do
    case :file.open(String.to_charlist(path), [:raw, :binary, :read]) do
      {:ok, f} ->
        try do
          detect(fn off, len ->
            case :file.pread(f, off, len) do
              {:ok, data} -> data
              _ -> ""
            end
          end)
        after
          :file.close(f)
        end

      _ ->
        {nil, nil}
    end
  end

  # ext2/3/4: the superblock's magic, 0xEF53, 56 bytes in.
  defp ext?(<<_::binary-56, 0x53, 0xEF, _::binary>>), do: true
  defp ext?(_), do: false

  # A FAT boot sector: the 0x55AA signature, a jump, a sensible sector
  # size and cluster size, and the FAT type text where FAT12/16 or FAT32
  # keep it.
  defp fat?(<<jmp, _::binary-10, bps::little-16, spc, _::binary>> = boot) when byte_size(boot) == 512 do
    binary_part(boot, 510, 2) == <<0x55, 0xAA>> and jmp in [0xEB, 0xE9] and bps in [512, 1024, 2048, 4096] and
      spc in [1, 2, 4, 8, 16, 32, 64, 128] and
      (binary_part(boot, 54, 3) == "FAT" or binary_part(boot, 82, 5) == "FAT32")
  end

  defp fat?(_), do: false

  defp fat_label(boot) do
    label = if binary_part(boot, 82, 5) == "FAT32", do: binary_part(boot, 71, 11), else: binary_part(boot, 43, 11)
    if String.trim(label) == "NO NAME", do: nil, else: text(label)
  end

  # exFAT keeps its label in the root directory: an entry of type 0x83
  # with up to 11 UTF-16 characters.
  defp exfat_label(<<_::binary-88, heap::little-32, root::little-32, _::binary-12, bps_shift, spc_shift, _::binary>>, read) do
    bps = 1 <<< bps_shift
    cluster = bps <<< spc_shift
    dir = read.(heap * bps + (root - 2) * cluster, min(cluster, 4096))

    Enum.find_value(for(<<entry::binary-32 <- dir>>, do: entry), fn
      <<0x83, n, name::binary-22, _::binary>> when n <= 11 -> name |> binary_part(0, n * 2) |> :unicode.characters_to_binary({:utf16, :little}) |> text()
      _ -> nil
    end)
  end

  defp exfat_label(_, _), do: nil

  defp text(bin) when is_binary(bin) do
    case bin |> String.split(<<0>>) |> hd() |> String.trim() do
      "" -> nil
      s -> if String.valid?(s), do: s, else: nil
    end
  end

  defp text(_), do: nil
end
