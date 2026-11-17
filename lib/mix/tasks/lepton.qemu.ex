defmodule Mix.Tasks.Lepton.Qemu do
  @shortdoc "Boot out/lepton.iso in QEMU (GUI, serial, or automated test)"
  @moduledoc """
  Boots the ISO in QEMU (`brew install qemu`).

      mix lepton.qemu              # GUI window (display + USB keyboard), like UTM
      mix lepton.qemu --print      # print a command line for a serial-console session
      mix lepton.qemu --test       # headless: boot, run `lepton-test`, report
      mix lepton.qemu --run "cmd"  # headless: boot, run shell commands, print output

  The machine matches UTM's defaults for ARM64 Linux guests: `virt`,
  UEFI (edk2), virtio-scsi CD-ROM, virtio-net, ramfb/virtio-gpu, xHCI USB
  keyboard and tablet.
  """
  use Mix.Task

  @iso "out/lepton.iso"

  @impl true
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [print: :boolean, test: :boolean, run: :keep, iso: :string, timeout: :integer, mem: :integer]
      )

    iso = opts[:iso] || @iso
    unless File.exists?(iso), do: Mix.raise("#{iso} not found; run `mix lepton.iso` first")

    cond do
      opts[:print] ->
        Mix.shell().info(Enum.join([qemu() | base_args(iso, opts) ++ ["-nographic"]], " "))

      opts[:test] ->
        commands = ["lepton-test"]
        output = LeptonBuild.QemuHarness.session(qemu(), base_args(iso, opts), commands, opts[:timeout] || 300_000)
        IO.write(output)
        unless output =~ ~r/\d+ tests?, 0 failures/, do: Mix.raise("in-OS test suite failed")

      cmds = Keyword.get_values(opts, :run) |> then(&if(&1 == [], do: nil, else: &1)) ->
        output = LeptonBuild.QemuHarness.session(qemu(), base_args(iso, opts), cmds, opts[:timeout] || 120_000)
        IO.write(output)

      true ->
        args = base_args(iso, opts) ++ ["-device", "virtio-gpu-pci", "-display", "cocoa", "-serial", "mon:stdio"]
        Mix.shell().info("booting #{iso} (close the window to stop)")
        System.cmd(qemu(), args, into: IO.stream(:stdio, :line))
    end
  end

  def qemu, do: System.find_executable("qemu-system-aarch64") || Mix.raise("qemu-system-aarch64 not found (brew install qemu)")

  def firmware do
    candidates = [
      "/opt/homebrew/share/qemu/edk2-aarch64-code.fd",
      "/usr/local/share/qemu/edk2-aarch64-code.fd",
      "/usr/share/qemu/edk2-aarch64-code.fd",
      "/usr/share/AAVMF/AAVMF_CODE.fd"
    ]

    Enum.find(candidates, &File.exists?/1) || Mix.raise("edk2 aarch64 firmware not found")
  end

  def base_args(iso, opts) do
    accel = if :os.type() == {:unix, :darwin} and arm_host?(), do: ["-accel", "hvf", "-cpu", "host"], else: ["-cpu", "max"]

    ["-M", "virt"] ++
      accel ++
      [
        "-m",
        to_string(opts[:mem] || 2048),
        "-smp",
        "4",
        "-bios",
        firmware(),
        "-device",
        "virtio-scsi-pci,id=scsi",
        "-drive",
        "if=none,id=cd,file=#{iso},media=cdrom,readonly=on",
        "-device",
        "scsi-cd,drive=cd",
        "-device",
        "virtio-net-pci,netdev=net0",
        "-netdev",
        "user,id=net0",
        "-device",
        "virtio-rng-pci",
        "-device",
        "qemu-xhci",
        "-device",
        "usb-kbd",
        "-device",
        "usb-tablet",
        "-device",
        "ramfb"
      ]
  end

  defp arm_host?, do: :erlang.system_info(:system_architecture) |> to_string() |> String.starts_with?("aarch64")
end

defmodule LeptonBuild.QemuHarness do
  @moduledoc """
  Drives a headless QEMU over its serial console: waits for the Lepton
  prompt, types commands, collects their output, then powers off.
  """

  @prompt_marker "LEPTON-HARNESS-READY"

  def session(qemu, args, commands, timeout) do
    args = args ++ ["-display", "none", "-serial", "stdio", "-monitor", "none"]
    port = Port.open({:spawn_executable, qemu}, [:binary, :exit_status, :stderr_to_stdout, args: args])
    deadline = System.monotonic_time(:millisecond) + timeout

    try do
      boot_log = wait_for(port, ~r/\$ |# |❯ /, "", deadline)
      # Plain line-oriented terminal (TERM=dumb disables the line editor)
      # and a prompt marker that never appears literally in typed input.
      [head, tail] = String.split(@prompt_marker, "-", parts: 2)
      send_line(port, ~s{export TERM=dumb NO_COLOR=1 PS1="$(echo #{head})-#{tail}$ "})
      _ = wait_for(port, ~r/#{@prompt_marker}\$ $/, "", deadline)

      outputs =
        for cmd <- commands do
          send_line(port, cmd)
          out = wait_for(port, ~r/#{@prompt_marker}\$ $/, "", deadline)
          "$ #{cmd}\n" <> clean(out, cmd)
        end

      send_line(port, "poweroff")
      wait_exit(port, 10_000)
      Enum.join([summarize_boot(boot_log) | outputs], "\n")
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  defp send_line(port, line) do
    # Type slowly enough for the 16550/PL011 FIFO.
    for chunk <- String.graphemes(line <> "\r") |> Enum.chunk_every(8) do
      Port.command(port, Enum.join(chunk))
      Process.sleep(5)
    end
  end

  defp wait_for(port, regex, acc, deadline) do
    if Regex.match?(regex, strip_ansi(acc)) do
      acc
    else
      remaining = deadline - System.monotonic_time(:millisecond)
      if remaining <= 0, do: raise("timed out waiting for #{inspect(regex)}; output so far:\n" <> strip_ansi(acc))

      receive do
        {^port, {:data, data}} -> wait_for(port, regex, acc <> data, deadline)
        {^port, {:exit_status, s}} -> raise("qemu exited (#{s}); output:\n" <> strip_ansi(acc))
      after
        remaining -> wait_for(port, regex, acc, deadline)
      end
    end
  end

  defp wait_exit(port, timeout) do
    receive do
      {^port, {:exit_status, _}} -> :ok
      {^port, _} -> wait_exit(port, timeout)
    after
      timeout -> :timeout
    end
  end

  defp clean(out, cmd) do
    out
    |> strip_ansi()
    |> String.replace("\r", "")
    |> String.replace(~r/#{@prompt_marker}\$ $/, "")
    |> String.replace_prefix(cmd <> "\n", "")
    |> String.trim_leading()
  end

  defp summarize_boot(log) do
    lines = log |> strip_ansi() |> String.replace("\r", "") |> String.split("\n")
    "--- boot (last lines) ---\n" <> (lines |> Enum.take(-8) |> Enum.join("\n")) <> "\n---"
  end

  def strip_ansi(s), do: s |> String.replace(~r/\e\[[0-9;?=]*[A-Za-z]|\e\][^\a]*\a|\e[78=>]/, "") |> String.replace(<<0>>, "")
end
