defmodule Chidori.WebPush.Subscriptions do
  @moduledoc """
  通知を受け取る端末の一覧（設定の「通知」タブで登録・削除する）と、全部の端末へ送るところ。

  **全部の端末に同じものを送ります。** 話題ごとに知らせるかどうかは ntfy と同じく
  話題の設定（`notify`）で決めていて、端末ごとには分けません。

  **表がまだ無い DB（マイグレーション前）でも画面を落としません。** 一覧は空として返します。
  """

  import Ecto.Query

  alias Chidori.Repo
  alias Chidori.WebPush
  alias Chidori.WebPush.Subscription

  require Logger

  @doc "登録してある端末（新しい順）。表が無ければ空。"
  def list do
    Repo.all(from(s in Subscription, order_by: [desc: s.inserted_at, desc: s.id]))
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning("端末の一覧を読めなかった: #{Exception.message(error)}")
      []
  end

  @doc """
  端末を登録します。`params` はブラウザの `PushSubscription.toJSON()` の形
  （`%{"endpoint" => ..., "keys" => %{"p256dh" => ..., "auth" => ...}}`）。

  **同じ宛先は上書きします**（登録し直した端末を 2 台に数えない）。
  """
  def subscribe(params, user_agent \\ "") do
    keys = Map.get(params, "keys") || %{}

    attrs = %{
      endpoint: params["endpoint"],
      p256dh: keys["p256dh"],
      auth: keys["auth"],
      label: label(user_agent)
    }

    %Subscription{}
    |> Subscription.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:p256dh, :auth, :label, :updated_at]},
      conflict_target: :endpoint,
      returning: true
    )
  end

  @doc "端末を消します（画面の「外す」と、届かなくなった端末）。"
  def delete(id) do
    from(s in Subscription, where: s.id == ^id) |> Repo.delete_all()
    :ok
  end

  @doc "宛先で消します（この端末で通知を止めたとき）。"
  def delete_endpoint(endpoint) when is_binary(endpoint) do
    from(s in Subscription, where: s.endpoint == ^endpoint) |> Repo.delete_all()
    :ok
  end

  @doc """
  全部の端末へ送ります。返すのは `[{端末, :ok | :expired | {:error, 理由}}]`。

  **届けられなくなった端末（`:expired`）はここで消します。**
  """
  def deliver_all(title, body, url, opts \\ []) do
    payload =
      Jason.encode!(%{
        title: title,
        body: body,
        url: url,
        tag: Keyword.get(opts, :tag, "chidori")
      })

    for subscription <- list() do
      result = WebPush.send_notification(subscription, payload)

      case result do
        :ok ->
          :ok

        :expired ->
          delete(subscription.id)

        {:error, reason} ->
          Logger.warning("端末へ知らせられなかった（#{subscription.label}）: #{inspect(reason)}")
      end

      {subscription, result}
    end
  end

  @doc """
  送った結果の言い方（「2 台に送りました」）。**届かなかった台数と、消した台数も出します**。
  """
  def result_text([]), do: "登録してある端末がありません。"

  def result_text(results) do
    count = fn wanted -> Enum.count(results, fn {_s, result} -> wanted.(result) end) end
    sent = count.(&(&1 == :ok))
    expired = count.(&(&1 == :expired))
    failed = count.(&match?({:error, _}, &1))

    ["#{sent} 台に送りました。"]
    |> then(&if(failed > 0, do: &1 ++ ["#{failed} 台は送れませんでした。"], else: &1))
    |> then(&if(expired > 0, do: &1 ++ ["受け取れなくなっていた #{expired} 台の登録を外しました。"], else: &1))
    |> Enum.join("")
  end

  @doc """
  画面で見分けるための端末の名前（「iPhone」「Mac Chrome」）。ブラウザの名乗りから作ります。

  細かく当てには行きません —— 並んだ端末のどれが手元のものかが分かれば足ります。
  """
  def label(user_agent) when is_binary(user_agent) do
    device =
      cond do
        user_agent =~ "iPhone" -> "iPhone"
        user_agent =~ "iPad" -> "iPad"
        user_agent =~ "Android" -> "Android"
        user_agent =~ "CrOS" -> "ChromeOS"
        user_agent =~ "Macintosh" -> "Mac"
        user_agent =~ "Windows" -> "Windows"
        user_agent =~ "Linux" -> "Linux"
        true -> "端末"
      end

    browser =
      cond do
        user_agent =~ "Edg" -> "Edge"
        user_agent =~ ~r/Firefox|FxiOS/ -> "Firefox"
        user_agent =~ ~r/Chrome|CriOS/ -> "Chrome"
        # iPhone のホーム画面から開いたものは Safari を名乗らない（ブラウザ名は付けない）
        user_agent =~ "Safari" -> "Safari"
        true -> nil
      end

    [device, browser] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  def label(_user_agent), do: "端末"
end
