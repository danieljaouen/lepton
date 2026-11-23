defmodule LeptonBuild.ImageTest do
  use ExUnit.Case

  alias LeptonBuild.Image

  # The build tooling lives in the repository only.
  @moduletag :docs

  # Everything after "--" goes to the BEAM, as arguments to Lepton.Init.main:
  # a flag there stops the boot (the verbose entry's did, until 1.16.2).
  test "GRUB's entries: kernel flags before \"--\", the BEAM's arguments after, and what GRUB says meanwhile" do
    cfg = Image.grub_cfg("erts-1.0", "29")
    lines = for line <- String.split(cfg, "\n"), String.contains?(line, "linux /boot/vmlinuz"), do: line
    assert length(lines) == 4

    for line <- lines do
      [kernel, beam] = String.split(line, " -- ")
      assert beam =~ ~r/-s Elixir\.Lepton\.Init main$/
      refute beam =~ "lepton."
      # (the kernel's messages on the firmware's framebuffer until a display driver loads)
      assert kernel =~ "earlycon=efifb keep_bootcon"
    end

    [_default, verbose, live, selftest] = lines
    assert verbose =~ "lepton.verbose=1" and not (verbose =~ "quiet")
    assert live =~ "lepton.live=1"
    assert selftest =~ "lepton.selftest=1"
    assert length(String.split(cfg, "echo \"Starting Lepton")) == 5
  end
end
