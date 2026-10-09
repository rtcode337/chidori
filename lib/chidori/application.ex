defmodule Chidori.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Start to serve requests, typically the last entry
    children =
      [
        ChidoriWeb.Telemetry,
        # DB は他の何より先に立てる。設定も選別結果もここから読む
        Chidori.Repo,
        # 画面で決めた巡回の間隔（`Chidori.CollectPace`）。**読めなければ既定の間隔**
        # のまま動く（テストでは DB を持たないプロセスから読むので、ここは空振りする）
        Supervisor.child_spec({Task, &Chidori.CollectPace.load_all/0}, id: :collect_paces),
        {DNSCluster, query: Application.get_env(:chidori, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Chidori.PubSub},
        # 外部への取得はこの下で動かす。収集を持つ GenServer では待たない ——
        # 待つと、収集中に画面を開いた人まで巻き添えで待たされる
        {Task.Supervisor, name: Chidori.TaskSupervisor},
        # 話題ごとに 1 つずつ収集を持つ。開かれた話題のぶんだけ立てる ——
        # 話題は増えていく前提なので、全部を起動時に立てると、
        # 誰も開いていない話題まで常駐する
        {Registry, keys: :unique, name: Chidori.News.Registry},
        {DynamicSupervisor, name: Chidori.News.Supervisor, strategy: :one_for_one},
        Chidori.Relations,
        # 読んだ本棚の覚え書き（データ収集の画面を開くたびに Chiezo へ取りに行かない）
        Chidori.Datasets.ShelfCache,
        Chidori.News.Hatena,
        # 代表作の絵の覚え書き（置き場を持つだけ。引くのは押した人のプロセス）
        Chidori.Artwork,
        # 関連図の顔写真を 1 枚ずつ間を空けて取りに行く列
        Chidori.Relations.Faces
      ] ++
        scheduler() ++
        [ChidoriWeb.Endpoint]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Chidori.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # 要約を作る時刻の時計。テストでは立てない —— 1 分ごとに起きて Chiezo を
  # 叩きに行かれると、何を見ているのか分からないテストになります
  defp scheduler do
    if Application.get_env(:chidori, :digest_scheduler, true),
      do: [Chidori.Digest.Scheduler],
      else: []
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ChidoriWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
