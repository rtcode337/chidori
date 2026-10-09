defmodule Chidori.DataStore.MarkRecords do
  @moduledoc """
  読んだ・見た記録の文書の形（`Chidori.DataStore`）。技術書の「読んだ」
  （`Chidori.Datasets.BookMarks`）と、関連図・Pi-hole の「見た」（`Chidori.Relations.Marks`）を
  **同じ形の 1 件 1 文書**にまとめます。どちらも「済んだか・いつ・ひとこと」で、
  分ける理由が無いため。

  | 脇書き（extra） | 中身 |
  |---|---|
  | `view` | 何の記録か（`books`・関連図の種類・Pi-hole の種類） |
  | `key` | 本の見出し・ノードの名前・ドメイン |
  | `done` | 読んだ・見た |
  | `on` | その日（`YYYY-MM-DD`。無ければ持たない） |
  | `note` | ひとこと |

  タグは `見た・読んだ` と `種類:<view>`（Chiezo の画面で絞れるように）。
  """

  alias Chidori.DataStore

  @doc "その種類の記録（`key` → 文書）。"
  def for_view(view) when is_binary(view) do
    for doc <- DataStore.docs(DataStore.mark_tag()),
        doc.extra["view"] == view,
        is_binary(doc.extra["key"]),
        into: %{},
        do: {doc.extra["key"], doc}
  end

  @doc "記録 1 件の中身（`%{done, on, note}`）。"
  def fields(%{extra: extra}) do
    %{
      done: extra["done"] == true,
      on: parse_date(extra["on"]),
      note: extra["note"] || ""
    }
  end

  @doc """
  書きます。`doc_id` があれば差し替え、無ければ足します。返すのは `{:ok, doc_id}` か
  `{:error, 理由}`。
  """
  def put(view, key, %{done: done, on: on, note: note}, doc_id) do
    attrs = record(view, key, done, on, note)

    result =
      if doc_id,
        do: DataStore.update(doc_id, attrs),
        else: DataStore.add(attrs)

    case result do
      {:ok, doc} -> {:ok, doc.doc_id}
      {:error, _reason} = error -> error
    end
  end

  @doc "消します（`doc_id` が無ければ何もしない）。"
  def delete(nil), do: :ok
  def delete(doc_id), do: DataStore.delete(doc_id)

  @doc "1 件の文書の形（前の表から写すときにも使う）。"
  def record(view, key, done, on, note) do
    title = "#{if(view == "books", do: "読んだ", else: "見た")}: #{view} / #{key}"
    on = if match?(%Date{}, on), do: Date.to_iso8601(on), else: on

    %{
      title: title,
      text: Enum.join(Enum.reject([title, note], &(&1 in [nil, ""])), "\n"),
      tags: [DataStore.mark_tag(), "種類:" <> view],
      extra:
        %{"view" => view, "key" => key, "done" => done == true, "note" => note || ""}
        |> then(&if(on in [nil, ""], do: &1, else: Map.put(&1, "on", on)))
    }
  end

  defp parse_date(text) when is_binary(text) do
    case Date.from_iso8601(text) do
      {:ok, date} -> date
      _error -> nil
    end
  end

  defp parse_date(_value), do: nil
end
