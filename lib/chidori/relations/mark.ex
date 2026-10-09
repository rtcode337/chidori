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
  end

  @fields ~w(view node_name seen seen_on note)a

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
  def blank?(%__MODULE__{seen: false, seen_on: nil, note: note}),
    do: String.trim(note || "") == ""

  def blank?(%__MODULE__{}), do: false
end
