defmodule Lepton.FD do
  @moduledoc """
  Closing file descriptors the VM didn't open.

  ERTS closes only descriptors it owns (files it opened, its sockets).
  A descriptor that arrives over a Unix socket (`SCM_RIGHTS`, as Wayland
  clients send their shared memory) has no owner, and nothing in OTP
  closes it. So this module carries the smallest possible NIF: a shared
  object, written here byte by byte (no compiler), whose one function
  makes the `close` system call.

  The library is about 600 bytes: an ELF header, three program headers,
  a one-symbol dynamic table and two functions of aarch64 code.
  `nif_init` fills in the `ErlNifEntry` (its pointers are computed with
  PC-relative `adr`, so the object needs no relocations) and
  `close(Fd)` shifts the small-integer term to a number and calls
  `svc #0` with `x8 = 57`. It is written to `/run/lepton` and loaded on
  first use, on aarch64 Linux only; elsewhere `close/1` returns
  `{:error, :unsupported}`.
  """

  import Bitwise

  @on_load :init

  @doc false
  def init do
    if supported?() do
      dir = "/run/lepton"
      path = Path.join(dir, "lepton_fd")

      with :ok <- File.mkdir_p(dir), :ok <- File.write(path <> ".so", library()) do
        _ = :erlang.load_nif(String.to_charlist(path), 0)
      end
    end

    # Loading the module never fails because of the NIF: close/1 says so instead.
    :ok
  end

  @doc "Close descriptor `fd` of this process."
  def close(fd) when is_integer(fd) and fd > 2 do
    nif_close(fd) |> result()
  catch
    :error, :unsupported -> {:error, :unsupported}
  end

  def close(_fd), do: {:error, :einval}

  defp result(n) when is_integer(n) and n < 0, do: {:error, errno(-n)}
  defp result(n) when is_integer(n), do: :ok
  defp result(other), do: other

  @doc false
  def nif_close(_fd), do: :erlang.nif_error(:unsupported)

  defp errno(9), do: :ebadf
  defp errno(4), do: :eintr
  defp errno(5), do: :eio
  defp errno(n), do: n

  def supported? do
    :os.type() == {:unix, :linux} and :erlang.system_info(:system_architecture) |> to_string() |> String.starts_with?("aarch64")
  end

  # -- the shared object ------------------------------------------------------------------------

  @module "Elixir.Lepton.FD"

  @doc "The NIF library's bytes (an ELF64 aarch64 shared object)."
  def library do
    # Layout (one RWX load segment at address 0):
    #   ELF header, program headers, .dynsym, .dynstr, .hash, .dynamic,
    #   strings, ErlNifEntry, ErlNifFunc, code
    ehdr = 64
    phnum = 3
    dynsym = ehdr + phnum * 56
    dynstr = dynsym + 2 * 24
    dynstr_bytes = <<0, "nif_init", 0>>
    hash = align(dynstr + byte_size(dynstr_bytes), 8)
    dynamic = align(hash + 5 * 4, 8)
    dyn_count = 6
    strings = dynamic + dyn_count * 16

    strs = [module: @module, variant: "beam.vanilla", min_erts: "erts-14.0", name: "nif_close"]

    {str_off, strings_end} =
      Enum.map_reduce(strs, strings, fn {k, s}, off -> {{k, off}, off + byte_size(s) + 1} end)

    str_off = Map.new(str_off)
    entry = align(strings_end, 8)
    funcs = entry + 96
    code = funcs + 32

    # nif_close(env, argc, argv): close(argv[0] >> 4). Success returns
    # argv[0]; failure returns -errno as a small integer.
    close_fn = [
      ldr(9, 2, 0),
      # asr x0, x9, #4 (small integer term -> number)
      0x9344FD20,
      # mov x8, #57 (close)
      0xD2800728,
      # svc #0
      0xD4000001,
      # cbnz x0, +12
      0xB5000060,
      ldr(0, 2, 0),
      ret(),
      # lsl x0, x0, #4 ; orr x0, x0, #0xf (number -> small integer term)
      0xD37CEC00,
      0xB2400C00,
      ret()
    ]

    # nif_init(): fill in the entry's and the function's pointers, return the entry.
    init_len = 15
    close_at = code + init_len * 4

    init = [
      adr(0, entry, code + 0),
      adr(1, str_off.module, code + 4),
      str(1, 0, 8),
      adr(1, funcs, code + 12),
      str(1, 0, 24),
      adr(1, str_off.variant, code + 20),
      str(1, 0, 64),
      adr(1, str_off.min_erts, code + 28),
      str(1, 0, 88),
      adr(2, funcs, code + 36),
      adr(1, str_off.name, code + 40),
      str(1, 2, 0),
      adr(1, close_at, code + 48),
      str(1, 2, 16),
      ret()
    ]

    ^init_len = length(init)

    code_bin = for i <- init ++ close_fn, into: <<>>, do: <<i::little-32>>
    size = code + byte_size(code_bin)

    header =
      <<0x7F, "ELF", 2, 1, 1, 0, 0::64, 3::little-16, 183::little-16, 1::little-32, 0::little-64, ehdr::little-64, 0::little-64,
        0::little-32, ehdr::little-16, 56::little-16, phnum::little-16, 64::little-16, 0::little-16, 0::little-16>>

    phdrs =
      phdr(1, 7, 0, size, 0x10000) <>
        phdr(2, 6, dynamic, dyn_count * 16, 8) <>
        # PT_GNU_STACK: no executable stack
        <<0x6474E551::little-32, 6::little-32, 0::little-64, 0::little-64, 0::little-64, 0::little-64, 0::little-64, 16::little-64>>

    syms = <<0::size(24 * 8)>> <> <<1::little-32, 0x12, 0, 1::little-16, code::little-64, length(init) * 4::little-64>>
    hash_bin = <<1::little-32, 2::little-32, 1::little-32, 0::little-32, 0::little-32>>

    dyn =
      for {tag, val} <- [{4, hash}, {5, dynstr}, {6, dynsym}, {10, byte_size(dynstr_bytes)}, {11, 24}, {0, 0}], into: <<>>,
          do: <<tag::little-64, val::little-64>>

    string_bin = for {_, s} <- strs, into: <<>>, do: <<s::binary, 0>>

    # ErlNifEntry {major, minor, name, num_of_funcs, funcs, load, reload,
    # upgrade, unload, vm_variant, options, sizeof(ErlNifResourceTypeInit),
    # min_erts}: the pointers are filled in by nif_init.
    entry_bin = <<2::little-32, 17::little-32, 0::64, 1::little-32, 0::32, 0::64, 0::64, 0::64, 0::64, 0::64, 0::64, 1::little-32, 0::32, 40::little-64, 0::64>>
    # ErlNifFunc {name, arity, fptr, flags}
    funcs_bin = <<0::64, 1::little-32, 0::32, 0::64, 0::little-32, 0::32>>

    [
      {0, header},
      {ehdr, phdrs},
      {dynsym, syms},
      {dynstr, dynstr_bytes},
      {hash, hash_bin},
      {dynamic, dyn},
      {strings, string_bin},
      {entry, entry_bin},
      {funcs, funcs_bin},
      {code, code_bin}
    ]
    |> Enum.reduce(<<>>, fn {off, bin}, acc -> pad(acc, off) <> bin end)
  end

  defp phdr(type, flags, off, size, align),
    do: <<type::little-32, flags::little-32, off::little-64, off::little-64, off::little-64, size::little-64, size::little-64, align::little-64>>

  defp align(n, a), do: div(n + a - 1, a) * a
  defp pad(bin, off) when byte_size(bin) <= off, do: bin <> :binary.copy(<<0>>, off - byte_size(bin))

  # -- aarch64 encodings ---------------------------------------------------------------------------

  @doc false
  def adr(rd, target, pc) do
    imm = target - pc
    0x10000000 ||| (imm &&& 3) <<< 29 ||| ((imm >>> 2) &&& 0x7FFFF) <<< 5 ||| rd
  end

  @doc false
  def str(rt, rn, off), do: 0xF9000000 ||| div(off, 8) <<< 10 ||| rn <<< 5 ||| rt

  @doc false
  def ldr(rt, rn, off), do: 0xF9400000 ||| div(off, 8) <<< 10 ||| rn <<< 5 ||| rt

  @doc false
  def ret, do: 0xD65F03C0
end
