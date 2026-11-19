defmodule Lepton.SoundTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.Sound
  alias Lepton.Sound.ALSA

  test "hw_params: 608 bytes, interleaved S16_LE, the rate and channels asked for" do
    p = ALSA.hw_params_struct(44100, 2)
    assert byte_size(p) == 608
    # access mask: RW_INTERLEAVED (bit 3); format mask: S16_LE (bit 2)
    assert <<0::32, 8::little-32, _::binary-28, 4::little-32, _::binary>> = p
    assert ALSA.interval(p, 2) == {2, 2}
    assert ALSA.interval(p, 3) == {44100, 44100}
    assert ALSA.interval(p, 9) == {0, 0xFFFFFFFF}
  end

  test "sound cards and their playback devices" do
    proc = tmp_dir("asound")
    dev = tmp_dir("snd")

    File.write!(Path.join(proc, "cards"), """
     0 [Intel          ]: HDA-Intel - HDA Intel
                          HDA Intel at 0x10010000 irq 38
     1 [Headset        ]: USB-Audio - USB Headset
                          Logitech USB Headset at usb-0000:00:02.0-1.3, full speed
    """)

    for f <- ~w(controlC0 pcmC0D0p pcmC0D0c controlC1 pcmC1D0p pcmC1D3p), do: File.write!(Path.join(dev, f), "")

    assert ALSA.cards(proc, dev) == [
             %{index: 0, id: "Intel", name: "HDA Intel", playback: [0]},
             %{index: 1, id: "Headset", name: "USB Headset", playback: [0, 3]}
           ]
  end

  test "the software volume follows softvol: linear in dB from -51 dB, silent at 0" do
    assert Sound.soft_value(100) == 255
    assert Sound.soft_value(0) == 0
    assert Sound.soft_gain(255) == 1.0
    assert Sound.soft_gain(0) == 0.0
    assert_in_delta Sound.soft_gain(Sound.soft_value(80)), 0.309, 0.001
    assert Sound.soft_gain(1) < 0.003
  end

  test "frames are converted to what the device plays: channels, rate, volume" do
    mono = <<1000::little-signed-16, -2000::little-signed-16>>
    stereo = %{rate: 48000, channels: 2}
    assert Sound.convert(mono, 48000, 1, stereo, 1.0) == <<1000::little-16, 1000::little-16, -2000::little-signed-16, -2000::little-signed-16>>
    assert Sound.convert(mono, 48000, 1, %{rate: 48000, channels: 1}, 0.5) == <<500::little-16, -1000::little-signed-16>>
    # Down to mono: the average.
    assert Sound.convert(<<100::little-16, 300::little-16>>, 48000, 2, %{rate: 48000, channels: 1}, 1.0) == <<200::little-16>>
    # 24 kHz to 48 kHz: twice the frames, in between interpolated.
    up = Sound.convert(<<0::little-16, 1000::little-16>>, 24000, 1, %{rate: 48000, channels: 1}, 1.0)
    assert for(<<s::little-signed-16 <- up>>, do: s) == [0, 500, 1000, 1000]
    # No clipping past 16 bits.
    assert Sound.convert(<<30000::little-16>>, 48000, 1, %{rate: 48000, channels: 1}, 2.0) == <<32767::little-16>>
  end

  test "tones and WAV files: 8, 16, 24-bit and float samples, extra chunks skipped" do
    tone = Sound.tone(1000, 100)
    assert byte_size(tone) == 4800 * 2
    samples = for <<s::little-signed-16 <- tone>>, do: s
    assert hd(samples) == 0 and Enum.max(samples) <= 12000 and Enum.max(samples) > 11000

    dir = tmp_dir("wav")

    wav = fn name, tag, bits, channels, data ->
      fmt = <<tag::little-16, channels::little-16, 22050::little-32, 0::32, 0::16, bits::little-16>>
      body = "WAVE" <> "fmt " <> <<16::little-32>> <> fmt <> "LIST" <> <<3::little-32, "abc", 0>> <> "data" <> <<byte_size(data)::little-32>> <> data
      path = Path.join(dir, name)
      File.write!(path, "RIFF" <> <<byte_size(body)::little-32>> <> body)
      path
    end

    p16 = wav.("a.wav", 1, 16, 2, <<1::little-16, 2::little-16>>)
    assert {:ok, %{rate: 22050, channels: 2, bits: 16, float: false, size: 4} = info} = Sound.wav_info(p16)
    assert {:ok, <<1::little-16, 2::little-16>>} = :file.read_file(p16) |> then(fn {:ok, b} -> {:ok, binary_part(b, info.offset, 4)} end)

    assert {:ok, %{bits: 8}} = Sound.wav_info(wav.("b.wav", 1, 8, 1, <<128, 255>>))
    assert Sound.to_s16(<<128, 255, 0>>, %{bits: 8}) == <<0::16, 127 * 256::little-16, -32768::little-signed-16>>
    assert Sound.to_s16(<<0, 0x34, 0x12>>, %{bits: 24}) == <<0x1234::little-16>>
    assert Sound.to_s16(<<0.5::little-float-32, -2.0::little-float-32>>, %{bits: 32, float: true}) == <<16384::little-16, -32767::little-signed-16>>
    assert {:ok, %{float: true}} = Sound.wav_info(wav.("c.wav", 3, 32, 1, <<0::32>>))
    assert {:error, "unsupported WAV encoding" <> _} = Sound.wav_info(wav.("d.wav", 2, 4, 1, <<0>>))
    File.write!(Path.join(dir, "e.wav"), "not a wav file at all")
    assert {:error, "not a WAV file"} = Sound.wav_info(Path.join(dir, "e.wav"))
  end

  test "commands without a sound card" do
    if Lepton.Sound.status().cards == [] do
      assert {"No sound card. Add a sound device to the VM (UTM: Sound), or plug in USB audio.\n", 0} = sh("sound")
      assert {out, 0} = sh("volume")
      assert out =~ ~r/^Volume: \d+%.*\(no sound card\)/
      assert {"", 1} = sh("beep")
    end

    assert {"", 2} = sh("volume loud")
    assert {"", 2} = sh("volume 101")
    assert {"", 2} = sh("beep 5")
    assert {"", 2} = sh("play")
  end

  # Inside Lepton: `mix lepton.qemu --test` gives the VM Intel HD Audio,
  # which QEMU records to a file.
  @tag :native
  # (The card's own Master is held at full: UTM's QEMU passes it to its
  # display client rather than apply it.)
  test "the VM's sound card: the volume is Lepton's software control; tones and WAV files play" do
    assert Enum.find_value(1..30, fn _ -> Sound.status().card || (Process.sleep(200) && nil) end)
    %{card: card} = Sound.status()
    assert card.name =~ "HDA"
    assert card.software and card.master.name == "Lepton Playback Volume"
    assert [{%{name: "Master Playback Volume"} = hw, max}, {%{name: "Master Playback Switch"} = sw, 1}] = card.hardware
    before = Sound.status()

    try do
      assert {:ok, %{volume: 30}} = Sound.set_volume(30)
      assert {:ok, [v, v]} = ALSA.read(card.index, card.master)
      assert v == Sound.soft_value(30)
      assert {:ok, [^max, ^max]} = ALSA.read(card.index, hw)
      assert {:ok, %{muted: true}} = Sound.mute(true)
      assert {:ok, [0, 0]} = ALSA.read(card.index, card.master)
      assert {:ok, [1, 1]} = ALSA.read(card.index, sw)
      assert {:ok, out} = Sound.output()
      assert out.gain == 0.0
      assert {:ok, %{muted: false, volume: 40}} = Sound.change(10)
      assert {:ok, [v, v]} = ALSA.read(card.index, card.master)
      assert v == Sound.soft_value(40)
      assert Sound.alsa_config() =~ ~s(name "Lepton Playback Volume")
      # (mixed: Firefox opens a stream for each tab that plays)
      assert Sound.alsa_config() =~ ~r/softvol; slave.pcm "lepton_mix".*\n.*type dmix/

      assert Sound.beep(440, 100) == :ok
      path = Path.join(tmp_dir("wavplay"), "t.wav")
      data = Sound.tone(330, 100, 22050)
      File.write!(path, "RIFF" <> <<36 + byte_size(data)::little-32>> <> "WAVEfmt " <> <<16::little-32, 1::little-16, 1::little-16, 22050::little-32, 44100::little-32, 2::little-16, 16::little-16>> <> "data" <> <<byte_size(data)::little-32>> <> data)
      assert {"", 0} = sh("play #{path}")
      assert {out, 0} = sh("volume")
      assert out =~ "Volume: 40% on HDA Intel"
    after
      Sound.set_volume(before.volume)
      Sound.mute(before.muted)
    end
  end
end
