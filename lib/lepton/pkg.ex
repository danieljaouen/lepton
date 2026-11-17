defmodule Lepton.Pkg do
  @moduledoc """
  `lpm` - the Lepton package manager, backed by **hex.pm**.

      lpm search QUERY          search hex.pm
      lpm info NAME             describe a package
      lpm install NAME[@REQ]    install (with dependencies), e.g. jason, jason@~>1.4
      lpm install ./DIR         install a local Mix project (lib/**/*.ex)
      lpm list                  installed packages
      lpm remove NAME
      lpm update                reinstall explicitly installed packages at their latest version

  Packages are Hex tarballs: the outer tarball is verified against the
  registry's SHA-256 checksum, sources are compiled *inside Lepton* (Elixir
  with `Kernel.ParallelCompiler`, Erlang with `:compile`, leex/yecc
  grammars generated first) into `/var/lib/lepton/packages/NAME-VSN/ebin`,
  which persists on an installed system and is loaded at every boot.

  A package can add shell commands: any module that `use Lepton.Command`
  is registered when the package loads. Publish such a package on hex.pm
  and `lpm install` makes its commands available immediately.
  """

  alias Lepton.{Ctx, IO, Persist}

  @api "https://hex.pm/api"
  @repo "https://repo.hex.pm"

  def root, do: Persist.state_path("packages")
  defp index_path, do: Path.join(root(), "index.etf")

  def installed do
    case File.read(index_path()) do
      {:ok, bin} -> :erlang.binary_to_term(bin)
      _ -> %{}
    end
  end

  defp save_index(index) do
    File.mkdir_p!(root())
    File.write!(index_path(), :erlang.term_to_binary(index))
  end

  @doc "Add every installed package to the code path and register its commands."
  def load_installed do
    for {_name, pkg} <- installed(), File.dir?(pkg.ebin), do: activate(pkg)
    :ok
  end

  defp activate(pkg) do
    Code.prepend_path(pkg.ebin)

    for file <- Path.wildcard(Path.join(pkg.ebin, "*.beam")) do
      mod = file |> Path.basename(".beam") |> String.to_atom()

      if Code.ensure_loaded?(mod) and function_exported?(mod, :__commands__, 0) do
        Lepton.Commands.register_module(mod)
      end
    end
  end

  # -- CLI --------------------------------------------------------------------------------

  def cli(args, ctx) do
    case args do
      ["search" | q] -> search(ctx, Enum.join(q, " "))
      ["info", name | _] -> info(ctx, name)
      ["install" | specs] when specs != [] -> install_many(ctx, specs)
      [cmd | names] when cmd in ["remove", "uninstall", "rm"] and names != [] -> Enum.each(names, &remove(ctx, &1)); 0
      [cmd | _] when cmd in ["list", "ls"] -> list(ctx)
      ["update" | _] -> update(ctx)
      _ -> IO.puts(ctx, @moduledoc |> String.split("\n") |> Enum.slice(2..10) |> Enum.join("\n")); 0
    end
  end

  defp list(ctx) do
    case installed() do
      m when map_size(m) == 0 -> IO.puts(ctx, "No packages installed. Try: lpm search json")
      m ->
        for {name, p} <- Enum.sort(m) do
          IO.puts(ctx, "#{String.pad_trailing(name, 24)} #{String.pad_trailing(p.version, 10)} #{if p.explicit, do: "", else: "(dependency)"}")
        end
    end

    0
  end

  defp search(ctx, query) do
    case get_json("#{@api}/packages?search=#{URI.encode_www_form(query)}&sort=recent_downloads") do
      {:ok, pkgs} ->
        for p <- Enum.take(pkgs, 20) do
          desc = get_in(p, ["meta", "description"]) || ""
          IO.puts(ctx, "#{String.pad_trailing(p["name"], 24)} #{String.pad_trailing(p["latest_stable_version"] || p["latest_version"] || "", 10)} #{String.slice(desc |> String.replace("\n", " "), 0, 60)}")
        end

        0

      {:error, e} -> IO.err(ctx, "lpm: #{e}"); 1
    end
  end

  defp info(ctx, name) do
    case get_json("#{@api}/packages/#{name}") do
      {:ok, p} ->
        IO.puts(ctx, "\e[1m#{p["name"]}\e[0m #{p["latest_stable_version"]}\n#{get_in(p, ["meta", "description"])}")
        IO.puts(ctx, "licenses: #{Enum.join(get_in(p, ["meta", "licenses"]) || [], ", ")}   downloads: #{get_in(p, ["downloads", "all"])}")
        IO.puts(ctx, "releases: " <> (p["releases"] |> Enum.take(8) |> Enum.map_join(" ", & &1["version"])))
        IO.puts(ctx, "https://hex.pm/packages/#{name}")
        0

      {:error, e} -> IO.err(ctx, "lpm: #{e}"); 1
    end
  end

  defp install_many(ctx, specs) do
    Enum.reduce(specs, 0, fn spec, status ->
      result =
        if String.starts_with?(spec, [".", "/", "~"]) do
          install_local(ctx, Ctx.path(ctx, spec))
        else
          {name, req} = case String.split(spec, "@", parts: 2) do
            [n, r] -> {n, r}
            [n] -> {n, nil}
          end

          install(ctx, name, req, true)
        end

      case result do
        {:ok, _} -> status
        {:error, e} -> IO.err(ctx, "lpm: #{spec}: #{e}"); 1
      end
    end)
  end

  defp update(ctx) do
    explicit = for {name, %{explicit: true, source: :hex}} <- installed(), do: name
    Enum.each(explicit, &remove(ctx, &1, false))
    install_many(ctx, explicit)
  end

  def remove(ctx, name, say \\ true) do
    index = installed()

    case index[name] do
      nil -> if say, do: IO.err(ctx, "lpm: #{name} is not installed")
      pkg ->
        Code.delete_path(pkg.ebin)
        File.rm_rf!(pkg.dir)
        save_index(Map.delete(index, name))
        if say, do: IO.puts(ctx, "removed #{name} #{pkg.version}")
    end

    0
  end

  # -- installing from hex.pm ----------------------------------------------------------------

  @doc "Install `name` matching requirement `req` (nil = latest stable), with dependencies."
  def install(ctx, name, req, explicit) do
    index = installed()

    with {:ok, req_parsed} <- parse_req(req) do
      case index[name] do
        %{version: v} = pkg when req_parsed == nil ->
          if explicit and not pkg.explicit, do: save_index(Map.put(index, name, %{pkg | explicit: true}))
          IO.puts(ctx, "#{name} #{v} is already installed")
          {:ok, pkg}

        %{version: v} = pkg ->
          if Version.match?(v, req_parsed), do: {:ok, pkg}, else: {:error, "#{name} #{v} is installed but #{req} is required (lpm remove #{name} first)"}

        nil ->
          fetch_and_build(ctx, name, req_parsed, explicit)
      end
    end
  end

  defp parse_req(nil), do: {:ok, nil}

  defp parse_req(req) do
    case Version.parse_requirement(req) do
      {:ok, r} -> {:ok, r}
      :error -> {:error, "invalid version requirement #{inspect(req)}"}
    end
  end

  defp fetch_and_build(ctx, name, req, explicit) do
    with {:ok, pkg} <- get_json("#{@api}/packages/#{name}"),
         {:ok, version} <- pick_version(pkg["releases"], req),
         {:ok, release} <- get_json("#{@api}/packages/#{name}/releases/#{version}"),
         :ok <- install_deps(ctx, release["requirements"] || %{}),
         {:ok, tar} <- get("#{@repo}/tarballs/#{name}-#{version}.tar"),
         :ok <- verify(tar, release["checksum"]) do
      IO.puts(ctx, "\e[1;36m==>\e[0m installing #{name} #{version}")
      dir = Path.join(root(), "#{name}-#{version}")
      File.rm_rf!(dir)
      File.mkdir_p!(dir)

      {:ok, files} = :erl_tar.extract({:binary, tar}, [:memory])
      files = Map.new(files, fn {k, v} -> {to_string(k), v} end)
      :ok = :erl_tar.extract({:binary, files["contents.tar.gz"]}, [:compressed, {:cwd, String.to_charlist(dir)}])
      meta = consult(files["metadata.config"])
      app = meta["app"] || name
      deps = for {dep, _} <- release["requirements"] || %{}, do: dep

      build(ctx, %{name: name, version: version, app: app, dir: dir, deps: deps, explicit: explicit, source: :hex, description: meta["description"]})
    end
  end

  defp pick_version(releases, req) do
    versions =
      releases
      |> Enum.map(&Version.parse!(&1["version"]))
      |> Enum.sort(&(Version.compare(&1, &2) == :gt))

    stable = Enum.filter(versions, &(&1.pre == []))

    choice =
      Enum.find(stable, &(req == nil or Version.match?(&1, req))) ||
        Enum.find(versions, &(req == nil or Version.match?(&1, req, allow_pre: true)))

    if choice, do: {:ok, to_string(choice)}, else: {:error, "no release matches the requirement"}
  end

  defp install_deps(ctx, requirements) do
    Enum.reduce_while(requirements, :ok, fn {dep, spec}, :ok ->
      if spec["optional"] do
        {:cont, :ok}
      else
        case install(ctx, dep, spec["requirement"], false) do
          {:ok, _} -> {:cont, :ok}
          {:error, e} -> {:halt, {:error, "dependency #{dep}: #{e}"}}
        end
      end
    end)
  end

  # The registry checksum is the SHA-256 of the whole tarball (tarball v3).
  defp verify(_tar, nil), do: {:error, "registry did not provide a checksum"}

  defp verify(tar, checksum) do
    if Base.encode16(:crypto.hash(:sha256, tar), case: :lower) == String.downcase(checksum),
      do: :ok,
      else: {:error, "checksum mismatch - refusing to install"}
  end

  # -- local projects ---------------------------------------------------------------------------

  def install_local(ctx, path) do
    mix = Path.join(path, "mix.exs")

    if File.exists?(mix) do
      text = File.read!(mix)
      app = case Regex.run(~r/app:\s*:(\w+)/, text) do
        [_, a] -> a
        _ -> Path.basename(path)
      end

      version = case Regex.run(~r/version:\s*"([^"]+)"/, text) do
        [_, v] -> v
        _ -> "0.0.0"
      end

      dir = Path.join(root(), "#{app}-#{version}")
      File.rm_rf!(dir)
      File.mkdir_p!(dir)
      for sub <- ~w(lib src include priv), File.dir?(Path.join(path, sub)), do: File.cp_r!(Path.join(path, sub), Path.join(dir, sub))
      IO.puts(ctx, "\e[1;36m==>\e[0m installing #{app} #{version} from #{path}")
      build(ctx, %{name: app, version: version, app: app, dir: dir, deps: [], explicit: true, source: {:local, path}, description: nil})
    else
      {:error, "#{path} has no mix.exs"}
    end
  end

  # -- building ------------------------------------------------------------------------------------

  defp build(ctx, pkg) do
    ebin = Path.join(pkg.dir, "ebin")
    File.mkdir_p!(ebin)
    dir = pkg.dir

    with :ok <- generate_parsers(dir),
         {:ok, erl_mods} <- compile_erlang(dir, ebin),
         {:ok, ex_mods} <- compile_elixir(dir, ebin) do
      modules = erl_mods ++ ex_mods
      write_app(pkg, ebin, modules)
      pkg = Map.merge(pkg, %{ebin: ebin, modules: modules})
      activate(pkg)
      save_index(Map.put(installed(), pkg.name, Map.drop(pkg, [:modules])))
      cmds = for m <- modules, Code.ensure_loaded?(m), function_exported?(m, :__commands__, 0), c <- m.__commands__(), do: c.name
      IO.puts(ctx, "    #{length(modules)} modules compiled" <> if(cmds == [], do: "", else: "; new commands: " <> Enum.join(cmds, ", ")))
      {:ok, pkg}
    else
      {:error, e} ->
        File.rm_rf!(dir)
        {:error, e}
    end
  end

  defp generate_parsers(dir) do
    for f <- Path.wildcard(Path.join(dir, "src/*.xrl")), do: :leex.file(String.to_charlist(f))
    for f <- Path.wildcard(Path.join(dir, "src/*.yrl")), do: :yecc.file(String.to_charlist(f))
    :ok
  end

  defp compile_erlang(dir, ebin) do
    files = Path.wildcard(Path.join(dir, "src/**/*.erl"))
    opts = [:return_errors, :return_warnings, {:outdir, String.to_charlist(ebin)}, {:i, String.to_charlist(Path.join(dir, "include"))}, {:i, String.to_charlist(Path.join(dir, "src"))}, {:i, String.to_charlist(dir)}]

    # Behaviours and parse transforms must compile first; retry until stable.
    compile_rounds(files, opts, ebin, [], 3)
  end

  defp compile_rounds([], _opts, _ebin, done, _), do: {:ok, done}

  defp compile_rounds(files, opts, ebin, done, rounds) do
    {ok, failed} =
      Enum.reduce(files, {done, []}, fn f, {ok, failed} ->
        case :compile.file(String.to_charlist(f), opts) do
          {:ok, mod, _warnings} ->
            :code.purge(mod)
            :code.load_abs(String.to_charlist(Path.join(ebin, Atom.to_string(mod))))
            {[mod | ok], failed}

          {:error, errors, _} ->
            {ok, [{f, errors} | failed]}
        end
      end)

    cond do
      failed == [] -> {:ok, ok}
      rounds > 1 and length(failed) < length(files) -> compile_rounds(Enum.map(failed, &elem(&1, 0)), opts, ebin, ok, rounds - 1)
      true -> {:error, "Erlang compilation failed: #{inspect(hd(failed), limit: 5)}"}
    end
  end

  defp compile_elixir(dir, ebin) do
    files = Path.wildcard(Path.join(dir, "lib/**/*.ex"))

    if files == [] do
      {:ok, []}
    else
      Code.prepend_path(ebin)

      case Kernel.ParallelCompiler.compile_to_path(files, ebin, return_diagnostics: true) do
        {:ok, mods, _} -> {:ok, mods}
        {:error, errors, _} ->
          first = errors |> List.wrap() |> List.first()
          {:error, "Elixir compilation failed: #{inspect(first, limit: 8)}"}
      end
    end
  end

  defp write_app(pkg, ebin, modules) do
    app = String.to_atom(pkg.app)
    src = Path.wildcard(Path.join(pkg.dir, "src/*.app.src")) |> List.first()

    props =
      case src && :file.consult(String.to_charlist(src)) do
        {:ok, [{:application, _, props}]} -> props
        _ -> [description: String.to_charlist(pkg.description || pkg.name), applications: [:kernel, :stdlib, :elixir, :logger]]
      end

    props = props |> Keyword.put(:vsn, String.to_charlist(pkg.version)) |> Keyword.put(:modules, modules)
    File.write!(Path.join(ebin, "#{app}.app"), :io_lib.format(~c"~p.~n", [{:application, app, props}]))
  end

  # -- helpers ---------------------------------------------------------------------------------------

  defp consult(bin) do
    {:ok, tokens, _} = :erl_scan.string(String.to_charlist(bin))

    tokens
    |> Enum.chunk_while([], fn
      {:dot, _} = t, acc -> {:cont, Enum.reverse([t | acc]), []}
      t, acc -> {:cont, [t | acc]}
    end, fn acc -> {:cont, acc} end)
    |> Enum.reject(&(&1 == []))
    |> Enum.map(fn form -> {:ok, term} = :erl_parse.parse_term(form); term end)
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  rescue
    _ -> %{}
  end

  defp get_json(url) do
    with {:ok, body} <- get(url), do: JSON.decode(body)
  end

  defp get(url) do
    :inets.start()
    :ssl.start()

    case :httpc.request(:get, {String.to_charlist(url), [{~c"user-agent", ~c"lepton-lpm/0.1"}, {~c"accept", ~c"application/json"}]}, [ssl: Lepton.Git.Remote.ssl_opts([]), timeout: 60_000, autoredirect: true], body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} -> {:ok, body}
      {:ok, {{_, 404, _}, _, _}} -> {:error, "not found on hex.pm"}
      {:ok, {{_, code, _}, _, _}} -> {:error, "hex.pm returned HTTP #{code}"}
      {:error, e} -> {:error, "network error: #{inspect(e)}"}
    end
  end
end
