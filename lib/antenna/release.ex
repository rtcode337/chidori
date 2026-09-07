defmodule Antenna.Release do
  @moduledoc """
  リリース(コンテナ)から呼ぶ運用のための入口。

  **Mix はリリースに入らない**ので、`mix ecto.migrate` は使えない。
  移行はここから走らせる(`bin/antenna eval "Antenna.Release.migrate()"`)。
  """

  @app :antenna

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
