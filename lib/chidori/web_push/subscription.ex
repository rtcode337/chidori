defmodule Chidori.WebPush.Subscription do
  @moduledoc """
  通知を受け取る端末 1 台。ブラウザが `PushManager.subscribe()` で渡す宛先（`endpoint`）と、
  中身を暗号にするための端末の鍵（`p256dh`・`auth`。base64url）を持ちます。

  `label` は画面で見分けるための名前（「iPhone」「Mac Chrome」）。登録したときの
  ブラウザの名乗りから作ります。
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "web_push_subscriptions" do
    field(:endpoint, :string)
    field(:p256dh, :string)
    field(:auth, :string)
    field(:label, :string, default: "")

    timestamps(type: :utc_datetime)
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:endpoint, :p256dh, :auth, :label])
    |> validate_required([:endpoint, :p256dh, :auth])
    # **配信先は https だけ**（ブラウザが渡す宛先はどれも https。それ以外は受け取らない）
    |> validate_format(:endpoint, ~r{\Ahttps://}, message: "https の宛先ではありません")
    |> validate_length(:endpoint, max: 2000)
    |> validate_key(:p256dh, 65)
    |> validate_key(:auth, 16)
    |> validate_length(:label, max: 100)
    |> unique_constraint(:endpoint)
  end

  # 鍵が読めない登録を受け取ると、送るたびに失敗する端末が残る
  defp validate_key(changeset, field, size) do
    validate_change(changeset, field, fn ^field, value ->
      case Chidori.WebPush.decode_b64(value) do
        {:ok, key} when byte_size(key) == size -> []
        _other -> [{field, "鍵の形が違います"}]
      end
    end)
  end
end
