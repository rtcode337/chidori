defmodule Chidori.DataStore.RequestRecords do
  @moduledoc """
  travel-log から届いた依頼の控え（まだ Chiezo に頼んでいないもの）の文書の形
  （`Chidori.DataStore`）。区画ごとに溜まった件数を見てから頼むために持ちます
  （`Chidori.Datasets.Requests`）。

  **置き場は利用者の記録と同じ `chidori_data`。** 控えは利用者が貼ったもので、
  頼むまで何日も溜めておくことがある —— Chidori の DB に持っていると、動かす場所を
  変えたり DB を作り直したりしたときに、まだ頼んでいない依頼が黙って消える。
  本番と手元の Chidori のどちらで貼っても、同じ控えに並ぶ。

  | 脇書き（extra） | 中身 |
  |---|---|
  | `collection` | 収集の名前 |
  | `text` | 依頼の文（travel-log の行のまま。続きの行も含む） |
  | `lat`・`lon` | 区画を引く座標 |
  | `partition_key` | 区画の鍵（座標で区画を引けない対象だけ。ご当地グルメは料理の県） |
  | `at` | 控えた時刻（UTC の ISO 8601） |

  タグは `依頼の控え` と `収集:<collection>`（Chiezo の画面で絞れるように）。
  同じ収集に同じ文の控えは 1 件だけ（`Requests.stash/3` が足す前に見る）。
  """

  require Logger

  alias Chidori.DataStore
  alias Chidori.Datasets.PendingRequest
  alias Chidori.Repo

  @doc """
  その収集の控え（控えた順）。1 件は `%{id, collection, text, lat, lon, partition_key, inserted_at}`
  （`id` は置き場の文書の id）。
  """
  def for_collection(name) when is_binary(name) do
    DataStore.request_tag()
    |> DataStore.docs()
    |> Enum.filter(&(&1.extra["collection"] == name))
    |> Enum.flat_map(&List.wrap(item(&1)))
    |> Enum.sort_by(&{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id})
  end

  @doc "文書 1 件を控えの形に。座標か文が欠けていれば nil。"
  def item(%{doc_id: id, extra: extra}) do
    with text when is_binary(text) and text != "" <- extra["text"],
         lat when is_number(lat) <- extra["lat"],
         lon when is_number(lon) <- extra["lon"] do
      %{
        id: id,
        collection: extra["collection"],
        text: text,
        lat: lat / 1,
        lon: lon / 1,
        partition_key: extra["partition_key"],
        inserted_at: parse_at(extra["at"])
      }
    else
      _missing -> nil
    end
  end

  @doc "控え 1 件の文書の形（`item` は `%{text, lat, lon}` と、あれば `partition_key`）。"
  def record(name, item, %DateTime{} = at) do
    title = "依頼の控え: #{name} / #{first_line(item.text)}"

    %{
      title: title,
      text: item.text,
      tags: [DataStore.request_tag(), "収集:" <> name],
      extra:
        %{
          "collection" => name,
          "text" => item.text,
          "lat" => item.lat,
          "lon" => item.lon,
          "at" => at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        }
        |> then(fn extra ->
          case Map.get(item, :partition_key) do
            key when is_binary(key) and key != "" -> Map.put(extra, "partition_key", key)
            _none -> extra
          end
        end)
    }
  end

  @doc """
  前の表（`pending_requests`）の控えを置き場へ移します（`Chidori.DataStore` が読めたときに呼ぶ）。
  **移せた行と、置き場に同じもの（収集と文）がもうある行は表から消す** —— 残すと、
  頼んで置き場から消えた控えが、次に起動したときにまた写されて戻ってくる。
  書けなかった行は表に残し、次に読めたときにまた試す。足した文書を返す。
  """
  def move_legacy(docs, add) when is_function(add, 1) do
    have =
      for doc <- docs,
          DataStore.request_tag() in doc.tags,
          into: MapSet.new(),
          do: {doc.extra["collection"], doc.extra["text"]}

    PendingRequest
    |> Repo.all()
    |> Enum.sort_by(&{DateTime.to_unix(&1.inserted_at), &1.id})
    |> Enum.flat_map(fn row ->
      if MapSet.member?(have, {row.collection, row.text}) do
        Repo.delete(row)
        []
      else
        case add.(record(row.collection, row, row.inserted_at)) do
          {:ok, doc} ->
            Repo.delete(row)
            [doc]

          {:error, reason} ->
            Logger.warning("前の表の依頼の控えを移せませんでした（#{inspect(reason)}）: #{row.text}")
            []
        end
      end
    end)
  rescue
    error ->
      Logger.warning("前の表の依頼の控えを読めませんでした: #{Exception.message(error)}")
      []
  end

  defp first_line(text), do: text |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 80)

  defp parse_at(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      _error -> DateTime.from_unix!(0)
    end
  end

  defp parse_at(_value), do: DateTime.from_unix!(0)
end
