defmodule Lepton.VDAgentTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.VDAgent

  # The client's side: what the agent wrote, as messages.
  defp written(buf \\ %{chunks: "", msgs: %{}}) do
    receive do
      {:wrote, bytes} ->
        case VDAgent.decode(bytes, buf) do
          {[], buf} -> written(buf)
          {msgs, _} -> msgs
        end
    after
      2000 -> flunk("the agent wrote nothing")
    end
  end

  defp agent do
    me = self()
    {:ok, pid} = VDAgent.start_link(name: nil, send: &send(me, {:wrote, &1}))
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    # it announces itself: clipboard by demand, LF line ends
    assert [{6, <<1::little-32, caps::little-32>>}] = written()
    assert Bitwise.band(caps, 0b1_0010_0000) == 0b1_0010_0000
    pid
  end

  defp eventually(f, n \\ 50), do: f.() || (n > 0 && (Process.sleep(20); eventually(f, n - 1)))

  defp from_client(pid, type, data), do: send(pid, {:vdagent_data, IO.iodata_to_binary(VDAgent.encode(type, data))})

  test "messages: chunks of at most 2048 bytes, put back together however they arrive" do
    big = String.duplicate("k", 5000)
    bytes = IO.iodata_to_binary(VDAgent.encode(4, <<1::little-32>> <> big))
    assert byte_size(bytes) == 20 + 4 + 5000 + 3 * 8

    # a byte at a time
    {msgs, _} =
      Enum.reduce(:binary.bin_to_list(bytes), {[], %{chunks: "", msgs: %{}}}, fn b, {acc, buf} ->
        {m, buf} = VDAgent.decode(<<b>>, buf)
        {acc ++ m, buf}
      end)

    assert msgs == [{4, <<1::little-32>> <> big}]
  end

  test "copied on the Mac: fetched at once, and pbpaste has it (>> appends it)" do
    pid = agent()
    from_client(pid, 6, <<1::little-32, 0::little-32>>)
    assert [{6, <<0::little-32, _::binary>>}] = written()

    key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI me@mac\n"
    from_client(pid, 7, <<1::little-32>>)
    assert [{8, <<1::little-32>>}] = written()
    from_client(pid, 4, <<1::little-32>> <> key)
    assert eventually(fn -> Lepton.Clipboard.get() == key end)

    home = tmp_dir("vdhome")
    File.mkdir_p!(Path.join(home, ".ssh"))
    File.write!(Path.join(home, ".ssh/authorized_keys"), "ssh-ed25519 AAAAold old@box\n")
    assert {"", 0} = sh("pbpaste >> ~/.ssh/authorized_keys", home: home)
    assert File.read!(Path.join(home, ".ssh/authorized_keys")) == "ssh-ed25519 AAAAold old@box\n" <> key

    # what came from the Mac isn't offered back to it
    refute_receive {:wrote, _}, 300
  end

  test "copied in Lepton: offered to the Mac, and sent when it pastes" do
    pid = agent()
    Lepton.Clipboard.put("from lepton")
    assert [{7, <<1::little-32>>}] = written()
    from_client(pid, 8, <<1::little-32>>)
    assert [{4, <<1::little-32, "from lepton">>}] = written()
    # something other than text: nothing to give
    from_client(pid, 8, <<2::little-32>>)
    assert [{4, <<0::little-32>>}] = written()
  end
end
