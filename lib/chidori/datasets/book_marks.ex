defmodule Chidori.Datasets.BookMarks do
  @moduledoc """
  技術書に付けた「読んだ」印とメモの置き場（`Chidori.Relations.Marks` と同じ形）。

  **利用者が書いたことは Chidori が持ちます。** 本棚は Chiezo から読んでいますが、
  「この本はもう読んだ」は利用者ごとの事情なので、Chiezo には置きません。

  **読んだ本は「いま勧められている上位」から外します**（`read_titles/0` →
  `ChidoriWeb.TopBooks`）。上位の枠は「次に何を読むか」を決めるためのもので、
  読み終えた本が並び続けると、まだ読んでいない本が押し出される。本棚の一覧には
  残し、読んだことが分かる印を付けます。
  """

  import Ecto.Query

  alias Chidori.Datasets.BookMark
  alias Chidori.Repo

  @doc "付いている印を、本の見出しで引ける形で返します。読めなければ空。"
  def all do
    BookMark |> Repo.all() |> Map.new(&{&1.title, &1})
  rescue
    _error -> %{}
  end

  @doc "読んだ本の見出し（上位の枠から外すもの）。読めなければ空。"
  def read_titles do
    BookMark
    |> where([m], m.read == true)
    |> select([m], m.title)
    |> Repo.all()
    |> MapSet.new()
  rescue
    _error -> MapSet.new()
  end

  @doc "1 冊ぶん。まだ付いていなければ `nil`。"
  def get(title) when is_binary(title), do: Repo.get_by(BookMark, title: title)

  @doc """
  印を書き込みます。**何も書かれていない印は残さず消します**。
  返すのは `{:ok, mark | nil}`（消したときは `nil`）か `{:error, changeset}`。
  """
  def put(title, attrs) when is_binary(title) do
    mark = get(title) || %BookMark{}
    changeset = BookMark.changeset(mark, Map.put(attrs, "title", title))

    case Ecto.Changeset.apply_action(changeset, :insert) do
      {:ok, applied} ->
        if BookMark.blank?(applied), do: delete(mark), else: Repo.insert_or_update(changeset)

      {:error, _changeset} = error ->
        error
    end
  end

  defp delete(%BookMark{id: nil}), do: {:ok, nil}

  defp delete(%BookMark{} = mark) do
    case Repo.delete(mark) do
      {:ok, _mark} -> {:ok, nil}
      {:error, _changeset} = error -> error
    end
  end
end
