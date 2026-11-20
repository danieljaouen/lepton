defmodule Lepton.Rsync.Session do
  @moduledoc """
  One side of an rsync transfer (protocol 27): the handshake, then the
  sender's or the receiver's part.

  The receiver runs a generator alongside it, as rsync does: the
  generator asks for each out-of-date file (sending the checksums of the
  copy it has), the receiver rebuilds files from what the sender returns.
  A file whose checksum doesn't match is asked for again, whole, in the
  second phase. Each phase ends with -1, which the sender echoes.
  """

  import Bitwise
  alias Lepton.Rsync.{Delta, Flist, Wire}

  @protocol 27

  defstruct [:wire, :seed, :opts, :server, :log, :ctx, written: 0, read: 0, size: 0]

  def protocol, do: @protocol

  @doc """
  Handshake. `role` is `:client` or `:server`; `log` is
  `fn kind, text -> ... end` for messages (kind `:info` or `:error`).
  """
  def start(wire, role, opts, ctx, log) do
    seed =
      case role do
        :client ->
          Wire.write_int(wire, @protocol)
          remote = Wire.read_int(wire)
          if remote < @protocol, do: throw({:rsync_error, 2, "the remote rsync speaks protocol #{remote}, older than #{@protocol}"})
          seed = Wire.read_int(wire)
          Wire.demux(wire)
          seed

        :server ->
          remote = Wire.read_int(wire)
          seed = :rand.uniform(0x7FFFFFFF)
          Wire.write(wire, [Wire.int(@protocol), Wire.int(seed)])
          Wire.mux(wire)
          if remote < @protocol, do: throw({:rsync_error, 2, "the client speaks protocol #{remote}, older than #{@protocol}"})
          seed
      end

    %__MODULE__{wire: wire, seed: seed, opts: opts, server: role == :server, log: log, ctx: ctx}
  end

  defp say(s, kind, text) do
    if s.server, do: Wire.message(s.wire, kind, text <> "\n"), else: s.log.(kind, text)
  end

  # -v: what the receiver made (the client shows it, whichever side it is).
  defp note(s, text), do: if(s.opts.verbose > 0, do: say(s, :info, text))

  # -- rules (excludes) ----------------------------------------------------------------------

  defp send_rules(s, patterns) do
    Wire.write(s.wire, [for(p <- patterns, r = "- " <> p, do: [Wire.int(byte_size(r)), r]), Wire.int(0)])
  end

  defp recv_rules(s, acc \\ []) do
    case Wire.read_int(s.wire) do
      0 ->
        Enum.reverse(acc)

      n ->
        rule = Wire.read(s.wire, n)

        acc =
          case rule do
            "- " <> p -> [p | acc]
            "+ " <> _ -> acc
            "!" -> []
            p -> [p | acc]
          end

        recv_rules(s, acc)
    end
  end

  # -- the sender ----------------------------------------------------------------------------

  @doc "Send `sources` (`[{as_given, absolute_path}]`). Returns `{exit_status, total_size}`."
  def sender(s, sources) do
    opts = s.opts

    opts =
      cond do
        s.server -> %{opts | excludes: opts.excludes ++ recv_rules(s)}
        opts.delete -> (send_rules(s, opts.excludes); opts)
        true -> opts
      end

    {entries, warnings} = Flist.build(sources, opts)
    for w <- warnings, do: say(s, :error, "rsync: " <> w)
    Flist.send(s.wire, entries, opts)

    if entries == [] do
      {if(warnings == [], do: 0, else: 23), 0}
    else
      files = List.to_tuple(entries)
      s = %{s | size: entries |> Enum.map(& &1.size) |> Enum.sum()}
      {s, errors} = serve(s, files, 0, 0)

      if s.server, do: Wire.write(s.wire, [Wire.long(s.read), Wire.long(s.written), Wire.long(s.size)])

      case Wire.read_int(s.wire) do
        -1 -> {if(errors + length(warnings) > 0, do: 23, else: 0), s.size}
        _ -> throw({:rsync_error, 12, "invalid packet at the end of the run"})
      end
    end
  end

  defp serve(s, files, phase, errors) do
    case Wire.read_int(s.wire) do
      -1 ->
        Wire.write_int(s.wire, -1)
        if phase + 1 >= 2, do: {s, errors}, else: serve(s, files, phase + 1, errors)

      i when i >= 0 and i < tuple_size(files) ->
        [count, blength, s2, rem] = for _ <- 1..4, do: Wire.read_int(s.wire)
        sums = for _ <- 1..count//1, do: {Wire.read_int(s.wire) &&& 0xFFFFFFFF, Wire.read(s.wire, s2)}
        e = elem(files, i)

        case File.read(e.path) do
          {:ok, data} ->
            {tokens, encoded} =
              if s.opts.compress,
                do: {[{:literal, data}], Delta.encode_compressed(data)},
                else: (t = Delta.tokens(data, {count, blength, s2, rem, sums}, s.seed); {t, Delta.encode_tokens(t)})

            out = [Wire.int(i), Wire.int(count), Wire.int(blength), Wire.int(s2), Wire.int(rem), encoded, Delta.file_sum(data, s.seed)]
            Wire.write(s.wire, out)
            if s.opts.verbose > 0 and not s.server, do: s.log.(:info, e.name)
            literal = for {:literal, d} <- tokens, reduce: 0, do: (n -> n + byte_size(d))
            serve(%{s | written: s.written + literal, read: s.read + count * (4 + s2)}, files, phase, errors)

          {:error, reason} ->
            say(s, :error, "rsync: send_files failed to open \"#{e.name}\": #{:file.format_error(reason)}")
            serve(s, files, phase, errors + 1)
        end

      i ->
        throw({:rsync_error, 12, "invalid file index #{i} from the receiver"})
    end
  end

  # -- the receiver ---------------------------------------------------------------------------

  @doc """
  Receive into `dest` (`{as_given, absolute_path}`). Returns
  `{exit_status, total_size}` (the size from the sender's statistics).
  """
  def receiver(s, {dest_given, dest}) do
    opts = s.opts

    opts =
      cond do
        not s.server -> (send_rules(s, opts.excludes); opts)
        opts.delete -> %{opts | excludes: opts.excludes ++ recv_rules(s)}
        true -> opts
      end

    s = %{s | opts: opts}
    {entries, io_error} = Flist.recv(s.wire, opts)

    if entries == [] do
      {if(io_error != 0, do: 23, else: 0), 0}
    else
      single? = match?([_], entries) and not Flist.dir?(hd(entries)) and not File.dir?(dest) and not String.ends_with?(dest_given, "/")
      target = fn e -> if single?, do: dest, else: (if e.name == ".", do: dest, else: Path.join(dest, e.name)) end

      unless single? or opts.dry_run do
        allowed!(s, dest)
        File.mkdir_p(dest)
      end

      if opts.delete and opts.recursive, do: delete_extraneous(s, entries, target)
      errors = make_dirs_and_links(s, entries, target)
      files = List.to_tuple(entries)

      wanted =
        for {e, i} <- Enum.with_index(entries), Flist.file?(e), stale?(s, e, target.(e)) do
          if s.opts.dry_run, do: note(s, e.name)
          i
        end

      wanted = if opts.dry_run, do: [], else: wanted
      me = self()
      gen = spawn_link(fn -> generate(s, files, target, wanted, me) end)
      {s, errors} = receive_files(s, files, target, gen, 0, [], errors)
      # Directory times last: writing files into them changed them.
      if opts.times and not opts.dry_run, do: for(e <- Enum.reverse(entries), Flist.dir?(e), File.dir?(target.(e)), do: File.touch(target.(e), e.mtime))

      size =
        if s.server do
          s.size
        else
          _written = Wire.read_long(s.wire)
          _read = Wire.read_long(s.wire)
          Wire.read_long(s.wire)
        end

      Wire.write_int(s.wire, -1)
      {if(errors + io_error > 0, do: 23, else: 0), size}
    end
  end

  defp allowed!(s, path) do
    case Lepton.Users.check_write(s.ctx, path) do
      :ok -> :ok
      _ -> throw({:rsync_error, 23, "#{path}: permission denied"})
    end
  end

  defp writable?(s, path), do: Lepton.Users.check_write(s.ctx, path) == :ok

  # Needs sending? (rsync's quick check: size and modification time)
  defp stale?(s, e, path) do
    o = s.opts

    case File.lstat(path, time: :posix) do
      {:ok, %{type: :regular} = st} ->
        cond do
          o.ignore_times -> true
          o.update and st.mtime > e.mtime -> false
          o.checksum -> Delta.file_sum(File.read!(path), nil) != e.sum or (touch(s, e, path, st); false)
          o.size_only -> st.size != e.size
          true -> st.size != e.size or st.mtime != e.mtime
        end

      _ ->
        true
    end
  end

  defp touch(s, e, path, st) do
    if s.opts.times and st.mtime != e.mtime and not s.opts.dry_run, do: File.touch(path, e.mtime)
  end

  defp make_dirs_and_links(s, entries, target) do
    Enum.reduce(entries, 0, fn e, errors ->
      path = target.(e)

      cond do
        s.opts.dry_run ->
          if Flist.dir?(e) and not File.dir?(path), do: note(s, e.name <> "/")
          errors

        Flist.dir?(e) ->
          cond do
            File.dir?(path) ->
              set_mode(s, e, path)
              errors

            not writable?(s, path) ->
              say(s, :error, "rsync: mkdir \"#{e.name}\" failed: permission denied")
              errors + 1

            true ->
              if File.exists?(path), do: File.rm(path)

              case File.mkdir_p(path) do
                :ok ->
                  if e.name != ".", do: note(s, e.name <> "/")
                  set_mode(s, e, path)
                  errors

                {:error, r} ->
                  say(s, :error, "rsync: mkdir \"#{e.name}\" failed: #{:file.format_error(r)}")
                  errors + 1
              end
          end

        Flist.link?(e) and s.opts.links ->
          case File.read_link(path) do
            {:ok, t} when t == e.link ->
              errors

            _ ->
              if writable?(s, path) do
                File.rm_rf(path)
                File.ln_s(e.link, path)
                note(s, "#{e.name} -> #{e.link}")
                errors
              else
                say(s, :error, "rsync: symlink \"#{e.name}\" failed: permission denied")
                errors + 1
              end
          end

        true ->
          errors
      end
    end)
  end

  defp set_mode(s, e, path) do
    if s.opts.perms, do: File.chmod(path, e.mode &&& 0o7777)
  end

  # --delete: in each directory sent, remove what the sender doesn't have.
  defp delete_extraneous(s, entries, target) do
    names = MapSet.new(entries, & &1.name)

    for d <- entries, Flist.dir?(d), dir = target.(d), {:ok, local} <- [File.ls(dir)], n <- Enum.sort(local) do
      rel = if d.name == ".", do: n, else: d.name <> "/" <> n
      path = Path.join(dir, n)

      unless MapSet.member?(names, rel) or Flist.excluded?(s.opts.excludes, rel, File.dir?(path)) do
        if s.opts.verbose > 0, do: say(s, :info, "deleting #{rel}#{if File.dir?(path) and not match?({:ok, %{type: :symlink}}, File.lstat(path)), do: "/", else: ""}")
        if not s.opts.dry_run and writable?(s, path), do: File.rm_rf(path)
      end
    end
  end

  # The generator: ask for each file, end the phase, then ask again
  # (whole) for the files that failed their checksum.
  defp generate(s, files, target, wanted, receiver) do
    for i <- wanted do
      e = elem(files, i)
      basis = if s.opts.whole_file, do: nil, else: (case File.read(target.(e)) do {:ok, b} -> b; _ -> nil end)
      sig = if basis in [nil, ""], do: {0, 0, 0, 0, []}, else: Delta.signature(basis, s.seed)
      Wire.write(s.wire, [Wire.int(i), Delta.encode_signature(sig)])
    end

    Wire.write_int(s.wire, -1)

    receive do
      {:redo, ^receiver, redo} ->
        for i <- redo, do: Wire.write(s.wire, [Wire.int(i), Delta.encode_signature({0, 0, 0, 0, []})])
        Wire.write_int(s.wire, -1)
    end
  end

  defp receive_files(s, files, target, gen, phase, failed, errors) do
    case Wire.read_int(s.wire) do
      -1 when phase == 0 ->
        send(gen, {:redo, self(), Enum.reverse(failed)})
        receive_files(s, files, target, gen, 1, [], errors)

      -1 ->
        {s, errors + length(failed)}

      i when i >= 0 and i < tuple_size(files) ->
        e = elem(files, i)
        [_count, blength, _s2, rem] = for _ <- 1..4, do: Wire.read_int(s.wire)
        path = target.(e)
        basis = case File.read(path) do {:ok, b} -> b; _ -> "" end
        data =
          if s.opts.compress do
            block = fn t -> block(basis, t, blength) end
            IO.iodata_to_binary(Delta.decode_compressed(&Wire.read(s.wire, &1), block, @protocol))
          else
            IO.iodata_to_binary(tokens(s, basis, blength, rem, []))
          end
        sum = Wire.read(s.wire, 16)

        cond do
          Delta.file_sum(data, s.seed) != sum and phase == 0 ->
            receive_files(s, files, target, gen, phase, [i | failed], errors)

          Delta.file_sum(data, s.seed) != sum ->
            say(s, :error, "rsync: \"#{e.name}\" failed verification twice; it was not updated")
            receive_files(s, files, target, gen, phase, failed, errors + 1)

          true ->
            case install(s, e, path, data) do
              :ok ->
                if s.opts.verbose > 0 and not s.server, do: s.log.(:info, e.name)
                receive_files(%{s | size: s.size + byte_size(data)}, files, target, gen, phase, failed, errors)

              {:error, msg} ->
                say(s, :error, "rsync: #{msg}")
                receive_files(s, files, target, gen, phase, failed, errors + 1)
            end
        end

      i ->
        throw({:rsync_error, 12, "invalid file index #{i} from the sender"})
    end
  end

  defp block(basis, i, blength) do
    len = byte_size(basis)
    start = i * blength
    if start >= len or i < 0, do: throw({:rsync_error, 12, "block #{i} is outside the file"})
    binary_part(basis, start, min(blength, len - start))
  end

  defp tokens(s, basis, blength, rem, acc) do
    case Wire.read_int(s.wire) do
      0 ->
        Enum.reverse(acc)

      n when n > 0 ->
        tokens(s, basis, blength, rem, [Wire.read(s.wire, n) | acc])

      n ->
        i = -n - 1
        len = byte_size(basis)
        start = i * blength
        size = min(blength, len - start)
        if start >= len or size <= 0, do: throw({:rsync_error, 12, "block #{i} is outside the file"})
        _ = rem
        tokens(s, basis, blength, rem, [binary_part(basis, start, size) | acc])
    end
  end

  # Write the new copy beside the old one, then put it in place.
  defp install(s, e, path, data) do
    tmp = Path.join(Path.dirname(path), ".#{Path.basename(path)}.#{System.unique_integer([:positive])}")

    old_mode =
      case File.stat(path) do
        {:ok, %{type: :regular, mode: m}} -> m &&& 0o7777
        _ -> nil
      end

    mode = cond do
      s.opts.perms -> e.mode &&& 0o7777
      old_mode -> old_mode
      true -> e.mode &&& 0o755
    end

    with :ok <- (if writable?(s, path), do: :ok, else: {:error, :eacces}),
         :ok <- File.write(tmp, data),
         :ok <- File.chmod(tmp, mode),
         :ok <- (if s.opts.times, do: File.touch(tmp, e.mtime), else: :ok),
         _ <- (if File.dir?(path), do: File.rm_rf(path)),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, "\"#{e.name}\" could not be written: #{:file.format_error(reason)}"}
    end
  end
end
