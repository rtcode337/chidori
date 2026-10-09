defmodule Chidori.DataStoreTest do
  @moduledoc """
  利用者が書いたことの置き場（Chiezo の `chidori_data`）。見ているのは、
  **置き場が無ければ作ってから読むこと**、**全部をページを送って読むこと**です。
  """

  use Chidori.DataCase, async: false

  alias Chidori.DataStore
  alias Chidori.HttpStub

  @base "http://chiezo.test:7010"

  describe "Chiezo の置き場" do
    setup do
      System.put_env("CHIEZO_BASE_URL", @base)
      on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
    end

    test "置き場が無ければ作り、種類ごとに全部を読む" do
      me = self()

      HttpStub.stub(fn
        %{method: :get, url: @base <> "/v1/stores"} ->
          HttpStub.ok(~s({"stores": []}))

        %{method: :post, url: @base <> "/v1/stores", body: body} ->
          send(me, {:created, Jason.decode!(body)})
          {:ok, %{status: 201, body: "{}"}}

        %{method: :get, url: @base <> "/v1/chidori_data/filter?" <> query} ->
          params = URI.decode_query(query)

          results =
            if params["tag"] == "興味トピック",
              do: [%{"doc_id" => 3, "title" => "t", "tags" => ["興味トピック"], "extra" => %{}}],
              else: []

          HttpStub.ok(Jason.encode!(%{"total" => length(results), "results" => results}))
      end)

      assert {:ok, [%{doc_id: 3, tags: ["興味トピック"]}]} = DataStore.Chiezo.load()
      assert_received {:created, %{"name" => "chidori_data"}}
    end

    test "書くときはタグをカンマで、脇書きはそのまま送る" do
      me = self()

      HttpStub.stub(fn %{method: :post, url: @base <> "/v1/stores/chidori_data", body: body} ->
        send(me, {:posted, Jason.decode!(body)})

        HttpStub.ok(
          ~s({"doc_id": 7, "title": "t", "tags": ["見た・読んだ", "種類:books"], "extra": {"key": "本"}})
        )
      end)

      assert {:ok, %{doc_id: 7}} =
               DataStore.Chiezo.add(%{
                 title: "t",
                 text: "t",
                 tags: ["見た・読んだ", "種類:books"],
                 extra: %{"key" => "本"}
               })

      assert_received {:posted, %{"tags" => "見た・読んだ,種類:books", "extra" => %{"key" => "本"}}}
    end
  end
end
