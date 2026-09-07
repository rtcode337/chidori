defmodule Antenna.Topics.Topic do
  @moduledoc "話題 1 つぶんの設定。"

  use Ecto.Schema

  import Ecto.Changeset

  # Chiezo のソース名になるので、向こうの決まり(英小文字で始まる 2〜31 文字)に合わせる
  @collection_format ~r/^[a-z][a-z0-9_]{1,30}$/

  schema "topics" do
    field(:name, :string)
    field(:collection, :string)
    field(:interest, :string, default: "")

    field(:collect_backend, :string)
    field(:collect_model, :string)
    field(:collect_effort, :string)
    field(:select_backend, :string)
    field(:select_model, :string)
    field(:select_effort, :string)

    timestamps(type: :utc_datetime)
  end

  @fields ~w(name collection interest collect_backend collect_model collect_effort
             select_backend select_model select_effort)a

  def changeset(topic, attrs) do
    topic
    |> cast(attrs, @fields)
    |> update_change(:name, &String.trim/1)
    |> update_change(:collection, &String.trim/1)
    # 空欄は「指定しない」。空文字のまま持つと、Chiezo へ空の相手を送ることになる
    |> blank_to_nil()
    |> validate_required([:name, :collection])
    |> validate_length(:name, max: 60)
    |> validate_format(:collection, @collection_format,
      message: "英小文字で始まる 2〜31 文字(英小文字・数字・_)にしてください"
    )
    |> unique_constraint(:name)
    |> unique_constraint(:collection)
  end

  defp blank_to_nil(changeset) do
    Enum.reduce(
      ~w(collect_backend collect_model collect_effort
         select_backend select_model select_effort)a,
      changeset,
      fn field, acc ->
        case get_change(acc, field) do
          value when is_binary(value) ->
            if String.trim(value) == "", do: put_change(acc, field, nil), else: acc

          _ ->
            acc
        end
      end
    )
  end
end
