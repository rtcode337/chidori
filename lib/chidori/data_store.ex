defmodule Chidori.DataStore do
  @moduledoc """
  **利用者が書いたことの置き場**。興味トピックと、読んだ・見た記録（技術書・関連図・
  Pi-hole のドメイン）を、Chiezo の名前付きの置き場（`chidori_data`）に預けます。

  **Chidori の DB には置きません。** 動かす場所を変えたり DB を作り直したりしても
  消えないように、そして同じ Chiezo を見ている別の Chidori とも同じ記録を共有できる
  ように。短期記憶（`chiezo_memory`）に相乗りしないのは、AI が「さっきの件」を
  探したときに、アプリの記録が混ざって出てこないようにするため。

  **起動したら一度全部読んで手元に持ち、書くときは Chiezo に書いてから手元を直します。**
  画面を開くたびに Chiezo を引きに行かない。読めなかったら 30 秒おきに読み直し、
  読めるまでは空として扱います（書くのは断る —— 読めていない状態で書くと、
  知らずに同じ記録をもう 1 件作る）。

  1 件は Chiezo の文書 1 つで、`%{doc_id, title, tags, extra}` の形で持ちます。
  何の記録かはタグで分けます（`interest_tag/0`・`mark_tag/0`）。

  Chiezo との読み書きは `backend/0` が受け持ちます（テストは手元だけで持つ実装に
  差し替える）。
  """

  use GenServer

  require Logger

  @store "chidori_data"
  @interest_tag "興味トピック"
  @mark_tag "見た・読んだ"
  @retry_ms 30_000

  @doc "置き場の名前（Chiezo の置き場の名前）。"
  def store, do: @store

  @doc "興味トピックの印のタグ。"
  def interest_tag, do: @interest_tag

  @doc "読んだ・見た記録の印のタグ。"
  def mark_tag, do: @mark_tag

  @doc "記録の種類のタグ（全部読むときに引く）。"
  def kind_tags, do: [@interest_tag, @mark_tag]

  @doc "Chiezo との読み書きを受け持つもの。"
  def backend, do: Application.get_env(:chidori, :data_store, Chidori.DataStore.Chiezo)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "そのタグの付いた記録（手元に持っているもの）。読めていなければ空。"
  def docs(tag) when is_binary(tag) do
    GenServer.call(__MODULE__, {:docs, tag})
  catch
    :exit, _reason -> []
  end

  @doc "読めているか。"
  def ready? do
    GenServer.call(__MODULE__, :ready?)
  catch
    :exit, _reason -> false
  end

  @doc "1 件書きます。`{:ok, 記録}` か `{:error, 理由}`。"
  def add(attrs), do: write({:add, attrs})

  @doc "1 件を差し替えます（渡した項目だけ）。"
  def update(doc_id, attrs), do: write({:update, doc_id, attrs})

  @doc "1 件消します。"
  def delete(doc_id), do: write({:delete, doc_id})

  defp write(request) do
    GenServer.call(__MODULE__, request, 30_000)
  catch
    :exit, _reason -> {:error, :data_store_unavailable}
  end

  @doc false
  # テストの入れ替え。手元の記録を空にして、読めた状態から始める
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(_opts) do
    send(self(), :load)
    {:ok, %{docs: %{}, ready: false}}
  end

  @impl true
  def handle_info(:load, state) do
    case backend().load() do
      {:ok, docs} ->
        {:noreply, %{state | docs: Map.new(docs, &{&1.doc_id, &1}), ready: true}}

      {:error, reason} ->
        Logger.warning("chidori_data を読めませんでした（#{inspect(reason)}）。読み直します")
        Process.send_after(self(), :load, @retry_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:docs, tag}, _from, state) do
    found =
      state.docs
      |> Map.values()
      |> Enum.filter(&(tag in &1.tags))
      |> Enum.sort_by(& &1.doc_id)

    {:reply, found, state}
  end

  def handle_call(:ready?, _from, state), do: {:reply, state.ready, state}

  def handle_call(:reset, _from, state) do
    backend().reset()
    {:reply, :ok, %{state | docs: %{}, ready: true}}
  end

  def handle_call(_request, _from, %{ready: false} = state),
    do: {:reply, {:error, :data_store_not_ready}, state}

  def handle_call({:add, attrs}, _from, state) do
    case backend().add(attrs) do
      {:ok, doc} -> {:reply, {:ok, doc}, put_in(state.docs[doc.doc_id], doc)}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:update, doc_id, attrs}, _from, state) do
    current = Map.get(state.docs, doc_id, %{doc_id: doc_id, title: "", tags: [], extra: %{}})

    case backend().update(current, attrs) do
      {:ok, doc} -> {:reply, {:ok, doc}, put_in(state.docs[doc.doc_id], doc)}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:delete, doc_id}, _from, state) do
    case backend().delete(doc_id) do
      :ok -> {:reply, :ok, %{state | docs: Map.delete(state.docs, doc_id)}}
      error -> {:reply, error, state}
    end
  end
