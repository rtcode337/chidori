defmodule Chidori.News.Favorites do
  @moduledoc """
  ニュースのお気に入り。**記事の URL と見出しだけを残します**（原文は持たない）。

  記事は Chiezo の収集に溜まり、流れの収集なので期限（`keep_days`）で消えます。
  古い記事を取っておくと置き場を圧迫するので、それはそのままにして、残したい記事だけを
  ここに控えます。原文は URL の先にあるので、写しは持ちません。

  置き場は見た記録と同じ（Chiezo の `chidori_data`。`Chidori.DataStore.MarkRecords`）。
  **鍵は URL**（見出しは配信元や整理の回で書き換わることがあり、同じ記事が 2 件に割れる）、
  見出しは見せる名前（`label`）に持ちます。どの話題の記事かは持ちません（話題をまたいで
  1 つの一覧に並べるため）。
  """

  alias Chidori.DataStore.MarkRecords

  @view "news_favorites"

  @doc "記録の種類（`Chidori.DataStore.MarkRecords` の view）。"
  def view, do: @view

  @doc """
  お気に入りの一覧。**付けた日の新しい順**（同じ日なら見出し順）。
  1 件は `%{url, title, on, doc_id}`。
  """
  def list do
    for {url, doc} <- MarkRecords.for_view(@view) do
      %{label: label, on: on} = MarkRecords.fields(doc)
      %{url: url, title: label || url, on: on, doc_id: doc.doc_id}
    end
    |> Enum.sort_by(&{-days(&1.on), &1.title})
  end

  defp days(%Date{} = on), do: Date.to_gregorian_days(on)
  defp days(_on), do: 0

  @doc "お気に入りに入っている URL の集まり（一覧の札に印を付けるため）。"
  def urls, do: MapSet.new(Map.keys(MarkRecords.for_view(@view)))

  @doc """
  お気に入りに入れます。**入れた日は日本時間で数えます**（`Chidori.Jst.today/0`）。
  同じ URL を入れ直しても増えません（見出しだけ新しくする）。
  URL の無い記事は入れられません（`{:error, :no_url}`）。
  """
  def add(url, title) do
    case Chidori.SafeUrl.href(url) do
      nil ->
        {:error, :no_url}

      _safe ->
        doc_id =
          case MarkRecords.for_view(@view) do
            %{^url => doc} -> doc.doc_id
            _none -> nil
          end

        fields = %{done: true, on: Chidori.Jst.today(), note: "", label: title}
        MarkRecords.put(@view, url, fields, doc_id)
    end
  end

  @doc "お気に入りから外します。入っていなければ何もしない。"
  def remove(url) do
    case MarkRecords.for_view(@view) do
      %{^url => doc} -> MarkRecords.delete(doc.doc_id)
      _none -> :ok
    end
  end
end
