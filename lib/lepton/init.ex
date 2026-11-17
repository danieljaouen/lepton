defmodule Lepton.Init do
  @moduledoc """
  PID 1.

  The kernel executes ERTS directly as `/init` (see the kernel command line
  in `LeptonBuild.Image`), and ERTS calls `main/0`. From here:

    1. mount the virtual filesystems (`/proc`, `/sys`, `/dev`, `/run`)
    2. quiet the kernel log, set the hostname
    3. load drivers (display, keyboard, network)
    4. start the Lepton application (process table, services)
    5. bring up networking in the background
    6. start a login session on every available console
  """

  require Logger

  alias Lepton.Sys

  @consoles ["/dev/tty1", "/dev/ttyAMA0", "/dev/hvc0"]

  @drivers [
    # display: see load_display/0
    # keyboards: USB (UTM/QEMU default) and virtio-input (Apple Virtualization)
    "xhci-pci",
    "usbhid",
    "hid-generic",
    "virtio_input",
    "evdev",
    # network, entropy, disks
    "virtio_net",
    "af_packet",
    "virtio_rng",
    "virtio_blk",
    "virtio_scsi",
    "sr_mod",
    "isofs",
    # installed systems: USB / SCSI / NVMe disks, ext2 data partition
    "usb-storage",
    "uas",
    "sd_mod",
    "nvme",
    "ext4"
  ]

  def main do
    # `-s` runs us inside init's boot sequence; return promptly.
    spawn(fn -> boot() end)
    :ok
  end

  def boot do
    t0 = System.monotonic_time(:millisecond)
    Application.load(:lepton)

    if Sys.pid1?() do
      early_mounts()
      File.write("/proc/sys/kernel/printk", "1 4 1 7")
      Sys.set_hostname(hostname())
      configure_logger()
      say("Lepton OS #{version()} booting on Linux #{Sys.kernel_release()}")
      load_drivers()
    end

    {:ok, _} = Application.ensure_all_started(:lepton)

    if Sys.pid1?() do
      wait_for_data_partition()
      verbose("storage: #{Lepton.Persist.mount()}")
      Lepton.Pkg.load_installed()
      Lepton.Power.start()
      Lepton.Net.start_background()
      Lepton.Services.boot()
      wait_for_consoles()
      ms = System.monotonic_time(:millisecond) - t0
      say("userland up in #{ms} ms")
      start_consoles()

      if Sys.cmdline_flag?("lepton.selftest=1") do
        spawn(fn -> selftest_on_boot() end)
      end
    end
  rescue
    e ->
      say("init: boot failed: " <> Exception.format(:error, e, __STACKTRACE__))
      emergency_shell()
  end

  def version, do: Application.spec(:lepton, :vsn) |> to_string()

  defp hostname do
    case File.read("/etc/hostname") do
      {:ok, name} -> String.trim(name)
      _ -> "lepton"
    end
  end

  @mounts [
    {"proc", "proc", "/proc", nil},
    {"sysfs", "sysfs", "/sys", nil},
    {"devtmpfs", "devtmpfs", "/dev", nil},
    {"devpts", "devpts", "/dev/pts", nil},
    {"tmpfs", "tmpfs", "/run", "mode=0755"},
    {"tmpfs", "tmpfs", "/dev/shm", "mode=1777"}
  ]

  defp early_mounts do
    for {type, src, dir, opts} <- @mounts do
      case Sys.mount(type, src, dir, opts) do
        :ok -> :ok
        {:error, reason} -> say("mount #{dir}: #{reason}")
      end
    end
  end

  defp load_drivers do
    load_display()

    Enum.each(@drivers, &modprobe/1)
  end

  # The console must live on the device the VM window shows. With a virtio
  # GPU (QEMU's virtio-gpu-pci, UTM's virtio-ramfb, Apple Virtualization)
  # that is the GPU: loading simpledrm first would put the console on the
  # firmware framebuffer, and UTM's virtio-ramfb, which switches to the GPU
  # once its driver starts, would then show "Display output is not active".
  # Without one (plain ramfb, or another firmware framebuffer) simpledrm
  # drives what the firmware set up.
  defp load_display do
    if virtio_gpu?() do
      modprobe("virtio-gpu")
      # If the GPU driver doesn't come up, fall back to the framebuffer.
      unless wait_for(fn -> Path.wildcard("/sys/class/drm/card*") != [] end, 20), do: modprobe("simpledrm")
    else
      modprobe("simpledrm")
    end
  end

  # PCI vendor 0x1af4 (virtio), device 0x1050 (virtio-gpu).
  defp virtio_gpu? do
    Enum.any?(Path.wildcard("/sys/bus/pci/devices/*"), fn dev ->
      read = fn f -> case File.read(Path.join(dev, f)) do
          {:ok, v} -> String.trim(v)
          _ -> nil
        end end

      read.("vendor") == "0x1af4" and read.("device") == "0x1050"
    end)
  end

  defp modprobe(mod) do
    case Lepton.Kmod.modprobe(mod) do
      :ok -> :ok
      {:error, reason} -> verbose("modprobe #{mod}: #{reason}")
    end
  end

  defp wait_for(fun, tries) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(50); wait_for(fun, tries - 1)
    end
  end

  defp configure_logger do
    {:ok, _} = Application.ensure_all_started(:logger)
    File.mkdir_p("/var/log")
    :logger.remove_handler(:default)

    :logger.add_handler(:lepton_file, :logger_std_h, %{
      config: %{file: ~c"/var/log/messages"},
      formatter: Logger.default_formatter()
    })

    Logger.configure(level: if(Sys.cmdline_flag?("lepton.verbose=1"), do: :debug, else: :info))
  end

  # Disks are probed asynchronously; give an installed disk time to appear.
  defp wait_for_data_partition(tries \\ 20) do
    if tries > 0 and Lepton.Persist.data_partition() == nil and Lepton.Install.Disk.disks() != [] do
      Process.sleep(100)
      wait_for_data_partition(tries - 1)
    end
  end

  # Device nodes appear asynchronously as drivers bind.
  defp wait_for_consoles(tries \\ 20) do
    if tries > 0 and not File.exists?("/dev/tty1") do
      Process.sleep(50)
      wait_for_consoles(tries - 1)
    end
  end

  def start_consoles do
    for dev <- @consoles do
      if usable_console?(dev) do
        verbose("starting session on #{dev}")
        Lepton.Session.start_console(dev)
      else
        verbose("no console #{dev}")
      end
    end
  end

  defp verbose(msg) do
    if Sys.cmdline_flag?("lepton.verbose=1"), do: say(msg)
    Logger.info(msg)
  end

  defp usable_console?(dev) do
    with true <- File.exists?(dev),
         {:ok, fd} <- :file.open(dev, [:write, :raw]) do
      :file.close(fd)
      true
    else
      _ -> false
    end
  end

  # Write to the kernel console directly (before any session exists).
  def say(msg) do
    case :file.open("/dev/console", [:write, :raw, :binary]) do
      {:ok, fd} ->
        :file.write(fd, "\r[lepton] " <> msg <> "\r\n")
        :file.close(fd)

      _ ->
        IO.puts(msg)
    end
  end

  defp selftest_on_boot do
    Process.sleep(1500)
    {output, status} = Lepton.SelfTest.run_capture()
    say("\r\n" <> output)
    say("SELFTEST #{if status == 0, do: "PASSED", else: "FAILED"}")
  end

  defp emergency_shell do
    say("starting emergency session on /dev/console")
    Application.ensure_all_started(:lepton)
    Lepton.Session.start_console("/dev/console")
  rescue
    _ -> :ok
  end
end
