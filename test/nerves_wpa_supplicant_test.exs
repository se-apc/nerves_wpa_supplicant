defmodule NervesWpaSupplicantTest do
  use ExUnit.Case
  #doctest Nerves.WpaSupplicant

  require Logger

  defmodule Test do
    use Nerves.WpaSupplicant

    def control_interface_event(event, _data, %{opts: opts} = s) do
      send opts[:cb], {event}
      {:noreply, s}
    end
  end

  test "Ping" do
    {:ok, pid} = Nerves.WpaSupplicant.start_link
    assert :PONG = Nerves.WpaSupplicant.request(pid, :PING)
  end

end
