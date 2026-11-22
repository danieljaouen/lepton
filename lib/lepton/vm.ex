defmodule Lepton.VM do
  @moduledoc """
  Virtual machines on Lepton, as UTM keeps them on a Mac: QEMU from
  Alpine (the `qemu` app), a directory per machine, and machines that keep
  running when the terminal that started them closes.

  A machine is a directory, `~/VMs/NAME`, holding its settings
  (`vm.toml`) and its disk (`disk.qcow2`, which grows as the guest writes
  to it). The settings:

      memory = 2048          # MB
      cpus = 2
      iso = "/root/lepton.iso"   # a CD in the drive ("" for none)
      forward = ["2222:22"]  # host port : guest port, TCP on 127.0.0.1

  It runs as its owner: `qemu-system-aarch64` with UEFI firmware (AAVMF),
  a virtio disk, the CD on virtio-scsi (booted first while there is one),
  user-mode networking, and its serial port on a socket that
  `Lepton.VM.Server` reads, keeping the latest output for `vm console`
  and `vm log`.

  **Acceleration.** With `/dev/kvm` (the kernel's KVM, which needs the
  CPU's virtualization extensions: Lepton itself booted with nested
  virtualization, `mix lepton.qemu --nested` on an M3 or later) the guest
  runs at the CPU's speed; without it QEMU emulates the CPU (TCG), many
  times slower.
  """

  alias Lepton.Apps

  @app "qemu"
  @defaults %{"memory" => 2048, "cpus" => 2, "iso" => "", "forward" => []}

  def app, do: @app
  def installed?, do: Apps.installed?(@app)

  # -- where things are ---------------------------------------------------------------

  def root(home), do: Path.join(home, "VMs")
  def dir(home, name), do: Path.join(root(home), name)
  def config_file(home, name), do: Path.join(dir(home, name), "vm.toml")
  def disk(home, name), do: Path.join(dir(home, name), "disk.qcow2")

  @doc "The runtime directory of a running machine: its QMP and serial sockets."
  def run_dir(uid, name), do: "/run/lepton/vms/#{uid}-#{name}"

  def prefix, do: Apps.dir(@app)
  def qemu(prefix \\ prefix()), do: Path.join(prefix, "usr/bin/qemu-system-aarch64")
  def qemu_img(prefix \\ prefix()), do: Path.join(prefix, "usr/bin/qemu-img")

  @doc "The UEFI firmware: Alpine's AAVMF, or QEMU's own edk2 build."
  def firmware(prefix \\ prefix()) do
    ["usr/share/AAVMF/QEMU_EFI.fd", "usr/share/qemu/edk2-aarch64-code.fd"]
    |> Enum.map(&Path.join(prefix, &1))
    |> Enum.find(&File.exists?/1)
  end

  def kvm?, do: File.exists?("/dev/kvm")

  @doc """
  QEMU for other programs (Lepton's `mix`, Claude Code: `mix lepton.qemu`
  in a checkout of Lepton): its directory to put on PATH, once its
  libraries are on musl's path and KVM is open to users. Nil without the
  qemu app.
  """
  def tool_path do
    if installed?() do
      if Lepton.Sys.native?() do
        Apps.musl_path(prefix())
        if kvm?(), do: File.chmod("/dev/kvm", 0o666)
      end

      Path.join(prefix(), "usr/bin")
    end
  end

  # -- machines -------------------------------------------------------------------------

  @doc "A valid machine name: letters, digits, `.`, `_` and `-`."
  def valid_name?(name), do: is_binary(name) and name =~ ~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/

  @doc "The machines in `home`, by name."
  def list(home) do
    case File.ls(root(home)) do
      {:ok, names} -> names |> Enum.filter(&File.exists?(config_file(home, &1))) |> Enum.sort()
      _ -> []
    end
  end

  def exists?(home, name), do: valid_name?(name) and File.exists?(config_file(home, name))

  @doc "A machine's settings, with the defaults filled in."
  def config(home, name) do
    Map.merge(@defaults, Lepton.TOML.read(config_file(home, name))) |> Map.put("name", name)
  end

  @doc "Write a machine's settings."
  def write_config(home, name, cfg) do
    File.write!(config_file(home, name), encode(cfg))
  end

  @doc "Settings as TOML, the keys Lepton knows in order."
  def encode(cfg) do
    known = ["memory", "cpus", "iso", "forward"]

    Enum.map_join(known, "", fn k ->
      case Map.get(cfg, k, @defaults[k]) do
        v when is_integer(v) -> "#{k} = #{v}\n"
        v when is_list(v) -> "#{k} = [#{Enum.map_join(v, ", ", &inspect(to_string(&1)))}]\n"
        v -> "#{k} = #{inspect(to_string(v))}\n"
      end
    end)
  end

  @doc """
  Change settings from `KEY=VALUE` strings: memory, cpus, iso,
  forward (comma-separated `HOST:GUEST` ports). `{:ok, cfg}` or `{:error, msg}`.
  """
  def update(cfg, assignments) do
    Enum.reduce_while(assignments, {:ok, cfg}, fn a, {:ok, cfg} ->
      case String.split(a, "=", parts: 2) do
        [k, v] ->
          case set(cfg, k, String.trim(v)) do
            {:ok, cfg} -> {:cont, {:ok, cfg}}
            error -> {:halt, error}
          end

        _ ->
          {:halt, {:error, "expected KEY=VALUE, got #{a}"}}
      end
    end)
  end

  defp set(cfg, k, v) when k in ["memory", "cpus"] do
    case Integer.parse(v) do
      {n, ""} when n > 0 -> {:ok, Map.put(cfg, k, n)}
      _ -> {:error, "#{k} must be a positive number"}
    end
  end

  defp set(cfg, "iso", v), do: {:ok, Map.put(cfg, "iso", v)}

  defp set(cfg, "forward", v) do
    ports = String.split(v, ",", trim: true) |> Enum.map(&String.trim/1)
    if Enum.all?(ports, &(&1 =~ ~r/^\d{1,5}:\d{1,5}$/)), do: {:ok, Map.put(cfg, "forward", ports)}, else: {:error, "forward is HOST:GUEST ports, like 2222:22"}
  end

  defp set(_cfg, k, _), do: {:error, "unknown setting #{k} (memory, cpus, iso, forward)"}

  @doc "A disk size (`16G`, `512M`) in bytes, or nil."
  def parse_size(s) do
    case Regex.run(~r/^(\d+)([KMGT]?)i?B?$/i, String.trim(s || "")) do
      [_, n, unit] -> String.to_integer(n) * Map.fetch!(%{"" => 1, "K" => 1024, "M" => 1024 ** 2, "G" => 1024 ** 3, "T" => 1024 ** 4}, String.upcase(unit))
      _ -> nil
    end
  end

  @doc """
  Make machine `name` in `home`: its directory, settings and an empty disk
  of `size` bytes (qemu-img). `owner` (a `Lepton.Users` user) owns them.
  """
  def create(home, name, cfg, size, owner) do
    cond do
      not valid_name?(name) -> {:error, "#{inspect(name)} isn't a valid name (letters, digits, . _ -)"}
      exists?(home, name) -> {:error, "#{name} already exists"}
      not installed?() -> {:error, "QEMU isn't installed (sudo app install qemu)"}
      true ->
        dir = dir(home, name)
        File.mkdir_p!(dir)
        Apps.musl_path(prefix())
        write_config(home, name, cfg)

        case System.cmd(qemu_img(), ["create", "-q", "-f", "qcow2", disk(home, name), Integer.to_string(size)], stderr_to_stdout: true, env: [{"LD_LIBRARY_PATH", nil}]) do
          {_, 0} ->
            own(Path.join([home, "VMs"]), owner)
            Enum.each([dir, config_file(home, name), disk(home, name)], &own(&1, owner))
            :ok

          {out, _} ->
            File.rm_rf(dir)
            {:error, "qemu-img: " <> String.trim(out)}
        end
    end
  end

  defp own(path, %{uid: uid, gid: gid}), do: (File.chown(path, uid); File.chgrp(path, gid))
  defp own(_, _), do: :ok

  def delete(home, name) do
    cond do
      not exists?(home, name) -> {:error, "no machine called #{name}"}
      running?(home, name) -> {:error, "#{name} is running: stop it first (vm stop #{name})"}
      true -> File.rm_rf(dir(home, name)); :ok
    end
  end

  # -- running --------------------------------------------------------------------------

  def running?(home, name), do: Lepton.VM.Server.whereis(home, name) != nil

  @doc """
  QEMU's arguments for machine `cfg`. `paths`: `:disk`, `:firmware`,
  `:data` (QEMU's data directory), `:serial` and `:qmp` (sockets).
  `kvm?`: run on KVM, or emulate.
  """
  def args(cfg, paths, kvm?) do
    accel = if kvm?, do: ["-accel", "kvm", "-cpu", "host"], else: ["-accel", "tcg,thread=multi", "-cpu", "max"]
    fwd = Enum.map_join(cfg["forward"] || [], "", fn p -> [h, g] = String.split(p, ":"); ",hostfwd=tcp:127.0.0.1:#{h}-:#{g}" end)

    cd =
      case cfg["iso"] do
        iso when is_binary(iso) and iso != "" ->
          ["-device", "virtio-scsi-pci,id=scsi", "-drive", "if=none,id=cd0,file=#{iso},media=cdrom,readonly=on", "-device", "scsi-cd,drive=cd0,bootindex=0"]

        _ ->
          []
      end

    ["-name", cfg["name"], "-nodefaults", "-no-user-config", "-M", "virt"] ++
      accel ++
      ["-smp", to_string(cfg["cpus"]), "-m", to_string(cfg["memory"])] ++
      ["-bios", paths.firmware, "-L", paths.data] ++
      ["-device", "virtio-rng-pci", "-netdev", "user,id=net0" <> fwd, "-device", "virtio-net-pci,netdev=net0"] ++
      ["-drive", "if=none,id=disk0,file=#{paths.disk},format=qcow2,discard=unmap", "-device", "virtio-blk-pci,drive=disk0,bootindex=1"] ++
      cd ++
      ["-chardev", "socket,id=ser0,path=#{paths.serial},server=on,wait=off", "-serial", "chardev:ser0"] ++
      ["-qmp", "unix:#{paths.qmp},server=on,wait=off", "-display", "none"]
  end

  @doc """
  Start machine `name` of `user` (a `Lepton.Users` user): `{:ok, pid}`
  or `{:error, msg}`.
  """
  def start(home, name, user) do
    cond do
      not exists?(home, name) -> {:error, "no machine called #{name}"}
      not installed?() -> {:error, "QEMU isn't installed (sudo app install qemu)"}
      running?(home, name) -> {:error, "#{name} is already running"}
      true -> DynamicSupervisor.start_child(Lepton.VM.Supervisor, {Lepton.VM.Server, home: home, name: name, user: user})
    end
    |> case do
      {:ok, pid} -> {:ok, pid}
      {:error, {:shutdown, reason}} -> {:error, reason}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @doc "Ask machine `name` to shut down (the power button), or end it at once with `force: true`."
  def stop(home, name, opts \\ []) do
    case Lepton.VM.Server.whereis(home, name) do
      nil -> {:error, "#{name} isn't running"}
      pid -> Lepton.VM.Server.stop(pid, opts[:force] == true)
    end
  end

  @doc "The status of each machine: `[%{name, running, memory, cpus, iso, ...}]`."
  def statuses(home) do
    for name <- list(home) do
      cfg = config(home, name)
      Map.merge(cfg, %{"running" => running?(home, name), "disk_used" => disk_used(home, name)})
    end
  end

  defp disk_used(home, name) do
    case File.stat(disk(home, name)) do
      {:ok, %{size: s}} -> s
      _ -> 0
    end
  end
end
