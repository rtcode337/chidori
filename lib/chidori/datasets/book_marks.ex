defmodule Chidori.Datasets.BookMarks do
  @moduledoc """
  技術書に付けた「読んだ」印とメモの置き場（`Chidori.Relations.Marks` と同じ形）。

  **利用者が書いたことは Chidori の側で持ちます。** 本棚は Chiezo の収集から読んで
  いますが、「この本はもう読んだ」は利用者ごとの事情なので、収集には書きません。
  置き場は Chiezo の `chidori_data`（`Chidori.DataStore`。記録の形は
  `Chidori.DataStore.MarkRecords`、種類は `books`）。

  **読んだ本は「いま勧められている上位」から外します**（`read_titles/0` →
  `ChidoriWeb.TopBooks`）。上位の枠は「次に何を読むか」を決めるためのもので、
  読み終えた本が並び続けると、まだ読んでいない本が押し出される。本棚の一覧には
  残し、読んだことが分かる印を付けます。
  """

  alias Chidori.Datasets.BookMark
  alias Chidori.DataStore.MarkRecords

  @view "books"

  @doc "付いている印を、本の見出しで引ける形で返します。読めなければ空。"
  def all do
    Map.new(MarkRecords.for_view(@view), fn {title, doc} -> {title, mark_of(title, doc)} end)
  end

  @doc "読んだ本の見出し（上位の枠から外すもの）。読めなければ空。"
  def read_titles do
    for {title, %BookMark{read: true}} <- all(), into: MapSet.new(), do: title
  end

  @doc "1 冊ぶん。まだ付いていなければ `nil`。"
  def get(title) when is_binary(title) do
    case MarkRecords.for_view(@view) do
      %{^title => doc} -> mark_of(title, doc)
      _none -> nil
    end
  end

  @doc """
  印を書き込みます。**何も書かれていない印は残さず消します**。
  返すのは `{:ok, mark | nil}`（消したときは `nil`）か `{:error, changeset}`。
  """
  def put(title, attrs) when is_binary(title) do
    mark = get(title) || %BookMark{}
    changeset = BookMark.changeset(mark, Map.put(attrs, "title", title))

    with {:ok, applied} <- Ecto.Changeset.apply_action(changeset, :insert) do
      if BookMark.blank?(applied), do: delete(mark), else: save(applied, changeset)
    end
  end

  defp save(%BookMark{} = mark, changeset) do
    fields = %{done: mark.read, on: mark.read_on, note: mark.note}

    case MarkRecords.put(@view, mark.title, fields, mark.doc_id) do
      {:ok, doc_id} -> {:ok, %{mark | doc_id: doc_id}}
      {:error, _reason} -> {:error, Ecto.Changeset.add_error(changeset, :title, "を保存できませんでした")}
    end
  end

  defp delete(%BookMark{doc_id: doc_id} = mark) do
    case MarkRecords.delete(doc_id) do
      :ok ->
        {:ok, nil}

      {:error, _reason} ->
        {:error, mark |> Ecto.Changeset.change() |> Ecto.Changeset.add_error(:title, "を消せませんでした")}
    end
  end

  defp mark_of(title, doc) do
    %{done: done, on: on, note: note} = MarkRecords.fields(doc)
    %BookMark{doc_id: doc.doc_id, title: title, read: done, read_on: on, note: note}
  end
end
