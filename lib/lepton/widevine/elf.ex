defmodule Lepton.Widevine.Elf do
  @moduledoc """
  Makes Google's ARM64 Widevine loadable by musl's dynamic linker.

  The plugin is built for glibc, and a few of its relocations are
  `R_AARCH64_IRELATIVE` (GNU indirect functions): the loader calls a
  "resolver" in the library that picks an implementation for the CPU,
  and stores its address. glibc does that; musl doesn't, and refuses the
  library ("unsupported relocation type 1032"), so Firefox's plugin
  process failed and DRM video and music didn't play.

  In Widevine 4.10 there are four, and each resolver picks between a
  version for memory tagging (MTE, which it uses only when the loader
  says the CPU has it) and a plain one. `fix_irelative/1` runs each
  resolver as a loader that tells it nothing about the CPU would
  (`x0 = 0`), which gives the plain version: correct on every CPU,
  and what glibc would choose on Apple's chips, which have no MTE. It
  then rewrites the relocation as an ordinary `R_AARCH64_RELATIVE` to
  that address. The resolvers are interpreted, not run: a few AArch64
  instructions (`adrp`, `adr`, `add`, `mov`, `tbz`/`tbnz`, `ret`,
  hints such as `bti`), and anything else is an error, so a future
  Widevine that needs more fails to install rather than loading wrongly.
  """

  import Bitwise

  @r_relative 1027
  @r_irelative 1032
  @dt_rela 7
  @dt_relasz 8
  @dt_jmprel 23
  @dt_pltrelsz 2

  @doc """
  Rewrite the `IRELATIVE` relocations of the ELF `bin`:
  `{:ok, patched, count}` or `{:error, reason}`.
  """
  def fix_irelative(<<0x7F, "ELF", 2, 1, _::binary>> = bin) do
    <<_::binary-32, phoff::little-64, _::binary-14, phentsize::little-16, phnum::little-16, _::binary>> = bin
    phdrs = for i <- 0..(phnum - 1)//1, do: phdr(bin, phoff + i * phentsize)
    loads = for %{type: 1} = p <- phdrs, do: p

    with %{} = dyn <- Enum.find(phdrs, &(&1.type == 2)) || {:error, "no dynamic section"},
         tags = dynamic(bin, dyn.offset, dyn.filesz),
         {:ok, relocs} <- relocs(bin, loads, tags) do
      Enum.reduce_while(relocs, {:ok, bin, 0}, fn {at, info, addend}, {:ok, acc, n} ->
        if (info &&& 0xFFFFFFFF) == @r_irelative do
          case resolve(bin, loads, addend) do
            {:ok, target} ->
              patched = put(acc, at + 8, <<@r_relative::little-64, target::little-signed-64>>)
              {:cont, {:ok, patched, n + 1}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        else
          {:cont, {:ok, acc, n}}
        end
      end)
    end
  end

  def fix_irelative(_), do: {:error, "not a 64-bit little-endian ELF file"}

  defp phdr(bin, at) do
    <<_::binary-size(^at), type::little-32, _flags::little-32, offset::little-64, vaddr::little-64, _paddr::little-64, filesz::little-64, _::binary>> = bin
    %{type: type, offset: offset, vaddr: vaddr, filesz: filesz}
  end

  defp dynamic(bin, offset, size) do
    for i <- 0..(div(size, 16) - 1)//1, reduce: %{} do
      acc ->
        at = offset + i * 16
        <<_::binary-size(^at), tag::little-signed-64, val::little-64, _::binary>> = bin
        Map.put_new(acc, tag, val)
    end
  end

  # Every RELA entry ({file offset, r_info, r_addend}) of .rela.dyn and .rela.plt.
  defp relocs(bin, loads, tags) do
    tables = [{tags[@dt_rela], tags[@dt_relasz]}, {tags[@dt_jmprel], tags[@dt_pltrelsz]}]

    Enum.reduce_while(tables, {:ok, []}, fn
      {nil, _}, acc ->
        {:cont, acc}

      {vaddr, size}, {:ok, acc} ->
        case offset(loads, vaddr) do
          nil ->
            {:halt, {:error, "relocations outside the file"}}

          start ->
            entries =
              for i <- 0..(div(size || 0, 24) - 1)//1 do
                at = start + i * 24
                <<_::binary-size(^at), _r_offset::little-64, info::little-64, addend::little-signed-64, _::binary>> = bin
                {at, info, addend}
              end

            {:cont, {:ok, acc ++ entries}}
        end
    end)
  end

  defp offset(loads, vaddr) do
    Enum.find_value(loads, fn p -> if vaddr >= p.vaddr and vaddr < p.vaddr + p.filesz, do: vaddr - p.vaddr + p.offset end)
  end

  defp put(bin, at, data) do
    n = byte_size(data)
    <<head::binary-size(^at), _::binary-size(^n), tail::binary>> = bin
    head <> data <> tail
  end

  @doc """
  What the resolver at `pc` returns when the loader gives it no CPU
  features (`x0 = 0`, `x1 = 0`): `{:ok, address}` or `{:error, reason}`.
  """
  def resolve(bin, loads, pc), do: run(bin, loads, pc, %{0 => 0, 1 => 0}, 0)

  defp run(_bin, _loads, pc, _regs, 64), do: {:error, "the resolver at 0x#{Integer.to_string(pc, 16)} doesn't return"}

  defp run(bin, loads, pc, regs, steps) do
    with at when at != nil <- offset(loads, pc),
         <<_::binary-size(^at), w::little-32, _::binary>> <- bin do
      case step(w, pc, regs) do
        {:next, regs} -> run(bin, loads, pc + 4, regs, steps + 1)
        {:jump, to, regs} -> run(bin, loads, to, regs, steps + 1)
        {:ret, value} -> {:ok, value}
        :unknown -> {:error, "an instruction Lepton can't interpret (0x#{Integer.to_string(w, 16)}) in the resolver at 0x#{Integer.to_string(pc, 16)}"}
      end
    else
      _ -> {:error, "a resolver outside the file (0x#{Integer.to_string(pc, 16)})"}
    end
  end

  defp reg(regs, 31), do: Map.get(regs, :zr, 0)
  defp reg(regs, n), do: Map.get(regs, n, 0)
  defp set(regs, 31, _v), do: regs
  defp set(regs, n, v), do: Map.put(regs, n, v &&& 0xFFFFFFFFFFFFFFFF)

  defp sext(v, bits), do: if((v &&& 1 <<< (bits - 1)) != 0, do: v - (1 <<< bits), else: v)

  @doc false
  # One instruction: {:next, regs}, {:jump, pc, regs}, {:ret, x0} or :unknown.
  def step(w, pc, regs) do
    cond do
      # Hints: nop, bti, paciasp, autiasp, ...
      (w &&& 0xFFFFF01F) == 0xD503201F ->
        {:next, regs}

      # ret / retaa / retab
      w in [0xD65F03C0, 0xD65F0BFF, 0xD65F0FFF] ->
        {:ret, reg(regs, 0)}

      # mov xd, xm (orr xd, xzr, xm)
      (w &&& 0xFFE0FFE0) == 0xAA0003E0 ->
        {:next, set(regs, w &&& 31, reg(regs, w >>> 16 &&& 31))}

      # adrp xd, label
      (w &&& 0x9F000000) == 0x90000000 ->
        imm = sext((w >>> 5 &&& 0x7FFFF) <<< 2 ||| (w >>> 29 &&& 3), 21) <<< 12
        {:next, set(regs, w &&& 31, (pc &&& bnot(0xFFF)) + imm)}

      # adr xd, label
      (w &&& 0x9F000000) == 0x10000000 ->
        imm = sext((w >>> 5 &&& 0x7FFFF) <<< 2 ||| (w >>> 29 &&& 3), 21)
        {:next, set(regs, w &&& 31, pc + imm)}

      # add xd, xn, #imm{, lsl #12}
      (w &&& 0xFF800000) == 0x91000000 ->
        imm = (w >>> 10 &&& 0xFFF) <<< if((w &&& 1 <<< 22) != 0, do: 12, else: 0)
        {:next, set(regs, w &&& 31, reg(regs, w >>> 5 &&& 31) + imm)}

      # tbz / tbnz xt, #bit, label
      (w &&& 0x7E000000) == 0x36000000 ->
        bit = (w >>> 31) <<< 5 ||| (w >>> 19 &&& 31)
        set? = (reg(regs, w &&& 31) >>> bit &&& 1) == 1
        tbnz? = (w &&& 1 <<< 24) != 0
        if set? == tbnz?, do: {:jump, pc + sext(w >>> 5 &&& 0x3FFF, 14) * 4, regs}, else: {:next, regs}

      true ->
        :unknown
    end
  end
end
