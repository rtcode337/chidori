defmodule Chidori.Relations.Mark do
  @moduledoc """
  関連図のノード 1 つに付けた「見た」印とメモ。

  **図の中身とは別のもの**です。ノードそのものは Chiezo から読んでいて、
  読み直すたびに入れ替わります。ここに入るのは利用者が書いたことなので、
  図が入れ替わっても残ります。置き場は Chiezo の `chidori_data`（`Chidori.Relations.Marks`）で、
  `doc_id` はその文書の番号。
  """

  use Ecto.Schema

  import Ecto.Changeset

  @note_max 2_000

  @primary_key false
  embedded_schema do
    field(:doc_id, :integer)
    field(:view, :string)
    field(:node_name, :string)
    field(:seen, :boolean, default: false)
    field(:seen_on, :date)
    field(:note, :string, default: "")

    # **いまは見られない**と印を付けた日（映画。配信にも上映にも無い作品を、次に見るものの
    # 候補から外しておく）。nil なら付いていない
    field(:unavailable_on, :date)

    # 見た印を付けた（見た日を変えた）時刻（UTC）。同じ日に見たものを、記録した新しい順に並べるのに使う。
    # この欄を足す前の記録には無い
    field(:seen_at, :utc_datetime)
  end

  @fields ~w(view node_name seen seen_on note unavailable_on)a

  def changeset(mark, attrs) do
    mark
    |> cast(attrs, @fields)
    |> update_change(:note, &String.trim/1)
    |> validate_required([:view, :node_name])
    |> validate_length(:note, max: @note_max)
  end

  @doc """
  何も書かれていない印か。

  **空になった印は残さない**ので、消してよいかの判断をここに置く ——
  印も日付もメモも無い行が残っていると、図の上では「見た」と区別が付かない。
  """
  def blank?(%__MODULE__{seen: false, seen_on: nil, unavailable_on: nil, note: note}),
    do: String.trim(note || "") == ""

  def blank?(%__MODULE__{}), do: false
end
