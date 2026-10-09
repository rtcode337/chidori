defmodule Chidori.Repo.Migrations.CreateArticleFame do
  @moduledoc """
  記事の知名度（月次ページビュー）の控え。

  値そのものは Chiezo の jawiki が持っているが、**引くのが記事 1 本につき 1 リクエスト**
  なので、図に載せる人数を増やすとそのぶん往復が増える（4,250 人なら 4,250 回）。
  ページビューは月次の値で日々変わるものではないので、こちらで持ち回れば
  2 回目以降は 0 回で済む。

  **落としてよい表**。消えても次に開いたときに引き直すだけで、失われるのは速さだけ。
  """

  use Ecto.Migration

  def change do
    create table(:article_fame, primary_key: false) do
      # 日本語版 Wikipedia の記事名。Chiezo へ渡す鍵そのものを主キーにする
      add :article, :string, primary_key: true, null: false

      # 月次ページビュー（bot 除外）。**引けなかったことも 0 として残す** ——
      # 残さないと、値を持たない記事を毎回引きに行くことになる
      add :views, :integer, null: false, default: 0

      # いつ引いたか。古くなったものだけ引き直すのに使う
      add :fetched_at, :utc_datetime, null: false
    end

    # 古いものを選び出すため（引き直しは期限切れだけが対象）
    create index(:article_fame, [:fetched_at])
  end
end
