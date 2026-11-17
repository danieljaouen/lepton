defmodule Lepton.TutorialTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  # Every command the tutorial suggests must work as shown, with colour on
  # and the user's dotfiles loaded, just as a new user would run it.
  @tag :dotfiles
  test "every suggested command runs successfully" do
    home = scratch_home()

    for {title, _text, cmd} <- Lepton.Tutorial.lessons(home), cmd != nil, runnable?(cmd) do
      {out, status} =
        Lepton.Shell.run_capture("{ " <> cmd <> "; } 2>&1",
          cwd: home,
          env: %{"HOME" => home, "PATH" => "/bin", "USER" => "root"},
          rc: true
        )

      assert status == 0, "lesson #{inspect(title)}: `#{cmd}` exited #{status}:\n#{out}"
      refute out =~ ~r/: (argument error|command not found)/, "lesson #{inspect(title)}: `#{cmd}`:\n#{out}"
    end
  end

  test "the pipes lesson finds git in the command list" do
    {out, 0} = sh("help | grep -i git | head -5", color: true)
    assert out =~ ~r/^\s+git\s/m
  end

  # Network configuration only exists on a real Lepton system.
  defp runnable?("ip " <> _), do: Lepton.Sys.native?()
  defp runnable?(_), do: true

  # The lessons write to ~/tutorial and create a git repository, so run them
  # in a throwaway home holding just the dotfiles.
  defp scratch_home do
    home = tmp_dir("tutorial-home")
    src = dotfiles_home()

    for f <- ~w(.zshrc .gitconfig .gitignore .tmux.conf .tmux.linux.conf .spacemacs .spacemacs.d .config .iex.exs),
        File.exists?(Path.join(src, f)) do
      File.cp_r!(Path.join(src, f), Path.join(home, f))
    end

    home
  end
end
