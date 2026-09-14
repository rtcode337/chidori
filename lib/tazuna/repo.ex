defmodule Tazuna.Repo do
  @moduledoc """
  唯一のデータストア。設定・集めたものの選別結果・通知の記録がここに残ります。

  **メモリに持たない理由は通知にあります。** 「同じものを二度知らせない」を成り立たせる
  には、何を知らせたかが再起動を跨いで残っている必要があります。設定も同じで、
  再起動で消える設定は設定として使えません。
  """

  use Ecto.Repo,
    otp_app: :tazuna,
    adapter: Ecto.Adapters.Postgres
end
