defmodule Tazuna.Notify.Setting do
  @moduledoc """
  話題 1 つぶんの通知先。**利用者が決めることだけ**を持ちます。

  話題そのものの定義（名前・関心・配信元）はコードにあります（`Tazuna.Topics`）——
  DB に定義を持たせていた頃は、コードに足した話題が既に使っている環境へ永遠に
  届きませんでした。
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "notify_settings" do
    field(:collection, :string)
    field(:ntfy_topic, :string, default: "")
    field(:ntfy_base_url, :string, default: "")

    timestamps(type: :utc_datetime)
  end

  @fields ~w(collection ntfy_topic ntfy_base_url)a

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, @fields)
    |> update_change(:ntfy_topic, &String.trim/1)
    |> update_change(:ntfy_base_url, &(&1 |> String.trim() |> String.trim_trailing("/")))
    |> validate_required([:collection])
    |> validate_length(:ntfy_topic, max: 200)
    |> validate_length(:ntfy_base_url, max: 500)
    # **押せる形だけを受け取る。** 空でない宛先に、置き場が無いのは設定し忘れ
    |> validate_format(:ntfy_base_url, ~r{\A(\z|https?://)},
      message: "http:// か https:// で書いてください"
    )
    |> unique_constraint(:collection)
  end
end
