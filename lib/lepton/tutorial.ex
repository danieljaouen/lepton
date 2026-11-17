defmodule Lepton.Tutorial do
  @moduledoc """
  `lepton-tutorial`: a short interactive tour. Each lesson explains a
  topic and suggests a command; type it (or anything else) to run it in a
  real shell, press Enter to move on, or `q` to quit. Key bindings shown
  are read from the user's own dotfiles.

  Offered once after installation; run it again any time.
  """

  alias Lepton.{IO, Persist}

  def run(ctx) do
    lessons = lessons(Lepton.Ctx.home(ctx))
    total = length(lessons)

    result =
      lessons
      |> Enum.with_index(1)
      |> Enum.reduce_while(:ok, fn {{title, text, cmd}, n}, _ ->
        IO.puts(ctx, "\n\e[1;36m[#{n}/#{total}] #{title}\e[0m\n" <> String.trim_trailing(text))
        if lesson(ctx, cmd) == :quit, do: {:halt, :quit}, else: {:cont, :ok}
      end)

    if Persist.installed?(), do: Persist.set_flag("tutorial-done")
    IO.puts(ctx, if(result == :quit, do: "\nTutorial stopped. Run `lepton-tutorial` to resume from the start.", else: "\n\e[1;32mThat's the tour - enjoy Lepton!\e[0m"))
    0
  end

  @doc "The lessons as `{title, text, suggested_command | nil}` (tested by the self-test)."
  def lessons(home) do
    tmux = Lepton.Mux.Config.load(home)
    prefix = tmux.options["prefix"] || "C-b"
    emacs = Lepton.Dotfiles.emacs(home)
    escape = emacs.vars["evil-escape-key-sequence"] || "jk"
    bind = fn key -> case tmux.tables["prefix"][key] do
        nil -> "(unbound)"
        b -> b.cmd
      end end

    [
      {"Welcome",
       """
       Lepton is a Unix-like system whose userland is written in Elixir and
       runs on the BEAM as PID 1. Everything you'll use - the shell, editor,
       multiplexer, git - is configured from your dotfiles.
       """, "neofetch"},
      {"Files and directories",
       """
       The usual tools work: ls, cd, mkdir, cp, mv, rm, cat, tree, find.
       Your zsh aliases are loaded too (try `l`, which is `ls -lah`).
       """, "mkdir -p ~/tutorial && echo 'hello, lepton' > ~/tutorial/hello.txt && l ~/tutorial"},
      {"Pipes, redirection and text tools",
       """
       Programs are BEAM processes connected by pipes. grep, sort, uniq, wc,
       sed, awk, cut, tr, head and tail are all here.
       """, "help | grep -i git | head -5"},
      {"Jobs and processes",
       """
       `&` runs a job in the background, C-z suspends the foreground job,
       `fg`/`bg`/`jobs` manage them, and `ps`, `kill` and `top` work on the
       process table.
       """, "sleep 2 & jobs; ps"},
      {"Services: long-running apps",
       """
       `svc` (also `systemctl`) runs apps in the background for you, like
       systemd: `svc start NAME`, `svc stop NAME`, `svc restart NAME`,
       `svc status NAME` and `svc logs NAME` (-f follows). A crashed service
       is restarted, and `svc enable NAME` starts it at every boot.
       A service is a small unit file; `svc new NAME COMMAND` writes one to
       ~/.config/lepton/services, and `svc` lists them all. Two come with
       Lepton: hello (an example) and httpd, a web server for ~/public.
       """, "svc start hello && sleep 5 && svc status hello && svc stop hello"},
      {"The editor: le",
       """
       `le FILE` (also vim/nvim/emacs/e) is Spacemacs-style: SPC opens the
       leader menu (SPC f s saves, SPC f f finds a file, SPC w / splits,
       SPC g s is magit), `#{escape}` leaves insert state, `;` opens the ex
       prompt, and C-h/j/k/l move between windows - and into tmux panes.
       Try: le ~/tutorial/hello.txt  (quit with SPC q q or ;q)
       """, nil},
      {"The multiplexer: tmux",
       """
       Your prefix is #{prefix}.  #{prefix} v splits side by side
       (#{bind.("v")}), #{prefix} s splits below, #{prefix} h/j/k/l move
       between panes, #{prefix} c opens a window, #{prefix} C-h / C-l move
       between windows, #{prefix} [ starts vi copy mode (v, y), and
       #{prefix} d detaches - `tmux attach` brings it back.
       """, nil},
      {"git and GitHub",
       """
       git understands your ~/.gitconfig aliases (git st, git ci, git gl...).
       `gh auth login` stores a GitHub token; then git push/pull and gh repo,
       gh issue and gh pr work over HTTPS.
       """, "cd ~/tutorial && git init -q && git add . && git ci -q -m 'first commit' && git gl"},
      {"Packages",
       """
       lpm installs Elixir/Erlang packages straight from hex.pm, compiles
       them inside Lepton and loads them (and any Lepton commands they
       define). Try: lpm search json   /   lpm install jason
       Built-in apps get updates only from the signed official list:
       `lpm official` shows them, `lpm upgrade grep` installs one and
       `lpm revert grep` goes back. A package can't take over a built-in.
       """, "lpm list"},
      {"Network",
       """
       The network comes up with DHCP. `ip addr`, `ping`, `curl` and the
       text browser `www` are available; `wifi` shows Wi-Fi status and
       `wifi setup` saves credentials.
       """, "ip addr"},
      {"Help",
       """
       `help` lists commands, `man CMD` describes one, `keys` shows every
       binding loaded from your dotfiles, and `lepton-test` runs the
       self-test suite. Run `lepton-tutorial` to see this again.
       """, "keys tmux | head -8"}
    ]
  end

  defp lesson(ctx, cmd) do
    hint = if cmd, do: "Try: \e[1m#{cmd}\e[0m  (Enter = run it, n = next, q = quit, or type your own)", else: "(Enter = next, q = quit, or type a command)"
    IO.puts(ctx, "\n" <> hint)
    Elixir.IO.write(ctx.stdout, "tutorial> ")

    case IO.read_line(ctx.stdin) do
      :eof -> :quit
      line ->
        case String.trim(line) do
          "q" -> :quit
          "n" -> :next
          "" when cmd != nil -> exec(ctx, cmd); pause(ctx)
          "" -> :next
          other -> exec(ctx, other); pause(ctx)
        end
    end
  end

  defp pause(ctx) do
    Elixir.IO.write(ctx.stdout, "\n(Enter to continue, q to quit) ")

    case IO.read_line(ctx.stdin) do
      :eof -> :quit
      line -> if String.trim(line) == "q", do: :quit, else: :next
    end
  end

  defp exec(ctx, src) do
    Lepton.Shell.run_string(src, cwd: ctx.cwd, env: ctx.env, stdin: ctx.stdin, stdout: ctx.stdout, stderr: ctx.stderr, tty: ctx.tty, rc: true)
  end
end
