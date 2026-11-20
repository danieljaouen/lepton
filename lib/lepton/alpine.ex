defmodule Lepton.Alpine do
  @moduledoc """
  Alpine Linux packages, installed at run time: what Lepton's native apps
  (`Lepton.Apps`) are made of.

  The package index (`APKINDEX`) of Alpine's `main` and `community`
  repositories for aarch64 gives each package's version, size,
  dependencies and what it provides (`so:libfoo.so.1`, `cmd:foo`).
  `resolve/2` follows the dependencies, `install/3` downloads each package
  over HTTPS (the CA bundle verifies the mirror) and unpacks it under a
  directory. A package is gzip-compressed tar (signature, metadata and
  files, one after the other); it is streamed to disk and inflated a
  chunk at a time, so a 100 MB package never sits in memory.

  Alpine's packages are built against musl, which Lepton already carries
  (`/usr/lib/ld-musl-aarch64.so.1`); apps find their libraries through
  `LD_LIBRARY_PATH`.
  """

  import Bitwise

  @mirror "https://dl-cdn.alpinelinux.org/alpine"
  @branch "v3.24"
  @repos ~w(main community)
  @arch "aarch64"

  defmodule Pkg do
    @moduledoc false
    defstruct [:name, :version, :repo, :branch, :size, :installed_size, deps: [], provides: []]
  end

  def branch, do: @branch

  @doc """
  Download and parse the package index of `branch`:
  `%{packages: %{name => Pkg}, provides: %{token => name}}`.
  """
  def index(branch \\ @branch) do
    Enum.reduce_while(@repos, {:ok, %{packages: %{}, provides: %{}}}, fn repo, {:ok, acc} ->
      with {:ok, tgz} <- get("#{@mirror}/#{branch}/#{repo}/#{@arch}/APKINDEX.tar.gz"),
           {:ok, text} <- tar_member(:zlib.gunzip(tgz), "APKINDEX") do
        {:cont, {:ok, merge(acc, parse_index(text, repo, branch))}}
      else
        err -> {:halt, err}
      end
    end)
  end

  defp merge(acc, pkgs) do
    Enum.reduce(pkgs, acc, fn pkg, acc ->
      provides = Enum.reduce(pkg.provides, acc.provides, &Map.put_new(&2, &1, pkg.name))
      %{acc | packages: Map.put_new(acc.packages, pkg.name, pkg), provides: provides}
    end)
  end

  @doc """
  Pin packages to other branches: `pins` is `%{name => branch}`; each
  pinned package is taken from that branch's index.
  """
  def pin(index, pins) do
    Enum.reduce_while(pins, {:ok, index}, fn {name, branch}, {:ok, index} ->
      with {:ok, other} <- index(branch),
           %Pkg{} = pkg <- other.packages[name] || {:error, {:unresolved, name}} do
        {:cont, {:ok, put_in(index.packages[name], pkg)}}
      else
        err -> {:halt, err}
      end
    end)
  end

  @doc "Parse an `APKINDEX` text."
  def parse_index(text, repo, branch \\ @branch) do
    text
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn block ->
      fields =
        for line <- String.split(block, "\n"), match?(<<_, ?:, _::binary>>, line), reduce: %{} do
          acc -> Map.put_new(acc, binary_part(line, 0, 1), binary_part(line, 2, byte_size(line) - 2))
        end

      %Pkg{
        name: fields["P"],
        version: fields["V"],
        repo: repo,
        branch: branch,
        size: String.to_integer(fields["S"] || "0"),
        installed_size: String.to_integer(fields["I"] || "0"),
        deps: String.split(fields["D"] || ""),
        provides: (fields["p"] || "") |> String.split() |> Enum.map(&(&1 |> String.split("=") |> hd()))
      }
    end)
    |> Enum.filter(& &1.name)
  end

  @doc """
  The packages `roots` need, following dependencies but not into
  packages `exclude` matches (a regex). Returns `{:ok, [Pkg]}` or
  `{:error, {:unresolved, dep}}`.
  """
  def resolve(index, roots, exclude \\ ~r/^$/) do
    walk(index, roots, exclude, MapSet.new(), [])
  end

  defp walk(_index, [], _exclude, _seen, acc), do: {:ok, Enum.reverse(acc)}

  defp walk(index, [dep | rest], exclude, seen, acc) do
    name = dep |> String.replace(~r/[<>=~].*$/, "")

    cond do
      String.starts_with?(dep, "!") ->
        walk(index, rest, exclude, seen, acc)

      true ->
        case Map.get(index.packages, name) || Map.get(index.packages, Map.get(index.provides, name)) do
          nil ->
            {:error, {:unresolved, dep}}

          pkg ->
            if MapSet.member?(seen, pkg.name) or Regex.match?(exclude, pkg.name),
              do: walk(index, rest, exclude, seen, acc),
              else: walk(index, pkg.deps ++ rest, exclude, MapSet.put(seen, pkg.name), [pkg | acc])
        end
    end
  end

  @doc """
  Download `pkg` and unpack its files under `root`. `progress` is called
  with the bytes downloaded so far.
  """
  def install(%Pkg{} = pkg, root, progress \\ fn _ -> :ok end) do
    url = "#{@mirror}/#{pkg.branch || @branch}/#{pkg.repo}/#{@arch}/#{pkg.name}-#{pkg.version}.apk"
    tmp = Path.join(root, ".download-#{pkg.name}.apk")
    File.mkdir_p!(root)

    try do
      with :ok <- download(url, tmp, progress) do
        extract(tmp, root)
      end
    after
      File.rm(tmp)
    end
  end

  # -- HTTP -----------------------------------------------------------------------------------------

  defp get(url) do
    :inets.start()
    :ssl.start()

    case :httpc.request(:get, {String.to_charlist(url), [{~c"user-agent", ~c"lepton-apps/0.1"}]}, http_opts(), [body_format: :binary], Lepton.Proxy.httpc_profile(url)) do
      {:ok, {{_, 200, _}, _, body}} -> {:ok, body}
      {:ok, {{_, code, _}, _, _}} -> {:error, {:http, code, url}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp http_opts, do: [ssl: Lepton.Git.Remote.ssl_opts([]), timeout: 600_000, connect_timeout: 30_000, autoredirect: true]

  defp download(url, path, progress) do
    :inets.start()
    :ssl.start()
    {:ok, f} = :file.open(String.to_charlist(path), [:raw, :binary, :write])

    try do
      {:ok, ref} = :httpc.request(:get, {String.to_charlist(url), [{~c"user-agent", ~c"lepton-apps/0.1"}]}, http_opts(), [sync: false, stream: :self], Lepton.Proxy.httpc_profile(url))
      receive_body(ref, f, 0, progress, url)
    after
      :file.close(f)
    end
  end

  defp receive_body(ref, f, n, progress, url) do
    receive do
      {:http, {^ref, :stream_start, _headers}} ->
        receive_body(ref, f, n, progress, url)

      {:http, {^ref, :stream, chunk}} ->
        :ok = :file.write(f, chunk)
        n = n + byte_size(chunk)
        progress.(n)
        receive_body(ref, f, n, progress, url)

      {:http, {^ref, :stream_end, _headers}} ->
        :ok

      {:http, {^ref, {{_, code, _}, _, _}}} ->
        {:error, {:http, code, url}}

      {:http, {^ref, {:error, reason}}} ->
        {:error, reason}
    after
      120_000 -> {:error, :timeout}
    end
  end

  # -- unpacking ------------------------------------------------------------------------------------

  @doc "Unpack an `.apk` (or any gzip-compressed tar stream, members back to back) under `root`."
  def extract(apk, root) do
    z = :zlib.open()
    # :reset starts the next gzip member where one ends (an apk is three).
    :ok = :zlib.inflateInit(z, 31, :reset)
    {:ok, f} = :file.open(String.to_charlist(apk), [:raw, :binary, :read, :read_ahead])

    try do
      st = read_loop(f, z, %{buf: "", mode: :header, root: root, pax: %{}, links: []})
      # Hard links name files unpacked earlier: copy them now.
      for {path, target} <- Enum.reverse(st.links), do: File.cp(Path.join(root, target), Path.join(root, path))
      :ok
    after
      :file.close(f)
      :zlib.close(z)
    end
  end

  defp read_loop(f, z, st) do
    case :file.read(f, 1 <<< 20) do
      {:ok, chunk} -> read_loop(f, z, untar(%{st | buf: st.buf <> IO.iodata_to_binary(:zlib.inflate(z, chunk))}))
      :eof -> st
    end
  end

  # The tar reader, a state machine over the inflated bytes: 512-byte
  # headers; file data padded to 512; PAX headers carrying long names.
  defp untar(%{mode: :header, buf: <<h::binary-size(512), rest::binary>>} = st), do: untar(header(%{st | buf: rest}, h))

  defp untar(%{mode: {:file, out, left, pad}, buf: buf} = st) when buf != "" do
    take = min(left, byte_size(buf))
    <<part::binary-size(^take), rest::binary>> = buf
    :ok = :file.write(out, part)

    if take == left do
      :file.close(out)
      untar(%{st | buf: rest, mode: {:skip, pad}})
    else
      %{st | buf: rest, mode: {:file, out, left - take, pad}}
    end
  end

  defp untar(%{mode: {:pax, acc, left, pad}, buf: buf} = st) when buf != "" do
    take = min(left, byte_size(buf))
    <<part::binary-size(^take), rest::binary>> = buf

    if take == left,
      do: untar(%{st | buf: rest, pax: parse_pax(acc <> part), mode: {:skip, pad}}),
      else: %{st | buf: rest, mode: {:pax, acc <> part, left - take, pad}}
  end

  defp untar(%{mode: {:skip, 0}} = st), do: untar(%{st | mode: :header})

  defp untar(%{mode: {:skip, n}, buf: buf} = st) when buf != "" do
    take = min(n, byte_size(buf))
    <<_::binary-size(^take), rest::binary>> = buf
    untar(%{st | buf: rest, mode: {:skip, n - take}})
  end

  defp untar(st), do: st

  # End-of-archive blocks: the next archive (gzip member) follows.
  defp header(st, <<0::size(512 * 8)>>), do: st

  defp header(st, h) do
    <<name::binary-size(100), mode::binary-size(8), _ids::binary-size(16), size::binary-size(12), _mtime::binary-size(12),
      _sum::binary-size(8), type, link::binary-size(100), _magic::binary-size(8), _names::binary-size(64),
      _dev::binary-size(16), prefix::binary-size(155), _::binary>> = h

    size = octal(size)
    pad = rem(512 - rem(size, 512), 512)
    prefix = cstr(prefix)
    path = st.pax["path"] || if(prefix == "", do: cstr(name), else: prefix <> "/" <> cstr(name))
    path = path |> String.trim_leading("./") |> String.trim_trailing("/")
    link = st.pax["linkpath"] || cstr(link)
    mode = octal(mode) &&& 0o7777
    dest = Path.join(st.root, path)
    # Package metadata (.PKGINFO, .SIGN.*, install scripts) is not unpacked.
    meta? = String.starts_with?(path, ".") and not String.contains?(path, "/")
    skip = %{st | pax: %{}, mode: {:skip, size + pad}}
    st = %{st | pax: %{}}

    cond do
      type in [?x, ?g] ->
        if type == ?x, do: %{st | mode: {:pax, "", size, pad}}, else: skip

      meta? or path == "" ->
        skip

      type in [?0, 0, ?7] ->
        File.mkdir_p!(Path.dirname(dest))
        File.rm(dest)
        {:ok, out} = :file.open(String.to_charlist(dest), [:raw, :binary, :write])
        File.chmod(dest, mode)

        if size == 0 do
          :file.close(out)
          %{st | mode: {:skip, pad}}
        else
          %{st | mode: {:file, out, size, pad}}
        end

      type == ?5 ->
        File.mkdir_p!(dest)
        File.chmod(dest, mode ||| 0o700)
        skip

      type == ?2 ->
        File.mkdir_p!(Path.dirname(dest))
        File.rm(dest)
        File.ln_s(link, dest)
        skip

      type == ?1 ->
        %{skip | links: [{path, String.trim_leading(link, "./")} | st.links]}

      true ->
        skip
    end
  end

  defp parse_pax(buf) do
    Regex.scan(~r/\d+ ([^=\n]+)=([^\n]*)\n/, buf) |> Map.new(fn [_, k, v] -> {k, v} end)
  end

  defp octal(field) do
    case field |> cstr() |> String.trim() |> Integer.parse(8) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp cstr(field), do: field |> :binary.split(<<0>>) |> hd()

  @doc false
  # One file of an (uncompressed) tar archive in memory.
  def tar_member(tar, name) do
    case tar do
      <<header::binary-size(512), rest::binary>> when header != <<0::size(512 * 8)>> ->
        <<n::binary-size(100), _::binary-size(24), size::binary-size(12), _::binary>> = header
        size = octal(size)
        padded = size + rem(512 - rem(size, 512), 512)
        <<data::binary-size(^size), _::binary>> = rest

        if cstr(n) == name do
          {:ok, data}
        else
          <<_::binary-size(^padded), more::binary>> = rest
          tar_member(more, name)
        end

      <<_::binary-size(512), rest::binary>> ->
        tar_member(rest, name)

      _ ->
        {:error, {:not_found, name}}
    end
  end
end
