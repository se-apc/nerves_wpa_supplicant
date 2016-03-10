defmodule Nerves.WpaSupplicant.Messages do

  def encode(cmd) when is_atom(cmd) do
    to_string(cmd)
  end
  def encode({:"CTRL-RSP-IDENTITY", network_id, string}) do
    "CTRL-RSP-IDENTITY-#{network_id}-#{string}"
  end
  def encode({:"CTRL-RSP-PASSWORD", network_id, string}) do
    "CTRL-RSP-PASSWORD-#{network_id}-#{string}"
  end
  def encode({:"CTRL-RSP-NEW_PASSWORD", network_id, string}) do
    "CTRL-RSP-NEW_PASSWORD-#{network_id}-#{string}"
  end
  def encode({:"CTRL-RSP-PIN", network_id, string}) do
    "CTRL-RSP-PIN-#{network_id}-#{string}"
  end
  def encode({:"CTRL-RSP-OTP", network_id, string}) do
    "CTRL-RSP-OTP-#{network_id}-#{string}"
  end
  def encode({:"CTRL-RSP-PASSPHRASE", network_id, string}) do
    "CTRL-RSP-PASSPHRASE-#{network_id}-#{string}"
  end
  def encode({cmd, arg}) when is_atom(cmd) do
    to_string(cmd) <> " " <> encode_arg(arg)
  end
  def encode({cmd, arg, arg2}) when is_atom(cmd) do
    to_string(cmd) <> " " <> encode_arg(arg) <> " " <> encode_arg(arg2)
  end
  def encode({cmd, arg, arg2, arg3}) when is_atom(cmd) do
    to_string(cmd) <> " " <> encode_arg(arg) <> " " <> encode_arg(arg2) <> " " <> encode_arg(arg3)
  end

  defp encode_arg(arg) when is_binary(arg) do
    if String.length(arg) == 17 &&
      Regex.match?(~r/[\da-fA-F][\da-fA-F]:[\da-fA-F][\da-fA-F]:[\da-fA-F][\da-fA-F]:[\da-fA-F][\da-fA-F]:[\da-fA-F][\da-fA-F]:[\da-fA-F][\da-fA-F]/, arg) do
      # This is a MAC address
      arg
    else
      # This is a string
      "\"" <> arg <> "\""
    end
  end
  defp encode_arg(arg) do
    to_string(arg)
  end

  def decode_event(event) do
    event
    |> decode
    |> normalize
  end

  def decode(<< "CTRL-REQ-", rest::binary >>) do
    [field, net_id, text] = String.split(rest, "-", parts: 3, trim: true)
    {"CTRL-REQ-" <> field, String.to_integer(net_id), text}
  end
  def decode(<< "CTRL-EVENT-BSS-ADDED", rest::binary >>) do
    [entry_id, bssid] = String.split(rest, " ", trim: true)
    {"CTRL-EVENT-BSS-ADDED", String.to_integer(entry_id), bssid}
  end
  def decode(<< "CTRL-EVENT-BSS-REMOVED", rest::binary >>) do
    [entry_id, bssid] = String.split(rest, " ", trim: true)
    {"CTRL-EVENT-BSS-REMOVED", String.to_integer(entry_id), bssid}
  end
  def decode(<< "CTRL-EVENT-CONNECTED", _rest::binary >>) do
    "CTRL-EVENT-CONNECTED"
  end
  def decode(<< "CTRL-EVENT-DISCONNECTED", _rest::binary >>) do
    {"CTRL-EVENT-DISCONNECTED", nil}
  end
  def decode(<< "CTRL-EVENT-", _type::binary>> = event) do
    event |> String.rstrip
  end
  def decode(<< "WPS-", _type::binary>> = event) do
    event |> String.rstrip
  end
  def decode(<< "AP-STA-CONNECTED ", mac::binary>>) do
    {"AP-STA-CONNECTED", String.rstrip(mac)}
  end
  def decode(<< "AP-STA-DISCONNECTED ", mac::binary>>) do
    {"AP-STA-DISCONNECTED", String.rstrip(mac)}
  end
  def decode(string) do
    {"INFO", String.rstrip(string)}
  end

  def normalize({atom, data}) when is_atom(atom) do
    normalize({to_string(atom), data})
  end
  def normalize({str, data}) do
    event = str
    |> String.downcase
    |> String.replace("-","_")
    |> String.to_atom
    {event, data}
  end
  def normalize(atom), do: normalize({atom, nil})

  @doc """
  Decode responses from the wpa_supplicant

  The decoding of a response depends on the request, so pass the request as
  the first argument and the response as the second one.
  """
  def decode_resp(req, resp) do
    # Strip the response of whitespace before trying to parse it.
    tresp(req, String.strip(resp))
    |> normalize
  end

  defp tresp(:PING, "PONG"), do: :PONG
  defp tresp(:MIB, resp), do: kv_resp(resp)
  defp tresp(:STATUS, resp), do: kv_resp(resp)
  defp tresp(:"STATUS-VERBOSE", resp), do: kv_resp(resp)
  defp tresp({:BSS, _}, ""), do: nil
  defp tresp({:BSS, _}, resp), do: kv_resp(resp)
  defp tresp(:INTERFACES, resp), do: String.split(resp, "\n")
  defp tresp(:ADD_NETWORK, netid), do: String.to_integer(netid)
  defp tresp(_, "OK"), do: :ok
  defp tresp(_, "FAIL"), do: :FAIL
  defp tresp(_, << "\"", string::binary >>), do: String.rstrip(string, ?")
  defp tresp(_, resp), do: resp

  defp kv_resp(resp) do
    resp
      |> String.split("\n", trim: true)
      |> List.foldl(%{}, fn(pair, acc) ->
           [key, value] = String.split(pair, "=")
           Dict.put(acc, String.to_atom(key), kv_value(String.rstrip(value)))
         end)
  end

  defp kv_value("TRUE"), do: true
  defp kv_value("FALSE"), do: false
  defp kv_value(""), do: nil
  defp kv_value(<< "0x", hex::binary >>), do: kv_value(hex, 16)
  defp kv_value(str), do: kv_value(str, 10)

  defp kv_value(value, base) do
    try do
      String.to_integer(value, base)
    rescue
      ArgumentError -> value
    end
  end

end
