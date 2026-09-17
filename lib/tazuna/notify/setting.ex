defmodule Tazuna.Notify.Setting do
  @moduledoc """
  話題 1 つぶんの通知先。**利用者が決めることだけ**を持ちます。

  話題そのものの定義（名前・関心・配信元）はコードにあります（`Tazuna.Topics`）——
  DB に定義を持たせていた頃は、コードに足した話題が既に使っている環境へ永遠に
  届きませんでした。
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "notify_settings" do
    field(:collection, :string)
    field(:ntfy_topic, :string, default: "")
    field(:ntfy_base_url, :string, default: "")
    field(:digest_at, :string, default: "")
    field(:last_digest_at, :utc_datetime)

    timestamps(type: :utc_datetime)
  end

  @fields ~w(collection ntfy_topic ntfy_base_url digest_at last_digest_at)a

  # 時刻 1 つぶんの書き方（JST の HH:MM）
  @time ~r/\A([01]?\d|2[0-3]):([0-5]\d)\z/

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, @fields)
    |> update_change(:ntfy_topic, &String.trim/1)
    |> update_change(:ntfy_base_url, &(&1 |> String.trim() |> String.trim_trailing("/")))
    |> validate_required([:collection])
    |> validate_length(:ntfy_topic, max: 200)
    |> validate_length(:ntfy_base_url, max: 500)
    # **押せる形だけを受け取る。** 空でない宛先に、置き場が無いのは設定し忘れ
    |> validate_format(:ntfy_base_url, ~r{\A(\z|https?://)},
      message: "http:// か https:// で書いてください"
    )
    |> update_change(:digest_at, &normalize_times/1)
    |> validate_change(:digest_at, &valid_times/2)
    |> unique_constraint(:collection)
  end

  @doc """
  知らせる時刻（JST）。書かれていなければ空で、その話題は回しません。

  返すのは `{時, 分}` の並びで、**早い順に揃えます** —— 書いた順のまま持つと、
  「次はいつか」を数えるたびに並べ直すことになります。
  """
  def digest_times(%__MODULE__{digest_at: text}) when is_binary(text) do
    text
    |> String.split(",")
    |> Enum.flat_map(fn part ->
      case Regex.run(@time, String.trim(part)) do
        [_all, hour, minute] -> [{String.to_integer(hour), String.to_integer(minute)}]
        _other -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def digest_times(_setting), do: []

  # 書き方は揃えて持つ（"7:0" と "07:00" が別の時刻に見えないように）
  defp normalize_times(text) do
    text
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map_join(",", fn part ->
      case Regex.run(@time, part) do
        [_all, hour, minute] -> String.pad_leading(hour, 2, "0") <> ":" <> minute
        _other -> part
      end
    end)
  end

  defp valid_times(:digest_at, ""), do: []

  defp valid_times(:digest_at, text) do
    bad =
      text
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&Regex.match?(@time, &1))

    if bad == [],
      do: [],
      else: [digest_at: "24 時間制の HH:MM で書いてください（例: 07:00,21:00）"]
  end
end
