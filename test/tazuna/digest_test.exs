defmodule Tazuna.DigestTest do
  @moduledoc """
  まとめを作らせて知らせる段取り。見ているのは 3 つ ——
  **整理を先に起こすこと**、**まとめができるまで待つこと**、
  そして**途中で止まったら理由を返すこと**です。
  """

  use Tazuna.DataCase, async: false

  alias Tazuna.Digest
  alias Tazuna.HttpStub
  alias Tazuna.Notify.Settings
  alias Tazuna.Topics

  @collection "tazuna_tech"

  setup do
    System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
    System.put_env("NTFY_BASE_URL", "http://ntfy.test")

    on_exit(fn ->
      System.delete_env("CHIEZO_BASE_URL")
      System.delete_env("NTFY_BASE_URL")
    end)

    Settings.put(@collection, %{"ntfy_topic" => "tazuna-tech"})
    {:ok, topic: Enum.find(Topics.list(), &(&1.collection == @collection))}
  end

  defp collection(overrides) do
    Map.merge(
      %{
        "name" => @collection,
        "enabled" => true,
        "interval_minutes" => 360,
        "last_run_at" => "2026-09-17T00:00:00+00:00",
        "sweeps" => [
          %{"name" => "整理", "interval_minutes" => 240, "enabled" => true},
          %{"name" => "要約", "on_demand" => true, "enabled" => true}
        ]
      },
      overrides
    )
  end

  defp digest(title) do
    %{
      "title" => title,
      "opening" => "冒頭だけ。",
      "tags" => ["まとめ"],
      "updated_at" => "2026-09-17T00:00:00+00:00"
    }
  end

  # 走らせた口を覚えておく。Chiezo は「起こした」までしか返さないので、
  # 起こされた後で状態が変わる、という動きを作る
  defp stub_chiezo(steps) do
    test_pid = self()
    {:ok, seen} = Agent.start_link(fn -> MapSet.new() end)

    HttpStub.stub(fn
      %{method: :post, url: url} = request ->
        which =
          cond do
            String.contains?(url, "/run") -> :refine
            String.contains?(url, "/focus") -> :digest
            true -> :notify
          end

        Agent.update(seen, &MapSet.put(&1, which))
        send(test_pid, {which, url, request.body})
        steps[which] || HttpStub.ok("{}")

      %{method: :get, url: "http://chiezo.test:7010/v1/collect"} ->
        HttpStub.ok(Jason.encode!(%{"collections" => [collection(%{})]}))

      %{method: :get, url: "http://chiezo.test:7010/v1/sources"} ->
        HttpStub.ok(Jason.encode!(%{"sources" => []}))

      %{method: :get, url: "http://chiezo.test:7010/v1/tazuna_tech/doc?" <> _query} ->
        HttpStub.ok(Jason.encode!(%{"title" => "まとめ", "body" => "## 要旨\n読める本文。"}))

      %{method: :get, url: _detail} ->
        done = Agent.get(seen, & &1)

        overrides =
          %{}
          |> Map.put(
            "last_run_at",
            if(MapSet.member?(done, :refine),
              do: "2026-09-17T01:00:00+00:00",
              else: "2026-09-17T00:00:00+00:00"
            )
          )
          |> Map.put(
            "recent",
            if(MapSet.member?(done, :digest),
              do: [digest("まとめ: 新しい回（2026-09-17 07:00）")],
              else: [digest("まとめ: 前の回（2026-09-16 21:00）")]
            )
          )

        HttpStub.ok(Jason.encode!(collection(overrides)))
    end)
  end

  test "整理を起こしてから要約を起こし、できたまとめを知らせる", %{topic: topic} do
    stub_chiezo(%{})

    assert Digest.run(topic) == {:ok, :sent}

    # 整理が先（整理されていないものでまとめさせない）
    assert_received {:refine, refine_url, _body}
    assert refine_url =~ "/run?sweep="
    assert URI.decode(refine_url) =~ "sweep=整理"

    # 要約は時計を持たない巡回なので、割り込みから起こす
    assert_received {:digest, focus_url, body}
    assert focus_url =~ "/focus"
    assert Jason.decode!(body)["sweep"] == "要約"
    # 指示文の無い割り込みは Chiezo が断る
    assert Jason.decode!(body)["note"] != ""

    # 知らせるのは、冒頭だけの要約ではなく取り直した本文から作った文
    assert_received {:notify, _url, notice}
    assert Jason.decode!(notice)["message"] =~ "読める本文。"
  end

  test "整理が終わらなければ、要約は起こさない", %{topic: topic} do
    # 整理の run は受けるが、収集の前回時刻が進まない（走り終えていない）
    test_pid = self()

    HttpStub.stub(fn
      %{method: :post, url: url} ->
        send(test_pid, {:posted, url})
        HttpStub.ok("{}")

      %{method: :get, url: "http://chiezo.test:7010/v1/collect"} ->
        HttpStub.ok(Jason.encode!(%{"collections" => [collection(%{})]}))

      %{method: :get, url: "http://chiezo.test:7010/v1/sources"} ->
        HttpStub.ok(Jason.encode!(%{"sources" => []}))

      %{method: :get, url: _detail} ->
        HttpStub.ok(Jason.encode!(collection(%{"recent" => []})))
    end)

    assert Digest.run(topic) == {:error, :timed_out}

    assert_received {:posted, url}
    assert url =~ "/run"
    refute_received {:posted, _focus}
  end

  test "止まっている収集は、起こさずに断る", %{topic: topic} do
    HttpStub.stub(fn
      %{method: :get, url: "http://chiezo.test:7010/v1/collect"} ->
        HttpStub.ok(Jason.encode!(%{"collections" => [collection(%{"enabled" => false})]}))

      %{method: :get, url: "http://chiezo.test:7010/v1/sources"} ->
        HttpStub.ok(Jason.encode!(%{"sources" => []}))

      %{method: :get, url: _detail} ->
        HttpStub.ok(Jason.encode!(collection(%{"enabled" => false, "recent" => []})))

      %{method: :post, url: url} ->
        flunk("止まっている収集を起こした: #{url}")
    end)

    assert Digest.run(topic) == {:error, :collection_disabled}
  end
end
