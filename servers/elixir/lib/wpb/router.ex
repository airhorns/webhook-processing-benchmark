defmodule Wpb.Router do
  @moduledoc """
  Minimal Plug router that handles POST /webhook with the Shopify HMAC contract.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "POST", request_path: "/webhook"} = conn, _opts) do
    handle_webhook(conn)
  end

  def call(conn, _opts) do
    Plug.Conn.send_resp(conn, 404, "")
  end

  defp handle_webhook(conn) do
    {:ok, body, conn} = read_full_body(conn, [])
    secret = :persistent_term.get(:wpb_secret)

    case Plug.Conn.get_req_header(conn, "x-shopify-hmac-sha256") do
      [header | _] ->
        if valid_hmac?(secret, body, header) do
          process_and_respond(conn, body)
        else
          Plug.Conn.send_resp(conn, 401, "")
        end

      _ ->
        Plug.Conn.send_resp(conn, 401, "")
    end
  end

  defp read_full_body(conn, acc) do
    case Plug.Conn.read_body(conn, length: 10_000_000) do
      {:ok, chunk, conn} ->
        {:ok, IO.iodata_to_binary([acc, chunk]), conn}

      {:more, chunk, conn} ->
        read_full_body(conn, [acc, chunk])

      {:error, _} = err ->
        err
    end
  end

  defp valid_hmac?(secret, body, header) do
    case Base.decode64(header) do
      {:ok, expected} ->
        computed = :crypto.mac(:hmac, :sha256, secret, body)
        Plug.Crypto.secure_compare(expected, computed)

      :error ->
        false
    end
  end

  # Variant selected at application start via WPB_JSON env; stored in :persistent_term.
  # WPB_JSON=otp28 → use OTP-built-in :json module. Anything else → Jason.
  @compile {:inline, json_decode: 1, json_encode_iodata: 1}

  defp json_decode(body) do
    case :persistent_term.get(:wpb_json_backend, :jason) do
      :otp28 -> :json.decode(body)
      :jason ->
        case Jason.decode(body) do
          {:ok, v} -> v
          {:error, _} -> throw(:bad_json)
        end
    end
  end

  defp json_encode_iodata(value) do
    case :persistent_term.get(:wpb_json_backend, :jason) do
      :otp28 -> :json.encode(value)
      :jason ->
        {:ok, io} = Jason.encode_to_iodata(value)
        io
    end
  end

  defp process_and_respond(conn, body) do
    parsed =
      try do
        {:ok, json_decode(body)}
      catch
        _, _ -> :error
      end

    case parsed do
      {:ok, %{"variants" => variants}} when is_list(variants) ->
        # OTP 28: :raw fds are tied to the controlling process, so we open
        # one per request inside the handler process. /dev/null open is cheap.
        {:ok, devnull} = :file.open(~c"/dev/null", [:write, :raw])

        try do
          Enum.each(variants, fn variant ->
            upcased = upcase_values(variant)
            :file.write(devnull, [json_encode_iodata(upcased), ?\n])
          end)
        after
          :file.close(devnull)
        end

        Plug.Conn.send_resp(conn, 200, "")

      _ ->
        Plug.Conn.send_resp(conn, 400, "")
    end
  end

  @compile {:inline, upcase_values: 1}
  defp upcase_values(value) when is_binary(value), do: String.upcase(value)
  defp upcase_values(value) when is_list(value), do: Enum.map(value, &upcase_values/1)

  defp upcase_values(value) when is_map(value) do
    :maps.map(fn _k, v -> upcase_values(v) end, value)
  end

  defp upcase_values(value), do: value
end
