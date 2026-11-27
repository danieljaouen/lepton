defmodule Lepton.Editor.Keymap do
  @moduledoc """
  Keymaps for `le`: Spacemacs defaults overlaid with the bindings found in
  the user's Spacemacs files (see `Lepton.Dotfiles.emacs/1`).

  Maps are `%{[key, ...] => action}` per state. Motions and operators
  (`w`, `3j`, `d2w`, `ci"`, ...) are handled by the evil engine in
  `Lepton.Editor`; the maps here hold commands and multi-key sequences
  such as the `SPC` leader tree.
  """

  alias Lepton.Keys

  # -- elisp command -> editor action ------------------------------------------------------

  @commands %{
    "evil-ex" => :ex,
    "evil-window-left" => :window_left,
    "evil-window-down" => :window_down,
    "evil-window-up" => :window_up,
    "evil-window-right" => :window_right,
    "delete-trailing-whitespace" => :delete_trailing_whitespace,
    "sort-lines" => :sort_lines,
    "align-repeat" => :align_repeat,
    "spacemacs/align-repeat" => :align_repeat,
    "backward-delete-char" => :backspace,
    "delete-backward-char" => :backspace,
    "evil-delete-backward-word" => :delete_backward_word,
    "backward-kill-word" => :delete_backward_word,
    "next-line" => :next_line,
    "previous-line" => :previous_line,
    "evil-next-line" => :next_line,
    "evil-previous-line" => :previous_line,
    "my-tab-command" => :tab_command,
    "indent-for-tab-command" => :indent,
    "yas-expand" => :snippet_expand,
    "evil-ex-search-forward" => :search_forward,
    "evil-ex-search-backward" => :search_backward,
    "evil-ex-search-next" => :search_next,
    "evil-ex-search-previous" => :search_previous,
    "evil-ex-search-word-forward" => :search_word_forward,
    "evil-ex-search-word-backward" => :search_word_backward,
    "company-select-next" => :completion_next,
    "company-select-previous" => :completion_previous,
    "insert-eex-statement" => :insert_eex_statement,
    "insert-eex-expression" => :insert_eex_expression,
    "magit-stash" => :magit_stash,
    "evil-scroll-line-to-top" => :scroll_line_to_top,
    "evil-scroll-line-to-center" => :scroll_line_to_center,
    "evil-scroll-line-to-bottom" => :scroll_line_to_bottom,
    "save-buffer" => :save,
    "evil-normal-state" => :normal_state,
    "evil-escape" => :normal_state,
    "undo" => :undo,
    "comment-line" => :comment_line,
    "org-cycle" => :org_cycle,
    "org-shifttab" => :org_global_cycle,
    "org-global-cycle" => :org_global_cycle,
    "evil-close-folds" => :fold_all,
    "evil-open-folds" => :unfold_all,
    "evil-toggle-fold" => :fold_toggle,
    "evil-close-fold" => :fold_close,
    "evil-open-fold" => :fold_open
  }

  def translate(nil), do: nil
  def translate(:unsupported), do: :unsupported
  def translate(name), do: Map.get(@commands, name, :unsupported)

  def supported?(nil), do: true
  def supported?(name), do: translate(name) != :unsupported

  @doc "Every elisp command name `le` understands (used by M-x)."
  def command_names, do: Map.keys(@commands)

  # Which elisp keymap applies to which editor state(s).
  @maps %{
    "global" => [:insert, :minibuffer],
    "evil-normal-state-map" => [:normal],
    "evil-visual-state-map" => [:visual],
    "evil-insert-state-map" => [:insert],
    "evil-motion-state-map" => [:normal, :visual, :special],
    "evil-evilified-state-map" => [:special],
    "isearch-mode-map" => [:minibuffer],
    "helm-map" => [:minibuffer],
    "helm-find-files-map" => [:minibuffer],
    "company-active-map" => [:completion],
    "Buffer-menu-mode-map" => [:special],
    "magit-mode-map:normal" => [:magit]
  }

  def states_for(map), do: Map.get(@maps, map, [])

  # -- defaults ----------------------------------------------------------------------------

  @leader [
    {"SPC SPC", :mx, "M-x"},
    {"SPC TAB", :last_buffer, "last buffer"},
    {"SPC '", :shell_hint, "shell"},
    {"SPC /", :search_project, "search project"},
    {"SPC ?", :describe_bindings, "show keybindings"},
    {"SPC 1", {:select_window, 1}, "window 1"},
    {"SPC 2", {:select_window, 2}, "window 2"},
    {"SPC 3", {:select_window, 3}, "window 3"},
    {"SPC 4", {:select_window, 4}, "window 4"},
    {"SPC b b", :switch_buffer, "buffers"},
    {"SPC b d", :kill_buffer, "kill buffer"},
    {"SPC b n", :next_buffer, "next buffer"},
    {"SPC b p", :previous_buffer, "previous buffer"},
    {"SPC b s", :scratch_buffer, "scratch"},
    {"SPC b m", :messages_buffer, "messages"},
    {"SPC b R", :revert_buffer, "revert"},
    {"SPC c l", :comment_line, "comment line"},
    {"SPC m c", :typst_compile, "Typst: compile to PDF"},
    {"SPC m p", :typst_preview, "Typst: compile and open the PDF"},
    {"SPC m w", :typst_toggle_watch, "Typst: compile on save (toggle)"},
    {"SPC f f", :find_file, "find file"},
    {"SPC f s", :save, "save"},
    {"SPC f S", :save_all, "save all"},
    {"SPC f r", :recent_files, "recent files"},
    {"SPC f j", :dired_jump, "dired jump"},
    {"SPC f t", :dired_jump, "file tree"},
    {"SPC f y", :show_file_name, "show file name"},
    {"SPC f R", :rename_file, "rename file"},
    {"SPC f D", :delete_file, "delete file"},
    {"SPC f e d", :open_dotfile, "open dotfile"},
    {"SPC g s", :magit_status, "git status"},
    {"SPC g l", :magit_log, "git log"},
    {"SPC g d", :git_diff, "git diff"},
    {"SPC g h", :github_browse, "GitHub: browse repo"},
    {"SPC h d b", :describe_bindings, "describe bindings"},
    {"SPC h d k", :describe_key, "describe key"},
    {"SPC h d v", :describe_variables, "describe variables"},
    {"SPC p f", :project_find_file, "project file"},
    {"SPC p p", :find_file, "switch project"},
    {"SPC p R", :project_replace, "replace in project"},
    {"SPC p %", :project_replace_regexp, "replace regexp in project"},
    {"SPC q q", :quit_all, "quit"},
    {"SPC q Q", :quit_all_force, "kill emacs"},
    {"SPC q s", :save_quit, "save & quit"},
    {"SPC s s", :swoop, "search buffer"},
    {"SPC s p", :search_project, "search project"},
    {"SPC s R", :directory_replace, "replace in directory"},
    {"SPC s %", :directory_replace_regexp, "replace regexp in directory"},
    {"SPC s c", :clear_highlight, "clear highlight"},
    {"SPC t n", :toggle_line_numbers, "line numbers"},
    {"SPC t r", :toggle_relative, "relative numbers"},
    {"SPC t f", :toggle_fill_column, "fill column indicator"},
    {"SPC t l", :toggle_truncate, "truncate lines"},
    {"SPC t w", :toggle_whitespace, "whitespace"},
    {"SPC w /", :split_right, "split right"},
    {"SPC w v", :split_right, "split right"},
    {"SPC w -", :split_below, "split below"},
    {"SPC w s", :split_below, "split below"},
    {"SPC w d", :delete_window, "delete window"},
    {"SPC w m", :maximize_window, "maximize"},
    {"SPC w =", :balance_windows, "balance"},
    {"SPC w w", :other_window, "other window"},
    {"SPC w h", :window_left, "window left"},
    {"SPC w j", :window_down, "window down"},
    {"SPC w k", :window_up, "window up"},
    {"SPC w l", :window_right, "window right"},
    {"SPC x a r", :align_repeat, "align repeat"},
    {"SPC x d w", :delete_trailing_whitespace, "delete trailing whitespace"},
    {"SPC x l s", :sort_lines, "sort lines"},
    {"SPC x u", :downcase_region, "downcase"},
    {"SPC x U", :upcase_region, "upcase"}
  ]

  @labels %{
    ["SPC"] => "leader",
    ["SPC", "b"] => "+buffers",
    ["SPC", "c"] => "+compile/comments",
    ["SPC", "f"] => "+files",
    ["SPC", "f", "e"] => "+emacs/spacemacs",
    ["SPC", "g"] => "+git/versions-control",
    ["SPC", "h"] => "+help",
    ["SPC", "h", "d"] => "+describe",
    ["SPC", "p"] => "+projects",
    ["SPC", "q"] => "+quit",
    ["SPC", "s"] => "+search/symbol",
    ["SPC", "t"] => "+toggles",
    ["SPC", "w"] => "+windows",
    ["SPC", "x"] => "+text",
    ["SPC", "x", "a"] => "+align",
    ["SPC", "x", "d"] => "+delete",
    ["SPC", "x", "l"] => "+lines",
    ["g"] => "+goto",
    ["z"] => "+fold/scroll",
    ["Z"] => "+quit",
    [","] => "+major mode"
  }

  @normal [
    {"i", :insert}, {"a", :append}, {"I", :insert_bol}, {"A", :append_eol},
    {"o", :open_below}, {"O", :open_above}, {"x", :delete_char}, {"X", :delete_char_before},
    {"s", :substitute_char}, {"S", :substitute_line}, {"D", :delete_eol}, {"C", :change_eol},
    {"Y", :yank_line}, {"p", :paste_after}, {"P", :paste_before}, {"u", :undo}, {"C-r", :redo},
    {"J", :join_lines}, {"r", :replace_char}, {"R", :replace_mode}, {"~", :toggle_case},
    {"v", :visual}, {"V", :visual_line}, {"C-v", :visual_block}, {"m", :set_mark}, {"\"", :select_register}, {".", :repeat}, {":", :ex}, {"/", :search_forward},
    {"?", :search_backward}, {"n", :search_next}, {"N", :search_previous},
    {"*", :search_word_forward}, {"#", :search_word_backward}, {"z z", :scroll_line_to_center},
    {"z t", :scroll_line_to_top}, {"z b", :scroll_line_to_bottom}, {"TAB", :org_cycle},
    {"<backtab>", :org_global_cycle}, {"z m", :fold_all}, {"z M", :fold_all}, {"z r", :unfold_all},
    {"z R", :unfold_all}, {"z a", :fold_toggle}, {"z c", :fold_close}, {"z o", :fold_open}, {"Z Z", :save_quit},
    {"Z Q", :quit_force}, {"C-d", :scroll_half_down}, {"C-u", :scroll_half_up},
    {"C-f", :page_down}, {"C-b", :page_up}, {"<next>", :page_down}, {"<prior>", :page_up},
    {"C-e", :scroll_line_down}, {"C-y", :scroll_line_up}, {"C-o", :jump_back}, {"g t", :next_buffer},
    {"g T", :previous_buffer}, {"g d", :goto_definition}, {"g J", :join_lines_raw},
    {"g v", :reselect_visual}, {"g i", :insert_last}, {"C-w h", :window_left},
    {"C-w j", :window_down}, {"C-w k", :window_up}, {"C-w l", :window_right},
    {"C-w v", :split_right}, {"C-w s", :split_below}, {"C-w c", :delete_window},
    {"C-w o", :maximize_window}, {"C-w w", :other_window}, {"C-g", :keyboard_quit},
    {"ESC", :keyboard_quit}, {"C-x C-s", :save}, {"C-x s", :save_all}, {"C-x C-c", :quit_all}, {"M-x", :mx},
    {"C-l", :redraw}
  ]

  @visual [
    {"ESC", :normal_state}, {"C-g", :normal_state}, {"v", :visual_toggle_char}, {"V", :visual_toggle_line},
    {"C-v", :visual_toggle_block}, {"\"", :select_register}, {"o", :visual_other_end}, {"O", :visual_other_side}, {"r", :replace_char}, {"d", :visual_delete}, {"x", :visual_delete}, {"y", :visual_yank},
    {"c", :visual_change}, {"s", :visual_change}, {">", :visual_indent}, {"<", :visual_dedent},
    {"J", :visual_join}, {"u", :visual_downcase}, {"U", :visual_upcase}, {"~", :visual_toggle_case},
    {"p", :visual_paste}, {":", :ex}, {"I", :visual_insert}, {"A", :visual_append}, {"C-l", :redraw}
  ]

  @insert [
    {"ESC", :normal_state}, {"C-g", :normal_state}, {"C-[", :normal_state}, {"RET", :newline}, {"M-RET", :newline},
    {"C-j", :newline}, {"DEL", :backspace}, {"<deletechar>", :delete_forward}, {"TAB", :indent},
    {"<left>", :left}, {"<right>", :right}, {"<up>", :previous_line}, {"<down>", :next_line},
    {"<home>", :bol}, {"<end>", :eol}, {"C-a", :bol}, {"C-e", :eol}, {"C-o", :normal_one},
    {"C-t", :indent_line}, {"C-v", :quoted_insert}, {"C-x C-s", :save}, {"C-x s", :save_all}, {"C-k", :kill_eol},
    {"M-t", :transpose_words}
  ]

  @special [
    {"j", :next_line}, {"k", :previous_line}, {"<down>", :next_line}, {"<up>", :previous_line},
    {"g g", :goto_first}, {"G", :goto_last}, {"q", :quit_special}, {"RET", :special_open},
    {"g r", :special_refresh}, {"TAB", :special_toggle}, {"-", :dired_up},
    {"C-d", :scroll_half_down}, {"C-u", :scroll_half_up}, {"?", :describe_bindings}, {":", :ex},
    {"C-l", :redraw}, {"v", :visual}, {"y y", :yank_line}
  ]

  # Only in magit's status buffer: elsewhere (search results, dired, help,
  # logs) b, w, e and the rest are motions, as in Vim.
  @magit [
    {"s", :magit_stage}, {"u", :magit_unstage}, {"S", :magit_stage_all}, {"U", :magit_unstage_all},
    {"c c", :magit_commit}, {"c a", :magit_amend}, {"P p", :magit_push}, {"F p", :magit_pull},
    {"l l", :magit_log}, {"b b", :magit_checkout}, {"b c", :magit_branch_create}, {"x", :magit_discard}
  ]

  @minibuffer [
    {"RET", :mb_accept}, {"C-j", :mb_accept}, {"ESC", :mb_cancel}, {"C-g", :mb_cancel},
    {"DEL", :backspace}, {"TAB", :mb_complete}, {"C-n", :mb_next}, {"C-p", :mb_previous},
    {"<down>", :mb_next}, {"<up>", :mb_previous}, {"C-u", :mb_kill}, {"<left>", :left},
    {"<right>", :right}, {"C-a", :bol}, {"C-e", :eol}, {"C-k", :kill_eol}
  ]

  @completion [{"TAB", :completion_accept}, {"RET", :completion_accept_or_newline}, {"ESC", :completion_abort}]

  defstruct normal: %{}, visual: %{}, insert: %{}, special: %{}, magit: %{}, minibuffer: %{}, completion: %{},
            labels: @labels, user: [], unsupported: []

  @doc "Build keymaps from defaults plus the user's Spacemacs bindings."
  def build(emacs \\ %Lepton.Dotfiles.Emacs{}) do
    km = %__MODULE__{
      normal: to_map(@normal ++ Enum.map(@leader, fn {k, a, _} -> {k, a} end)),
      visual: to_map(@visual ++ Enum.map(@leader, fn {k, a, _} -> {k, a} end)),
      insert: to_map(@insert),
      special: to_map(@special ++ Enum.map(@leader, fn {k, a, _} -> {k, a} end)),
      magit: to_map(@magit),
      minibuffer: to_map(@minibuffer),
      completion: to_map(@completion),
      labels: Map.merge(@labels, Map.new(@leader, fn {k, _, label} -> {Keys.parse(k), label} end))
    }

    Enum.reduce(emacs.bindings, km, &apply_user/2)
  end

  defp to_map(pairs), do: Map.new(pairs, fn {k, a} -> {Keys.parse(k), a} end)

  defp apply_user({map, key, command}, km) do
    states = states_for(map)
    keys = Keys.parse(key)
    action = translate(command)

    km = %{km | user: km.user ++ [{map, key, command}]}
    km = if action == :unsupported, do: %{km | unsupported: km.unsupported ++ [{map, key, command}]}, else: km

    Enum.reduce(states, km, fn state, km ->
      table = Map.fetch!(km, state)

      table =
        cond do
          action == nil -> Map.drop(table, [keys])
          action == :unsupported -> table
          true -> table |> drop_conflicts(keys) |> Map.put(keys, action)
        end

      Map.put(km, state, table)
    end)
  end

  # Binding "C-y ," makes "C-y" a prefix, so a plain "C-y" binding must go
  # (and vice versa), mirroring Emacs keymap semantics.
  defp drop_conflicts(table, keys) do
    Map.reject(table, fn {k, _} ->
      k != keys and (List.starts_with?(k, keys) or List.starts_with?(keys, k))
    end)
  end

  @doc "Look up `keys` in `table`: {:action, a} | :prefix | :none."
  def lookup(table, keys) do
    case Map.fetch(table, keys) do
      {:ok, action} ->
        {:action, action}

      :error ->
        if Enum.any?(Map.keys(table), &(List.starts_with?(&1, keys) and &1 != keys)), do: :prefix, else: :none
    end
  end

  @doc "Continuations of a prefix, for the which-key popup: [{key, label}]."
  def continuations(km, table, prefix) do
    n = length(prefix)

    table
    |> Map.keys()
    |> Enum.filter(&(List.starts_with?(&1, prefix) and length(&1) > n))
    |> Enum.map(&Enum.take(&1, n + 1))
    |> Enum.uniq()
    |> Enum.map(fn keys ->
      label =
        case Map.fetch(table, keys) do
          {:ok, action} -> Map.get(km.labels, keys) || action_label(action)
          :error -> Map.get(km.labels, keys, "+prefix")
        end

      {List.last(keys), label}
    end)
    |> Enum.sort_by(fn {k, _} -> {String.length(k) > 1, String.downcase(k), k} end)
  end

  def action_label({a, _}), do: action_label(a)
  def action_label(a), do: a |> to_string() |> String.replace("_", "-")
end
