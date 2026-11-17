defmodule Lepton.Editor.Ex do
  @moduledoc """
  Ex command line (`:` - or `;`, per the user's keybindings.el).

  Supports `:w`, `:q`, `:wq`, `:x`, `:q!`, `:e FILE`, `:sp`/`:vsp`, `:bn`,
  `:bp`, `:bd`, `:ls`, `:N`, `:s/re/rep/g` with ranges (`%`, `'<,'>`,
  `N,M`), `:sort`, `:noh`, `:set nu|rnu|nonu`, `:!cmd`, `:r !cmd`, and any
  M-x command name, including the user's `defalias`es (e.g. `:sl` ->
  sort-lines).
  """

  alias Lepton.Editor
  alias Lepton.Editor.Buffer

  def run(st, input) do
    input = String.trim(input)
    {range, cmd} = parse_range(st, input)
    exec(st, range, cmd)
  rescue
    e -> Editor.api(st, :error, "E: " <> Exception.message(e))
  end

  defp parse_range(st, input) do
    {l, _} = Editor.api(st, :cursor, nil)
    last = Buffer.line_count(Editor.buf(st)) - 1

    cond do
      String.starts_with?(input, "%") -> {{0, last}, String.slice(input, 1..-1//1)}
      String.starts_with?(input, "'<,'>") ->
        range = case st.last_visual do
          {_, {a, _}, {b, _}} -> {min(a, b), max(a, b)}
          nil -> {l, l}
        end
        {range, String.slice(input, 5..-1//1)}

      m = Regex.run(~r/^(\d+|\.|\$),(\d+|\.|\$)(.*)$/, input) ->
        [_, a, b, rest] = m
        {{addr(a, l, last), addr(b, l, last)}, rest}

      true ->
        {nil, input}
    end
  end

  defp addr(".", l, _), do: l
  defp addr("$", _, last), do: last
  defp addr(n, _, _), do: String.to_integer(n) - 1

  defp exec(st, range, cmd) do
    case cmd do
      "" -> st
      "w" -> Editor.api(st, :save, nil)
      "w " <> path -> write_as(st, path)
      "w!" -> Editor.api(st, :save, nil)
      q when q in ["q", "quit", "clo", "close"] -> Editor.api(st, :quit_window, false)
      q when q in ["q!", "quit!"] -> Editor.api(st, :quit_window, true)
      q when q in ["qa", "qall", "qa!"] -> Editor.do_action(st, if(String.ends_with?(q, "!"), do: :quit_all_force, else: :quit_all))
      q when q in ["wq", "x", "xit", "wq!"] -> st |> Editor.api(:save, nil) |> Editor.api(:quit_window, false)
      q when q in ["wqa", "xa", "wall", "wa"] -> st |> Editor.do_action(:save_all) |> then(&if(q in ["wa", "wall"], do: &1, else: %{&1 | quit: true}))
      "e!" -> Editor.do_action(st, :revert_buffer)
      "e " <> path -> Editor.api(st, :visit, Lepton.Ctx.path(st.ctx, String.trim(path)))
      "e" -> Editor.do_action(st, :find_file)
      s when s in ["sp", "split"] -> Editor.api(st, :split, :below)
      "sp " <> path -> st |> Editor.api(:split, :below) |> Editor.api(:visit, Lepton.Ctx.path(st.ctx, String.trim(path)))
      s when s in ["vs", "vsp", "vsplit"] -> Editor.api(st, :split, :right)
      "vsp " <> path -> st |> Editor.api(:split, :right) |> Editor.api(:visit, Lepton.Ctx.path(st.ctx, String.trim(path)))
      b when b in ["bn", "bnext"] -> Editor.api(st, :cycle, 1)
      b when b in ["bp", "bprev", "bprevious"] -> Editor.api(st, :cycle, -1)
      b when b in ["bd", "bdelete"] -> Editor.api(st, :kill_buffer, Editor.buf(st).id)
      l when l in ["ls", "buffers"] -> Editor.do_action(st, :switch_buffer)
      n when n in ["noh", "nohlsearch"] -> %{st | search: nil}
      "sort" <> _ -> sort(st, range)
      "s" <> rest -> substitute(st, range, rest)
      "set " <> opt -> set(st, opt)
      "r !" <> command -> read_command(st, command)
      "!" <> command -> shell(st, command)
      "$" -> Editor.api(st, :set_cursor, {Buffer.line_count(Editor.buf(st)) - 1, 0})
      "magit" -> Editor.do_action(st, :magit_status)
      "Gstatus" -> Editor.do_action(st, :magit_status)
      "help" -> Editor.do_action(st, :describe_bindings)
      "d" -> delete_range(st, range)
      other ->
        cond do
          Regex.match?(~r/^\d+$/, other) ->
            Editor.api(st, :set_cursor, {String.to_integer(other) - 1, 0})

          true ->
            # Fall back to M-x: elisp names and the user's defaliases (sl -> sort-lines).
            name = Map.get(st.emacs.aliases, other, other)

            case Lepton.Editor.Keymap.translate(name) do
              :unsupported -> Editor.api(st, :error, "E492: Not an editor command: #{other}")
              action -> Editor.do_action(range_visual(st, range), action)
            end
        end
    end
  end

  # Run region commands on an ex range by faking a line-wise selection.
  defp range_visual(st, nil), do: st

  defp range_visual(st, {a, b}) do
    st = Editor.api(st, :set_cursor, {b, 0})
    %{st | mode: :visual_line, visual_start: {a, 0}}
  end

  defp write_as(st, path) do
    path = Lepton.Ctx.path(st.ctx, String.trim(path))
    b = Editor.buf(st)
    b = %{b | path: path, name: Path.basename(path), mode: Buffer.mode_for(path)}
    st |> Editor.api(:put_buf, b) |> Editor.api(:save, nil)
  end

  defp sort(st, range) do
    {a, b} = range || {0, Buffer.line_count(Editor.buf(st)) - 1}
    st = Editor.api(st, :snapshot, nil)
    buf = Editor.buf(st)
    sorted = buf |> Buffer.get_lines(a, b) |> Enum.sort()
    Editor.api(st, :put_buf, Buffer.replace_lines(buf, a, b, sorted))
  end

  defp delete_range(st, range) do
    {l, _} = Editor.api(st, :cursor, nil)
    {a, b} = range || {l, l}
    st = Editor.api(st, :snapshot, nil)
    {buf, _} = Buffer.delete_lines(Editor.buf(st), a, b)
    st |> Editor.api(:put_buf, buf) |> Editor.api(:set_cursor, {a, 0})
  end

  defp substitute(st, range, rest) do
    case rest do
      <<sep::utf8, body::binary>> when sep not in [?\s] ->
        parts = String.split(body, <<sep::utf8>>)
        [pat, rep | more] = parts ++ ["", ""]
        flags = List.first(more) || ""
        {l, _} = Editor.api(st, :cursor, nil)
        {a, b} = range || {l, l}

        flag_opts = if String.contains?(flags, "i"), do: "iu", else: "u"
        re = Regex.compile!(pat, flag_opts)
        rep = String.replace(rep, "&", "\\0")
        st = Editor.api(st, :snapshot, nil)
        buf = Editor.buf(st)
        lines = Buffer.get_lines(buf, a, b)
        new = Enum.map(lines, &Regex.replace(re, &1, rep, global: String.contains?(flags, "g")))
        changed = Enum.zip(lines, new) |> Enum.count(fn {x, y} -> x != y end)

        st
        |> Editor.api(:put_buf, Buffer.replace_lines(buf, a, b, new))
        |> Editor.api(:msg, "#{changed} substitution#{if changed == 1, do: "", else: "s"}")

      _ ->
        Editor.api(st, :error, "E: bad substitute command")
    end
  end

  defp set(st, opt) do
    vars =
      case String.trim(opt) do
        o when o in ["nu", "number"] -> %{"line-numbers" => true, "display-line-numbers-type" => true}
        o when o in ["nonu", "nonumber"] -> %{"line-numbers" => false}
        o when o in ["rnu", "relativenumber"] -> %{"line-numbers" => true, "display-line-numbers-type" => "relative"}
        o when o in ["nornu", "norelativenumber"] -> %{"display-line-numbers-type" => true}
        o when o in ["list"] -> %{"show-whitespace" => true}
        o when o in ["nolist"] -> %{"show-whitespace" => false}
        o when o in ["ic", "ignorecase"] -> %{"case-fold-search" => true}
        o when o in ["noic", "noignorecase"] -> %{"case-fold-search" => false}
        _ -> %{}
      end

    %{st | vars: Map.merge(st.vars, vars), frame: []}
  end

  defp shell(st, command) do
    {out, status} = Lepton.Shell.run_capture(command, cwd: Editor.api(st, :dir, nil), env: st.ctx.env)
    text = String.trim(out)
    if String.contains?(text, "\n"),
      do: Editor.special_buffer(st, "*Shell Command Output*", :help, text),
      else: Editor.api(st, :msg, if(text == "", do: "(exit #{status})", else: text))
  end

  defp read_command(st, command) do
    {out, _} = Lepton.Shell.run_capture(command, cwd: Editor.api(st, :dir, nil), env: st.ctx.env)
    {l, _} = Editor.api(st, :cursor, nil)
    st = Editor.api(st, :snapshot, nil)
    lines = out |> String.trim_trailing("\n") |> String.split("\n")
    Editor.api(st, :put_buf, Buffer.insert_lines(Editor.buf(st), l + 1, lines))
  end
end
