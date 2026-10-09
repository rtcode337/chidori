defmodule Chidori.Datasets.ShopLinksTest do
  @moduledoc """
  店の説明に添える URL の選び方。見ているのは、**開けない URL と口コミサイトの別の店の頁を
  落とすこと**、**確かめていない URL と断られた URL は使うこと**、
  **http から https への転送は https を書くこと**です。
  """

  use ExUnit.Case, async: true

  alias Chidori.Datasets.ShopLinks

  @site "https://shop.example/"
  @review "https://tabelog.com/kanagawa/A1401/A140210/14000001/"

  test "公式サイト欄を先に使う" do
    assert ShopLinks.pick(%{"website" => @site, "url" => @review}, "キッチン 例", %{}) == @site
  end

  test "まだ確かめていない URL は今までどおり使う" do
    assert ShopLinks.pick(%{"url" => @review}, "キッチン 例", %{}) == @review
  end

  test "開けなかった URL は使わず、次の候補へ" do
    links = %{@site => %{"status" => "HTTP 404"}}
    assert ShopLinks.pick(%{"website" => @site, "url" => @review}, "店", links) == @review
    assert ShopLinks.pick(%{"website" => @site}, "店", links) == ""
  end

  test "断られた URL は使う（人のブラウザでは開ける）" do
    links = %{@site => %{"status" => "断られた(HTTP 403)"}}
    assert ShopLinks.pick(%{"website" => @site}, "店", links) == @site
  end

  test "口コミサイトの頁は、題名に店の名前が無ければ別の店として落とす" do
    other = %{@review => %{"status" => "ok", "title" => "中華 例楼 本店 (駅前/中華料理)"}}
    assert ShopLinks.pick(%{"url" => @review}, "COFFEE SHOP サンプル", other) == ""

    same = %{@review => %{"status" => "ok", "title" => "コーヒーショップ サンプル (駅前/喫茶店)"}}
    assert ShopLinks.pick(%{"url" => @review}, "コーヒーショップ サンプル", same) == @review
  end

  test "公式サイトは題名を問わない（チェーンは会社の名前を題名にする）" do
    links = %{@site => %{"status" => "ok", "title" => "株式会社 例フーズ"}}
    assert ShopLinks.pick(%{"website" => @site}, "例食堂 駅前店", links) == @site
  end

  test "http から https へ同じホストのまま転送されたら、https のほうを書く" do
    http = "http://www.shop.example/"
    links = %{http => %{"status" => "ok", "final_url" => "https://shop.example/", "title" => ""}}
    assert ShopLinks.pick(%{"website" => http}, "店", links) == "https://shop.example/"

    # 別のホストへの転送は、頁が無くなってトップへ飛ばされたものかもしれない
    moved = %{http => %{"status" => "ok", "final_url" => "https://other.example/", "title" => ""}}
    assert ShopLinks.pick(%{"website" => http}, "店", moved) == http
  end

  test "名前の照合は表記の揺れを均す" do
    assert ShopLinks.names_it?("ＫＩＴＣＨＥＮ　ＳＡＭＰＬＥ (駅前/洋食)", "Kitchen Sample")
    refute ShopLinks.names_it?("例ファーム｜予約・アクセス", "キッチン サンプル")
  end

  test "http(s) でないものは使わない" do
    assert ShopLinks.pick(%{"website" => "shop.example", "url" => "ftp://x"}, "店", %{}) == ""
  end
end
