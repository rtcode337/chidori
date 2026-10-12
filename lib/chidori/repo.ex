defmodule Chidori.Repo do
  @moduledoc """
  手元の DB。画面で決めた設定・通知の記録・顔写真の写しなどがここに残ります
  （利用者が書いたこと —— 興味トピック・読んだ・見た記録 —— は `Chidori.DataStore`）。

  **メモリに持たない理由は通知にあります。** 「同じものを二度知らせない」を成り立たせる
  には、何を知らせたかが再起動を跨いで残っている必要があります。設定も同じで、
  再起動で消える設定は設定として使えません。
  """

  use Ecto.Repo,
    otp_app: :chidori,
    adapter: Ecto.Adapters.Postgres
end
