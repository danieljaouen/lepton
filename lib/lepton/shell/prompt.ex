defmodule Lepton.Shell.Prompt do
  @moduledoc """
  A starship-compatible prompt.

  Reads `~/.config/starship.toml` and renders the same module set and
  format language starship uses (`[text]($style)` groups, `$variables`,
  `\\(` escapes, `$all`), for the modules that make sense here: username,
  hostname, directory, git_branch, git_status, elixir, cmd_duration, jobs,
  line_break and character.

  If `PS1` is set it wins (used by the automated test harness).
  """

  alias Lepton.{Ctx, Style, TOML}

  @all ~w(username hostname directory git_branch git_status elixir cmd_duration jobs line_break character)

  @defaults %{
    "add_newline" => true,
    "username" => %{"format" => "[$user]($style) in ", "style_user" => "yellow bold", "style_root" => "red bold", "show_always" => false, "disabled" => false},
    "hostname" => %{"format" => "[$hostname]($style) in ", "ssh_only" => true, "style" => "bold dimmed green", "disabled" => false},
    "directory" => %{"format" => "[$path]($style)[$read_only]($read_only_style) ", "style" => "bold cyan", "truncation_length" => 3, "truncation_symbol" => "", "home_symbol" => "~", "read_only" => "🔒", "read_only_style" => "red", "truncate_to_repo" => true},
    "git_branch" => %{"format" => "on [$symbol$branch]($style) ", "symbol" => " ", "style" => "bold purple", "disabled" => false},
    "git_status" => %{"format" => "([\\[$all_status$ahead_behind\\]]($style) )", "style" => "bold red", "disabled" => false},
    "elixir" => %{"format" => "via [$symbol($version \\(OTP $otp_version\\) )]($style)", "symbol" => "💧 ", "style" => "bold purple", "disabled" => false},
    "cmd_duration" => %{"format" => "took [$duration]($style) ", "style" => "yellow bold", "min_time" => 2000, "disabled" => false},
    "jobs" => %{"format" => "[$symbol$number]($style) ", "symbol" => "✦", "style" => "bold blue", "disabled" => false},
    "character" => %{"format" => "$symbol ", "success_symbol" => "[❯](bold green)", "error_symbol" => "[❯](bold red)", "disabled" => false}
  }

  def config(ctx) do
    user = TOML.read(Path.join([Ctx.home(ctx), ".config", "starship.toml"]))

    Map.merge(@defaults, user, fn
      _k, d, u when is_map(d) and is_map(u) -> Map.merge(d, u)
      _k, _d, u -> u
    end)
  end

  @doc "Render the primary prompt for `shell`."
  def render(shell) do
    case Map.get(shell.ctx.env, "PS1") do
      nil -> starship(shell)
      ps1 -> expand_ps1(ps1, shell)
    end
  end

  def continuation, do: "∙ "

  defp expand_ps1(ps1, shell) do
    ps1
    |> String.replace("\\u", Map.get(shell.ctx.env, "USER", "root"))
    |> String.replace("\\h", Lepton.Sys.hostname())
    |> String.replace("\\w", Ctx.tildify(shell.ctx, shell.ctx.cwd))
    |> String.replace("\\$", "#")
  end

  defp starship(shell) do
    cfg = config(shell.ctx)
    color? = Style.color?(shell.ctx)
    format = Map.get(cfg, "format", "$all")
    git = Lepton.Git.prompt_info(shell.ctx.cwd)

    vars = fn name -> module(name, cfg, shell, git, color?) end

    body =
      format
      |> String.replace("$all", Enum.map_join(@all, &("$" <> &1)))
      |> render_format(vars, color?)

    newline = if cfg["add_newline"] != false, do: "\n", else: ""
    newline <> body
  end

  # -- modules -----------------------------------------------------------------------

  defp module(name, cfg, shell, git, color?) do
    mod = Map.get(cfg, name, %{})

    if mod["disabled"] == true do
      ""
    else
      render_module(name, mod, shell, git, color?)
    end
  end

  defp render_module("line_break", _mod, _shell, _git, _c), do: "\n"

  defp render_module("username", mod, shell, _git, c) do
    user = Map.get(shell.ctx.env, "USER", "root")

    if mod["show_always"] or user == "root" do
      style = if user == "root", do: mod["style_root"] || mod["style_user"], else: mod["style_user"]
      fmt(mod["format"], %{"user" => user, "style" => style}, c)
    else
      ""
    end
  end

  defp render_module("hostname", mod, shell, _git, c) do
    ssh? = Map.has_key?(shell.ctx.env, "SSH_CONNECTION")

    if mod["ssh_only"] == false or ssh? do
      fmt(mod["format"], %{"hostname" => Lepton.Sys.hostname(), "style" => mod["style"], "ssh_symbol" => ""}, c)
    else
      ""
    end
  end

  defp render_module("directory", mod, shell, git, c) do
    cwd = shell.ctx.cwd
    home = Ctx.home(shell.ctx)
    n = mod["truncation_length"] || 3

    {base, rel} =
      cond do
        git && mod["truncate_to_repo"] != false && String.starts_with?(cwd, git.root) ->
          {Path.basename(git.root), Path.relative_to(cwd, git.root)}

        cwd == home ->
          {mod["home_symbol"] || "~", "."}

        String.starts_with?(cwd, home <> "/") ->
          {mod["home_symbol"] || "~", Path.relative_to(cwd, home)}

        true ->
          {"", String.trim_leading(cwd, "/")}
      end

    parts = Enum.reject([base | Path.split(rel)], &(&1 in ["", "."]))
    parts = if parts == [] and base == "", do: ["/"], else: parts
    parts = if base == "" and parts != ["/"], do: ["/" <> hd(parts) | tl(parts)], else: parts

    path =
      if length(parts) > n do
        (mod["truncation_symbol"] || "") <> Enum.join(Enum.take(parts, -n), "/")
      else
        Enum.join(parts, "/") |> String.replace("//", "/")
      end

    fmt(mod["format"], %{"path" => path, "style" => mod["style"], "read_only" => "", "read_only_style" => mod["read_only_style"]}, c)
  end

  defp render_module("git_branch", _mod, _shell, nil, _c), do: ""

  defp render_module("git_branch", mod, _shell, git, c) do
    fmt(mod["format"], %{"symbol" => symbol(mod["symbol"], ""), "branch" => git.branch, "style" => mod["style"], "remote_branch" => "", "remote_name" => ""}, c)
  end

  defp render_module("git_status", _mod, _shell, nil, _c), do: ""

  defp render_module("git_status", mod, _shell, git, c) do
    status =
      [
        if(git.conflicted > 0, do: "="),
        if(git.deleted > 0, do: "✘"),
        if(git.renamed > 0, do: "»"),
        if(git.modified > 0, do: "!"),
        if(git.staged > 0, do: "+"),
        if(git.untracked > 0, do: "?")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join()

    ab =
      cond do
        git.ahead > 0 and git.behind > 0 -> "⇕"
        git.ahead > 0 -> "⇡"
        git.behind > 0 -> "⇣"
        true -> ""
      end

    if status == "" and ab == "" do
      ""
    else
      fmt(mod["format"], %{"all_status" => status, "ahead_behind" => ab, "style" => mod["style"]}, c)
    end
  end

  defp render_module("elixir", mod, shell, _git, c) do
    if File.exists?(Path.join(shell.ctx.cwd, "mix.exs")) do
      fmt(mod["format"], %{"symbol" => mod["symbol"], "version" => "v" <> System.version(), "otp_version" => System.otp_release(), "style" => mod["style"]}, c)
    else
      ""
    end
  end

  defp render_module("cmd_duration", mod, shell, _git, c) do
    if shell.last_duration >= (mod["min_time"] || 2000) do
      fmt(mod["format"], %{"duration" => duration(shell.last_duration), "style" => mod["style"]}, c)
    else
      ""
    end
  end

  defp render_module("jobs", mod, shell, _git, c) do
    case map_size(shell.jobs) do
      0 -> ""
      n -> fmt(mod["format"], %{"symbol" => mod["symbol"], "number" => to_string(n), "style" => mod["style"]}, c)
    end
  end

  defp render_module("character", mod, shell, _git, c) do
    sym = if shell.status == 0, do: mod["success_symbol"], else: mod["error_symbol"]
    color = if shell.status == 0, do: "bold green", else: "bold red"
    # The user's symbols may be Nerd Font glyphs that were lost or that the
    # Linux console cannot draw; fall back to starship's default arrow.
    sym = symbol(sym, "[#{arrow(shell.ctx)}](#{color})")
    fmt(mod["format"], %{"symbol" => sym}, c)
  end

  defp render_module(_, _, _, _, _), do: ""

  # The Linux console font has no ❯; check the real terminal (inside a
  # multiplexer pane TERM is screen-256color).
  defp arrow(ctx) do
    if "linux" in [Map.get(ctx.env, "TERM"), Map.get(ctx.env, "LEPTON_OUTER_TERM")], do: ">", else: "❯"
  end

  defp symbol(nil, default), do: default
  defp symbol(s, default), do: if(String.trim(s) == "", do: default, else: s)

  defp duration(ms) when ms < 60_000, do: "#{div(ms, 1000)}s"
  defp duration(ms), do: "#{div(ms, 60_000)}m#{div(rem(ms, 60_000), 1000)}s"

  # -- the format language ------------------------------------------------------------------

  defp fmt(nil, _vars, _c), do: ""

  defp fmt(format, vars, color?) do
    render_format(format, fn name -> Map.get(vars, name, "") || "" end, color?)
  end

  @doc false
  def render_format(format, lookup, color?) do
    {out, _} = parse_format(format) |> render_segments(lookup, color?)
    out
  end

  # Returns {text, any_variable_non_empty?}
  defp render_segments(segments, lookup, color?) do
    Enum.reduce(segments, {"", false}, fn seg, {acc, any} ->
      {text, nonempty} = render_segment(seg, lookup, color?)
      {acc <> text, any or nonempty}
    end)
  end

  defp render_segment({:text, t}, _lookup, _c), do: {t, false}

  defp render_segment({:var, name}, lookup, color?) do
    value = lookup.(name)
    # Values may themselves contain format groups (e.g. character symbols).
    value = if String.contains?(value, "]("), do: render_format(value, lookup, color?), else: value
    {value, value != ""}
  end

  defp render_segment({:group, inner, style}, lookup, color?) do
    {text, nonempty} = render_segments(inner, lookup, color?)
    style = if String.starts_with?(style, "$"), do: lookup.(String.trim_leading(style, "$")), else: style
    {Style.apply(text, style, color?), nonempty}
  end

  # (conditional) groups vanish when none of their variables has a value
  defp render_segment({:cond, inner}, lookup, color?) do
    {text, nonempty} = render_segments(inner, lookup, color?)
    if nonempty, do: {text, true}, else: {"", false}
  end

  def parse_format(s), do: s |> String.to_charlist() |> do_parse([]) |> elem(0)

  defp do_parse([], acc), do: {Enum.reverse(acc), []}
  defp do_parse([?\\, c | rest], acc), do: do_parse(rest, push_text(acc, <<c::utf8>>))

  defp do_parse([?[ | rest], acc) do
    {inner, rest} = do_parse_until(rest, ?])

    case rest do
      [?( | rest] ->
        {style, rest} = Enum.split_while(rest, &(&1 != ?)))
        do_parse(Enum.drop(rest, 1), [{:group, inner, List.to_string(style)} | acc])

      _ ->
        do_parse(rest, [{:group, inner, ""} | acc])
    end
  end

  defp do_parse([?( | rest], acc) do
    {inner, rest} = do_parse_until(rest, ?))
    do_parse(rest, [{:cond, inner} | acc])
  end

  defp do_parse([?$ | rest], acc) do
    {name, rest} = Enum.split_while(rest, &(&1 in ?a..?z or &1 in ?A..?Z or &1 in ?0..?9 or &1 == ?_))
    do_parse(rest, [{:var, List.to_string(name)} | acc])
  end

  defp do_parse([c | rest], acc), do: do_parse(rest, push_text(acc, <<c::utf8>>))

  defp do_parse_until(chars, close), do: until(chars, close, [])

  defp until([], _close, acc), do: {Enum.reverse(acc), []}
  defp until([c | rest], c, acc), do: {Enum.reverse(acc), rest}
  defp until([?\\, c | rest], close, acc), do: until(rest, close, push_text(acc, <<c::utf8>>))

  defp until([?[ | _] = chars, close, acc) do
    {[group], rest} = do_parse_one(chars)
    until(rest, close, [group | acc])
  end

  defp until([?( | rest], close, acc) do
    {inner, rest} = until(rest, ?), [])
    until(rest, close, [{:cond, inner} | acc])
  end

  defp until([?$ | rest], close, acc) do
    {name, rest} = Enum.split_while(rest, &(&1 in ?a..?z or &1 in ?A..?Z or &1 in ?0..?9 or &1 == ?_))
    until(rest, close, [{:var, List.to_string(name)} | acc])
  end

  defp until([c | rest], close, acc), do: until(rest, close, push_text(acc, <<c::utf8>>))

  defp do_parse_one([?[ | rest]) do
    {inner, rest} = until(rest, ?], [])

    case rest do
      [?( | rest] ->
        {style, rest} = Enum.split_while(rest, &(&1 != ?)))
        {[{:group, inner, List.to_string(style)}], Enum.drop(rest, 1)}

      _ ->
        {[{:group, inner, ""}], rest}
    end
  end

  defp push_text([{:text, t} | acc], s), do: [{:text, t <> s} | acc]
  defp push_text(acc, s), do: [{:text, s} | acc]
end
