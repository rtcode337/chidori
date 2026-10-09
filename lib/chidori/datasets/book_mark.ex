defmodule Chidori.Datasets.BookMark do
  @moduledoc """
  技術書 1 冊に付けた「読んだ」印とメモ。関連図の「見た」印
  （`Chidori.Relations.Mark`）と同じ形です。

  **本棚の中身とは別のもの**です。本は Chiezo から読んでいて、読み直すたびに
  入れ替わります。ここに入るのは利用者が書いたことなので、本棚が入れ替わっても残ります。
  置き場は Chiezo の `chidori_data`（`Chidori.Datasets.BookMarks`）で、`doc_id` はその文書の番号。
  """

  use Ecto.Schema

  import Ecto.Changeset

  @note_max 2_000

  @primary_key false
  embedded_schema do
    field(:doc_id, :integer)
    field(:title, :string)
    field(:read, :boolean, default: false)
    field(:read_on, :date)
    field(:note, :string, default: "")
  end

  @fields ~w(title read read_on note)a

  def changeset(mark, attrs) do
    mark
    |> cast(attrs, @fields)
    |> update_change(:note, &String.trim/1)
    |> validate_required([:title])
    |> validate_length(:note, max: @note_max)
  end

  @doc """
  何も書かれていない印か。**空になった印は残さない**（`Chidori.Relations.Mark.blank?/1`
  と同じ理由 —— 印も日付もメモも無い行が残ると、「読んだ」と見分けが付かない）。
  """
  def blank?(%__MODULE__{read: false, read_on: nil, note: note}),
    do: String.trim(note || "") == ""

  def blank?(%__MODULE__{}), do: false
end
