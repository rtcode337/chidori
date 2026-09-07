defmodule Antenna.SelectionTest do
  use ExUnit.Case, async: false

  alias Antenna.HttpStub
  alias Antenna.Selection

  @base "http://chiezo.test:7010"

  defp topic(overrides \\ %{}) do
    Map.merge(
      %{
        interest: "暮らしへの影響が大きいこと",
        select_backend: nil,
        select_model: nil,
        select_effort: nil
      },
      overrides
    )
  end

  defp candidates do
    [
      %{title: "地震の続報", summary: "要約A"},
      %{title: "静かな話題", summary: "要約B"},
      %{title: "もう一つ", summary: "要約C"}
    ]
  end

  defp answer(picks), do: Jason.encode!(%{"content" => Jason.encode!(%{"picks" => picks})})

  test "候補の中から選ばせる" do
    test_pid = self()

    HttpStub.stub(fn %{method: :post, url: url, body: body} ->
      send(test_pid, {:asked, url, Jason.decode!(body)})
      HttpStub.ok(answer([%{"title" => "地震の続報", "why" => "影響が広いため"}]))
    end)

    assert {:ok, [pick]} = Selection.pick(@base, topic(), candidates())
    assert pick.title == "地震の続報"
    assert pick.why == "影響が広いため"

    assert_received {:asked, url, payload}
    assert url =~ "/v1/ai/complete"
    # 候補は渡してあるので web は開けない（そのぶん速い）
    assert payload["web"] == false

    # 相手を名指ししていなければ、その項目は送らない（Chiezo の既定にまかせる）
    refute Map.has_key?(payload, "backend")
    assert List.last(payload["messages"])["content"] =~ "地震の続報"
  end

  test "選ぶ相手を名指しできる" do
    test_pid = self()

    HttpStub.stub(fn %{body: body} ->
      send(test_pid, {:asked, Jason.decode!(body)})
      HttpStub.ok(answer([]))
    end)

    Selection.pick(
      @base,
      topic(%{select_backend: "antigravity", select_effort: "low"}),
      candidates()
    )

    assert_received {:asked, payload}
    assert payload["backend"] == "antigravity"
    assert payload["effort"] == "low"
    refute Map.has_key?(payload, "model")
  end

  test "候補に無い見出しは落とす" do
    # AI が作った見出しを「選ばれたもの」として出すと、押しても中身が無い
    HttpStub.stub(fn _ ->
      HttpStub.ok(answer([%{"title" => "作り話", "why" => "…"}, %{"title" => "静かな話題"}]))
    end)

    assert {:ok, [%{title: "静かな話題", why: nil}]} = Selection.pick(@base, topic(), candidates())
  end

  test "同じ見出しは 1 つにまとめる" do
    HttpStub.stub(fn _ ->
      HttpStub.ok(answer([%{"title" => "もう一つ"}, %{"title" => "もう一つ"}]))
    end)

    assert {:ok, [_only_one]} = Selection.pick(@base, topic(), candidates())
  end

  test "どれも選ばれないこともある" do
    HttpStub.stub(fn _ -> HttpStub.ok(answer([])) end)
    assert {:ok, []} = Selection.pick(@base, topic(), candidates())
  end

  test "コードブロックで囲まれていても読める" do
    body = Jason.encode!(%{"content" => "```json\n{\"picks\":[{\"title\":\"もう一つ\"}]}\n```"})
    HttpStub.stub(fn _ -> HttpStub.ok(body) end)

    assert {:ok, [%{title: "もう一つ"}]} = Selection.pick(@base, topic(), candidates())
  end

  test "JSON でなければ断る" do
    HttpStub.stub(fn _ -> HttpStub.ok(Jason.encode!(%{"content" => "選べませんでした"})) end)
    assert {:error, :invalid_ai_response} = Selection.pick(@base, topic(), candidates())
  end

  test "Chiezo が落ちていればそう返す" do
    HttpStub.stub(fn _ -> {:error, :boom} end)
    assert {:error, :chiezo_unavailable} = Selection.pick(@base, topic(), candidates())
  end
end
