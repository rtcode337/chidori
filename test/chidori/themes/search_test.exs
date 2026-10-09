defmodule Chidori.Themes.SearchTest do
  @moduledoc """
  トピックを名前で探す（表記ゆれ・畳んだ言い換えも）。本棚の本と興味トピックの
  突き合わせも同じ均し方を使う。
  """

  use ExUnit.Case, async: true

  alias Chidori.Themes.Search

  defp theme(name, opts \\ []) do
    %{
      name: name,
      parent: opts[:parent],
      docs: opts[:docs] || 1,
      recent: opts[:recent] || 0,
      tags: ["トピック" | Enum.map(opts[:synonyms] || [], &"同義:#{&1}")]
    }
  end

  test "全角半角・大小・カタカナとひらがな・中黒や空白の違いを同じに扱う" do
    assert Search.normalize("Ｃｌａｕｄｅ　Ｃｏｄｅ") == Search.normalize("claude code")
    assert Search.normalize("コーディング・エージェント") == Search.normalize("こーでぃんぐえーじぇんと")
    assert Search.normalize("GitHub-Actions") == Search.normalize("github actions")
  end

  test "畳んだ言い換えでも当たる" do
    themes = [theme("Claude Code", synonyms: ["クロードコード"]), theme("Codex")]

    assert [%{name: "Claude Code"}] = Search.search(themes, "くろーど")
  end

  test "そのもの・前から一致・途中に含む、の順に並べる" do
    themes = [theme("生成AI画像"), theme("画像生成AI"), theme("画像生成")]

    assert Enum.map(Search.search(themes, "画像生成"), & &1.name) == ["画像生成", "画像生成AI"]

    assert Enum.map(Search.search(themes, "生成"), & &1.name) ==
             ["生成AI画像", "画像生成", "画像生成AI"]
  end

  test "空の語では何も返さない" do
    assert Search.search([theme("AI")], "  ") == []
  end

  test "興味トピックに近いのは、そのもの・言い換え・すぐ下の子" do
    themes = [
      theme("AIエージェント", synonyms: ["AI Agent"]),
      theme("Claude Code", parent: "AIエージェント"),
      theme("Kubernetes")
    ]

    near = Search.near_map(themes, ["AIエージェント"])

    assert near[Search.normalize("ai agent")] == "AIエージェント"
    assert near[Search.normalize("claude code")] == "AIエージェント"
    refute Map.has_key?(near, Search.normalize("Kubernetes"))
  end
end
