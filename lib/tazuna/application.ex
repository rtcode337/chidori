defmodule Tazuna.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TazunaWeb.Telemetry,
      # DB は他の何より先に立てる。設定も選別結果もここから読む
      Tazuna.Repo,
      {DNSCluster, query: Application.get_env(:tazuna, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Tazuna.PubSub},
      # 外部への取得はこの下で動かす。収集を持つ GenServer では待たない ——
      # 待つと、収集中に画面を開いた人まで巻き添えで待たされる
      {Task.Supervisor, name: Tazuna.TaskSupervisor},
      # 話題ごとに 1 つずつ収集を持つ。開かれた話題のぶんだけ立てる ——
      # 話題は増えていく前提なので、全部を起動時に立てると、
      # 誰も開いていない話題まで常駐する
      {Registry, keys: :unique, name: Tazuna.News.Registry},
      {DynamicSupervisor, name: Tazuna.News.Supervisor, strategy: :one_for_one},
      Tazuna.Relations,
      # 代表作の絵の覚え書き（置き場を持つだけ。引くのは押した人のプロセス）
      Tazuna.Artwork,
      # Start to serve requests, typically the last entry
      TazunaWeb.Endpoint,
      # まとめが出ていないかを時々見に行く。**Endpoint の後ろに置く** ——
      # 知らせの「続きを読む」に自分の宛先を載せるので、先に立てておく必要がある。
      # 宛先を設定した話題が 1 つも無ければ、見に行く先も無い（空回りするだけ）
      Tazuna.Notify.Watcher
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Tazuna.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TazunaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
