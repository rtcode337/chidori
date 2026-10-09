defmodule Chidori.Repo.Migrations.AddDigestResultToNotifySettings do
  use Ecto.Migration

  def change do
    alter table(:notify_settings) do
      # 定時の回がどう終わったか。**画面に出すために残す** ——
      # 残さないと、知らせが来なかった理由はログにしか無い（誰も見ていない時刻に
      # 走る回なので、気づくのは「来ていない」と思ったときになる）
      add(:last_digest_result, :string, null: false, default: "")
    end
  end
end
