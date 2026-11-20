defmodule Lepton.FD do
  @moduledoc """
  Closing file descriptors the VM didn't open, `ioctl`, and `mount`.

  ERTS closes only descriptors it owns (files it opened, its sockets).
  A descriptor that arrives over a Unix socket (`SCM_RIGHTS`, as Wayland
  clients send their shared memory) has no owner, and nothing in OTP
  closes it. Nor can OTP make `ioctl` calls, which device drivers are
  controlled with (sound cards' formats and volume, input devices'
  ranges). So this module carries a small NIF: a shared object, written
  here byte by byte (no compiler), with functions that make the system
  calls. (`mount` is here for FUSE: the kernel takes the `/dev/fuse`
  descriptor from the process that mounts, so a helper program can't.)

  The library is about 1 KB: an ELF header, three program headers, a
  dynamic table and three functions of aarch64 code. `nif_init` fills in
  the `ErlNifEntry` (its pointers are computed with PC-relative `adr`).
  `close(Fd)` shifts the small-integer term to a number and calls `svc #0`
  with `x8 = 57`. `ioctl(Fd, Request, Binary)` copies the binary into a
  new one, passes it to `svc #0` with `x8 = 29` and returns both; it calls
  four of the VM's `enif_` functions through a GOT the loader fills in
  (`R_AARCH64_GLOB_DAT` relocations), and runs on a dirty I/O scheduler.
  The library is written to `/run/lepton` and loaded on first use, on
  aarch64 Linux only; elsewhere both return `{:error, :unsupported}`.
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

  @doc """
  `ioctl(2)`: `request` on descriptor `fd` (or a raw file Lepton opened),
  with `arg` the structure the request reads and writes, as bytes. The
  kernel works on a copy. Returns `{:ok, result, arg}` with the copy as
  the kernel left it, or `{:error, errno}`.
  """
  def ioctl(fd, request, arg \\ <<>>)

  def ioctl(fd, request, arg) when is_integer(fd) and is_integer(request) and is_binary(arg) do
    case nif_ioctl(fd, request, arg) do
      {n, _} when n < 0 -> {:error, errno(-n)}
      {n, out} -> {:ok, n, out}
    end
  catch
    :error, :unsupported -> {:error, :unsupported}
  end

  def ioctl(file, request, arg) do
    <<fd::native-32>> = :prim_file.get_handle(file)
    ioctl(fd, request, arg)
  end

  @doc false
  def nif_ioctl(_fd, _request, _arg), do: :erlang.nif_error(:unsupported)

  @doc """
  The `mount` system call (a FUSE mount needs the `/dev/fuse` descriptor
  to be this process's, so it can't be done by a helper program).
  """
  def mount(source, target, type, flags, data) do
    strings = [source, target, type, data]
    {offsets, blob} = Enum.map_reduce(strings, 40, fn s, off -> {off, off + byte_size(s) + 1} end)
    [src, tgt, typ, dat] = offsets
    _ = blob
    bin = <<src::little-64, tgt::little-64, typ::little-64, flags::little-64, dat::little-64>> <> Enum.map_join(strings, &(&1 <> <<0>>))
    nif_mount(bin) |> result()
  catch
    :error, :unsupported -> {:error, :unsupported}
  end

  @doc false
  def nif_mount(_bin), do: :erlang.nif_error(:unsupported)

  @errnos %{2 => :enoent, 4 => :eintr, 5 => :eio, 9 => :ebadf, 11 => :eagain, 16 => :ebusy, 19 => :enodev, 22 => :einval, 25 => :enotty, 32 => :epipe, 77 => :ebadfd}
  defp errno(n), do: Map.get(@errnos, n, n)

  def supported? do
    :os.type() == {:unix, :linux} and :erlang.system_info(:system_architecture) |> to_string() |> String.starts_with?("aarch64")
  end

  # -- the shared object ------------------------------------------------------------------------

  @module "Elixir.Lepton.FD"

  # nif_ioctl(env, argc, argv): ioctl(Fd, Request, a copy of Binary) ->
  # {Result, Copy}. Assembled (clang -target aarch64-linux-gnu) from:
  #
  #     stp x29, x30, [sp, #-96]! ; mov x29, sp
  #     stp x19, x20, [sp, #16] ; stp x21, x22, [sp, #32]
  #     mov x19, x0 ; mov x20, x2                      // env, argv
  #     enif_inspect_binary(env, argv[2], sp + 48)     // cbz x0, badarg
  #     x21 = enif_make_new_binary(env, bin.size, sp + 88)
  #     copy bin.size bytes from bin.data to x21       // ldrb/strb loop
  #     x0 = ioctl(argv[0] >> 4, argv[1] >> 4, x21)    // mov x8, #29 ; svc #0
  #     sp[48], sp[56] = x0 << 4 | 0xf, the new binary
  #     return enif_make_tuple_from_array(env, sp + 48, 2)
  #   badarg: return enif_make_badarg(env)
  #
  # The functions are called through the four GOT slots at the end
  # (`ldr x16, slot ; blr x16`), in @imports order.
  @ioctl_code [
    0xA9BA7BFD, 0x910003FD, 0xA90153F3, 0xA9025BF5, 0xAA0003F3, 0xAA0203F4, 0xAA1303E0, 0xF9400A81,
    0x9100C3E2, 0x58000570, 0xD63F0200, 0xB4000440, 0xAA1303E0, 0xF9401BE1, 0x910163E2, 0x580004F0,
    0xD63F0200, 0xAA0003F5, 0xF9401FE1, 0xF9401BE2, 0xD2800003, 0xEB02007F, 0x540000AA, 0x38636824,
    0x38236AA4, 0x91000463, 0x17FFFFFB, 0xF9400280, 0x9344FC00, 0xF9400681, 0x9344FC21, 0xAA1503E2,
    0xD28003A8, 0xD4000001, 0xD37CEC00, 0xB2400C00, 0xF9001BE0, 0xF9402FE1, 0xF9001FE1, 0xAA1303E0,
    0x9100C3E1, 0xD2800042, 0x580001D0, 0xD63F0200, 0x14000004, 0xAA1303E0, 0x58000190, 0xD63F0200,
    0xA9425BF5, 0xA94153F3, 0xA8C67BFD, 0xD65F03C0,
    # the GOT
    0, 0, 0, 0, 0, 0, 0, 0
  ]
  @ioctl_got 52 * 4
  @imports ["enif_inspect_binary", "enif_make_new_binary", "enif_make_tuple_from_array", "enif_make_badarg"]

  # nif_mount(env, argc, argv): mount(p + p[0], p + p[1], p + p[2], p[3],
  # p + p[4]) where p is the binary's data: offsets of the source, target,
  # type and data strings, and the flags. Returns the result as a small
  # integer (-errno). Assembled from:
  #
  #     stp x29, x30, [sp, #-80]! ; mov x29, sp ; str x19, [sp, #16]
  #     mov x19, x0 ; ldr x1, [x2] ; add x2, sp, #24
  #     enif_inspect_binary(env, argv[0], sp + 24)    // cbz x0, badarg
  #     x9 = bin.data ; x0..x4 = the strings and flags ; mov x8, #40 ; svc #0
  #     return x0 << 4 | 0xf
  #   badarg: return enif_make_badarg(env)
  #
  # Words 6 and 25 load GOT slots 0 and 3 (patched in `library/0`).
  @mount_code [
    0xA9BB7BFD, 0x910003FD, 0xF9000BF3, 0xAA0003F3, 0xF9400041, 0x910063E2, :got0, 0xD63F0200,
    0xB4000200, 0xF94013E9, 0xF940012A, 0x8B0A0120, 0xF940052A, 0x8B0A0121, 0xF940092A, 0x8B0A0122,
    0xF9400D23, 0xF940112A, 0x8B0A0124, 0xD2800508, 0xD4000001, 0xD37CEC00, 0xB2400C00, 0x14000004,
    0xAA1303E0, :got3, 0xD63F0200, 0xF9400BF3, 0xA8C57BFD, 0xD65F03C0
  ]

  @doc "The NIF library's bytes (an ELF64 aarch64 shared object)."
  def library do
    # Layout (one RWX load segment at address 0):
    #   ELF header, program headers, .dynsym, .dynstr, .hash, .rela.dyn,
    #   .dynamic, strings, ErlNifEntry, ErlNifFunc[3], code (nif_init,
    #   nif_close, nif_ioctl and its GOT, nif_mount)
    ehdr = 64
    phnum = 3
    dynsym = ehdr + phnum * 56
    nsyms = 2 + length(@imports)
    dynstr = dynsym + nsyms * 24
    names = ["nif_init" | @imports]

    {name_off, dynstr_len} = Enum.map_reduce(names, 1, fn n, off -> {off, off + byte_size(n) + 1} end)
    dynstr_bytes = IO.iodata_to_binary([0 | Enum.map(names, &[&1, 0])])

    hash = align(dynstr + dynstr_len, 8)
    rela = align(hash + (3 + nsyms) * 4, 8)
    dynamic = rela + length(@imports) * 24
    dyn_count = 9
    strings = dynamic + dyn_count * 16

    strs = [module: @module, variant: "beam.vanilla", min_erts: "erts-14.0", close: "nif_close", ioctl: "nif_ioctl", mount: "nif_mount"]

    {str_off, strings_end} =
      Enum.map_reduce(strs, strings, fn {k, s}, off -> {{k, off}, off + byte_size(s) + 1} end)

    str_off = Map.new(str_off)
    entry = align(strings_end, 8)
    funcs = entry + 96
    code = funcs + 3 * 32

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

    # nif_init(): fill in the entry's and the functions' pointers, return the entry.
    init_len = 23
    close_at = code + init_len * 4
    # (nif_ioctl's GOT must be 8-byte aligned)
    ioctl_at = align(close_at + length(close_fn) * 4, 8)
    got = ioctl_at + @ioctl_got
    mount_at = got + length(@imports) * 8

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
      adr(1, str_off.close, code + 40),
      str(1, 2, 0),
      adr(1, close_at, code + 48),
      str(1, 2, 16),
      adr(1, str_off.ioctl, code + 56),
      str(1, 2, 32),
      adr(1, ioctl_at, code + 64),
      str(1, 2, 48),
      adr(1, str_off.mount, code + 72),
      str(1, 2, 64),
      adr(1, mount_at, code + 80),
      str(1, 2, 80),
      ret()
    ]

    ^init_len = length(init)

    words = fn list -> for i <- list, into: <<>>, do: <<i::little-32>> end
    mount_fn =
      @mount_code
      |> Enum.with_index()
      |> Enum.map(fn
        {:got0, i} -> ldr_literal(16, got, mount_at + i * 4)
        {:got3, i} -> ldr_literal(16, got + 3 * 8, mount_at + i * 4)
        {w, _} -> w
      end)

    code_bin = pad(words.(init ++ close_fn), ioctl_at - code) <> words.(@ioctl_code) <> words.(mount_fn)
    size = code + byte_size(code_bin)

    header =
      <<0x7F, "ELF", 2, 1, 1, 0, 0::64, 3::little-16, 183::little-16, 1::little-32, 0::little-64, ehdr::little-64, 0::little-64,
        0::little-32, ehdr::little-16, 56::little-16, phnum::little-16, 64::little-16, 0::little-16, 0::little-16>>

    phdrs =
      phdr(1, 7, 0, size, 0x10000) <>
        phdr(2, 6, dynamic, dyn_count * 16, 8) <>
        # PT_GNU_STACK: no executable stack
        <<0x6474E551::little-32, 6::little-32, 0::little-64, 0::little-64, 0::little-64, 0::little-64, 0::little-64, 16::little-64>>

    # nif_init is defined here; the enif_ functions are the VM's (undefined, global functions).
    [init_name | import_names] = name_off

    syms =
      <<0::size(24 * 8)>> <>
        <<init_name::little-32, 0x12, 0, 1::little-16, code::little-64, length(init) * 4::little-64>> <>
        for(off <- import_names, into: <<>>, do: <<off::little-32, 0x12, 0, 0::little-16, 0::little-64, 0::little-64>>)

    # One bucket, holding nif_init; every chain ends at once.
    hash_bin = <<1::little-32, nsyms::little-32, 1::little-32>> <> :binary.copy(<<0::little-32>>, nsyms)

    # R_AARCH64_GLOB_DAT: the loader puts each function's address in its GOT slot.
    rela_bin =
      for i <- 0..(length(@imports) - 1), into: <<>>,
          do: <<got + i * 8::little-64, (2 + i) <<< 32 ||| 1025::little-64, 0::little-64>>

    dyn =
      for {tag, val} <- [{4, hash}, {5, dynstr}, {6, dynsym}, {10, dynstr_len}, {11, 24}, {7, rela}, {8, byte_size(rela_bin)}, {9, 24}, {0, 0}],
          into: <<>>,
          do: <<tag::little-64, val::little-64>>

    string_bin = for {_, s} <- strs, into: <<>>, do: <<s::binary, 0>>

    # ErlNifEntry {major, minor, name, num_of_funcs, funcs, load, reload,
    # upgrade, unload, vm_variant, options, sizeof(ErlNifResourceTypeInit),
    # min_erts}: the pointers are filled in by nif_init.
    entry_bin = <<2::little-32, 17::little-32, 0::64, 3::little-32, 0::32, 0::64, 0::64, 0::64, 0::64, 0::64, 0::64, 1::little-32, 0::32, 40::little-64, 0::64>>
    # ErlNifFunc {name, arity, fptr, flags}: close/1, and ioctl/3 on a
    # dirty I/O scheduler (flags 2: it may block, draining sound say).
    # mount/1 on a dirty I/O scheduler too.
    funcs_bin =
      <<0::64, 1::little-32, 0::32, 0::64, 0::little-32, 0::32>> <> <<0::64, 3::little-32, 0::32, 0::64, 2::little-32, 0::32>> <>
        <<0::64, 1::little-32, 0::32, 0::64, 2::little-32, 0::32>>

    [
      {0, header},
      {ehdr, phdrs},
      {dynsym, syms},
      {dynstr, dynstr_bytes},
      {hash, hash_bin},
      {rela, rela_bin},
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
  # ldr xT, <literal at target>
  def ldr_literal(rt, target, pc), do: 0x58000000 ||| (div(target - pc, 4) &&& 0x7FFFF) <<< 5 ||| rt

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
