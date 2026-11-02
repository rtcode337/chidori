defmodule Chidori.Relations.PartitionsTest do
  # 判定は Chiezo の `partition._band_locator` と同じ規則。食い違うと、頼んだ区画に
  # 画面で数えた人がいない、ということが起きる
  use ExUnit.Case, async: true

  alias Chidori.Relations.Partitions

  @partitions [
    %{key: "フランス|-1800"},
    %{key: "フランス|1801-1850"},
    %{key: "フランス|1851-"},
    %{key: "フランス|不明|A〜M"},
    %{key: "フランス|不明|N〜Z"},
    %{key: "アルメニア|エストニア|-"},
    %{key: "その他|-"}
  ]

  defp find(tags, title \\ "X"),
    do: Partitions.locator(@partitions, "地域", "年代").(tags, title)

  test "生年の入る帯を選ぶ（生没年は最初の数を見る）" do
    assert find(["地域:フランス", "年代:1840-1926"]) == "フランス|1801-1850"
    assert find(["地域:フランス", "年代:1801-1850"]) == "フランス|1801-1850"
  end

  test "端の帯は外側も引き受ける" do
    assert find(["地域:フランス", "年代:1500-1560"]) == "フランス|-1800"
    assert find(["地域:フランス", "年代:1990-"]) == "フランス|1851-"
  end

  test "年代の無い人は、見出しで置き場を選ぶ" do
    assert find(["地域:フランス"], "B") == "フランス|不明|A〜M"
    assert find(["地域:フランス"], "P") == "フランス|不明|N〜Z"
    # 手前が無ければ先頭の置き場
    assert find(["地域:フランス"], "0") == "フランス|不明|A〜M"
  end

  test "寄せ集めの区画にも入る" do
    assert find(["地域:エストニア", "年代:1900-1950"]) == "アルメニア|エストニア|-"
  end

  test "地域の無い人は「その他」" do
    assert find(["年代:1900-1950"]) == "その他|-"
  end

  test "入る区画が無ければ nil" do
    assert find(["地域:日本", "年代:1900-1950"]) == nil
  end

  describe "月で割った年（Chiezo の detail）" do
    @months [
      %{key: "日本|-2025"},
      %{key: "日本|2026|-2月"},
      %{key: "日本|2026|3-11月"},
      %{key: "日本|2026|12-月"}
    ]

    defp film(tags), do: Partitions.locator(@months, "国", "年代", "公開月").(tags, "X")

    test "公開月の月で月の帯を選ぶ（書き方は「2026年3月」でも「2026-03」でも）" do
      assert film(["国:日本", "年代:2026", "公開月:2026年1月"]) == "日本|2026|-2月"
      assert film(["国:日本", "年代:2026", "公開月:2026年3月"]) == "日本|2026|3-11月"
      assert film(["国:日本", "年代:2026", "公開月:2026-12"]) == "日本|2026|12-月"
    end

    test "月の分からないもの・年の合わない月は最初の月の帯" do
      assert film(["国:日本", "年代:2026"]) == "日本|2026|-2月"
      assert film(["国:日本", "年代:2026", "公開月:2025年12月"]) == "日本|2026|-2月"
    end

    test "月で割っていない年は年の帯、先の年は行き場が無い" do
      assert film(["国:日本", "年代:1990", "公開月:1990年5月"]) == "日本|-2025"
      assert film(["国:日本", "年代:2027", "公開月:2027年1月"]) == nil
    end
  end
end
