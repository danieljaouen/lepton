defmodule Lepton.Wayland.Protocol do
  @moduledoc """
  The interfaces Photon speaks: the core protocol (`wayland.xml`, with
  subsurfaces and a data device that holds no clipboard yet), the stable
  `xdg-shell`, KDE's server-side decoration protocol (Photon draws the
  title bars) and text-input v3 (Korean typing), as far as the versions
  below, plus one Lepton extension,
  `lepton_shm`.

  `lepton_shm` is `wl_shm` for clients inside Lepton's own VM:
  `create_pool(id, path, size)` names a file in the compositor's
  `XDG_RUNTIME_DIR` instead of passing a descriptor. Photon opens the file
  and removes it, which saves the descriptor round trip (descriptors
  that do arrive are closed with `Lepton.FD`). A client that binds `lepton_shm` gets no
  `wl_keyboard.keymap` (no descriptor): its keys are the US layout of
  `Lepton.Wayland.Keymap`.

  Each interface lists its requests and events in protocol order (the
  position is the opcode) with their argument types (`Lepton.Wayland.Wire`).
  `{:new_id, "iface"}` and `{:object, "iface"}` name the interface;
  `{:new_id, nil}` is `wl_registry.bind`'s untyped ID.
  """

  rect = [:int, :int, :int, :int]

  @interfaces %{
    "wl_display" => %{
      version: 1,
      requests: [sync: [{:new_id, "wl_callback"}], get_registry: [{:new_id, "wl_registry"}]],
      events: [error: [:object, :uint, :string], delete_id: [:uint]]
    },
    "wl_registry" => %{
      version: 1,
      requests: [bind: [:uint, {:new_id, nil}]],
      events: [global: [:uint, :string, :uint], global_remove: [:uint]]
    },
    "wl_callback" => %{version: 1, requests: [], events: [done: [:uint]]},
    "wl_compositor" => %{
      version: 4,
      requests: [create_surface: [{:new_id, "wl_surface"}], create_region: [{:new_id, "wl_region"}]],
      events: []
    },
    "wl_shm_pool" => %{
      version: 1,
      requests: [create_buffer: [{:new_id, "wl_buffer"}, :int, :int, :int, :int, :uint], destroy: [], resize: [:int]],
      events: []
    },
    "wl_shm" => %{
      version: 1,
      requests: [create_pool: [{:new_id, "wl_shm_pool"}, :fd, :int]],
      events: [format: [:uint]]
    },
    "lepton_shm" => %{
      version: 1,
      requests: [destroy: [], create_pool: [{:new_id, "wl_shm_pool"}, :string, :int]],
      events: []
    },
    "wl_buffer" => %{version: 1, requests: [destroy: []], events: [release: []]},
    "wl_surface" => %{
      version: 4,
      requests: [
        destroy: [],
        attach: [{:object, "wl_buffer"}, :int, :int],
        damage: rect,
        frame: [{:new_id, "wl_callback"}],
        set_opaque_region: [{:object, "wl_region"}],
        set_input_region: [{:object, "wl_region"}],
        commit: [],
        set_buffer_transform: [:int],
        set_buffer_scale: [:int],
        damage_buffer: rect
      ],
      events: [enter: [{:object, "wl_output"}], leave: [{:object, "wl_output"}]]
    },
    "wl_region" => %{version: 1, requests: [destroy: [], add: rect, subtract: rect], events: []},
    "wl_subcompositor" => %{
      version: 1,
      requests: [destroy: [], get_subsurface: [{:new_id, "wl_subsurface"}, {:object, "wl_surface"}, {:object, "wl_surface"}]],
      events: []
    },
    "wl_subsurface" => %{
      version: 1,
      requests: [
        destroy: [],
        set_position: [:int, :int],
        place_above: [{:object, "wl_surface"}],
        place_below: [{:object, "wl_surface"}],
        set_sync: [],
        set_desync: []
      ],
      events: []
    },
    "wl_data_device_manager" => %{
      version: 3,
      requests: [create_data_source: [{:new_id, "wl_data_source"}], get_data_device: [{:new_id, "wl_data_device"}, {:object, "wl_seat"}]],
      events: []
    },
    # KDE's server-side decoration protocol: GTK 3 draws no title bar of
    # its own when the compositor's default mode is server (2).
    "org_kde_kwin_server_decoration_manager" => %{
      version: 1,
      requests: [create: [{:new_id, "org_kde_kwin_server_decoration"}, {:object, "wl_surface"}]],
      events: [default_mode: [:uint]]
    },
    "org_kde_kwin_server_decoration" => %{
      version: 1,
      requests: [release: [], request_mode: [:uint]],
      events: [mode: [:uint]]
    },
    "wl_data_source" => %{
      version: 3,
      requests: [offer: [:string], destroy: [], set_actions: [:uint]],
      events: [target: [:string], send: [:string, :fd], cancelled: [], dnd_drop_performed: [], dnd_finished: [], action: [:uint]]
    },
    "wl_data_offer" => %{
      version: 3,
      requests: [accept: [:uint, :string], receive: [:string, :fd], destroy: [], finish: [], set_actions: [:uint, :uint]],
      events: [offer: [:string], source_actions: [:uint], action: [:uint]]
    },
    "wl_data_device" => %{
      version: 3,
      requests: [
        start_drag: [{:object, "wl_data_source"}, {:object, "wl_surface"}, {:object, "wl_surface"}, :uint],
        set_selection: [{:object, "wl_data_source"}, :uint],
        release: []
      ],
      events: [
        data_offer: [{:new_id, "wl_data_offer"}],
        enter: [:uint, {:object, "wl_surface"}, :fixed, :fixed, {:object, "wl_data_offer"}],
        leave: [],
        motion: [:uint, :fixed, :fixed],
        drop: [],
        selection: [{:object, "wl_data_offer"}]
      ]
    },
    "wl_seat" => %{
      version: 5,
      requests: [get_pointer: [{:new_id, "wl_pointer"}], get_keyboard: [{:new_id, "wl_keyboard"}], get_touch: [{:new_id, "wl_touch"}], release: []],
      events: [capabilities: [:uint], name: [:string]]
    },
    "wl_pointer" => %{
      version: 5,
      requests: [set_cursor: [:uint, {:object, "wl_surface"}, :int, :int], release: []],
      events: [
        enter: [:uint, {:object, "wl_surface"}, :fixed, :fixed],
        leave: [:uint, {:object, "wl_surface"}],
        motion: [:uint, :fixed, :fixed],
        button: [:uint, :uint, :uint, :uint],
        axis: [:uint, :uint, :fixed],
        frame: [],
        axis_source: [:uint],
        axis_stop: [:uint, :uint],
        axis_discrete: [:uint, :int]
      ]
    },
    "wl_keyboard" => %{
      version: 5,
      requests: [release: []],
      events: [
        keymap: [:uint, :fd, :uint],
        enter: [:uint, {:object, "wl_surface"}, :array],
        leave: [:uint, {:object, "wl_surface"}],
        key: [:uint, :uint, :uint, :uint],
        modifiers: [:uint, :uint, :uint, :uint, :uint],
        repeat_info: [:int, :int]
      ]
    },
    "wl_touch" => %{version: 5, requests: [release: []], events: []},
    "wl_output" => %{
      version: 2,
      requests: [],
      events: [
        geometry: [:int, :int, :int, :int, :int, :string, :string, :int],
        mode: [:uint, :int, :int, :int],
        done: [],
        scale: [:int]
      ]
    },
    "xdg_wm_base" => %{
      version: 1,
      requests: [
        destroy: [],
        create_positioner: [{:new_id, "xdg_positioner"}],
        get_xdg_surface: [{:new_id, "xdg_surface"}, {:object, "wl_surface"}],
        pong: [:uint]
      ],
      events: [ping: [:uint]]
    },
    "xdg_positioner" => %{
      version: 1,
      requests: [
        destroy: [],
        set_size: [:int, :int],
        set_anchor_rect: rect,
        set_anchor: [:uint],
        set_gravity: [:uint],
        set_constraint_adjustment: [:uint],
        set_offset: [:int, :int]
      ],
      events: []
    },
    "xdg_surface" => %{
      version: 1,
      requests: [
        destroy: [],
        get_toplevel: [{:new_id, "xdg_toplevel"}],
        get_popup: [{:new_id, "xdg_popup"}, {:object, "xdg_surface"}, {:object, "xdg_positioner"}],
        set_window_geometry: rect,
        ack_configure: [:uint]
      ],
      events: [configure: [:uint]]
    },
    "xdg_toplevel" => %{
      version: 1,
      requests: [
        destroy: [],
        set_parent: [{:object, "xdg_toplevel"}],
        set_title: [:string],
        set_app_id: [:string],
        show_window_menu: [{:object, "wl_seat"}, :uint, :int, :int],
        move: [{:object, "wl_seat"}, :uint],
        resize: [{:object, "wl_seat"}, :uint, :uint],
        set_max_size: [:int, :int],
        set_min_size: [:int, :int],
        set_maximized: [],
        unset_maximized: [],
        set_fullscreen: [{:object, "wl_output"}],
        unset_fullscreen: [],
        set_minimized: []
      ],
      events: [configure: [:int, :int, :array], close: []]
    },
    "xdg_popup" => %{
      version: 1,
      requests: [destroy: [], grab: [{:object, "wl_seat"}, :uint]],
      events: [configure: rect, popup_done: []]
    },
    # text-input-unstable-v3: how GTK programs (Firefox) take composed
    # text, Korean for one: the syllable being typed (preedit) and the
    # text that is done (commit_string). See Lepton.Hangul.
    "zwp_text_input_manager_v3" => %{
      version: 1,
      requests: [destroy: [], get_text_input: [{:new_id, "zwp_text_input_v3"}, {:object, "wl_seat"}]],
      events: []
    },
    "zwp_text_input_v3" => %{
      version: 1,
      requests: [
        destroy: [],
        enable: [],
        disable: [],
        set_surrounding_text: [:string, :int, :int],
        set_text_change_cause: [:uint],
        set_content_type: [:uint, :uint],
        set_cursor_rectangle: rect,
        commit: []
      ],
      events: [
        enter: [{:object, "wl_surface"}],
        leave: [{:object, "wl_surface"}],
        preedit_string: [:string, :int, :int],
        commit_string: [:string],
        delete_surrounding_text: [:uint, :uint],
        done: [:uint]
      ]
    }
  }

  # Requests that destroy their object (the server answers with delete_id).
  @destructors MapSet.new([
                 {"wl_shm_pool", :destroy},
                 {"lepton_shm", :destroy},
                 {"wl_subcompositor", :destroy},
                 {"wl_subsurface", :destroy},
                 {"wl_data_source", :destroy},
                 {"wl_data_device", :release},
                 {"wl_data_offer", :destroy},
                 {"org_kde_kwin_server_decoration", :release},
                 {"wl_buffer", :destroy},
                 {"wl_surface", :destroy},
                 {"wl_region", :destroy},
                 {"wl_seat", :release},
                 {"wl_pointer", :release},
                 {"wl_keyboard", :release},
                 {"wl_touch", :release},
                 {"xdg_wm_base", :destroy},
                 {"xdg_positioner", :destroy},
                 {"xdg_surface", :destroy},
                 {"xdg_toplevel", :destroy},
                 {"xdg_popup", :destroy},
                 {"zwp_text_input_manager_v3", :destroy},
                 {"zwp_text_input_v3", :destroy}
               ])

  def interfaces, do: @interfaces
  def interface(name), do: Map.get(@interfaces, name)
  def version(name), do: @interfaces[name].version

  @doc "`{name, arg_types}` of request `opcode` of `iface`, or nil."
  def request(iface, opcode), do: at(@interfaces[iface].requests, opcode)

  @doc "`{name, arg_types}` of event `opcode` of `iface`, or nil."
  def event(iface, opcode), do: at(@interfaces[iface].events, opcode)

  @doc "`{opcode, arg_types}` of event `name`."
  def event_op(iface, name), do: op(@interfaces[iface].events, name, iface)

  @doc "`{opcode, arg_types}` of request `name`."
  def request_op(iface, name), do: op(@interfaces[iface].requests, name, iface)

  def destructor?(iface, request), do: MapSet.member?(@destructors, {iface, request})

  defp at(list, i), do: Enum.at(list, i)

  defp op(list, name, iface) do
    case Enum.find_index(list, fn {n, _} -> n == name end) do
      nil -> raise ArgumentError, "#{iface} has no #{name}"
      i -> {i, Keyword.fetch!(list, name)}
    end
  end
end
