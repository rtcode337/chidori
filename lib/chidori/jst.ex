defmodule Chidori.Jst do
  @moduledoc """
  人に見せる日時を日本時間で書きます。

  持ち回るのと比べるのは UTC のまま、**変換するのは出す直前だけ**にします。
  実行環境のタイムゾーンには頼りません —— 開発ホストとコンテナで表示が変わると、
  手元では正しく見えるぶん気づけません。

  日本標準時は夏時間を持たないので固定の +09:00 で足ります
  （タイムゾーンの表を引かないぶん、tzdata の無いコンテナでも壊れません）。
  """

  @offset_seconds 9 * 60 * 60

  @doc """
  `2026-09-07 19:38 JST` の形にします。

  Chiezo から届く日時は文字列なので、そのまま渡せるようにしてあります。
  **読めなければ渡されたものをそのまま返します** —— 表示を止めるより、
  元の文字列が出ているほうが状況を追えます。
  """
  def format(nil), do: nil

  def format(%DateTime{} = at) do
    at
    |> DateTime.add(@offset_seconds, :second)
    |> Calendar.strftime("%Y-%m-%d %H:%M JST")
  end

  def format(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> format(at)
      {:error, _reason} -> text
    end
  end

  def format(other), do: other

  @doc """
  いまからどれだけ前か（「3 時間前」）。**読む人がいつのものかを量るための一言**で、
  細かさは要らない —— 1 分未満は「たった今」、1 時間未満は分、2 日未満は時間、
  それより前は日で言う。先の時刻（時計のずれ）は「たった今」にする。
  """
  def ago(%DateTime{} = at, now \\ DateTime.utc_now()) do
    seconds = max(DateTime.diff(now, at, :second), 0)

    cond do
      seconds < 60 -> "たった今"
      seconds < 3600 -> "#{div(seconds, 60)} 分前"
      seconds < 48 * 3600 -> "#{div(seconds, 3600)} 時間前"
      true -> "#{div(seconds, 86_400)} 日前"
    end
  end

  @doc """
  日本時間での「今日」。

  **実行環境のローカル日付に頼りません** —— UTC で動くコンテナでは、
  日本の朝 9 時までが前日になります（「見た日」の既定値がそこでずれる）。
  """
  def today(now \\ DateTime.utc_now()) do
    now |> DateTime.add(@offset_seconds, :second) |> DateTime.to_date()
  end

  @doc "曜日（「月曜」…「日曜」）。日付は日本の暦のまま読む。"
  def weekday_label(%Date{} = date),
    do: Enum.at(~w(月曜 火曜 水曜 木曜 金曜 土曜 日曜), Date.day_of_week(date) - 1)

  @doc "いまの日本時間の `{時, 分}`。"
  def now_hm(now \\ DateTime.utc_now()) do
    jst = DateTime.add(now, @offset_seconds, :second)
    {jst.hour, jst.minute}
  end

  @doc """
  日本時間の「その日の何時何分」を UTC で返します。

  **予定の時刻は JST で決めて、比べるのは UTC** です —— 利用者が書くのは
  「07:00 に知らせて」で、それを実行環境の時計と比べるには UTC に直すしかありません。
  """
  def utc_at(%Date{} = date, hour, minute) do
    date
    |> DateTime.new!(Time.new!(hour, minute, 0), "Etc/UTC")
    |> DateTime.add(-@offset_seconds, :second)
  end
end
