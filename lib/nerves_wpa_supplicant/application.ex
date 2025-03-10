defmodule Nerves.WpaSupplicant.Application do
  @moduledoc false
  
  use Application

  def start(_type, _args) do

    children = [
      {Registry, keys: :duplicate, name: Nerves.WpaSupplicant}
    ]

    opts = [strategy: :one_for_one, name: Nerves.WpaSupplicant.Supervisor]

    Supervisor.start_link(children, opts)
  end
 end
