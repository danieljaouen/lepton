defmodule LeptonBuild.ELF do
  @moduledoc """
  Minimal ELF64 little-endian reader: enough to find an object's
  `DT_NEEDED` shared libraries so the image ships exactly the closure of
  libraries ERTS needs.
  """

  @dt_needed 1
  @dt_strtab 5
  @pt_load 1
  @pt_dynamic 2

  def elf?(<<0x7F, "ELF", _::binary>>), do: true
  def elf?(_), do: false

  @doc "Returns the list of DT_NEEDED sonames, or [] for static/non-ELF files."
  def needed(bin) when is_binary(bin) do
    if elf?(bin), do: do_needed(bin), else: []
  end

  defp do_needed(bin) do
    <<_ident::binary-size(16), _type::little-16, _machine::little-16, _version::little-32, _entry::little-64,
      phoff::little-64, _shoff::little-64, _flags::little-32, _ehsize::little-16, phentsize::little-16,
      phnum::little-16, _::binary>> = bin

    phdrs =
      for i <- 0..(phnum - 1)//1 do
        <<type::little-32, _flags::little-32, offset::little-64, vaddr::little-64, _paddr::little-64,
          filesz::little-64, _memsz::little-64, _align::little-64>> = binary_part(bin, phoff + i * phentsize, 56)

        %{type: type, offset: offset, vaddr: vaddr, filesz: filesz}
      end

    case Enum.find(phdrs, &(&1.type == @pt_dynamic)) do
      nil ->
        []

      dyn ->
        entries = for <<tag::little-64, val::little-64 <- binary_part(bin, dyn.offset, dyn.filesz)>>, do: {tag, val}
        strtab_vaddr = entries |> Enum.find_value(fn {t, v} -> t == @dt_strtab && v end)
        strtab_off = vaddr_to_offset(phdrs, strtab_vaddr)

        for {@dt_needed, off} <- entries do
          read_cstring(bin, strtab_off + off)
        end
    end
  end

  defp vaddr_to_offset(phdrs, vaddr) do
    seg = Enum.find(phdrs, &(&1.type == @pt_load and vaddr >= &1.vaddr and vaddr < &1.vaddr + &1.filesz))
    vaddr - seg.vaddr + seg.offset
  end

  defp read_cstring(bin, off) do
    rest = binary_part(bin, off, byte_size(bin) - off)
    [s | _] = :binary.split(rest, <<0>>)
    s
  end
end
