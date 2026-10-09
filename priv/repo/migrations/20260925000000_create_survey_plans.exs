defmodule Chidori.Repo.Migrations.CreateSurveyPlans do
  @moduledoc """
  収集ごとの「整理をどこから・いつ頼むか」。

  **Chiezo には持たせない。** どこを先に見てほしいか、何時に回したいかは利用者の
  都合で、Chiezo は題材も都合も持たない側。時計は Chidori が持ち、Chiezo には
  「いまこの区画を見て」としか言わない（要約と同じ立場）。
  """

  use Ecto.Migration

  def change do
    create table(:survey_plans) do
      add(:collection, :string, null: false)

      # 起点の地名と座標。**ここから放射状に広げる**（ざっと見ると同じ回り方）
      add(:place, :string, null: false, default: "")
      add(:lat, :float)
      add(:lon, :float)

      # 起点を決めた時刻。**これより前に見た区画は、まだ見ていないものとして扱う** ——
      # 起点を変えたら、新しい起点から回り直す
      add(:place_set_at, :utc_datetime)
      # 頼む時刻（JST、「03:00,15:00」の形）。空なら自分からは回らない
      add(:run_at, :string, null: false, default: "")
      add(:last_run_at, :utc_datetime)
      add(:last_result, :text, null: false, default: "")

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:survey_plans, [:collection]))
  end
end
