defmodule Lepton.KernelLogTest do
  use ExUnit.Case, async: true

  alias Lepton.KernelLog

  @dmesg """
  [    0.000000] Booting Linux on physical CPU 0x0000000000 [0x610f0000]
  [    1.253855] snd_hda_codec_generic hdaudioC0D0:    inputs:
  [   61.500000] lepton: memory: 120 MiB available of 3936 MiB; stopping process 812 (900 MiB): firefox
  [   62.000001] Out of memory: Killed process 900 (firefox)
  """

  test "the kernel's new lines, without Lepton's own" do
    assert {["Booting Linux on physical CPU 0x0000000000 [0x610f0000]", "snd_hda_codec_generic hdaudioC0D0:    inputs:", "Out of memory: Killed process 900 (firefox)"], 62.000001} =
             KernelLog.new_lines(@dmesg, -1.0)

    assert {["Out of memory: Killed process 900 (firefox)"], 62.000001} = KernelLog.new_lines(@dmesg, 1.253855)
    assert {[], 62.000001} = KernelLog.new_lines(@dmesg, 62.000001)
    assert {[], 5.0} = KernelLog.new_lines("", 5.0)
  end
end
