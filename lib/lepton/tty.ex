defmodule Lepton.TTY do
  @moduledoc """
  A terminal device.

  A TTY is an Erlang I/O server, so ordinary `IO.puts/2` and `IO.gets/2`
  work against it, plus a small control API for full-screen programs:

    * `set_mode(tty, :raw)` - keys are delivered verbatim to `read_key/2`
    * `set_mode(tty, :cooked)` - a line discipline with echo, `C-h`/`DEL`,
      `C-w`, `C-u`, `C-d` (EOF) serves `get_line` requests
    * `set_foreground(tty, pid)` - the process notified of `C-c`
      (`{:signal, :int}`) and `C-z` (`{:signal, :tstp}`) in cooked mode

  Output goes to a backend: a device node, the BEAM's own stdio (hosted
  mode) or a multiplexer pane.

  **Window size on serial lines.** A serial console has no winsize ioctl
  and no SIGWINCH, so when the backend cannot report a size the TTY
  watches it itself: while a program has the terminal in raw mode it asks
  the terminal emulator for its size every #{1500} ms (a cursor-position
  report after moving to the far corner, as `resize(1)` does). When the
  answer changes, the size is updated and raw readers receive a
  `{:resize, rows, cols}` key - Lepton's SIGWINCH.
  """

  use GenServer

  alias Lepton.Keys

  defstruct backend: nil,
            mode: :cooked,
            mode_owner: nil,
            pending: <<>>,
            keys: :queue.new(),
            key_waiters: [],
            line: "",
            lines: [],
            eof: false,
            requests: :queue.new(),
            foreground: nil,
            size: {24, 80},
            name: nil,
            term: "xterm-256color",
            cpr_waiter: nil,
            esc_timer: nil,
            until_cont: [],
            auto_probe: false,
            probe_interval: 1500,
            probe_sent: nil,
            muted: nil

  # -- API -----------------------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def start(opts), do: GenServer.start(__MODULE__, opts)

  def set_mode(tty, mode) when mode in [:raw, :cooked], do: GenServer.call(tty, {:set_mode, mode, self()})
  def mode(tty), do: GenServer.call(tty, :mode)

  @doc "Blocks until a key is available. Returns a key, or :timeout."
  def read_key(tty, timeout \\ :infinity) do
    ref = make_ref()
    GenServer.cast(tty, {:want_key, self(), ref})

    receive do
      {:key, ^ref, key} -> key
    after
      timeout ->
        GenServer.cast(tty, {:cancel_key, ref})

        receive do
          {:key, ^ref, key} -> key
        after
          0 -> :timeout
        end
    end
  end

  def write(tty, data), do: GenServer.call(tty, {:write, IO.iodata_to_binary(data)}, :infinity)
  def size(tty), do: GenServer.call(tty, :size)
  def set_size(tty, size), do: GenServer.cast(tty, {:set_size, size})
  def term(tty), do: GenServer.call(tty, :term)
  def name(tty), do: GenServer.call(tty, :name)
  def set_foreground(tty, pid), do: GenServer.call(tty, {:foreground, pid})

  @doc "Feed raw input bytes (used by backends)."
  def input(tty, bytes), do: send(tty, {:tty_input, bytes})

  @doc """
  Ignore input while `owner` lives (or until `unmute/1`). Photon mutes the
  display's console: its keyboard is Photon's then, and the kernel still
  types the same keys into the console.
  """
  def mute(tty, owner), do: GenServer.call(tty, {:mute, owner})
  def unmute(tty), do: GenServer.call(tty, :unmute)

  @doc "The TTY of a console device (`\"/dev/tty1\"`), if it has one."
  def whereis(device), do: Process.whereis(device_name(device))

  defp device_name(device), do: String.to_atom("lepton_tty:" <> device)

  @doc "Ask the terminal for its size with a cursor-position report."
  def probe_size(tty, timeout \\ 300) do
    GenServer.call(tty, {:probe_size, timeout}, timeout + 1000)
  end

  def tty?(pid) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, d} -> Keyword.get(d, :"$lepton_tty", false) == true
      nil -> false
    end
  end

  def tty?(_), do: false

  # -- server ------------------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.put(:"$lepton_tty", true)
    backend = Keyword.fetch!(opts, :backend)
    {mod, arg} = backend
    {:ok, handle} = mod.open(arg, self())
    name = opts[:name] || ""
    if String.starts_with?(name, "/dev/") and Process.whereis(device_name(name)) == nil, do: Process.register(self(), device_name(name))

    reported = mod.size(handle)

    state = %__MODULE__{
      backend: {mod, handle},
      name: opts[:name] || "tty",
      term: opts[:term] || "xterm-256color",
      size: reported || {24, 80},
      # Only terminals that can't report their own size need watching.
      auto_probe: Keyword.get(opts, :auto_probe, reported == nil),
      probe_interval: opts[:probe_interval] || 1500
    }

    if state.auto_probe, do: Process.send_after(self(), :probe_tick, state.probe_interval)
    {:ok, state}
  end

  @impl true
  def handle_call({:set_mode, mode, owner}, _from, state) do
    state = maybe_monitor_owner(state, mode, owner)
    state = %{state | mode: mode}
    state = if mode == :cooked, do: requeue_keys_as_input(state), else: state
    {:reply, :ok, serve(state)}
  end

  def handle_call(:mode, _from, state), do: {:reply, state.mode, state}

  def handle_call({:mute, owner}, _from, state) do
    Process.monitor(owner)
    {:reply, :ok, %{state | muted: owner}}
  end

  def handle_call(:unmute, _from, state), do: {:reply, :ok, %{state | muted: nil}}

  def handle_call({:write, data}, _from, state) do
    out(state, data)
    {:reply, :ok, state}
  end

  def handle_call(:size, _from, state), do: {:reply, state.size, state}
  def handle_call(:term, _from, state), do: {:reply, state.term, state}
  def handle_call(:name, _from, state), do: {:reply, state.name, state}
  def handle_call({:foreground, pid}, _from, state), do: {:reply, :ok, %{state | foreground: pid}}

  def handle_call({:probe_size, timeout}, from, state) do
    out(state, "\e7\e[999;999H\e[6n\e8")
    ref = Process.send_after(self(), {:cpr_timeout, from}, timeout)
    {:noreply, %{state | cpr_waiter: {from, ref}}}
  end

  @impl true
  def handle_cast({:want_key, pid, ref}, state) do
    {:noreply, serve(%{state | key_waiters: state.key_waiters ++ [{pid, ref}]})}
  end

  def handle_cast({:cancel_key, ref}, state) do
    {:noreply, %{state | key_waiters: Enum.reject(state.key_waiters, fn {_, r} -> r == ref end)}}
  end

  # A new size from the backend's side (a window, an SSH client): a
  # full-screen program gets the {:resize, rows, cols} key.
  def handle_cast({:set_size, size}, %{size: size} = state), do: {:noreply, state}

  def handle_cast({:set_size, {rows, cols} = size}, %{mode: :raw} = state) do
    {:noreply, serve(%{state | size: size, keys: :queue.in({:resize, rows, cols}, state.keys)})}
  end

  def handle_cast({:set_size, size}, state), do: {:noreply, %{state | size: size}}

  @impl true
  def handle_info({:tty_input, _bytes}, %{muted: pid} = state) when is_pid(pid), do: {:noreply, state}

  def handle_info({:tty_input, bytes}, state) do
    if state.esc_timer, do: Process.cancel_timer(state.esc_timer)
    {keys, rest} = Keys.decode(state.pending <> bytes)
    state = %{state | pending: rest, esc_timer: nil}
    state = Enum.reduce(keys, state, &handle_key/2)

    state =
      if rest != <<>>,
        do: %{state | esc_timer: Process.send_after(self(), :esc_timeout, 30)},
        else: state

    {:noreply, serve(state)}
  end

  def handle_info(:esc_timeout, state) do
    keys = Keys.flush(state.pending)
    state = Enum.reduce(keys, %{state | pending: <<>>, esc_timer: nil}, &handle_key/2)
    {:noreply, serve(state)}
  end

  def handle_info({:cpr_timeout, from}, %{cpr_waiter: {from, _}} = state) do
    GenServer.reply(from, :error)
    {:noreply, %{state | cpr_waiter: nil}}
  end

  def handle_info({:cpr_timeout, _}, state), do: {:noreply, state}

  def handle_info({:io_request, from, reply_as, request}, state) do
    handle_io(from, reply_as, request, state)
  end

  def handle_info({:DOWN, _ref, :process, pid, _}, %{mode_owner: pid} = state) do
    # A full-screen program died without restoring the terminal.
    out(state, "\e[?1049l\e[?25h\e[0m")
    {:noreply, serve(%{state | mode: :cooked, mode_owner: nil} |> requeue_keys_as_input())}
  end

  def handle_info({:DOWN, _, :process, pid, _}, %{muted: pid} = state), do: {:noreply, %{state | muted: nil}}
  def handle_info({:DOWN, _, :process, _, _}, state), do: {:noreply, state}

  def handle_info({:backend_closed, _}, state), do: {:stop, :normal, state}
  def handle_info(:probe_tick, state) do
    Process.send_after(self(), :probe_tick, state.probe_interval)
    now = System.monotonic_time(:millisecond)
    # Probe only while a full-screen program (or the line editor) owns the
    # terminal, not while an earlier probe may still be answered, and not
    # mid-key (a reply right after a lone ESC would read as M-[...).
    stale? = state.probe_sent == nil or now - state.probe_sent > 3 * state.probe_interval
    idle? = state.cpr_waiter == nil and state.esc_timer == nil and state.pending == <<>>

    if state.mode == :raw and idle? and stale? do
      out(state, "\e7\e[999;999H\e[6n\e8")
      {:noreply, %{state | probe_sent: now}}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- keys ----------------------------------------------------------------------------

  defp handle_key({:cpr, rows, cols}, %{cpr_waiter: {from, ref}} = state) do
    Process.cancel_timer(ref)
    GenServer.reply(from, {:ok, {rows, cols}})
    %{state | cpr_waiter: nil, size: {rows, cols}}
  end

  # Answer to a background size probe: consume it, and on a change notify
  # the raw reader. Implausible sizes (e.g. a modified F-key that looks like
  # a report) are ignored.
  defp handle_key({:cpr, rows, cols}, %{probe_sent: sent} = state) when sent != nil do
    state = %{state | probe_sent: nil}

    cond do
      rows < 4 or cols < 10 -> state
      {rows, cols} == state.size -> state
      state.mode == :raw -> %{state | size: {rows, cols}, keys: :queue.in({:resize, rows, cols}, state.keys)}
      true -> %{state | size: {rows, cols}}
    end
  end

  defp handle_key({:cpr, _, _} = key, %{mode: :raw} = state), do: %{state | keys: :queue.in(key, state.keys)}
  defp handle_key({:cpr, _, _}, state), do: state

  defp handle_key(key, %{mode: :raw} = state), do: %{state | keys: :queue.in(key, state.keys)}

  defp handle_key(key, state) do
    case key do
      "C-c" ->
        out(state, "^C\r\n")
        signal(state, :int)
        %{state | line: ""}

      "C-z" ->
        out(state, "^Z\r\n")
        signal(state, :tstp)
        state

      "C-\\" ->
        out(state, "^\\\r\n")
        signal(state, :quit)
        state

      "C-d" when state.line == "" ->
        %{state | eof: true}

      "RET" ->
        out(state, "\r\n")
        %{state | lines: state.lines ++ [state.line <> "\n"], line: ""}

      "C-j" ->
        out(state, "\r\n")
        %{state | lines: state.lines ++ [state.line <> "\n"], line: ""}

      k when k in ["DEL", "C-h"] ->
        if state.line == "" do
          state
        else
          out(state, "\b \b")
          %{state | line: String.slice(state.line, 0..-2//1)}
        end

      "C-w" ->
        trimmed = String.trim_trailing(state.line)
        kept = Regex.replace(~r/\S*$/, trimmed, "")
        erase = String.length(state.line) - String.length(kept)
        out(state, String.duplicate("\b \b", erase))
        %{state | line: kept}

      "C-u" ->
        out(state, String.duplicate("\b \b", String.length(state.line)))
        %{state | line: ""}

      key ->
        case Keys.text(key) do
          nil ->
            state

          text ->
            out(state, text)
            %{state | line: state.line <> text}
        end
    end
  end

  defp signal(%{foreground: pid}, sig) when is_pid(pid), do: send(pid, {:signal, sig})
  defp signal(_, _), do: :ok

  # Keys typed while a raw program ran (and not consumed) become type-ahead.
  defp requeue_keys_as_input(state) do
    keys = :queue.to_list(state.keys)
    Enum.reduce(keys, %{state | keys: :queue.new()}, &handle_key/2)
  end

  defp maybe_monitor_owner(state, :raw, owner) do
    if owner != state.mode_owner, do: Process.monitor(owner)
    %{state | mode_owner: owner}
  end

  defp maybe_monitor_owner(state, :cooked, _owner), do: %{state | mode_owner: nil}

  # -- serving waiters -----------------------------------------------------------------

  defp serve(state) do
    state |> serve_keys() |> serve_requests()
  end

  # A reader that died while waiting must not swallow the next key.
  defp serve_keys(%{key_waiters: [{pid, ref} | rest]} = state) do
    if Process.alive?(pid), do: serve_one_key(state, pid, ref, rest), else: serve_keys(%{state | key_waiters: rest})
  end

  defp serve_keys(state), do: state

  defp serve_one_key(state, pid, ref, rest) do
    case :queue.out(state.keys) do
      {{:value, key}, q} ->
        send(pid, {:key, ref, key})
        serve_keys(%{state | keys: q, key_waiters: rest})

      {:empty, _} ->
        state
    end
  end


  defp serve_requests(%{mode: :raw} = state), do: state

  defp serve_requests(state) do
    case :queue.out(state.requests) do
      {{:value, {from, reply_as, req}}, q} ->
        case try_request(req, state) do
          {:reply, result, state} ->
            send(from, {:io_reply, reply_as, result})
            serve_requests(%{state | requests: q})

          :wait ->
            state

          {:wait, state} ->
            state
        end

      {:empty, _} ->
        state
    end
  end

  # -- I/O protocol ----------------------------------------------------------------------

  defp handle_io(from, reply_as, request, state) do
    case request do
      {:put_chars, enc, chars} ->
        out(state, to_bytes(enc, chars))
        send(from, {:io_reply, reply_as, :ok})
        {:noreply, state}

      {:put_chars, enc, m, f, a} ->
        out(state, to_bytes(enc, apply(m, f, a)))
        send(from, {:io_reply, reply_as, :ok})
        {:noreply, state}

      {:requests, reqs} ->
        Enum.each(reqs, fn r -> handle_io(from, make_ref(), r, state) end)
        send(from, {:io_reply, reply_as, :ok})
        {:noreply, state}

      {:setopts, _} ->
        send(from, {:io_reply, reply_as, :ok})
        {:noreply, state}

      :getopts ->
        send(from, {:io_reply, reply_as, [binary: true, encoding: :unicode]})
        {:noreply, state}

      {:get_geometry, :columns} ->
        send(from, {:io_reply, reply_as, elem(state.size, 1)})
        {:noreply, state}

      {:get_geometry, :rows} ->
        send(from, {:io_reply, reply_as, elem(state.size, 0)})
        {:noreply, state}

      req when elem(req, 0) in [:get_line, :get_chars, :get_until] ->
        prompt = prompt_of(req)
        if prompt != "", do: out(state, prompt)
        state = %{state | requests: :queue.in({from, reply_as, req}, state.requests)}
        {:noreply, serve(state)}

      _ ->
        send(from, {:io_reply, reply_as, {:error, :request}})
        {:noreply, state}
    end
  end

  defp prompt_of({:get_line, _enc, prompt}), do: to_bytes(:unicode, prompt)
  defp prompt_of({:get_chars, _enc, prompt, _n}), do: to_bytes(:unicode, prompt)
  defp prompt_of({:get_until, _enc, prompt, _m, _f, _a}), do: to_bytes(:unicode, prompt)
  defp prompt_of(_), do: ""

  defp try_request({:get_line, _enc, _prompt}, state) do
    case state.lines do
      [line | rest] -> {:reply, line, %{state | lines: rest}}
      [] when state.eof -> {:reply, :eof, %{state | eof: false}}
      [] -> :wait
    end
  end

  defp try_request({:get_chars, _enc, _prompt, n}, state) do
    case state.lines do
      [line | rest] ->
        {taken, left} = String.split_at(line, n)
        lines = if left == "", do: rest, else: [left | rest]
        {:reply, taken, %{state | lines: lines}}

      [] when state.eof ->
        {:reply, :eof, %{state | eof: false}}

      [] ->
        :wait
    end
  end

  defp try_request({:get_until, _enc, _prompt, m, f, a}, state) do
    run_until(m, f, a, state.until_cont, %{state | until_cont: []})
  end

  defp run_until(m, f, a, cont, state) do
    {data, state} =
      case state.lines do
        [line | rest] -> {line, %{state | lines: rest}}
        [] when state.eof -> {:eof, %{state | eof: false}}
        [] -> {nil, state}
      end

    case data do
      nil ->
        # Keep the partial collection until more input arrives.
        {:wait, %{state | until_cont: cont}}

      data ->
        chars = if data == :eof, do: :eof, else: String.to_charlist(data)

        case apply(m, f, [cont, chars | a]) do
          {:done, result, _rest} ->
            result = if is_list(result), do: List.to_string(result), else: result
            {:reply, result, state}

          {:more, cont} ->
            run_until(m, f, a, cont, state)
        end
    end
  end

  defp to_bytes(_enc, chars) when is_atom(chars), do: Atom.to_string(chars)
  defp to_bytes(:latin1, chars) when is_binary(chars), do: chars
  defp to_bytes(_enc, chars) when is_binary(chars), do: chars

  defp to_bytes(_enc, chars) do
    case :unicode.characters_to_binary(chars) do
      bin when is_binary(bin) -> bin
      _ -> IO.iodata_to_binary(chars)
    end
  end

  defp out(%{backend: {mod, handle}}, data) do
    data = String.replace(data, ~r/(?<!\r)\n/, "\r\n")
    mod.write(handle, data)
  end
end
