defmodule Lepton.SelfTest do
  @moduledoc """
  `lepton-test`: runs the ExUnit suite *inside* Lepton.

  The same test files run on a development machine with `mix test` and in
  the OS from `/usr/share/lepton/test`. Tags:

    * `:native` - needs the real Lepton system (PID 1, /proc, drivers);
      excluded when not running natively
    * `:network` - needs internet access; included automatically when the
      network is up (DHCP lease + DNS), or with `--include network`
    * `:dotfiles` - needs the user's dotfiles installed in `$HOME`
    * `:docs` - checks the documentation generator (development machine only)

  Options: `--only TAG`, `--include TAG`, `--exclude TAG`, `--seed N`,
  `-v` (print each test name), plus test file paths.
  """

  alias Lepton.Ctx

  def test_dir do
    if Lepton.Sys.native?(), do: "/usr/share/lepton/test", else: Path.join(File.cwd!(), "test")
  end

  def run(args, ctx) do
    {opts, files} = parse(args)
    files = if files == [], do: Path.wildcard(Path.join(test_dir(), "**/*_test.exs")) |> Enum.sort(), else: Enum.map(files, &Ctx.path(ctx, &1))

    if files == [] do
      Lepton.IO.err(ctx, "lepton-test: no test files found in #{test_dir()}")
      1
    else
      run_files(files, opts, ctx)
    end
  end

  defp parse(args), do: parse(args, %{include: [], exclude: [], only: [], seed: 0, verbose: false}, [])
  defp parse(["--only", t | rest], o, f), do: parse(rest, %{o | only: o.only ++ [String.to_atom(t)]}, f)
  defp parse(["--include", t | rest], o, f), do: parse(rest, %{o | include: o.include ++ [String.to_atom(t)]}, f)
  defp parse(["--exclude", t | rest], o, f), do: parse(rest, %{o | exclude: o.exclude ++ [String.to_atom(t)]}, f)
  defp parse(["--seed", n | rest], o, f), do: parse(rest, %{o | seed: String.to_integer(n)}, f)
  defp parse(["-v" | rest], o, f), do: parse(rest, %{o | verbose: true}, f)
  defp parse([file | rest], o, f), do: parse(rest, o, f ++ [file])
  defp parse([], o, f), do: {o, f}

  defp run_files(files, opts, ctx) do
    {:ok, _} = Application.ensure_all_started(:ex_unit)
    :persistent_term.put({__MODULE__, :device}, ctx.stdout)
    :persistent_term.put({__MODULE__, :verbose}, opts.verbose)
    :persistent_term.put({__MODULE__, :color}, Lepton.Style.color?(ctx))

    auto_exclude =
      [] ++
        if(Lepton.Sys.native?(), do: [], else: [:native]) ++
        if(network_up?() or :network in opts.include, do: [], else: [:network]) ++
        if(dotfiles_present?(), do: [], else: [:dotfiles]) ++
        # The documentation generator is build tooling, not in the image.
        if(Code.ensure_loaded?(LeptonBuild.Docs), do: [], else: [:docs])

    exclude = (auto_exclude ++ opts.exclude) -- opts.include
    {include, exclude} = if opts.only != [], do: {opts.only, [:test | exclude]}, else: {opts.include, exclude}

    ExUnit.configure(
      formatters: [Lepton.SelfTest.Formatter],
      exclude: exclude,
      include: include,
      seed: opts.seed,
      max_cases: 1,
      timeout: 120_000,
      autorun: false
    )

    Lepton.IO.puts(ctx, "Lepton self-test: #{length(files)} files from #{test_dir()}; excluding #{inspect(exclude)}")
    Code.put_compiler_option(:ignore_module_conflict, true)

    compiled =
      Enum.reduce_while(files, :ok, fn file, :ok ->
        try do
          Code.compile_file(file)
          {:cont, :ok}
        rescue
          e ->
            Lepton.IO.err(ctx, "could not load #{file}: #{Exception.message(e)}")
            {:halt, :error}
        end
      end)

    case compiled do
      :ok ->
        result = ExUnit.run()
        if result.failures == 0, do: 0, else: 1

      :error ->
        1
    end
  end

  def network_up? do
    Lepton.Net.leases() != %{} and match?({:ok, _}, :inet.getaddr(~c"github.com", :inet))
  catch
    _, _ -> false
  end

  def dotfiles_present?, do: File.exists?(Path.join(Lepton.TestHelpers.dotfiles_home(), ".tmux.conf"))

  @doc "Run the suite with output captured (used by the `lepton.selftest=1` boot option)."
  def run_capture do
    {:ok, dev} = StringIO.open("")
    ctx = %Ctx{cwd: "/root", env: %{"HOME" => "/root", "NO_COLOR" => "1"}, stdout: dev, stderr: dev}
    status = run([], ctx)
    {_, out} = StringIO.contents(dev)
    {out, status}
  end
end

