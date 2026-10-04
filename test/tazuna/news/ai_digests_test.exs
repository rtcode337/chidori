defmodule Tazuna.News.AiDigestsTest do
  use ExUnit.Case, async: true

  alias Tazuna.News.AiDigests

  test "書き手ごとに最新の 1 本を選び、書き手の名前順に並べる" do
    docs = [
      %{
        "title" => "まとめ b（古い）",
        "tags" => ["まとめ", "担当:b"],
        "body" => "古い",
        "updated_at" => "2026-10-04T01:00:00+00:00"
      },
      %{
        "title" => "まとめ b（新しい）",
        "tags" => ["まとめ", "担当:b"],
        "body" => "新しい",
        "updated_at" => "2026-10-04T04:00:00+00:00"
      },
      %{
        "title" => "まとめ a",
        "tags" => ["まとめ", "担当:a"],
        "body" => "a の要約",
        "updated_at" => "2026-10-04T02:00:00+00:00"
      },
      # 書き手の分からないものは出さない
      %{
        "title" => "まとめ ?",
        "tags" => ["まとめ"],
        "body" => "?",
        "updated_at" => "2026-10-04T05:00:00+00:00"
      }
    ]

    assert [%{author: "a"}, %{author: "b", title: "まとめ b（新しい）", body: "新しい", at: at}] =
             AiDigests.pick_latest(docs)

    assert at == "2026-10-04 13:00 JST"
  end

  test "本文の最後の、目を付けた銘柄の JSON を切り落とす（囲みがあってもなくても）" do
    assert AiDigests.strip_codes("## 要旨\n本文\n\n```json\n{\"notable_codes\": []}\n```\n") ==
             "## 要旨\n本文"

    assert AiDigests.strip_codes("## 要旨\n本文\n{\"notable_codes\":[{\"code\":\"7203\"}]}") ==
             "## 要旨\n本文"

    assert AiDigests.strip_codes("## 要旨\n本文\n") == "## 要旨\n本文"
  end
end
