defmodule Antenna.Jst do
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
  日本時間での「今日」。

  **実行環境のローカル日付に頼りません** —— UTC で動くコンテナでは、
  日本の朝 9 時までが前日になります（「見た日」の既定値がそこでずれる）。
  """
  def today(now \\ DateTime.utc_now()) do
    now |> DateTime.add(@offset_seconds, :second) |> DateTime.to_date()
  end
end
