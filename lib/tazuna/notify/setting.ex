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
    field(:last_digest_result, :string, default: "")

    timestamps(type: :utc_datetime)
  end

  @fields ~w(collection ntfy_topic ntfy_base_url digest_at last_digest_at last_digest_result)a

  # 時刻の区切り。**読点も空白も受けます** —— 書く人は「08:00、21:00」とも書きます
  @separators ~r/[,、\s]+/

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
  def digest_times(%__MODULE__{digest_at: text}) when is_binary(text), do: times_of(text)

  def digest_times(_setting), do: []

  @doc """
  「07:00,21:00」のように書かれた時刻の並びを読みます（`{時, 分}` を早い順に）。
  **読めないものは落とします**（保存するときに `bad_times/1` で弾いてあるので、
  ここへ来るのは古い書き方くらい）。ほかの定時の設定もこの書き方を使います。
  """
  def times_of(text) when is_binary(text) do
    text
    |> split()
    |> Enum.flat_map(fn part ->
      case parse(part) do
        {:ok, time} -> [time]
        :error -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def times_of(_text), do: []

  @doc "書かれた時刻のうち、読めないもの（空なら全部読める）。"
  def bad_times(text) when is_binary(text),
    do: text |> split() |> Enum.filter(&(parse(&1) == :error))

  def bad_times(_text), do: []

  @doc """
  書かれた時刻 1 つを読みます。**書き方は緩く受けます** —— `08:00` も `8:00` も
  `0800` も `8` も同じ時刻です（全角のコロンも読みます）。

  厳しくすると、**時刻の書き方を間違えただけでフォームごと保存されません** ——
  通知先まで一緒に消えます（実際にそうなりました）。
  """
  def parse(text) when is_binary(text) do
    text = text |> String.replace("：", ":") |> String.trim()

    read =
      cond do
        Regex.match?(~r/\A\d{1,2}:\d{1,2}\z/, text) ->
          [hour, minute] = String.split(text, ":")
          {String.to_integer(hour), String.to_integer(minute)}

        # 「0800」「800」—— 時計の読みをそのまま書く人がいる
        Regex.match?(~r/\A\d{3,4}\z/, text) ->
          {hour, minute} = String.split_at(text, String.length(text) - 2)
          {String.to_integer(hour), String.to_integer(minute)}

        Regex.match?(~r/\A\d{1,2}\z/, text) ->
          {String.to_integer(text), 0}

        true ->
          :error
      end

    case read do
      {hour, minute} when hour in 0..23 and minute in 0..59 -> {:ok, {hour, minute}}
      _other -> :error
    end
  end

  def parse(_text), do: :error

  @doc "時刻 1 つの書き方。**画面に出すのも持つのもこの形**にします。"
  def format({hour, minute}) do
    String.pad_leading("#{hour}", 2, "0") <> ":" <> String.pad_leading("#{minute}", 2, "0")
  end

  defp split(text), do: text |> String.split(@separators) |> Enum.reject(&(&1 == ""))

  @doc "書き方を揃えます（\"8\" と \"08:00\" が別の時刻に見えないように）。"
  def normalize_times(text) do
    text
    |> split()
    |> Enum.map_join(",", fn part ->
      case parse(part) do
        {:ok, time} -> format(time)
        :error -> part
      end
    end)
  end

  defp valid_times(:digest_at, ""), do: []

  defp valid_times(:digest_at, text) do
    if bad_times(text) == [],
      do: [],
      else: [
        digest_at:
          "知らせる時刻は 24 時間制で書いてください" <>
            "（例: 08:00,21:00。0800 や 8:00 も読めます）"
      ]
  end
end
