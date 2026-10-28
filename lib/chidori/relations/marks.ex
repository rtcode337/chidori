defmodule Chidori.Relations.Marks do
  @moduledoc """
  関連図のノードに付けた「見た」印とメモの置き場。

  **利用者が書いたことは Chidori の側で持ちます。** 図そのものは Chiezo の収集から
  読んでいて、読み直すたびに入れ替わりますが、ここに入るのは「この画家の展覧会へ
  行った」のような利用者ごとの事情なので、収集には書きません（あちらは題材も好みも
  持たない側）。置き場は Chiezo の `chidori_data`（`Chidori.DataStore`。記録の形は
  `Chidori.DataStore.MarkRecords`、種類は図の種類）。

  **データ収集の Pi-hole のドメインも、同じ置き場を使います**（view は
  `Chidori.Datasets.Pihole.mark_view/0`、ノードの名前がドメイン）。見たかどうか・いつ・
  ひとこと、という形が同じで、分ける理由が無いため。

  **暫定の形です。** いまは 1 ノードに 1 件で、見たかどうか・いつ・ひとこと、
  だけを持ちます。同じ画家を何度も見に行く記録が要るようになったら、
  展覧会ごとの記録を別に足す形へ広げられます。
  """

  alias Chidori.DataStore.MarkRecords
  alias Chidori.Relations.Mark

  @doc "その図に付いている印を、ノード名で引ける形で返します。"
  def for_view(view) when is_binary(view) do
    Map.new(MarkRecords.for_view(view), fn {name, doc} -> {name, mark_of(view, name, doc)} end)
  end

  @doc "1 ノードぶん。まだ付いていなければ `nil`。"
  def get(view, node_name) when is_binary(view) and is_binary(node_name) do
    case MarkRecords.for_view(view) do
      %{^node_name => doc} -> mark_of(view, node_name, doc)
      _none -> nil
    end
  end

  @doc """
  印を書き込みます。**何も書かれていない印は残さず消します** ——
  印も日付もメモも無い記録が残っていると、図の上で「見た」と見分けが付きません。

  返すのは `{:ok, mark | nil}`（消したときは `nil`）か `{:error, changeset}`。
  """
  def put(view, node_name, attrs) when is_binary(view) and is_binary(node_name) do
    mark = get(view, node_name) || %Mark{}
    attrs = Map.merge(attrs, %{"view" => view, "node_name" => node_name})
    changeset = Mark.changeset(mark, attrs)

    with {:ok, applied} <- Ecto.Changeset.apply_action(changeset, :insert) do
      applied = %{applied | seen_at: seen_at(mark, applied)}
      if Mark.blank?(applied), do: delete(mark), else: save(applied, changeset)
    end
  end

  # 見た印を付けた時刻。**見た印を新しく付けたか、見た日を変えたときだけ**いまにする（メモを直しただけでは
  # 動かさない）。見た印を外したら消す
  defp seen_at(_before, %Mark{seen: false}), do: nil

  defp seen_at(%Mark{seen: true, seen_on: on, seen_at: at}, %Mark{seen_on: on})
       when not is_nil(at),
       do: at

  defp seen_at(_before, _after), do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp save(%Mark{} = mark, changeset) do
    fields = %{
      done: mark.seen,
      on: mark.seen_on,
      note: mark.note,
      # いまは見られない印は、記録の脇書き（`detail`）に持つ（見た・読んだの形を変えずに足す）
      # 見た印を付けた時刻も同じ脇書きに（同じ日に見たものの並びに使う）
      detail:
        %{}
        |> then(
          &if(mark.unavailable_on,
            do: Map.put(&1, "unavailable_on", Date.to_iso8601(mark.unavailable_on)),
            else: &1
          )
        )
        |> then(
          &if(mark.seen_at,
            do: Map.put(&1, "seen_at", DateTime.to_iso8601(mark.seen_at)),
            else: &1
          )
        )
        |> then(&if(&1 == %{}, do: nil, else: &1))
    }

    case MarkRecords.put(mark.view, mark.node_name, fields, mark.doc_id) do
      {:ok, doc_id} ->
        {:ok, %{mark | doc_id: doc_id}}

      {:error, _reason} ->
        {:error, Ecto.Changeset.add_error(changeset, :node_name, "を保存できませんでした")}
    end
  end

  defp delete(%Mark{doc_id: doc_id} = mark) do
    case MarkRecords.delete(doc_id) do
      :ok ->
        {:ok, nil}

      {:error, _reason} ->
        {:error,
         mark |> Ecto.Changeset.change() |> Ecto.Changeset.add_error(:node_name, "を消せませんでした")}
    end
  end

  defp mark_of(view, name, doc) do
    %{done: done, on: on, note: note, detail: detail} = MarkRecords.fields(doc)

    %Mark{
      doc_id: doc.doc_id,
      view: view,
      node_name: name,
      seen: done,
      seen_on: on,
      note: note,
      unavailable_on: unavailable_on(detail),
      seen_at: seen_at_of(detail)
    }
  end

  defp seen_at_of(%{"seen_at" => text}) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      _error -> nil
    end
  end

  defp seen_at_of(_detail), do: nil

  defp unavailable_on(%{"unavailable_on" => text}) when is_binary(text) do
    case Date.from_iso8601(text) do
      {:ok, date} -> date
      _error -> nil
    end
  end

  defp unavailable_on(_detail), do: nil

  @doc "いまは見られない印が付いているか。"
  def unavailable?(%Mark{unavailable_on: %Date{}}), do: true
  def unavailable?(_mark), do: false
end
