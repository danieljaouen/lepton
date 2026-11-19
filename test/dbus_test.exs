defmodule Lepton.DBusTest do
  use ExUnit.Case
  import Bitwise

  alias Lepton.DBus.Wire

  test "signatures parse into types and back" do
    assert Wire.parse("a{sv}s") == [{:dict, :s, :v}, :s]
    assert Wire.parse("a(yv)") == [{:array, {:struct, [:y, :v]}}]
    assert Wire.parse("oa{sa{sv}}") == [:o, {:dict, :s, {:dict, :s, :v}}]
    assert Wire.sig(Wire.parse("a{oa{sa{sv}}}")) == "a{oa{sa{sv}}}"
  end

  test "values are aligned to their size, arrays to their elements" do
    # y then u: three bytes of padding before the u
    assert Wire.encode("yu", [1, 2]) == <<1, 0, 0, 0, 2, 0, 0, 0>>
    # a string: length, bytes, NUL
    assert Wire.encode("s", ["hi"]) == <<2::little-32, "hi", 0>>
    # an array of int64 at offset 0: length 8, then padding to 8, then the element
    assert Wire.encode("ax", [[5]]) == <<8::little-32, 0::32, 5::little-64>>
    # an empty array of structs still pads to the struct's alignment
    assert Wire.encode("a(ii)", [[]]) == <<0::little-32, 0::32>>
    assert Wire.encode("g", ["sv"]) == <<2, "sv", 0>>
  end

  test "values survive the round trip" do
    sig = "ybnqiuxtdsogav(isb)a{sv}"

    values = [
      255, true, -2, 65535, -70000, 4_000_000_000, -1 <<< 40, 1 <<< 60, 1.5, "héllo", "/org/bluez/hci0", "a{sv}",
      [{:variant, "s", "x"}, {:variant, "u", 7}],
      {-1, "two", false},
      %{"Name" => {:variant, "s", "Keyboard"}, "Paired" => {:variant, "b", true}, "RSSI" => {:variant, "n", -60}}
    ]

    decoded = Wire.decode(sig, Wire.encode(sig, values))
    assert Enum.take(decoded, 12) == Enum.take(values, 12)
    assert Enum.at(decoded, 12) == ["x", 7]
    assert Enum.at(decoded, 13) == {-1, "two", false}
    assert Enum.at(decoded, 14) == %{"Name" => "Keyboard", "Paired" => true, "RSSI" => -60}
    # Alignment counts from the message's start.
    assert Wire.decode("t", Wire.encode("t", [9], 4), 4) == [9]
  end

  test "messages: Hello as libdbus writes it, and split back" do
    hello = %{type: :method_call, serial: 1, path: "/org/freedesktop/DBus", interface: "org.freedesktop.DBus", member: "Hello", destination: "org.freedesktop.DBus"}
    bin = Wire.message(hello)
    assert <<?l, 1, 0, 1, 0::little-32, 1::little-32, fields_len::little-32, _::binary>> = bin
    # The header is padded to 8 bytes; Hello has no body.
    assert byte_size(bin) == div(16 + fields_len + 7, 8) * 8
    assert {:ok, msg, "rest"} = Wire.split(bin <> "rest")
    assert %{type: :method_call, serial: 1, member: "Hello", path: "/org/freedesktop/DBus", destination: "org.freedesktop.DBus", body: []} = msg
    assert Wire.split(binary_part(bin, 0, 20)) == :more

    # A reply with a body, after a header whose length isn't a multiple of 8.
    reply = %{type: :method_return, serial: 7, reply_serial: 1, destination: ":1.5", signature: "a{sv}", body: [%{"Powered" => {:variant, "b", true}}]}
    assert {:ok, %{type: :method_return, reply_serial: 1, signature: "a{sv}", body: [%{"Powered" => true}]}, ""} = Wire.split(Wire.message(reply))

    error = %{type: :error, serial: 8, reply_serial: 3, error_name: "org.bluez.Error.Failed", signature: "s", body: ["Page Timeout"]}
    assert {:ok, %{type: :error, error_name: "org.bluez.Error.Failed", body: ["Page Timeout"]}, ""} = Wire.split(Wire.message(error))
  end
end
