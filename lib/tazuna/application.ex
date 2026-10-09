defmodule Tazuna.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Start to serve requests, typically the last entry
    children =
      [
        TazunaWeb.Telemetry,
        # DB は他の何より先に立てる。設定も選別結果もここから読む
        Tazuna.Repo,
        # 画面で決めた巡回の間隔（`Tazuna.CollectPace`）。**読めなければ既定の間隔**
        # のまま動く（テストでは DB を持たないプロセスから読むので、ここは空振りする）
        Supervisor.child_spec({Task, &Tazuna.CollectPace.load_all/0}, id: :collect_paces),
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
        # 読んだ本棚の覚え書き（データ収集の画面を開くたびに Chiezo へ取りに行かない）
        Tazuna.Datasets.ShelfCache,
        Tazuna.News.Hatena,
        # 代表作の絵の覚え書き（置き場を持つだけ。引くのは押した人のプロセス）
        Tazuna.Artwork,
        # 関連図の顔写真を 1 枚ずつ間を空けて取りに行く列
        Tazuna.Relations.Faces
      ] ++
        scheduler() ++
        [TazunaWeb.Endpoint]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Tazuna.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # 要約を作る時刻の時計。テストでは立てない —— 1 分ごとに起きて Chiezo を
  # 叩きに行かれると、何を見ているのか分からないテストになります
  # 整理を頼む時刻の時計も同じ扱い（テストでは立てない）
  defp scheduler do
    if Application.get_env(:tazuna, :digest_scheduler, true),
      do: [
        Tazuna.Digest.Scheduler,
        Tazuna.Datasets.SurveyScheduler
      ],
      else: []
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TazunaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