end

defmodule Chidori.DataStore.Chiezo do
  @moduledoc """
  `Chidori.DataStore` の Chiezo 側。名前付きの置き場の口（`/v1/stores/…`）を叩きます。
  **置き場が無ければ作ります**（作ってから使う決まりで、無い置き場に書くと 404 になる）。
  """

  alias Chidori.Chiezo
  alias Chidori.DataStore

  @page 500

  def load do
    with {:ok, base} <- base(),
         :ok <- ensure_store(base) do
      Enum.reduce_while(DataStore.kind_tags(), {:ok, []}, fn tag, {:ok, acc} ->
        case pages(base, tag, 0, []) do
          {:ok, docs} -> {:cont, {:ok, acc ++ docs}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, docs} -> {:ok, Enum.uniq_by(docs, & &1.doc_id)}
        error -> error
      end
    end
  end

  def add(attrs) do
    with {:ok, base} <- base() do
      body = Jason.encode!(payload(attrs))
      Chiezo.post(base <> "/v1/stores/" <> DataStore.store(), body) |> decode_doc()
    end
  end

  def update(%{doc_id: doc_id}, attrs) do
    with {:ok, base} <- base() do
      url = base <> "/v1/stores/" <> DataStore.store() <> "/" <> to_string(doc_id)
      url |> Chidori.Http.patch(Jason.encode!(payload(attrs)), json_opts()) |> decode_doc()
    end
  end

  def delete(doc_id) do
    with {:ok, base} <- base() do
      url = base <> "/v1/stores/" <> DataStore.store() <> "/" <> to_string(doc_id)

      case Chidori.Http.delete(url, json_opts()) do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        # もう無い（別の Chidori が消した）。手元からも外せばよい
        {:ok, %{status: 404}} -> :ok
        {:ok, %{status: status}} -> {:error, {:chiezo_status, status}}
        {:error, _reason} -> {:error, :chiezo_unavailable}
      end
    end
  end

  def reset, do: :ok

  defp base do
    case Chiezo.base_url() do
      nil -> {:error, :chiezo_not_configured}
      base -> {:ok, base}
    end
  end

  defp json_opts,
    do: [headers: [{"user-agent", "chidori"}], content_type: "application/json", timeout: 15_000]

  defp ensure_store(base) do
    case Chiezo.get(base <> "/v1/stores") do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"stores" => stores}} ->
            if Enum.any?(stores, &(&1["name"] == DataStore.store())),
              do: :ok,
              else: create_store(base)

          _other ->
            {:error, :chiezo_unexpected_body}
        end

      {:ok, %{status: status}} ->
        {:error, {:chiezo_status, status}}

      {:error, _reason} ->
        {:error, :chiezo_unavailable}
    end
  end

  defp create_store(base) do
    case Chiezo.post(base <> "/v1/stores", Jason.encode!(%{name: DataStore.store()})) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      # 同時に作られた
      {:ok, %{status: 409}} -> :ok
      {:ok, %{status: status}} -> {:error, {:chiezo_status, status}}
      {:error, _reason} -> {:error, :chiezo_unavailable}
    end
  end

  defp pages(base, tag, offset, acc) do
    query =
      URI.encode_query(%{
        "tag" => tag,
        "limit" => @page,
        "offset" => offset,
        "fields" => "doc_id,title,tags,extra"
      })

    with {:ok, %{status: 200, body: body}} <-
           Chiezo.get(base <> "/v1/" <> DataStore.store() <> "/filter?" <> query),
         {:ok, %{"total" => total, "results" => results}} <- Jason.decode(body) do
      got = acc ++ Enum.map(results, &doc_of/1)

      if results == [] or length(got) >= total,
        do: {:ok, got},
        else: pages(base, tag, offset + @page, got)
    else
      {:ok, %{status: status}} -> {:error, {:chiezo_status, status}}
      {:error, %Jason.DecodeError{}} -> {:error, :chiezo_unexpected_body}
      {:error, _reason} -> {:error, :chiezo_unavailable}
      _other -> {:error, :chiezo_unexpected_body}
    end
  end

  defp payload(attrs) do
    attrs
    |> Map.take([:text, :title, :tags, :extra])
    |> Map.update(:tags, nil, &Enum.join(&1, ","))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp decode_doc({:ok, %{status: status, body: body}}) when status in 200..299 do
    case Jason.decode(body) do
      {:ok, %{"doc_id" => _} = doc} -> {:ok, doc_of(doc)}
      _other -> {:error, :chiezo_unexpected_body}
    end
  end

  defp decode_doc({:ok, %{status: status}}), do: {:error, {:chiezo_status, status}}
  defp decode_doc({:error, _reason}), do: {:error, :chiezo_unavailable}

  defp doc_of(doc) do
    %{
      doc_id: doc["doc_id"],
      title: doc["title"] || "",
      tags: doc["tags"] || [],
      extra: doc["extra"] || %{}
    }
  end
end
