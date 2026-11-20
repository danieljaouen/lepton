defmodule Lepton.PrintTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.{IPP, Print}
  alias Lepton.Print.Server

  setup do
    state = tmp_dir("printstate")
    System.put_env("LEPTON_STATE_DIR", state)
    on_exit(fn -> System.delete_env("LEPTON_STATE_DIR") end)
    :ok
  end

  describe "the formats" do
    test "IPP messages round trip" do
      req =
        IPP.request(:print_job, [
          {"printer-uri", [{:uri, "ipp://p/ipp/print"}]},
          {"document-format-supported", [{:mime_type, "application/pdf"}, {:mime_type, "image/jpeg"}]},
          {"copies-supported", [{:range, {1, 99}}]},
          {"printer-is-accepting-jobs", [{:boolean, true}]},
          {"printer-state", [{:enum, 3}]}
        ], 42)

      {:ok, back} = IPP.decode(IPP.encode(%{req | data: "DOC"}))
      assert back.code == IPP.op(:print_job) and back.id == 42 and back.data == "DOC"
      assert IPP.get(back, :operation, "printer-uri") == "ipp://p/ipp/print"
      assert IPP.all(back, :operation, "document-format-supported") == ["application/pdf", "image/jpeg"]
      assert IPP.get(back, :operation, "copies-supported") == {1, 99}
      assert IPP.get(back, :operation, "printer-is-accepting-jobs") == true
      assert {:error, :malformed} = IPP.decode("x")
    end

    test "text becomes a PDF: pages, wrapping, and a cross-reference table that points at its objects" do
      text = Enum.map_join(1..150, "\n", &"line #{&1} (with parens) \\ and é") <> "\n" <> String.duplicate("x", 200)
      pdf = Print.pdf(text, "na_letter_8.5x11in")
      assert String.starts_with?(pdf, "%PDF-1.4")
      assert pdf =~ "/Count 3"
      assert pdf =~ "/MediaBox [0 0 612 792]"
      assert pdf =~ "(line 1 \\(with parens\\) \\\\ and \xE9) Tj"
      [_, xref] = Regex.run(~r/startxref\n(\d+)\n/, pdf)
      offsets = Regex.scan(~r/(\d{10}) 00000 n /, pdf) |> Enum.map(fn [_, o] -> String.to_integer(o) end)

      for {off, i} <- Enum.with_index(offsets, 1), do: assert(binary_part(pdf, off, byte_size("#{i} 0 obj")) == "#{i} 0 obj")
      assert binary_part(pdf, String.to_integer(xref), 4) == "xref"
    end

    test "mDNS answers become printers" do
      name = fn n -> for(l <- String.split(n, "."), into: "", do: <<byte_size(l)>> <> l) <> <<0>> end
      # PTR _ipp._tcp.local -> Office Laser._ipp._tcp.local; SRV, TXT and A
      inst = "Office Laser._ipp._tcp.local"
      rr = fn n, type, data -> name.(n) <> <<type::16, 1::16, 120::32, byte_size(data)::16>> <> data end
      txt = for(s <- ["rp=ipp/print", "ty=Acme LaserJet 9"], into: "", do: <<byte_size(s)>> <> s)

      packet =
        <<0::16, 0x8400::16, 0::16, 1::16, 0::16, 3::16>> <>
          rr.("_ipp._tcp.local", 12, name.(inst)) <>
          rr.(inst, 33, <<0::16, 0::16, 631::16>> <> name.("acme.local")) <>
          rr.(inst, 16, txt) <> rr.("acme.local", 1, <<192, 168, 1, 50>>)

      assert [%{name: "Office_Laser", uri: "ipp://192.168.1.50:631/ipp/print", info: "Office Laser", model: "Acme LaserJet 9"}] = Print.printers(Print.records(packet))
      assert Print.query(["_ipp._tcp.local"]) =~ "_ipp"
    end

    test "formats are told apart" do
      assert Print.format("%PDF-1.7") == "application/pdf"
      assert Print.format(<<0xFF, 0xD8, 0xFF, 0xE0>>) == "image/jpeg"
      assert Print.format("hello\n") == "text/plain"
    end
  end

  # -- a printer, and cupsd ----------------------------------------------------------------------

  # An IPP Everywhere printer: tells about itself, and hands the test each job.
  defp fake_printer(test, formats) do
    {:ok, l} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(l)
    spawn_link(fn -> printer_loop(l, test, formats) end)
    "ipp://127.0.0.1:#{port}/ipp/print"
  end

  defp printer_loop(l, test, formats) do
    {:ok, c} = :gen_tcp.accept(l)
    body = http_body(c, "")
    {:ok, req} = IPP.decode(body)

    resp =
      case IPP.op_name(req.code) do
        :get_printer_attributes ->
          IPP.response(req, :ok, [{IPP.group_tag(:printer), [{"document-format-supported", Enum.map(formats, &{:mime_type, &1})}, {"media-default", [{:keyword, "na_letter_8.5x11in"}]}]}])

        :print_job ->
          send(test, {:printed, IPP.get(req, :operation, "job-name"), IPP.get(req, :operation, "document-format"), IPP.get(req, :job, "copies", 1), req.data})
          IPP.response(req, :ok, [{IPP.group_tag(:job), [{"job-id", [{:integer, 7}]}]}])
      end

    out = IPP.encode(resp)
    :gen_tcp.send(c, "HTTP/1.1 200 OK\r\nContent-Type: application/ipp\r\nContent-Length: #{byte_size(out)}\r\nConnection: close\r\n\r\n#{out}")
    :gen_tcp.close(c)
    printer_loop(l, test, formats)
  end

  defp http_body(c, acc) do
    {:ok, data} = :gen_tcp.recv(c, 0, 5000)
    acc = acc <> data

    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, body] ->
        [_, len] = Regex.run(~r/content-length: (\d+)/i, head)
        if byte_size(body) >= String.to_integer(len), do: body, else: http_body(c, acc)

      _ ->
        http_body(c, acc)
    end
  end

  # Inside Lepton the cups service runs one already.
  defp start_cupsd do
    case Process.whereis(Server) do
      nil ->
        {:ok, pid} = Server.start_link(port: 0, discover: false)
        Process.unlink(pid)
        on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
        pid

      pid ->
        pid
    end
  end

  test "lpadmin, lp, lpstat, lpoptions, printers and cancel, through cupsd to the printer" do
    start_cupsd()
    uri = fake_printer(self(), ["application/pdf", "image/jpeg"])
    home = tmp_dir("printhome")

    assert {"", 0} = sh("lpadmin -p office -v #{uri} -D 'Office laser' -E")
    assert {_, 1} = sh("lpadmin -p nope -v #{uri}", user: "nobody")

    {out, 0} = sh("lpstat -p -v")
    assert out =~ "printer office is idle.  enabled  (Office laser)"
    assert out =~ "device for office: #{uri}"

    # one printer: it's the one, without a default
    file = Path.join(tmp_dir("printfile"), "notes.txt")
    File.write!(file, "Hello, printer!\n")
    {out, 0} = sh("lp -n 2 #{file}", home: home)
    assert out =~ ~r/^request id is office-\d+ \(1 file\(s\)\)\n$/
    assert_receive {:printed, "notes.txt", "application/pdf", 2, pdf}, 5000
    assert pdf =~ "%PDF" and pdf =~ "(Hello, printer!) Tj"

    {"", 0} = sh("echo from stdin | lpr -P office -T piped", home: home)
    assert_receive {:printed, "piped", "application/pdf", 1, _}, 5000

    assert {"", 0} = sh("lpoptions -d office", home: home)
    assert File.read!(Path.join(home, ".cups/lpoptions")) =~ "Default office\n"
    {out, 0} = sh("lpstat -d", home: home)
    assert out == "system default destination: office\n"
    {out, 0} = sh("printers", home: home)
    assert out =~ " * 1. office"

    # a job waiting for its document can be cancelled
    {:ok, resp} = Print.call("#{Server.uri()}/", IPP.request(:create_job, [{"printer-uri", [{:uri, "#{Server.uri()}/printers/office"}]}, {"requesting-user-name", [{:name, "root"}]}]))
    id = IPP.get(resp, :job, "job-id")
    {out, 0} = sh("lpstat -o")
    assert out =~ "office-#{id}"
    assert {"", 0} = sh("cancel #{id}")
    {out, 0} = sh("lpstat -o")
    refute out =~ "office-#{id}"

    assert {"", 0} = sh("lpadmin -x office")
  end

  test "a printer that takes neither PDF nor text says so" do
    start_cupsd()
    uri = fake_printer(self(), ["image/pwg-raster"])
    assert {:error, msg} = Print.print(uri, "hello")
    assert msg =~ "can't print text/plain"
  end

  test "cupsd speaks HTTP as libcups does: keep-alive, chunked bodies, Expect: 100-continue" do
    start_cupsd()
    {:ok, s} = :gen_tcp.connect({127, 0, 0, 1}, Server.port(), [:binary, active: false])
    body = IPP.encode(IPP.request(:cups_get_printers, []))
    half = div(byte_size(body), 2)
    chunked = Integer.to_string(half, 16) <> "\r\n" <> binary_part(body, 0, half) <> "\r\n" <>
      Integer.to_string(byte_size(body) - half, 16) <> "\r\n" <> binary_part(body, half, byte_size(body) - half) <> "\r\n0\r\n\r\n"

    for _ <- 1..2 do
      :gen_tcp.send(s, "POST / HTTP/1.1\r\nHost: localhost:631\r\nContent-Type: application/ipp\r\nTransfer-Encoding: chunked\r\nExpect: 100-continue\r\n\r\n")
      assert {:ok, "HTTP/1.1 100 Continue\r\n\r\n"} = :gen_tcp.recv(s, 25, 5000)
      :gen_tcp.send(s, chunked)
      {:ok, head} = :gen_tcp.recv(s, 0, 5000)
      assert head =~ "HTTP/1.1 200 OK"
      assert head =~ "Content-Type: application/ipp"
    end

    :gen_tcp.close(s)
  end
end
