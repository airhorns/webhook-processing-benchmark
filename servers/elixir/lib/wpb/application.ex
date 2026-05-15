defmodule Wpb.Application do
  use Application

  @impl true
  def start(_type, _args) do
    port = String.to_integer(System.get_env("PORT", "8080"))
    secret_file = System.get_env("HMAC_SECRET_FILE", "../../shared/secret.txt")
    secret = File.read!(secret_file) |> String.trim()

    # :raw allows writes from any process. :delayed_write is not safe across processes.
    :persistent_term.put(:wpb_secret, secret)

    json_backend =
      case System.get_env("WPB_JSON") do
        "otp28" -> :otp28
        _ -> :jason
      end

    :persistent_term.put(:wpb_json_backend, json_backend)

    schedulers = :erlang.system_info(:schedulers_online)

    IO.puts(:stderr, "elixir (bandit) listening on :#{port} (#{schedulers} online schedulers, json=#{json_backend})")

    children = [
      {Bandit,
       plug: Wpb.Router,
       scheme: :http,
       ip: {127, 0, 0, 1},
       port: port,
       startup_log: false}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Wpb.Supervisor)
  end
end
