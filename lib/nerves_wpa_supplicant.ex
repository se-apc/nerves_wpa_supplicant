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

  require Logger

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
  ## Examples
      iex> WpaSupplicant.request(pid, :PING)
      :PONG
  """
  def request(pid, command) do
    GenServer.call(pid, {:request, command})
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
    Logger.info("WpaSupplicant: sending '#{payload}'")
    send state.port, {self, {:command, payload}}
    {:noreply, state}
  end

  def handle_info({_, {:data, message}}, state) do
    handle_wpa(message, state)
  end

  def handle_wpa(<< "<", _priority::utf8, ">", message::binary>>, state) do
    Logger.debug "WPA-Event Received: #{inspect message}"
    if state.mod != nil do
      {event, data} = Messages.decode_event(message)
      state.mod.control_interface_event(event, data, state)
    else
      {:noreply, state}
    end
  end

  def handle_wpa(response, state) do
    Logger.debug "Received Response: #{inspect response}"
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