defmodule Lepton.SelfTest.Formatter do
  @moduledoc false
  # An ExUnit formatter that writes to the terminal of whoever ran lepton-test.
  use GenServer

  def init(_opts), do: {:ok, %{tests: 0, failures: 0, excluded: 0, skipped: 0, failed: [], start: System.monotonic_time(:millisecond)}}

  defp out(data), do: IO.write(:persistent_term.get({Lepton.SelfTest, :device}, :stdio), data)
  defp color(code, text), do: if(:persistent_term.get({Lepton.SelfTest, :color}, false), do: "\e[#{code}m#{text}\e[0m", else: text)

  def handle_cast({:test_finished, %ExUnit.Test{state: nil} = t}, st) do
    if :persistent_term.get({Lepton.SelfTest, :verbose}, false), do: out(color("32", "  ✓ ") <> "#{inspect(t.module)} #{t.name}\n"), else: out(color("32", "."))
    {:noreply, %{st | tests: st.tests + 1}}
  end

  def handle_cast({:test_finished, %ExUnit.Test{state: {:excluded, _}}}, st), do: {:noreply, %{st | excluded: st.excluded + 1}}
  def handle_cast({:test_finished, %ExUnit.Test{state: {:skipped, _}}}, st), do: (out(color("33", "*")); {:noreply, %{st | skipped: st.skipped + 1}})

  def handle_cast({:test_finished, %ExUnit.Test{state: {kind, failures}} = t}, st) when kind in [:failed, :invalid] do
    out(color("31", "F"))
    {:noreply, %{st | tests: st.tests + 1, failures: st.failures + 1, failed: st.failed ++ [{t, failures}]}}
  end

  def handle_cast({:suite_finished, _times}, st) do
    out("\n\n")

    st.failed
    |> Enum.with_index(1)
    |> Enum.each(fn {{test, failures}, n} ->
      failures = if is_list(failures), do: failures, else: [{:error, failures, []}]
      out(ExUnit.Formatter.format_test_failure(test, failures, n, 100, fn _, msg -> msg end) <> "\n")
    end)

    secs = (System.monotonic_time(:millisecond) - st.start) / 1000
    out("Finished in #{:erlang.float_to_binary(secs, decimals: 1)} seconds\n")
    summary = "#{st.tests} tests, #{st.failures} failures" <> if(st.excluded > 0, do: " (#{st.excluded} excluded)", else: "") <> if(st.skipped > 0, do: ", #{st.skipped} skipped", else: "")
    out(color(if(st.failures == 0, do: "32", else: "31"), summary) <> "\n")
    {:noreply, st}
  end

  def handle_cast(_event, st), do: {:noreply, st}
end

defmodule Lepton.TestHelpers do
  @moduledoc "Helpers shared by the test suite (on the host and inside Lepton)."

  def tmp_dir(name \\ "t") do
    base = if Lepton.Sys.native?(), do: "/tmp", else: System.tmp_dir!()
    dir = Path.join(base, "lepton-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end

  @doc """
  Run a shell command line; returns {stdout, status}. Colour is off unless
  `color: true` (colour paths differ, so test them too).
  """
  def sh(src, opts \\ []) do
    env = Map.merge(%{"HOME" => opts[:home] || dotfiles_home(), "NO_COLOR" => "1", "PATH" => "/bin"}, Map.new(opts[:env] || %{}))
    env = if opts[:color], do: Map.delete(env, "NO_COLOR"), else: env
    # stderr is discarded unless LEPTON_TEST_STDERR is set (debugging).
    sink = if System.get_env("LEPTON_TEST_STDERR"), do: Process.group_leader(), else: elem(StringIO.open(""), 1)
    Lepton.Shell.run_capture(src, cwd: opts[:cwd] || tmp_dir("sh"), env: env, stdin: opts[:stdin], stderr: opts[:stderr] || sink)
  end

  @doc """
  A home directory containing the user's dotfiles: `/root` inside Lepton,
  or a temporary copy laid out from `./dotfiles` on a development machine.
  """
  def dotfiles_home do
    cond do
      Lepton.Sys.native?() ->
        "/root"

      home = :persistent_term.get({__MODULE__, :home}, nil) ->
        home

      true ->
        repo = Path.join(File.cwd!(), "dotfiles/topics")
        home = Path.join(System.tmp_dir!(), "lepton-home-#{System.unique_integer([:positive])}")

        mapping = %{
          ".tmux.conf" => "tmux/tmux.conf",
          ".tmux.linux.conf" => "tmux/tmux.linux.conf",
          ".tmux.osx.conf" => "tmux/tmux.osx.conf",
          ".gitconfig" => "git/gitconfig",
          ".gitignore" => "git/gitignore",
          ".zshrc" => "zsh/zshrc",
          ".spacemacs" => "emacs/spacemacs.el",
          ".spacemacs.d/editing.el" => "emacs/spacemacs-editing.el",
          ".spacemacs.d/keybindings.el" => "emacs/spacemacs-keybindings.el",
          ".config/starship.toml" => "starship/starship.toml",
          ".iex.exs" => "elixir/iex.exs"
        }

        for {dest, src} <- mapping, File.exists?(Path.join(repo, src)) do
          File.mkdir_p!(Path.dirname(Path.join(home, dest)))
          File.cp!(Path.join(repo, src), Path.join(home, dest))
        end

        :persistent_term.put({__MODULE__, :home}, home)
        home
    end
  end
end
