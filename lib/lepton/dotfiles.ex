defmodule Lepton.Dotfiles do
  @moduledoc """
  Reads the user's dotfiles (installed into `$HOME` at build time following
  the dotfiles repo's own `locations/` layout) and turns them into the
  configuration Lepton's programs use:

    * `~/.spacemacs` + `~/.spacemacs.d/*.el` -> editor keymaps, variables,
      theme and layers (`emacs/0`)
    * `~/.tmux.conf` (+ files it sources) -> multiplexer key tables and
      options (`Lepton.Mux.Config`)
    * `~/.gitconfig` (+ includes) -> git aliases, identity, behaviour
      (`Lepton.Git.Config`)
    * `~/.zshrc` -> shell aliases and options (`Lepton.Shell.Zshrc`)
    * `~/.config/starship.toml` -> prompt (`Lepton.Shell.Prompt`)
  """

  alias Lepton.Elisp

  defmodule Emacs do
    @moduledoc "Configuration extracted from Spacemacs files."
    defstruct bindings: [], vars: %{}, aliases: %{}, layers: [], themes: [], functions: [], sources: []
  end

  def home(ctx \\ nil) do
    cond do
      ctx -> Lepton.Ctx.home(ctx)
      Lepton.Sys.native?() -> "/root"
      true -> System.user_home() || "/root"
    end
  end

  @doc "Load Spacemacs configuration from `home`."
  def emacs(home \\ home()) do
    files =
      [Path.join(home, ".spacemacs"), Path.join(home, ".spacemacs.d/init.el")] ++
        Enum.map(~w(editing keybindings languages), &Path.join(home, ".spacemacs.d/#{&1}.el"))

    files
    |> Enum.filter(&File.regular?/1)
    |> Enum.reduce(%Emacs{}, fn path, acc ->
      case Elisp.read_file(path) do
        {:ok, forms} -> forms |> Enum.reduce(acc, &extract(&1, &2, nil)) |> Map.update!(:sources, &(&1 ++ [path]))
        _ -> acc
      end
    end)
    |> then(fn e -> %{e | bindings: Enum.reverse(e.bindings)} end)
  end

  @doc "Parse elisp source directly (used by tests)."
  def emacs_from_string(src) do
    {:ok, forms} = Elisp.read_all(src)
    e = Enum.reduce(forms, %Emacs{}, &extract(&1, &2, nil))
    %{e | bindings: Enum.reverse(e.bindings)}
  end

  # Walk forms, descending into wrappers like with-eval-after-load/progn/defun.
  defp extract([{:sym, "global-set-key"}, key, cmd | _], acc, _ctx) do
    add_binding(acc, "global", Elisp.key(key), cmd)
  end

  defp extract([{:sym, "define-key"}, map, key, cmd | _], acc, _ctx) do
    add_binding(acc, Elisp.name(map), Elisp.key(key), cmd)
  end

  defp extract([{:sym, "evil-define-key"}, state, map | pairs], acc, _ctx) do
    map = "#{Elisp.name(map)}:#{Elisp.name(state)}"

    pairs
    |> Enum.chunk_every(2)
    |> Enum.reduce(acc, fn
      [key, cmd], acc -> add_binding(acc, map, Elisp.key(key), cmd)
      _, acc -> acc
    end)
  end

  defp extract([{:sym, setq} | pairs], acc, _ctx) when setq in ["setq", "setq-default"] do
    pairs
    |> Enum.chunk_every(2)
    |> Enum.reduce(acc, fn
      [{:sym, name}, value], acc -> set_var(acc, name, value)
      _, acc -> acc
    end)
  end

  defp extract([{:sym, "defalias"}, from, to | _], acc, _ctx) do
    %{acc | aliases: Map.put(acc.aliases, Elisp.name(from), Elisp.name(to))}
  end

  defp extract([{:sym, "defun"}, {:sym, name} | body], acc, _ctx) do
    acc = %{acc | functions: acc.functions ++ [name]}
    Enum.reduce(body, acc, &extract(&1, &2, name))
  end

  defp extract([{:sym, wrapper} | body], acc, ctx)
       when wrapper in ["with-eval-after-load", "eval-after-load", "progn", "when", "unless", "add-hook", "let", "let*"] do
    Enum.reduce(body, acc, &extract(&1, &2, ctx))
  end

  defp extract(list, acc, ctx) when is_list(list), do: Enum.reduce(list, acc, &extract_nested(&1, &2, ctx))
  defp extract(_, acc, _ctx), do: acc

  defp extract_nested(form, acc, ctx) when is_list(form), do: extract(form, acc, ctx)
  defp extract_nested(_, acc, _ctx), do: acc

  defp add_binding(acc, nil, _, _), do: acc
  defp add_binding(acc, _, nil, _), do: acc

  defp add_binding(acc, map, key, cmd) do
    command =
      case cmd do
        {:sym, "nil"} -> nil
        other -> Elisp.name(other) || :unsupported
      end

    %{acc | bindings: [{map, key, command} | acc.bindings]}
  end

  defp set_var(acc, "dotspacemacs-configuration-layers", value) do
    layers =
      case value do
        {:quote, items} -> Enum.map(items, fn
            {:sym, n} -> n
            [{:sym, n} | _] -> n
            _ -> nil
          end) |> Enum.reject(&is_nil/1)
        _ -> []
      end

    %{acc | layers: layers}
  end

  defp set_var(acc, "dotspacemacs-themes", {:quote, themes}) do
    %{acc | themes: Enum.map(themes, &Elisp.name/1)}
  end

  defp set_var(acc, name, value) do
    case Elisp.value(value) do
      :unknown -> acc
      v -> %{acc | vars: Map.put(acc.vars, name, v)}
    end
  end

  # -- `keys` command ---------------------------------------------------------------------------

  def describe(ctx, topic) do
    home = home(ctx)
    color = Lepton.Style.color?(ctx)
    h = fn t -> if color, do: "\e[1;36m#{t}\e[0m", else: t end

    if topic in [nil, "editor", "emacs", "spacemacs"] do
      e = emacs(home)
      Lepton.IO.puts(ctx, h.("Editor (le) - Spacemacs bindings from: ") <> Enum.join(Enum.map(e.sources, &Lepton.Ctx.tildify(ctx, &1)), ", "))
      Lepton.IO.puts(ctx, "  theme: #{List.first(e.themes) || "monokai"}   layers: #{Enum.join(e.layers, " ")}")

      for {map, key, cmd} <- e.bindings do
        support = Lepton.Editor.Keymap.supported?(cmd)
        mark = if support, do: "", else: "   (not supported)"
        Lepton.IO.puts(ctx, "  #{String.pad_trailing(map, 34)} #{String.pad_trailing(key, 8)} #{cmd || "<unbound>"}#{mark}")
      end

      Lepton.IO.puts(ctx, "  variables: " <> Enum.map_join(e.vars, ", ", fn {k, v} -> "#{k}=#{inspect(v)}" end))
      Lepton.IO.puts(ctx, "")
    end

    if topic in [nil, "tmux"] do
      cfg = Lepton.Mux.Config.load(home)
      Lepton.IO.puts(ctx, h.("Multiplexer (tmux) - from ~/.tmux.conf") <> "   prefix: #{cfg.options["prefix"]}")

      for {table, binds} <- Enum.sort(cfg.tables), {key, %{cmd: cmd, repeat: r}} <- Enum.sort(binds) do
        Lepton.IO.puts(ctx, "  #{String.pad_trailing(table, 13)} #{String.pad_trailing(key, 8)}#{if r, do: " (repeat)", else: "         "} #{cmd}")
      end

      Lepton.IO.puts(ctx, "")
    end

    if topic in [nil, "git"] do
      cfg = Lepton.Git.Config.global(home)
      Lepton.IO.puts(ctx, h.("git aliases - from ~/.gitconfig"))
      for {k, v} <- Lepton.Git.Config.section(cfg, "alias"), do: Lepton.IO.puts(ctx, "  git #{String.pad_trailing(k, 6)} -> git #{v}")
      Lepton.IO.puts(ctx, "")
    end

    if topic in [nil, "shell", "zsh"] do
      Lepton.IO.puts(ctx, h.("Shell (lsh) - emacs line editing (oh-my-zsh bindkey -e), aliases from ~/.zshrc"))
      Lepton.IO.puts(ctx, "  run `alias` to list aliases, `bindkey` for line-editor keys")
    end

    0
  end
end
