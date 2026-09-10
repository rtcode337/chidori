defmodule Antenna.ArticleFame do
  @moduledoc """
  記事の知名度（月次ページビュー）の控え 1 件ぶん。

  値の出どころと使い道は `Antenna.Fame` を参照。ここは表の形だけを持ちます。
  **鍵は記事名そのもの**（Chiezo へ渡す値がそのまま鍵なので、別に id を振る意味がない）。
  """

  use Ecto.Schema

  @primary_key {:article, :string, autogenerate: false}
  schema "article_fame" do
    field(:views, :integer, default: 0)
    field(:fetched_at, :utc_datetime)
  end
end
