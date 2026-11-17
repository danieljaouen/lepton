defmodule Lepton.TTYTest do
  use ExUnit.Case

  alias Lepton.TTY
  alias Lepton.TTY.Capture

  test "serial-style terminals are re-measured and raw readers get a resize event" do
    {:ok, tty} = TTY.start(backend: {Capture, nil}, auto_probe: true, probe_interval: 30)
    :ok = TTY.set_mode(tty, :raw)
    %{backend: {_, agent}} = :sys.get_state(tty)

    # The TTY asks the terminal for its size (cursor position report)...
    assert eventually(fn -> Capture.output(agent) =~ "\e[6n" end)
    # ...and the terminal answers with a new size.
    TTY.input(tty, "\e[50;160R")
    assert TTY.read_key(tty, 1000) == {:resize, 50, 160}
    assert TTY.size(tty) == {50, 160}

    # Same size again: no event. Implausible answers are ignored.
    assert eventually(fn -> :sys.get_state(tty).probe_sent != nil end)
    TTY.input(tty, "\e[50;160R")
    assert TTY.read_key(tty, 200) == :timeout
    assert eventually(fn -> :sys.get_state(tty).probe_sent != nil end)
    TTY.input(tty, "\e[1;2R")
    assert TTY.read_key(tty, 200) == :timeout
    assert TTY.size(tty) == {50, 160}
  end

  test "terminals that report their own size are not probed" do
    {:ok, tty} = TTY.start(backend: {Capture, nil})
    :ok = TTY.set_mode(tty, :raw)
    %{backend: {_, agent}, auto_probe: auto} = :sys.get_state(tty)
    refute auto
    Process.sleep(100)
    refute Capture.output(agent) =~ "\e[6n"
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20); eventually(fun, tries - 1)
    end
  end
end
