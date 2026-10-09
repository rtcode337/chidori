import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/chidori start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :chidori, ChidoriWeb.Endpoint, server: true
end

config :chidori, ChidoriWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "7000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :chidori, ChidoriWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/chidori_web/router\.ex$"E,
        ~r"lib/chidori_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  config :chidori, Chidori.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10")),
    socket_options: if(System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: [])

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # 短い鍵は起動時に弾く。通してしまうと、起動には成功したのに
  # すべての要求が 500 になり、原因がログの奥まで追わないと分からない
  if byte_size(secret_key_base) < 64 do
    raise """
    environment variable SECRET_KEY_BASE is too short (#{byte_size(secret_key_base)} bytes).
    It must be at least 64 bytes. You can generate one by calling: mix phx.gen.secret
    """
  end

  # ブラウザが開くときの宛先。**リンクの組み立てにしか使わない**が、既定のままだと
  # スマホから IP で開いたときに `localhost` を指すリンクが返る
  host = System.get_env("PHX_HOST") || "localhost"
  scheme = System.get_env("PHX_SCHEME") || "http"
  url_port =
    String.to_integer(
      System.get_env("PHX_URL_PORT") ||
        if(scheme == "https", do: "443", else: System.get_env("PORT", "7000"))
    )

  # **どこから開いても繋がるようにする。** LiveView は繋ぎ直すときに接続元を
  # 見比べるので、`PHX_HOST` と違う宛先（IP やホスト名）で開くと画面が
  # 「繋がりません」のまま止まる。LAN の中に閉じていて認証も無い層なので、
  # 既定では見比べない（外へ出すなら `PHX_CHECK_ORIGIN` に宛先を並べる）
  check_origin =
    case System.get_env("PHX_CHECK_ORIGIN") do
      nil -> false
      "" -> false
      list -> list |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end

  config :chidori, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :chidori, ChidoriWeb.Endpoint,
    url: [host: host, port: url_port, scheme: scheme],
    check_origin: check_origin,
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :chidori, ChidoriWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :chidori, ChidoriWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
