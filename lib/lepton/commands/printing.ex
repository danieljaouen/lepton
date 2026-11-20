defmodule Lepton.Commands.Printing do
  @moduledoc "Printing: CUPS's commands, talking to Lepton's cupsd (`Lepton.Print.Server`)."

  use Lepton.Command
  alias Lepton.{IPP, Print}
  alias Lepton.Print.Server

  # -- talking to cupsd ---------------------------------------------------------------------------

  defp cupsd(op, attrs, data \\ "", groups \\ []) do
    req = %{IPP.request(op, attrs, 1, groups) | data: data}

    case Print.call(Server.uri() <> "/", req) do
      {:ok, resp} -> {:ok, resp}
      {:error, _} -> {:error, "the print service isn't running (start it: sudo svc start cups)"}
    end
  end

  defp printer_uri(name), do: "#{Server.uri()}/printers/#{URI.encode(name)}"

  defp printers do
    case cupsd(:cups_get_printers, []) do
      {:ok, resp} -> {:ok, IPP.each(resp, :printer)}
      e -> e
    end
  end

  defp pick(ctx, nil) do
    case Print.default(Ctx.home(ctx)) do
      nil ->
        case printers() do
          {:ok, [one]} -> {:ok, hd(one["printer-name"])}
          {:ok, []} -> {:error, "no printers: add one with lpadmin, or check the network (lpinfo -v)"}
          {:ok, _} -> {:error, "no default printer: choose one with lpoptions -d NAME (lpstat -p lists them)"}
          e -> e
        end

      name ->
        {:ok, name}
    end
  end

  defp pick(_ctx, name), do: {:ok, name}

  # -- lp / lpr ----------------------------------------------------------------------------------

  defcmd "lp", "print files (or standard input)", usage: "lp [-d PRINTER] [-n COPIES] [-t TITLE] [FILE...]" do
    {opts, files} = getopt(args, "d:n:t:o:q:")
    submit(ctx, opts["d"], Lepton.Args.int(opts, "n", 1), opts["t"], files, "lp")
  end

  defcmd "lpr", "print files (or standard input), BSD style", usage: "lpr [-P PRINTER] [-# COPIES] [-T TITLE] [FILE...]" do
    {opts, files} = getopt(args, "P:#:T:o:")
    submit(ctx, opts["P"], Lepton.Args.int(opts, "#", 1), opts["T"], files, "lpr")
  end

  defp submit(ctx, dest, copies, title, files, cmd) do
    inputs =
      case files do
        [] -> [{"(stdin)", {:ok, IO.read_all(ctx.stdin)}}]
        fs -> for f <- fs, do: {f, File.read(Ctx.path(ctx, f))}
      end

    with {:ok, printer} <- pick(ctx, dest) do
      Enum.reduce(inputs, 0, fn {name, data}, status ->
        with {:ok, bin} <- data,
             {:ok, resp} <-
               cupsd(:print_job, [
                 {"printer-uri", [{:uri, printer_uri(printer)}]},
                 {"requesting-user-name", [{:name, ctx.user}]},
                 {"job-name", [{:name, title || Path.basename(name)}]},
                 {"document-format", [{:mime_type, Print.format(bin)}]}
               ], bin, if(copies > 1, do: [{IPP.group_tag(:job), [{"copies", [{:integer, copies}]}]}], else: [])),
             id when is_integer(id) <- IPP.get(resp, :job, "job-id") || {:error, IPP.get(resp, :operation, "status-message") || "#{printer}: no such printer"} do
          if cmd == "lp", do: IO.puts(ctx, "request id is #{printer}-#{id} (1 file(s))")
          status
        else
          {:error, r} when is_atom(r) -> IO.err(ctx, "#{cmd}: #{name}: #{:file.format_error(r)}"); 1
          {:error, msg} -> IO.err(ctx, "#{cmd}: #{msg}"); 1
        end
      end)
    else
      {:error, msg} -> IO.err(ctx, "#{cmd}: #{msg}"); 1
    end
  end

  # -- lpstat ----------------------------------------------------------------------------------

  defcmd "lpstat", "the printers, the default, and the print jobs", usage: "lpstat [-p] [-d] [-o] [-v] [-t]" do
    {opts, _} = getopt(args, "pdovtaW:")
    all = opts["t"]
    show = fn k -> all || opts[k] end
    nothing? = not Enum.any?(~w(p d o v t), &opts[&1])

    case printers() do
      {:ok, ps} ->
        default = Print.default(Ctx.home(ctx))

        if show.("d"), do: IO.puts(ctx, if(default, do: "system default destination: #{default}", else: "no system default destination"))

        if show.("v") do
          for p <- ps, do: IO.puts(ctx, "device for #{hd(p["printer-name"])}: #{hd(p["device-uri"] || ["?"])}")
        end

        if show.("p") do
          for p <- ps do
            state = if hd(p["printer-state"]) == 4, do: "now printing", else: "is idle"
            IO.puts(ctx, "printer #{hd(p["printer-name"])} #{state}.  enabled  (#{hd(p["printer-info"] || [""])})")
          end
        end

        if show.("o") || nothing? do
          {:ok, resp} = cupsd(:get_jobs, [{"which-jobs", [{:keyword, "not-completed"}]}])

          for j <- IPP.each(resp, :job), nothing? == false or hd(j["job-originating-user-name"]) == ctx.user do
            created = j["time-at-creation"] |> hd() |> Lepton.Time.local() |> Lepton.Commands.System.strftime("%a %d %b %Y %H:%M:%S")
            IO.puts(ctx, String.pad_trailing("#{hd(j["job-printer-uri"]) |> Path.basename() |> URI.decode()}-#{hd(j["job-id"])}", 22) <>
              String.pad_trailing(hd(j["job-originating-user-name"]), 12) <> " #{Server.state_name(hd(j["job-state"]))}  #{created}  #{hd(j["job-name"])}")
          end
        end

        0

      {:error, msg} ->
        IO.err(ctx, "lpstat: #{msg}")
        1
    end
  end

  # -- cancel ----------------------------------------------------------------------------------

  defcmd "cancel", "cancel print jobs", usage: "cancel [JOB | PRINTER-JOB]... | -a" do
    {opts, ids} = getopt(args, "a")

    ids =
      if opts["a"] do
        {:ok, resp} = cupsd(:get_jobs, [])
        for j <- IPP.each(resp, :job), do: hd(j["job-id"])
      else
        for id <- ids, {n, ""} <- [Integer.parse(id |> String.split("-") |> List.last())], do: n
      end

    Enum.reduce(ids, 0, fn id, status ->
      case cupsd(:cancel_job, [{"job-uri", [{:uri, "#{Server.uri()}/jobs/#{id}"}]}, {"requesting-user-name", [{:name, ctx.user}]}]) do
        {:ok, %IPP{code: 0}} -> status
        {:ok, _} -> IO.err(ctx, "cancel: job #{id}: not found, or already finished"); 1
        {:error, msg} -> IO.err(ctx, "cancel: #{msg}"); 1
      end
    end)
  end

  # -- lpadmin / lpoptions / lpinfo ----------------------------------------------------------------

  defcmd "lpadmin", "add or remove a printer, or set the system's default", usage: "lpadmin -p NAME -v URI [-D DESCRIPTION] [-L LOCATION] [-E] | -x NAME | -d NAME", root: true do
    {opts, _} = getopt(args, "p:v:D:L:Ex:d:m:")

    result =
      cond do
        opts["x"] -> Print.delete(opts["x"])
        opts["d"] -> Print.set_system_default(opts["d"])
        opts["p"] && opts["v"] -> Print.add(opts["p"], opts["v"], opts["D"] || "", opts["L"] || "")
        true -> {:error, "usage: lpadmin -p NAME -v URI [-D DESCRIPTION] [-L LOCATION] [-E] | -x NAME | -d NAME"}
      end

    case result do
      :ok -> 0
      {:error, msg} -> IO.err(ctx, "lpadmin: #{msg}"); 1
    end
  end

  defcmd "lpoptions", "your default printer (in ~/.cups/lpoptions)", usage: "lpoptions [-d PRINTER]" do
    {opts, _} = getopt(args, "d:p:o:l")

    case opts["d"] do
      nil ->
        IO.puts(ctx, "Default #{Print.default(Ctx.home(ctx)) || "(none)"}")
        0

      name ->
        Print.set_default(Ctx.home(ctx), name)
        0
    end
  end

  defcmd "lpinfo", "the printers found on the network (IPP, by mDNS)", usage: "lpinfo -v" do
    for p <- Print.discover(3000), do: IO.puts(ctx, "network #{p.uri}  \"#{p.info}\"#{if p.model != "", do: " (#{p.model})", else: ""}")
    0
  end

  # -- printers: choose one (the classic desktop's Printers) ----------------------------------------

  defcmd "printers", "the printers: see them and choose your default", usage: "printers [NAME]" do
    case {args, printers()} do
      {_, {:error, msg}} ->
        IO.err(ctx, "printers: #{msg}")
        1

      {[name], {:ok, ps}} ->
        if Enum.any?(ps, &(hd(&1["printer-name"]) == name)),
          do: (Print.set_default(Ctx.home(ctx), name); IO.puts(ctx, "#{name} is your default printer."); 0),
          else: (IO.err(ctx, "printers: #{name}: no such printer"); 1)

      {[], {:ok, []}} ->
        IO.puts(ctx, "No printers. Lepton finds IPP printers (AirPrint, IPP Everywhere) on your network by")
        IO.puts(ctx, "themselves; check that the printer is on and on this network, or add one:")
        IO.puts(ctx, "  sudo lpadmin -p office -v ipp://192.168.1.50/ipp/print -E")
        0

      {[], {:ok, ps}} ->
        default = Print.default(Ctx.home(ctx))
        IO.puts(ctx, "Printers:")

        for {p, i} <- Enum.with_index(ps, 1) do
          name = hd(p["printer-name"])
          mark = if name == default, do: "*", else: " "
          IO.puts(ctx, " #{mark} #{i}. #{String.pad_trailing(name, 26)} #{hd(p["printer-info"] || [""])}")
        end

        if ctx.tty do
          IO.write(ctx, "\nNumber of the printer to use by default (Enter keeps #{default || "none"}): ")

          with line when is_binary(line) <- IO.read_line(ctx.stdin),
               {n, _} when n >= 1 and n <= length(ps) <- Integer.parse(String.trim(line)) do
            name = hd(Enum.at(ps, n - 1)["printer-name"])
            Print.set_default(Ctx.home(ctx), name)
            IO.puts(ctx, "#{name} is your default printer: lp and Firefox print there.")
          end
        end

        0
    end
  end

  # -- cupsd ----------------------------------------------------------------------------------------

  defcmd "cupsd", "the print service: the queue, and IPP on 127.0.0.1:631 (the cups service runs it)", usage: "cupsd", root: true do
    Server.run(&IO.puts(ctx, &1))
  end
end
