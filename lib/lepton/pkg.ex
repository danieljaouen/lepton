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
      lpm official              official updates for built-in apps (signed list)
      lpm upgrade [APP...]      install/refresh official updates, e.g. lpm upgrade grep
      lpm revert APP            go back to the built-in version of APP

  Packages are Hex tarballs: the outer tarball is verified against the
  registry's SHA-256 checksum, sources are compiled *inside Lepton* (Elixir
  with `Kernel.ParallelCompiler`, Erlang with `:compile`, leex/yecc
  grammars generated first) into `/var/lib/lepton/packages/NAME-VSN/ebin`,
  which persists on an installed system and is loaded at every boot.

  A package can add shell commands: any module that `use Lepton.Command`
  is registered when the package loads. Publish such a package on hex.pm
  and `lpm install` makes its commands available immediately.

  **Protecting the system.** Installing a package runs its code, so only
  install packages you trust. Beyond that, a package can never silently
  take over part of the OS:

    * commands named like a built-in (`grep`, `git`, ...) are skipped -
      only an *official update* may stand in for a built-in, and only
      through `lpm upgrade` (see `Lepton.Official`: a list signed with the
      Lepton key pins the exact package, version and checksum);
    * a package may not define `Lepton.*` modules or any module the
      system already has (Elixir, OTP, Lepton), and package code is placed
      *after* the system's on the code path;
    * only code compiled from the package's sources is used - prebuilt
      `.beam` files in a tarball are discarded.

  Built-ins are never deleted: `lpm revert APP` or `builtin APP` gets them
  back.
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

  # Registers the package's commands; returns the built-in names it was
  # not allowed to take over.
  defp activate(pkg) do
    # Appended: a package can never shadow a system module.
    Code.append_path(pkg.ebin)
    replaces = get_in(pkg, [Access.key(:official, %{}), Access.key(:replaces, [])]) || []

    for file <- Path.wildcard(Path.join(pkg.ebin, "*.beam")),
        mod = file |> Path.basename(".beam") |> String.to_atom(),
        not reserved_module?(mod),
        Code.ensure_loaded?(mod) and function_exported?(mod, :__commands__, 0),
        name <- Lepton.Commands.register_module(mod, replaces),
        uniq: true,
        do: name
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
      ["official" | _] -> official(ctx)
      ["upgrade" | names] -> upgrade(ctx, names)
      ["revert" | names] when names != [] -> revert(ctx, names)
      _ -> IO.puts(ctx, @moduledoc |> String.split("\n") |> Enum.slice(2..13) |> Enum.join("\n")); 0
    end
  end

  defp list(ctx) do
    case installed() do
      m when map_size(m) == 0 -> IO.puts(ctx, "No packages installed. Try: lpm search json")
      m ->
        for {name, p} <- Enum.sort(m) do
          note = cond do
            p[:official] -> "(official update for #{Enum.join(p.official.replaces, ", ")})"
            p.explicit -> ""
            true -> "(dependency)"
          end

          IO.puts(ctx, "#{String.pad_trailing(name, 24)} #{String.pad_trailing(p.version, 10)} #{note}")
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
    # Official updates are pinned; `lpm upgrade` manages them.
    explicit = for {name, %{explicit: true, source: :hex} = p} <- installed(), !p[:official], do: name
    Enum.each(explicit, &remove(ctx, &1, false))
    install_many(ctx, explicit)
  end

  def remove(ctx, name, say \\ true) do
    index = installed()

    case index[name] do
      nil -> if say, do: IO.err(ctx, "lpm: #{name} is not installed")
      pkg ->
        # Unregister its commands (restoring any built-in it stood in for)
        # and unload its code.
        for file <- Path.wildcard(Path.join(pkg.ebin, "*.beam")),
            mod = file |> Path.basename(".beam") |> String.to_atom(),
            not reserved_module?(mod) do
          Lepton.Commands.unregister_module(mod)
          :code.purge(mod)
          :code.delete(mod)
        end

        Code.delete_path(pkg.ebin)
        File.rm_rf!(pkg.dir)
        save_index(Map.delete(index, name))
        if say, do: IO.puts(ctx, "removed #{name} #{pkg.version}")
    end

    0
  end

  # -- installing from hex.pm ----------------------------------------------------------------

  @doc """
  Install `name` matching requirement `req` (nil = latest stable), with
  dependencies. `opts[:pins]` (official updates) maps every allowed package
  to `%{version, checksum}`; anything unpinned is refused.
  """
  def install(ctx, name, req, explicit, opts \\ %{}) do
    index = installed()

    pin = opts[:pins] && opts.pins[name]

    with {:ok, req_parsed} <- parse_req(req) do
      case index[name] do
        %{version: v} when is_map_key(opts, :pins) and (pin == nil or v != pin.version) ->
          {:error, "#{name} #{v} is installed but the official list pins #{if pin, do: pin.version, else: "another version"} (lpm remove #{name} first)"}

        %{} = pkg when is_map_key(opts, :pins) ->
          {:ok, pkg}

        %{version: v} = pkg when req_parsed == nil ->
          if explicit and not pkg.explicit, do: save_index(Map.put(index, name, %{pkg | explicit: true}))
          IO.puts(ctx, "#{name} #{v} is already installed")
          {:ok, pkg}

        %{version: v} = pkg ->
          if Version.match?(v, req_parsed), do: {:ok, pkg}, else: {:error, "#{name} #{v} is installed but #{req} is required (lpm remove #{name} first)"}

        nil ->
          fetch_and_build(ctx, name, req_parsed, explicit, opts)
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

  defp fetch_and_build(ctx, name, req, explicit, opts) do
    with {:ok, pin} <- pinned(opts, name, req),
         {:ok, pkg} <- get_json("#{@api}/packages/#{name}"),
         {:ok, version} <- if(pin, do: {:ok, pin.version}, else: pick_version(pkg["releases"], req)),
         {:ok, release} <- get_json("#{@api}/packages/#{name}/releases/#{version}"),
         :ok <- install_deps(ctx, release["requirements"] || %{}, Map.delete(opts, :official)),
         {:ok, tar} <- get("#{@repo}/tarballs/#{name}-#{version}.tar"),
         :ok <- verify(tar, release["checksum"]),
         :ok <- if(pin, do: verify(tar, pin.checksum), else: :ok) do
      IO.puts(ctx, "\e[1;36m==>\e[0m installing #{name} #{version}" <> if(pin, do: " (pinned by the official list)", else: ""))
      dir = Path.join(root(), "#{name}-#{version}")
      File.rm_rf!(dir)
      File.mkdir_p!(dir)

      {:ok, files} = :erl_tar.extract({:binary, tar}, [:memory])
      files = Map.new(files, fn {k, v} -> {to_string(k), v} end)
      :ok = :erl_tar.extract({:binary, files["contents.tar.gz"]}, [:compressed, {:cwd, String.to_charlist(dir)}])
      # Only code compiled here from source runs: drop any shipped .beam files.
      File.rm_rf!(Path.join(dir, "ebin"))
      meta = consult(files["metadata.config"])
      app = meta["app"] || name
      deps = for {dep, _} <- release["requirements"] || %{}, do: dep

      pkg = %{name: name, version: version, app: app, dir: dir, deps: deps, explicit: explicit, source: :hex, description: meta["description"]}
      build(ctx, if(opts[:official], do: Map.put(pkg, :official, opts.official), else: pkg))
    end
  end

  defp pinned(%{pins: pins}, name, req) do
    case pins[name] do
      nil -> {:error, "#{name} is not pinned by the official list - refusing to install it"}
      pin -> if req == nil or Version.match?(pin.version, req), do: {:ok, pin}, else: {:error, "pinned #{name} #{pin.version} does not satisfy #{inspect(req)}"}
    end
  end

  defp pinned(_opts, _name, _req), do: {:ok, nil}

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

  defp install_deps(ctx, requirements, opts) do
    Enum.reduce_while(requirements, :ok, fn {dep, spec}, :ok ->
      if spec["optional"] do
        {:cont, :ok}
      else
        case install(ctx, dep, spec["requirement"], false, opts) do
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
         :ok <- check_sources(dir),
         {:ok, erl_mods} <- compile_erlang(dir, ebin),
         {:ok, ex_mods} <- compile_elixir(dir, ebin),
         :ok <- check_compiled(erl_mods ++ ex_mods) do
      modules = erl_mods ++ ex_mods
      write_app(pkg, ebin, modules)
      pkg = Map.merge(pkg, %{ebin: ebin, modules: modules})
      skipped = activate(pkg)
      save_index(Map.put(installed(), pkg.name, Map.drop(pkg, [:modules])))
      cmds = for m <- modules, Code.ensure_loaded?(m), function_exported?(m, :__commands__, 0), c <- m.__commands__(), c.name not in skipped, do: c.name
      IO.puts(ctx, "    #{length(modules)} modules compiled" <> if(cmds == [], do: "", else: "; commands: " <> Enum.join(cmds, ", ")))

      if skipped != [] do
        IO.puts(ctx, "    \e[33mskipped #{Enum.join(skipped, ", ")}: built-in commands can only be replaced by official updates (lpm official)\e[0m")
      end

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
      Code.append_path(ebin)

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

  # -- protecting system modules --------------------------------------------------------------------

  @doc """
  True for modules a package may not define: Lepton's own namespace and
  any module the system already provides (Elixir, OTP, Lepton).
  """
  def reserved_module?(mod) do
    name = Atom.to_string(mod)

    name in ["Elixir.Lepton", "Elixir.LeptonBuild"] or String.starts_with?(name, ["Elixir.Lepton.", "Elixir.LeptonBuild."]) or
      mod in :erlang.pre_loaded() or system_beam?(mod)
  end

  # A .beam for `mod` in the OS's own libraries (OTP, Elixir, Lepton).
  # Package paths are appended, so the first match is the system's if it
  # has one.
  defp system_beam?(mod) do
    case :code.where_is_file(~c"#{mod}.beam") do
      :non_existing -> false
      path -> String.starts_with?(List.to_string(path), system_dirs())
    end
  end

  defp system_dirs do
    elixir = :code.lib_dir(:elixir) |> List.to_string() |> Path.dirname()
    lepton = :code.lib_dir(:lepton)
    dirs = [List.to_string(:code.root_dir()), elixir] ++ if(is_list(lepton), do: [List.to_string(lepton)], else: [])
    Enum.map(dirs, &(String.trim_trailing(&1, "/") <> "/"))
  end

  # Refuse before compiling: compiling a module loads it, which would
  # replace the running system's copy.
  defp check_sources(dir) do
    elixir =
      for f <- Path.wildcard(Path.join(dir, "lib/**/*.ex")),
          {:ok, ast} <- [Code.string_to_quoted(File.read!(f))],
          mod <- defined_modules(ast, nil),
          do: mod

    erlang =
      for f <- Path.wildcard(Path.join(dir, "src/**/*.erl")),
          [_, m] <- [Regex.run(~r/^-module\(\s*'?([a-zA-Z0-9_@.]+)'?\s*\)/m, File.read!(f))],
          do: String.to_atom(m)

    case Enum.filter(elixir ++ erlang, &reserved_module?/1) do
      [] -> :ok
      bad -> {:error, "refusing to install: it defines system modules (#{bad |> Enum.uniq() |> Enum.map_join(", ", &inspect/1)})"}
    end
  end

  # After compiling (catches dynamically named modules): undo and refuse.
  defp check_compiled(mods) do
    case Enum.filter(mods, &(String.starts_with?(Atom.to_string(&1), ["Elixir.Lepton.", "Elixir.LeptonBuild."]) or system_beam?(&1))) do
      [] ->
        :ok

      bad ->
        for m <- bad, do: (:code.purge(m); :code.load_file(m))
        {:error, "refusing to install: it defines system modules (#{Enum.map_join(bad, ", ", &inspect/1)})"}
    end
  end

  @doc false
  def defined_modules({:defmodule, _, [{:__aliases__, _, parts}, body]}, parent) do
    mod =
      case parts do
        [{:__MODULE__, _, _} | rest] when parent != nil -> Module.concat([parent | rest])
        _ -> if Enum.all?(parts, &is_atom/1), do: Module.concat(if(parent, do: [parent | parts], else: parts))
      end

    if mod, do: [mod | defined_modules(body, mod)], else: defined_modules(body, parent)
  end

  def defined_modules(tuple, parent) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> defined_modules(parent)
  def defined_modules(list, parent) when is_list(list), do: Enum.flat_map(list, &defined_modules(&1, parent))
  def defined_modules(_, _), do: []

  # -- official updates for built-in apps ------------------------------------------------------------

  defp with_list(ctx, fun) do
    case Lepton.Official.fetch() do
      {:ok, manifest} ->
        if manifest[:offline], do: IO.err(ctx, "lpm: offline (#{manifest.offline}); using the last verified official list")
        fun.(manifest)

      {:error, e} ->
        IO.err(ctx, "lpm: #{e}")
        1
    end
  end

  defp official(ctx) do
    with_list(ctx, fn manifest ->
      index = installed()

      if manifest[:maintainers] do
        IO.puts(ctx, "Official updates are maintained by the #{manifest.maintainers} organization on hex.pm (https://hex.pm/orgs/#{manifest.maintainers}).")
      end

      if manifest.apps == [] do
        IO.puts(ctx, "No official updates yet (list ##{manifest.serial}, #{manifest.issued}). Built-in apps are current.")
      end

      for a <- manifest.apps do
        state =
          case index[a.package] do
            %{version: v, official: _} when v == a.version -> "\e[32minstalled\e[0m"
            %{version: v, official: _} -> "installed #{v} - run lpm upgrade"
            _ -> "available - lpm upgrade #{hd(a.replaces ++ [a.package])}"
          end

        IO.puts(ctx, "#{String.pad_trailing(Enum.join(a.replaces, ", "), 16)} #{String.pad_trailing(a.package, 20)} #{String.pad_trailing(a.version, 10)} #{state}")
        if a.description, do: IO.puts(ctx, "    " <> a.description)
      end

      0
    end)
  end

  defp upgrade(ctx, names) do
    with_list(ctx, fn manifest ->
      index = installed()

      targets =
        if names == [] do
          # Everything already upgraded; withdrawn updates are reverted.
          for {name, %{official: _}} <- index do
            case Lepton.Official.find(manifest, name) do
              nil -> {:withdrawn, name}
              entry -> {:ok, entry}
            end
          end
        else
          for n <- names, do: (Lepton.Official.find(manifest, n) && {:ok, Lepton.Official.find(manifest, n)}) || {:missing, n}
        end

      if targets == [], do: IO.puts(ctx, "No official updates installed. See: lpm official")

      Enum.reduce(targets, 0, fn
        {:missing, n}, _ ->
          IO.err(ctx, "lpm: #{n} has no official update (see: lpm official)")
          1

        {:withdrawn, name}, status ->
          remove(ctx, name, false)
          IO.puts(ctx, "#{name} was withdrawn from the official list; restored the built-in version")
          status

        {:ok, entry}, status ->
          case install_official(ctx, entry, manifest.serial) do
            :ok -> status
            {:error, e} -> IO.err(ctx, "lpm: #{entry.package}: #{e}"); 1
          end
      end)
    end)
  end

  defp install_official(ctx, entry, serial) do
    case installed()[entry.package] do
      %{version: v, official: _} when v == entry.version ->
        IO.puts(ctx, "#{entry.package} #{v} is up to date")

      _ ->
        # Replace any other installed version (official or not).
        remove(ctx, entry.package, false)
        pins = Map.new([entry | entry.deps], &{&1.package, %{version: &1.version, checksum: &1.checksum}})
        official = %{replaces: entry.replaces, serial: serial}

        case install(ctx, entry.package, "== " <> entry.version, true, %{pins: pins, official: official}) do
          {:ok, _} -> IO.puts(ctx, "#{Enum.join(entry.replaces, ", ")} now #{entry.package} #{entry.version} (built-in kept: lpm revert / builtin #{hd(entry.replaces ++ [""])})")
          {:error, _} = e -> e
        end
    end
    |> case do
      {:error, _} = e -> e
      _ -> :ok
    end
  end

  defp revert(ctx, names) do
    index = installed()

    Enum.reduce(names, 0, fn n, status ->
      found = Enum.find(index, fn {name, p} -> p[:official] && (name == n or n in p.official.replaces) end)

      case found do
        {name, p} ->
          remove(ctx, name, false)
          IO.puts(ctx, "#{Enum.join(p.official.replaces, ", ")}: back to the built-in version")
          status

        nil ->
          IO.err(ctx, "lpm: #{n} is not replaced by an official update")
          1
      end
    end)
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

  @doc false
  def get(url) do
    :inets.start()
    :ssl.start()

    case :httpc.request(:get, {String.to_charlist(url), [{~c"user-agent", ~c"lepton-lpm/0.1"}, {~c"accept", ~c"application/json"}]}, [ssl: Lepton.Git.Remote.ssl_opts([]), timeout: 60_000, autoredirect: true], body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} -> {:ok, body}
      {:ok, {{_, 404, _}, _, _}} -> {:error, "not found on #{URI.parse(url).host}"}
      {:ok, {{_, code, _}, _, _}} -> {:error, "#{URI.parse(url).host} returned HTTP #{code}"}
      {:error, e} -> {:error, "network error: #{inspect(e)}"}
    end
  end
end
