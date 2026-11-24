defmodule Lepton.Vault.CLI do
  @moduledoc "The `vault` command: the password manager (`Lepton.Vault`) in the shell."

  alias Lepton.{Ctx, IO, Style, Vault}

  @usage "vault [status] | init | unlock [-t MIN] | lock | list [-t TAG] [QUERY] | show [-r] ITEM | get ITEM [FIELD] | copy ITEM [FIELD] | otp ITEM | add [-k KIND] [-g] [-n LEN] [-p] TITLE [FIELD=VALUE...] | edit [-g] [-p] ITEM [FIELD=VALUE...] | rm ITEM | generate [-n LEN] [-S] [-c] | audit | passwd | upgrade | import FILE | export [--csv] | gui"

  def usage, do: @usage

  def run(args, ctx) do
    path = Vault.path(Ctx.home(ctx), ctx.env)

    case args do
      [] -> status(ctx, path)
      ["status"] -> status(ctx, path)
      ["init"] -> init(ctx, path)
      ["unlock" | rest] -> unlock_cmd(ctx, path, rest)
      ["lock"] -> lock(ctx, path)
      [ls | rest] when ls in ["list", "ls"] -> list(ctx, path, rest)
      ["show" | rest] -> show(ctx, path, rest)
      ["get", ref] -> get(ctx, path, ref, "password")
      ["get", ref, field] -> get(ctx, path, ref, field)
      ["copy", ref] -> copy(ctx, path, ref, "password")
      ["copy", ref, field] -> copy(ctx, path, ref, field)
      ["otp", ref] -> get(ctx, path, ref, "otp")
      ["add" | rest] -> add(ctx, path, rest)
      ["edit" | rest] -> edit(ctx, path, rest)
      [rm, ref] when rm in ["rm", "delete"] -> rm(ctx, path, ref)
      [gen | rest] when gen in ["generate", "gen"] -> generate(ctx, rest)
      ["audit"] -> audit(ctx, path)
      ["passwd"] -> passwd(ctx, path)
      ["upgrade"] -> upgrade(ctx, path)
      ["import", file] -> import(ctx, path, file)
      ["export" | rest] -> export(ctx, path, rest)
      ["gui"] -> gui(ctx)
      _ -> fail(ctx, "usage: " <> @usage, 2)
    end
  end

  defp fail(ctx, msg, status \\ 1) do
    IO.err(ctx, if(String.starts_with?(msg, "usage:"), do: msg, else: "vault: " <> msg))
    status
  end

  defp failed(ctx, reason), do: fail(ctx, Vault.describe(reason))

  # -- locking ----------------------------------------------------------------------------------

  defp status(ctx, path) do
    cond do
      not Vault.exists?(path) ->
        IO.puts(ctx, "No vault yet: `vault init` makes one (#{path}).")
        1

      Vault.unlocked?(ctx.user, path) ->
        {:ok, items} = Vault.items(ctx.user, path)
        IO.puts(ctx, "#{path}: unlocked, #{length(items)} item#{if length(items) == 1, do: "", else: "s"}")
        kdf_line(ctx, path)
        0

      true ->
        IO.puts(ctx, "#{path}: locked (vault unlock)")
        kdf_line(ctx, path)
        0
    end
  end

  # How the master password becomes the key; an older vault can move on.
  defp kdf_line(ctx, path) do
    with {:ok, bin} <- File.read(path), kdf when kdf != nil <- Vault.kdf(bin) do
      hint = if elem(kdf, 0) == :pbkdf2, do: " (`vault upgrade` moves it to Argon2id)", else: ""
      IO.puts(ctx, "Master password key: #{Vault.describe_kdf(kdf)}#{hint}")
    end
  end

  defp init(ctx, path) do
    if Vault.exists?(path) do
      fail(ctx, "#{path} exists already")
    else
      IO.puts(ctx, "Choose a master password: at least 8 characters. Nothing can recover it, so remember it (or write it down somewhere safe).")

      with pw when is_binary(pw) <- secret(ctx, "Master password: "),
           again when is_binary(again) <- secret(ctx, "Master password again: "),
           true <- pw == again || {:error, "the passwords didn't match"},
           :ok <- Vault.create(ctx.user, path, pw) do
        IO.puts(ctx, "Made #{path}; it is unlocked. `vault add TITLE` adds a login.")
        0
      else
        nil -> 1
        {:error, reason} -> failed(ctx, reason)
      end
    end
  end

  defp unlock_cmd(ctx, path, rest) do
    {opts, _} = Lepton.Args.getopt(rest, "t:")

    case unlock(ctx, path, timeout: Lepton.Args.int(opts, "t", 10)) do
      :ok ->
        IO.puts(ctx, "Unlocked#{if opts["t"] == "0", do: " until `vault lock`", else: " (locks after #{Lepton.Args.int(opts, "t", 10)} minutes idle)"}.")
        0

      {:error, reason} ->
        failed(ctx, reason)
    end
  end

  defp lock(ctx, path) do
    Vault.lock(ctx.user, path)
    IO.puts(ctx, "Locked.")
    0
  end

  # Unlocked already, or ask for the master password (on the terminal, else a line of input).
  defp unlock(ctx, path, opts \\ []) do
    cond do
      not Vault.exists?(path) -> {:error, :missing}
      Vault.unlocked?(ctx.user, path) and opts == [] -> :ok
      pw = secret(ctx, "Master password: ") ->
        # (Argon2id takes a few seconds: say so)
        if ctx.tty, do: IO.write(ctx, "Unlocking...\r")
        result = Vault.unlock(ctx.user, path, pw, opts)
        if ctx.tty, do: IO.write(ctx, "\e[2K\r")
        result
      true -> {:error, :locked}
    end
  end

  defp secret(ctx, prompt) do
    if ctx.tty do
      Lepton.Setup.read_secret(ctx, prompt)
    else
      case IO.read_line(ctx) do
        :eof -> nil
        line -> String.trim_trailing(line, "\n")
      end
    end
  end

  defp with_items(ctx, path, fun) do
    with :ok <- unlock(ctx, path), {:ok, items} <- Vault.items(ctx.user, path) do
      fun.(items)
    else
      {:error, reason} -> failed(ctx, reason)
    end
  end

  defp with_item(ctx, path, ref, fun) do
    with_items(ctx, path, fn items ->
      case Vault.find(items, ref) do
        {:ok, item} -> fun.(item)
        {:error, reason} -> failed(ctx, reason)
      end
    end)
  end

  # -- looking -------------------------------------------------------------------------------------

  defp list(ctx, path, rest) do
    {opts, words} = Lepton.Args.getopt(rest, "t:")

    with_items(ctx, path, fn items ->
      items = Vault.search(items, Enum.join(words, " "))
      items = if tag = opts["t"], do: Enum.filter(items, &(tag in (&1["tags"] || []))), else: items
      color? = Style.color?(ctx)

      if items != [] do
        IO.puts(ctx, Style.apply(row(["ID", "TITLE", "USERNAME", "URL"]), "1", color?))
        for i <- items, do: IO.puts(ctx, row([i["id"], (if i["favorite"], do: "*", else: "") <> i["title"], i["username"] || kind_note(i), i["url"] || ""]))
      end

      0
    end)
  end

  defp kind_note(%{"kind" => "login"}), do: ""
  defp kind_note(%{"kind" => kind}), do: "(#{kind})"

  defp row([id, title, user, url]), do: String.trim_trailing(Enum.join([String.pad_trailing(id, 10), cell(title, 24), cell(user, 22), url], ""))
  defp cell(s, w), do: String.pad_trailing(if(String.length(s) > w - 2, do: String.slice(s, 0, w - 3) <> "~", else: s), w)

  defp show(ctx, path, rest) do
    {opts, refs} = Lepton.Args.getopt(rest, "r")

    case refs do
      [] ->
        fail(ctx, "usage: vault show [-r] ITEM", 2)

      words ->
        with_item(ctx, path, Enum.join(words, " "), fn item ->
          color? = Style.color?(ctx)
          IO.puts(ctx, Style.apply(item["title"], "1", color?) <> Style.apply("  (#{item["kind"]}, #{item["id"]})", "2", color?))

          for f <- Vault.shown_fields(item) do
            IO.puts(ctx, "  " <> String.pad_trailing(f, 11) <> shown(item, f, opts["r"] == true))
          end

          if (item["tags"] || []) != [], do: IO.puts(ctx, "  " <> String.pad_trailing("tags", 11) <> Enum.join(item["tags"], ", "))
          IO.puts(ctx, "  " <> String.pad_trailing("updated", 11) <> String.replace(item["updated"], ~r/T(\d\d:\d\d).*/, " \\1 UTC"))
          if (h = item["history"] || []) != [], do: IO.puts(ctx, "  " <> String.pad_trailing("history", 11) <> "#{length(h)} earlier password#{if length(h) == 1, do: "", else: "s"}")
          0
        end)
    end
  end

  defp shown(item, "otp", reveal?) do
    case Vault.totp(item["otp"]) do
      {:ok, code, left} -> String.slice(code, 0, 3) <> " " <> String.slice(code, 3..-1//1) <> "  (#{left}s)" <> if(reveal?, do: "  " <> item["otp"], else: "")
      _ -> "(not a TOTP secret)"
    end
  end

  defp shown(item, f, reveal?) do
    v = item[f] |> to_string() |> String.replace("\n", "\n" <> String.duplicate(" ", 13))
    if Vault.secret?(f) and not reveal?, do: "********", else: v
  end

  # The raw value, for scripts: `vault get github` prints the password.
  defp value(item, "otp") do
    case Vault.totp(item["otp"] || "") do
      {:ok, code, _} -> {:ok, code}
      _ -> {:error, "#{item["title"]} has no one-time password"}
    end
  end

  defp value(item, field) do
    case item[field] do
      nil -> {:error, "#{item["title"]} has no #{field}"}
      v when is_binary(v) -> {:ok, v}
      v -> {:ok, to_string(v)}
    end
  end

  defp get(ctx, path, ref, field) do
    with_item(ctx, path, ref, fn item ->
      case value(item, field) do
        {:ok, v} ->
          IO.puts(ctx, v)
          0

        {:error, msg} ->
          fail(ctx, msg)
      end
    end)
  end

  defp copy(ctx, path, ref, field) do
    with_item(ctx, path, ref, fn item ->
      case value(item, field) do
        {:ok, v} ->
          Vault.copy(v)
          IO.puts(ctx, "Copied #{item["title"]}'s #{field}; the clipboard is cleared in 45 seconds.")
          0

        {:error, msg} ->
          fail(ctx, msg)
      end
    end)
  end

  # -- changing -------------------------------------------------------------------------------------

  # FIELD=VALUE assignments, and the other words.
  defp assignments(words) do
    {sets, rest} = Enum.split_with(words, &Regex.match?(~r/^[a-z][a-z0-9_-]*=/, &1))
    {Map.new(sets, &(String.split(&1, "=", parts: 2) |> List.to_tuple())), rest}
  end

  defp new_password(ctx, opts) do
    cond do
      opts["g"] -> {:ok, Vault.generate(length: Lepton.Args.int(opts, "n", 20), symbols: !opts["S"])}
      opts["p"] -> with pw when is_binary(pw) <- secret(ctx, "Password: "), do: {:ok, pw}, else: (_ -> {:error, "no password"})
      true -> :none
    end
  end

  defp add(ctx, path, rest) do
    {opts, words} = Lepton.Args.getopt(rest, "k:gn:pS")
    {fields, title} = assignments(words)
    kind = opts["k"] || fields["kind"] || "login"

    cond do
      title == [] and fields["title"] == nil ->
        fail(ctx, "usage: vault add [-k KIND] [-g] [-n LEN] [-p] TITLE [FIELD=VALUE...]", 2)

      kind not in Vault.kinds() ->
        fail(ctx, "a kind is one of #{Enum.join(Vault.kinds(), ", ")}")

      true ->
        with :ok <- unlock(ctx, path) do
          pw =
            case new_password(ctx, opts) do
              # Logins get a generated password unless they say otherwise.
              :none when kind == "login" -> if fields["password"], do: {:ok, fields["password"]}, else: {:ok, Vault.generate()}
              :none -> {:ok, fields["password"]}
              other -> other
            end

          with {:ok, pw} <- pw do
            item = Vault.new_item(fields |> Map.put_new("title", Enum.join(title, " ")) |> Map.put("kind", kind) |> Map.put("password", pw))
            {:ok, _} = Vault.update(ctx.user, path, &{:ok, [item | &1], nil})
            IO.puts(ctx, "Added #{item["title"]} (#{item["id"]})#{if pw && !fields["password"] && !opts["p"], do: " with a generated password: vault copy #{item["id"]}", else: ""}.")
            0
          end
        end
        |> case do
          {:error, reason} -> failed(ctx, reason)
          status -> status
        end
    end
  end

  defp edit(ctx, path, rest) do
    {opts, words} = Lepton.Args.getopt(rest, "gn:pS")
    {fields, ref} = assignments(words)

    if ref == [] or (fields == %{} and !opts["g"] and !opts["p"]) do
      fail(ctx, "usage: vault edit [-g] [-p] ITEM FIELD=VALUE... (FIELD= removes one)", 2)
    else
      with_item(ctx, path, Enum.join(ref, " "), fn item ->
        case new_password(ctx, opts) do
          {:error, reason} ->
            failed(ctx, reason)

          pw ->
            fields = fields |> Map.delete("id") |> then(&if(match?({:ok, _}, pw), do: Map.put(&1, "password", elem(pw, 1)), else: &1))
            {:ok, _} = Vault.update(ctx.user, path, &{:ok, Vault.replace(&1, Vault.set_fields(item, fields)), nil})
            IO.puts(ctx, "Changed #{item["title"]}#{if fields["password"] && item["password"], do: " (the old password is kept in its history)", else: ""}.")
            0
        end
      end)
    end
  end

  defp rm(ctx, path, ref) do
    with_item(ctx, path, ref, fn item ->
      {:ok, _} = Vault.update(ctx.user, path, &{:ok, Vault.delete(&1, item["id"]), nil})
      IO.puts(ctx, "Deleted #{item["title"]}.")
      0
    end)
  end

  defp generate(ctx, rest) do
    {opts, _} = Lepton.Args.getopt(rest, "n:Sc")
    pw = Vault.generate(length: Lepton.Args.int(opts, "n", 20), symbols: !opts["S"])

    if opts["c"] do
      Vault.copy(pw)
      IO.puts(ctx, "Copied a #{String.length(pw)}-character password; the clipboard is cleared in 45 seconds.")
    else
      IO.puts(ctx, pw)
    end

    0
  end

  defp audit(ctx, path) do
    with_items(ctx, path, fn items ->
      case Vault.audit(items) do
        [] ->
          IO.puts(ctx, "No weak or reused passwords in #{length(items)} items.")
          0

        found ->
          for {i, issues} <- found, do: IO.puts(ctx, "#{String.pad_trailing(i["id"], 10)}#{cell(i["title"], 24)}#{Enum.join(issues, ", ")}")
          IO.puts(ctx, "\n#{length(found)} to change: vault edit -g ITEM gives one a new password.")
          1
      end
    end)
  end

  defp passwd(ctx, path) do
    with true <- Vault.exists?(path) || {:error, :missing},
         old when is_binary(old) <- secret(ctx, "Current master password: "),
         new when is_binary(new) <- secret(ctx, "New master password: "),
         again when is_binary(again) <- secret(ctx, "New master password again: "),
         true <- new == again || {:error, "the passwords didn't match"},
         :ok <- Vault.change_password(ctx.user, path, old, new) do
      IO.puts(ctx, "The master password is changed.")
      0
    else
      nil -> 1
      {:error, reason} -> failed(ctx, reason)
    end
  end

  # The key made again with the KDF new vaults get (Argon2id), the master password kept.
  defp upgrade(ctx, path) do
    with true <- Vault.exists?(path) || {:error, :missing},
         {:ok, bin} <- File.read(path),
         true <- Vault.kdf(bin) != Vault.default_kdf() || :current,
         pw when is_binary(pw) <- secret(ctx, "Master password: "),
         _ = IO.puts(ctx, "Upgrading to #{Vault.describe_kdf(Vault.default_kdf())} (this takes a few seconds)..."),
         :ok <- Vault.change_password(ctx.user, path, pw, pw) do
      IO.puts(ctx, "Done: the master password's key is now made with #{Vault.describe_kdf(Vault.default_kdf())}.")
      0
    else
      :current -> IO.puts(ctx, "The vault already uses #{Vault.describe_kdf(Vault.default_kdf())}."); 0
      nil -> 1
      {:error, reason} -> failed(ctx, reason)
    end
  end

  defp import(ctx, path, file) do
    text = if file == "-", do: {:ok, IO.read_all(ctx.stdin)}, else: File.read(Ctx.path(ctx, file))

    with {:ok, text} <- text,
         {:ok, list} <- if(String.starts_with?(String.trim_leading(text), ["{", "["]), do: Vault.from_json(text), else: Vault.from_csv(text)),
         :ok <- unlock(ctx, path) do
      new = Enum.map(list, &Vault.new_item(Map.delete(&1, "id")))
      {:ok, _} = Vault.update(ctx.user, path, &{:ok, &1 ++ new, nil})
      IO.puts(ctx, "Imported #{length(new)} item#{if length(new) == 1, do: "", else: "s"}. Delete #{file} when you no longer need it: it isn't encrypted.")
      0
    else
      {:error, reason} when is_atom(reason) and reason in [:enoent, :eacces, :eisdir] -> fail(ctx, "#{file}: #{:file.format_error(reason)}")
      {:error, reason} -> failed(ctx, reason)
    end
  end

  defp export(ctx, path, rest) do
    with_items(ctx, path, fn items ->
      IO.err(ctx, "vault: the export is not encrypted: keep it safe, and delete it when you are done")
      IO.write(ctx, if("--csv" in rest, do: Vault.to_csv(items), else: Vault.to_json(items)))
      0
    end)
  end

  defp gui(ctx) do
    if ctx.env["WAYLAND_DISPLAY"] do
      case Lepton.Vault.App.start(env: ctx.env, user: ctx.user) do
        {:ok, _} -> 0
        {:error, reason} -> fail(ctx, "can't open the window: #{inspect(reason)}")
      end
    else
      fail(ctx, "the Passwords window needs the desktop (photon, or the classic desktop's Start menu)")
    end
  end
end
