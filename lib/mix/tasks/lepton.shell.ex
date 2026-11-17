defmodule Mix.Tasks.Lepton.Shell do
  @shortdoc "Run the Lepton userland (lsh, le, tmux, git...) in this terminal"
  @moduledoc """
  Hosted mode: runs Lepton's login session on the current terminal of a
  development machine, without booting the OS. Your real `$HOME`
  dotfiles are used.

      mix lepton.shell
  """
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    Lepton.Session.start_hosted()
  end
end
