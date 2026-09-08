import Config

# テストは1本ずつ独立させる。**sandbox で包む**ので、テストが書いた行は
# そのテストが終わると消える(前のテストの行を引きずると、単体では通るのに
# 並べると落ちる、という追いにくい壊れ方をする)。
# `MIX_TEST_PARTITION` は複数プロセスで回すときに DB を分けるためのもの
config :antenna, Antenna.Repo,
  url:
    System.get_env("DATABASE_URL") ||
      "ecto://antenna:antenna@localhost:7071/antenna_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :antenna, AntennaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  # 生成された実値ではなく、**明らかに偽物と分かるもの**を置く（長さだけ満たす）。
  # 本番は `SECRET_KEY_BASE` から取るので、ここが漏れて困ることは無いが、
  # リポジトリに乱数の実値があると「これは本物か」を毎回確かめることになる
  secret_key_base: String.duplicate("t", 64),
  server: false

# 外部への取得はスタブへ差し替える。テストが実際に相手を叩くと、
# 相手の都合で落ちるうえに相手への負担にもなる
config :antenna, :http_client, Antenna.HttpStub

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
