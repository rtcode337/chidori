defmodule Antenna.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AntennaWeb.Telemetry,
      # DB は他の何より先に立てる。設定も選別結果もここから読む
      Antenna.Repo,
      {DNSCluster, query: Application.get_env(:antenna, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Antenna.PubSub},
      # 外部への取得はこの下で動かす。収集を持つ GenServer では待たない ——
      # 待つと、収集中に画面を開いた人まで巻き添えで待たされる
      {Task.Supervisor, name: Antenna.TaskSupervisor},
      # 話題ごとに 1 つずつ収集を持つ。開かれた話題のぶんだけ立てる ——
      # 話題は増えていく前提なので、全部を起動時に立てると、
      # 誰も開いていない話題まで常駐する
      {Registry, keys: :unique, name: Antenna.News.Registry},
      {DynamicSupervisor, name: Antenna.News.Supervisor, strategy: :one_for_one},
      Antenna.Relations,
      # Start to serve requests, typically the last entry
      AntennaWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Antenna.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AntennaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
