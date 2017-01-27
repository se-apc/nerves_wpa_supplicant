# Copyright 2016 Frank Hunleth
# Copyright 2014 LKC Technologies, Inc.
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
  require Logger

  alias Nerves.WpaSupplicant.Messages

  defstruct port: nil,
            manager: nil,
            requests: []

  @doc """
  Start and link a Nerves.WpaSupplicant process that uses the specified
  control socket. A GenEvent will be spawned for managing wpa_supplicant
  events. Call event_manager/1 to get the GenEvent pid.
  """
  def start_link(control_socket_path) do
    { :ok, manager } = GenEvent.start_link
    start_link(control_socket_path, manager)
  end

  @doc """
  Start and link a Nerves.WpaSupplicant that uses the specified control
  socket and GenEvent event manager.
  """
  def start_link(control_socket_path, event_manager) do
    GenServer.start_link(__MODULE__, {control_socket_path, event_manager})
  end

  @doc """
  Stop the Nerves.WpaSupplicant control interface
  """
  def stop(pid) do
    GenServer.stop(pid)
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
  Get a reference to the GenEvent event manager in use by this
  supplicant.
  """
  def event_manager(pid) do
    GenServer.call(pid, :event_manager)
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

  Note that this is a helper function that wraps several low-level calls and
  is limited to specifying only one network at a time. If you'd
  like to register multiple networks with the supplicant, send the
  ADD_NETWORK, SET_NETWORK, SELECT_NETWORK messages manually.

  Returns `:ok` or `{:error, key, reason}` if a key fails to set.
  """
  def set_network(pid, options) when is_map(options), do: set_network(pid, Map.to_list(options))
  def set_network(pid, options) do
    # Don't worry if the following fails. We just need to
    # make sure that no other networks registered with the
    # wpa_supplicant take priority over ours
    request(pid, {:REMOVE_NETWORK, :all})

    netid = request(pid, :ADD_NETWORK)
    case set_network_kvlist(pid, netid, options, {:none, :ok}) do
      :ok ->
        # Everything succeeded -> select the network
        request(pid, {:SELECT_NETWORK, netid})
      error ->
        # Something failed, so return the error
        error
    end
  end

  defp set_network_kvlist(pid, netid, [{key, value} | tail], {_, :ok}) do
    rc = request(pid, {:SET_NETWORK, netid, key, value})
    set_network_kvlist(pid, netid, tail, {key, rc})
  end
  defp set_network_kvlist(_pid, _netid, [], {_, :ok}), do: :ok
  defp set_network_kvlist(_pid, _netid, _kvpairs, {key, rc}) do
    {:error, key, rc}
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

  def init({control_socket_path, event_manager}) do
    executable = :code.priv_dir(:nerves_wpa_supplicant) ++ '/wpa_ex'
    port = Port.open({:spawn_executable, executable},
                     [{:args, [control_socket_path]},
                      {:packet, 2},
                      :binary,
                      :exit_status])
    { :ok, %Nerves.WpaSupplicant{port: port, manager: event_manager} }
  end

  def handle_call({:request, command}, from, state) do
    payload = Messages.encode(command)
    Logger.info("Nerves.WpaSupplicant: sending '#{payload}'")
    send state.port, {self(), {:command, payload}}
    state = %{state | :requests => state.requests ++ [{from, command}]}
    {:noreply, state}
  end
  def handle_call(:event_manager, _from, state) do
    {:reply, state.manager, state}
  end

  def handle_info({_, {:data, message}}, state) do
    handle_wpa(message, state)
  end
  def handle_info({_, {:exit_status, _}}, state) do
    {:stop, :unexpected_exit, state}
  end

  defp handle_wpa(<< "<", _priority::utf8, ">", notification::binary>>, state) do
    decoded_notif = Messages.decode_notif(notification)
    GenEvent.notify(state.manager, {:nerves_wpa_supplicant, self(), decoded_notif})
    {:noreply, state}
  end
  defp handle_wpa(response, state) do
    [{client, command} | next_ones] = state.requests
    state = %{state | :requests => next_ones}

    decoded_response = Messages.decode_resp(command, response)
    GenServer.reply client, decoded_response
    {:noreply, state}
  end
end
