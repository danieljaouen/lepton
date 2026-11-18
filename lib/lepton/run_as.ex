defmodule Lepton.RunAs do
  @moduledoc """
  Running native programs as a user.

  Lepton's userland is one Erlang VM running as root, so programs it
  starts run as root too, whoever is logged in. Firefox refuses that (its
  profile would be root's files in the user's home). Lepton's accounts
  are Lepton's, but their user IDs are real, so native programs can run
  as the user: through `runas UID GID PROGRAM [ARG...]`, which drops the
  supplementary groups, sets the group and user IDs, and executes
  PROGRAM with its arguments and environment.

  `runas` is a static aarch64 executable of about 340 bytes, written here
  (an ELF header, one program header and 41 instructions of system calls:
  setgroups, setgid, setuid, execve; exit 126 if any fails). The code was
  assembled from the source below; it is position-independent and calls
  nothing outside itself.

      _start: ldr x19, [sp]            // argc
              add x20, sp, #8          // argv
              cmp x19, #4 ; b.lt fail
              ldr x0, [x20, #8] ; bl atoi ; mov x21, x0     // uid
              ldr x0, [x20, #16] ; bl atoi ; mov x22, x0    // gid
              setgroups(0, NULL) ; setgid(x22) ; setuid(x21) // cbnz x0, fail after each
              execve(argv[3], argv + 3, argv + argc + 1)
      fail:   exit(126)
      atoi:   x0 = decimal string -> x0 = number
  """

  @code [
    0xF94003F3, 0x910023F4, 0xF100127F, 0x5400034B, 0xF9400680, 0x9400001B, 0xAA0003F5, 0xF9400A80,
    0x94000018, 0xAA0003F6, 0xD2800000, 0xD2800001, 0xD28013E8, 0xD4000001, 0xB50001E0, 0xAA1603E0,
    0xD2801208, 0xD4000001, 0xB5000160, 0xAA1503E0, 0xD2801248, 0xD4000001, 0xB50000E0, 0x8B130E82,
    0x91002042, 0xF9400E80, 0x91006281, 0xD2801BA8, 0xD4000001, 0xD2800FC0, 0xD2800BA8, 0xD4000001,
    0xD2800001, 0xD2800143, 0x38401402, 0x34000082, 0xD100C042, 0x9B030821, 0x17FFFFFC, 0xAA0103E0,
    0xD65F03C0
  ]

  @base 0x400000

  @doc "The `runas` executable's bytes (a static ELF64 aarch64 executable)."
  def executable do
    code = for i <- @code, into: <<>>, do: <<i::little-32>>
    phnum = 2
    start = 64 + phnum * 56
    size = start + byte_size(code)

    header =
      <<0x7F, "ELF", 2, 1, 1, 0, 0::64, 2::little-16, 183::little-16, 1::little-32, @base + start::little-64, 64::little-64,
        0::little-64, 0::little-32, 64::little-16, 56::little-16, phnum::little-16, 64::little-16, 0::little-16, 0::little-16>>

    # PT_LOAD (read + execute) of the whole file; PT_GNU_STACK (not executable)
    load = <<1::little-32, 5::little-32, 0::little-64, @base::little-64, @base::little-64, size::little-64, size::little-64, 0x10000::little-64>>
    stack = <<0x6474E551::little-32, 6::little-32, 0::size(5 * 64), 16::little-64>>
    header <> load <> stack <> code
  end

  @doc "Where `runas` is (written there the first time); nil off aarch64 Linux."
  def path do
    path = "/run/lepton/runas"

    cond do
      not Lepton.FD.supported?() ->
        nil

      File.exists?(path) ->
        path

      true ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, executable())
        File.chmod!(path, 0o755)
        path
    end
  end

  @doc """
  How to start `exe` with `args` as `user` (a `Lepton.Users` account):
  `{executable, args}`. Root, or a system without `runas`, runs it directly.
  """
  def command(%Lepton.Users{uid: uid, gid: gid}, exe, args) when uid != 0 do
    case path() do
      nil -> {exe, args}
      runas -> {runas, [to_string(uid), to_string(gid), exe | args]}
    end
  end

  def command(_user, exe, args), do: {exe, args}
end
