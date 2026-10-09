defmodule Chidori.Repo.Migrations.CreateNotifySettings do
  @moduledoc """
  話題ごとの通知先。

  **環境変数だけでは、宛先を変えるのに立て直しが要る。** 通知先は運用しながら
  決めるもの（試しに別のトピックへ流す、しばらく止める）なので、画面から直せる
  必要がある。**Chiezo の収集の設定とは立場が違う** —— あちらは向こうが持っている
  ものを読んでいるだけだが、通知先は Chidori にしか無い。

  **話題の定義そのものは持たない**(`Chidori.Topics.defined/0`)。DB に定義を持たせて
  いた頃は、コードに足した話題が既に使っている環境へ永遠に届かなかった。
  ここに置くのは、利用者が決めることだけ。
  """

  use Ecto.Migration

  def change do
    create table(:notify_settings) do
      # どの収集のものか。話題ごとに宛先を分けられないと、技術の話を追いたい
      # だけの人に暮らしの話まで届く
      add :collection, :string, null: false
      # ntfy のトピック名。空なら知らせない（**既定は持たない** —— 公開の ntfy では
      # 推測できる名前は誰でも読める）
      add :ntfy_topic, :string, null: false, default: ""
      # ntfy のルートURL。空なら NTFY_BASE_URL に倒す —— 置き場は環境の事情なので、
      # 画面で上書きできるようにしつつ、既定は環境変数から取る
      add :ntfy_base_url, :string, null: false, default: ""

      timestamps(type: :utc_datetime)
    end

    create unique_index(:notify_settings, [:collection])
  end
end
