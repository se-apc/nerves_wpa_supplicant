# Copyright 2014 LKC Technologies, Inc.\
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule Nerves.WpaSupplicant do
  use GenServer
  alias Nerves.WpaSupplicant.Messages

  #require Logger

  @run_path "/var/run/wpa_supplicant"

  @doc """
  Invoked when a control interface event is received
  """
  @callback control_interface_event(ctl_if_event :: term, data :: term, state :: term) ::
    {:noreply, state :: term} | {:stop, reason :: term, state :: term}

  defmacro __using__(_opts) do
    quote do
      @behaviour Nerves.WpaSupplicant

      def start_link(opts \\ []) do
        opts = Keyword.put_new(opts, :mod, __MODULE__)
        GenServer.start_link(Nerves.WpaSupplicant, opts)
      end

      def control_interface_event(_event, _data, state),
        do: {:noreply, state}

      defoverridable [control_interface_event: 3, start_link: 1]
    end
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Send a request to the wpa_supplicant.

  ## Example

      iex> Nerves.WpaSupplicant.request(pid, :PING)
      :PONG
  """
  def request(pid, command) do
    GenServer.call(pid, {:request, command})
  end

  @doc """
  Return the current status of the wpa_supplicant. It wraps the
  STATUS command.
  """
  def status(pid) do
    request(pid, :STATUS)
  end

  @doc """
  Tell the wpa_supplicant to connect to the specified network. Invoke
  like this:

      iex> Nerves.WpaSupplicant.set_network(pid, ssid: "MyNetworkSsid", key_mgmt: :WPA_PSK, psk: "secret")

  or like this:

      iex> Nerves.WpaSupplicant.set_network(pid, %{ssid: "MyNetworkSsid", key_mgmt: :WPA_PSK, psk: "secret"})

  Many options are supported, but it is likely that `ssid` and `psk` are
  the most useful. The full list can be found in the wpa_supplicant
  documentation. Here's a list of some common ones:

  Option                | Description
  ----------------------|------------
  :ssid                 | Network name. This is mandatory.
  :key_mgmt             | The security in use. This is mandatory. Set to :NONE, :WPA_PSK
  :proto                | Protocol use use. E.g., :WPA2
  :psk                  | WPA preshared key. 8-63 chars or the 64 char one as processed by `wpa_passphrase`
  :bssid                | Optional BSSID. If set, only associate with the AP with a matching BSSID
  :mode                 | Mode: 0 = infrastructure (default), 1 = ad-hoc, 2 = AP
  :frequency            | Channel frequency. e.g., 2412 for 802.11b/g channel 1
  :wep_key0..3          | Static WEP key
  :wep_tx_keyidx        | Default WEP key index (0 to 3)

  Note that this is a helper function that wraps several low level calls and
  is limited to specifying only one network at a time. If you'd
  like to register multiple networks with the supplicant, send the
  ADD_NETWORK, SET_NETWORK, SELECT_NETWORK messages manually.
  """
  def set_network(pid, options) do
    # Don't worry if the following fails. We just need to
    # make sure that no other networks registered with the
    # wpa_supplicant take priority over ours
    request(pid, {:REMOVE_NETWORK, :all})

    netid = request(pid, :ADD_NETWORK)
    Enum.each(options, fn({key, value}) ->
        :ok = request(pid, {:SET_NETWORK, netid, key, value})
      end)

    :ok = request(pid, {:SELECT_NETWORK, netid})
  end

  @doc """
  This is a helper function that will initiate a scan, wait for the
  scan to complete and return a list of all of the available access
  points. This can take a while if the wpa_supplicant hasn't scanned
  for access points recently.
  """
  def scan(pid) do
    stream = pid |> event_manager |> GenEvent.stream(timeout: 60000)
    case request(pid, :SCAN) do
      :ok -> :ok

      # If the wpa_supplicant is already scanning, FAIL-BUSY is
      # returned.
      "FAIL-BUSY" -> :ok
    end

    # Wait for the scan results
    Enum.take_while(stream, fn(x) -> x == {:wpa_supplicant, pid, :"CTRL-EVENT-SCAN-RESULTS"} end)

    # Collect all BSSs
    all_bss(pid, 0, [])
  end

  defp all_bss(pid, count, acc) do
    result = request(pid, {:BSS, count})
    if result do
      all_bss(pid, count + 1, [result | acc])
    else
      acc
    end
  end

  def init(opts) do
    {opts, eopts} = Keyword.split(opts, [:iface, :mod])
    iface = opts[:iface] || :wlan0
    mod = opts[:mod]
    sock = @run_path <> "/#{iface}"

    executable = :code.priv_dir(:nerves_wpa_supplicant) ++ '/wpa_ex'
    port = Port.open({:spawn_executable, executable},
                     [{:args, [sock]},
                      {:packet, 2},
                      :binary,
                      :exit_status])
    {:ok, %{iface: iface, port: port, mod: mod, queue: :queue.new, opts: eopts}}
  end

  def handle_call({:request, command}, from, state) do
    {caller, _} = from
    ref = Process.monitor(caller)
    state = update_in state.queue, &:queue.in({command, from, ref}, &1)

    payload = Messages.encode(command)
    #Logger.info("WpaSupplicant: sending '#{payload}'")
    send state.port, {self, {:command, payload}}
    {:noreply, state}
  end

  def handle_info({_, {:data, message}}, state) do
    handle_wpa(message, state)
  end

  def handle_wpa(<< "<", _priority::utf8, ">", message::binary>>, state) do
    #Logger.debug "WPA-Event Received: #{inspect message}"
    if state.mod != nil do
      {event, data} = Messages.decode_event(message)
      state.mod.control_interface_event(event, data, state)
    else
      {:noreply, state}
    end
  end

  def handle_wpa(response, state) do
    #Logger.debug "Received Response: #{inspect response}"
    queue =
      case :queue.out(state.queue) do
      {{:value, {cmd, from, ref}}, q} ->
        Process.demonitor(ref)
        reply = Messages.decode_resp(cmd, response)
        GenServer.reply(from, reply)
        q
      {:empty, q} ->
        q
    end
    {:noreply, %{state | queue: queue}}
  end

end
