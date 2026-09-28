defmodule Tazuna.News.StockResearchTest do
  @moduledoc "銘柄調査の巡回と依頼文。"

  use ExUnit.Case, async: true

  alias Tazuna.News
  alias Tazuna.News.StockResearch

  setup do
    %{topic: Tazuna.Topics.get("tazuna_stocks")}
  end

  test "時計を持たない情報収集の 1 本だけ", %{topic: topic} do
    # 何を調べるかを知っているのは 売買提案のアプリ だけ。Chiezo の時計で回すと空振りする
    assert [%{name: "情報収集", on_demand: true}] = News.sweeps(topic)
  end

  test "1 件 = 1 銘柄 × 1 日で、売買提案のアプリ が読む JSON を本文の最後に置かせる", %{topic: topic} do
    prompt = StockResearch.prompt(topic)

    assert prompt =~ ~s("<コード> <銘柄名> <今日の日付 YYYY-MM-DD>")
    assert prompt =~ ~s("銘柄:<コード>")
    assert prompt =~ ~s("材料:あり" / "材料:なし")
    assert prompt =~ "```json"
    assert prompt =~ "verified"
    # 空振りも 1 件（調べていないのと区別するため）
    assert prompt =~ "材料が見つからなければ"
  end

  test "記事を集める回も整理の回も持たない" do
    attrs = News.attrs("tazuna_stocks", Tazuna.Topics.get("tazuna_stocks"))

    assert attrs.feed == nil
    assert Enum.map(attrs.sweeps, & &1.name) == ["情報収集"]
    refute attrs.prompt =~ "{cursor}"
  end
end
