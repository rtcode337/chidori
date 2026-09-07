defmodule Antenna.Relations do
  @moduledoc """
  関連図ページで使う、表示用のネットワークデータです。

  初期表示のサンプルは関係の見せ方を示すためのものです。「関連図を収集」を押すと
  Chiezo 経由の AI が公開情報を調べ、同じ形式へ差し替えます。収集に失敗しても
  直前の図は残します。

  取得は `Task.Supervisor` の下で動かし、この GenServer では待ちません。
  結果は `subscribe/1` した先へ届きます。
  """

  use GenServer

  require Logger

  alias Antenna.Http

  # 図を描く面の大きさ。サンプルの座標もこの中に収めてある
  @canvas_width 980
  @canvas_height 560

  @request_timeout 120_000
  @connect_timeout 5_000
  @user_agent "antenna/0.1 (+https://github.com/rtcode337/antenna)"

  # 押すたびに AI へ投げると枠を使い切る。こちら側で間隔を空ける
  @min_interval_ms 15_000

  # 図に置ける上限。増やすと札が重なって読めなくなる
  @max_nodes %{"people" => 10, "painters" => 8}
  @max_edges 14
  @max_sources 6
  # 線の上に出す文字。長いと隣の線の札と重なる
  @max_label_chars 24

  @views %{
    "people" => %{
      title: "人物のつながり",
      eyebrow: "FAMILY & DUO",
      description: "家族とコンビを、関係の種類ごとにたどれます。",
      width: @canvas_width,
      height: @canvas_height,
      nodes: [
        %{id: "yusaku", name: "松田優作", note: "俳優", x: 130, y: 145, kind: :person, years: nil},
        %{id: "miyuki", name: "松田美由紀", note: "俳優・写真家", x: 310, y: 85, kind: :person, years: nil},
        %{id: "ryuhei", name: "松田龍平", note: "俳優", x: 350, y: 205, kind: :person, years: nil},
        %{id: "shota", name: "松田翔太", note: "俳優", x: 535, y: 145, kind: :person, years: nil},
        %{
          id: "two_beats",
          name: "ツービート",
          note: "漫才コンビ",
          x: 180,
          y: 395,
          kind: :group,
          years: nil
        },
        %{id: "takeshi", name: "ビートたけし", note: "メンバー", x: 410, y: 335, kind: :person, years: nil},
        %{id: "kiyoshi", name: "ビートきよし", note: "メンバー", x: 410, y: 455, kind: :person, years: nil}
      ],
      edges: [
        %{from: "yusaku", to: "miyuki", label: "配偶者", kind: :family},
        %{from: "yusaku", to: "ryuhei", label: "親子", kind: :family},
        %{from: "miyuki", to: "ryuhei", label: "親子", kind: :family},
        %{from: "yusaku", to: "shota", label: "親子", kind: :family},
        %{from: "miyuki", to: "shota", label: "親子", kind: :family},
        %{from: "two_beats", to: "takeshi", label: "メンバー", kind: :duo},
        %{from: "two_beats", to: "kiyoshi", label: "メンバー", kind: :duo}
      ],
      sources: [
        %{
          label: "松田優作（Wikipedia）",
          url: "https://ja.wikipedia.org/wiki/%E6%9D%BE%E7%94%B0%E5%84%AA%E4%BD%9C"
        },
        %{
          label: "ツービート（Wikipedia）",
          url: "https://ja.wikipedia.org/wiki/%E3%83%84%E3%83%BC%E3%83%93%E3%83%BC%E3%83%88"
        }
      ]
    },
    "painters" => %{
      title: "画家の影響と時代",
      eyebrow: "ARTISTS & INFLUENCE",
      description: "左から右へ、影響がつながる流れを表します。ノード下の帯は活躍した年代の目安です。",
      width: @canvas_width,
      height: @canvas_height,
      nodes: [
        %{
          id: "delacroix",
          name: "ウジェーヌ・ドラクロワ",
          note: "ロマン主義",
          x: 100,
          y: 165,
          kind: :artist,
          years: "1820–1860"
        },
        %{
          id: "manet",
          name: "エドゥアール・マネ",
          note: "近代絵画",
          x: 285,
          y: 105,
          kind: :artist,
          years: "1850–1880"
        },
        %{
          id: "monet",
          name: "クロード・モネ",
          note: "印象派",
          x: 470,
          y: 210,
          kind: :artist,
          years: "1860–1920"
        },
        %{
          id: "van_gogh",
          name: "フィンセント・ファン・ゴッホ",
          note: "ポスト印象派",
          x: 650,
          y: 110,
          kind: :artist,
          years: "1880–1890"
        },
        %{
          id: "matisse",
          name: "アンリ・マティス",
          note: "フォーヴィスム",
          x: 835,
          y: 205,
          kind: :artist,
          years: "1890–1950"
        }
      ],
      edges: [
        %{from: "delacroix", to: "manet", label: "色彩表現", kind: :influence},
        %{from: "manet", to: "monet", label: "近代絵画", kind: :influence},
        %{from: "monet", to: "van_gogh", label: "印象派", kind: :influence},
        %{from: "van_gogh", to: "matisse", label: "色彩", kind: :influence}
      ],
      sources: [
        %{
          label: "フィンセント・ファン・ゴッホ（Wikipedia）",
          url:
            "https://ja.wikipedia.org/wiki/%E3%83%95%E3%82%A3%E3%83%B3%E3%82%BB%E3%83%B3%E3%83%88%E3%83%BB%E3%83%95%E3%82%A1%E3%83%B3%E3%83%BB%E3%82%B4%E3%83%83%E3%83%9B"
        },
        %{
          label: "アンリ・マティス（Wikipedia）",
          url:
            "https://ja.wikipedia.org/wiki/%E3%82%A2%E3%83%B3%E3%83%AA%E3%83%BB%E3%83%9E%E3%83%86%E3%82%A3%E3%82%B9"
        }
      ]
    }
  }

  def start_link(_options) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def current(key) when is_binary(key) do
    GenServer.call(__MODULE__, {:current, valid_key(key)})
  end

  def collect_now(key) when is_binary(key) do
    GenServer.cast(__MODULE__, {:collect, valid_key(key)})
  end

  def keys, do: Map.keys(@views)

  @doc """
  収集状態の変化を受け取ります。LiveView が接続時に呼びます。
  """
  def subscribe(key) when is_binary(key) do
    Phoenix.PubSub.subscribe(Antenna.PubSub, topic(valid_key(key)))
  end

  @doc """
  種類を切り替えたときに使います。外さないと、見ていない側の収集結果でも
  画面が書き換わります。
  """
  def unsubscribe(key) when is_binary(key) do
    Phoenix.PubSub.unsubscribe(Antenna.PubSub, topic(valid_key(key)))
  end

  @doc """
  設定に関係なく確かめられるよう、鍵の丸めは公開しておく。
  """
  def valid_key(key) when key in ["people", "painters"], do: key
  def valid_key(_key), do: "people"

  @impl true
  def init(:ok) do
    state = %{
      relations: @views,
      statuses: Map.new(keys(), &{&1, :sample}),
      collected_at: %{},
      reasons: %{},
      tasks: %{},
      last_attempt_at: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:current, key}, _from, state) do
    {:reply, public(state, key), state}
  end

  @impl true
  def handle_cast({:collect, key}, state) do
    cond do
      state.statuses[key] == :loading ->
        {:noreply, state}

      throttled?(state, key) ->
        {:noreply, broadcast(put_in(state.reasons[key], :too_soon), key)}

      true ->
        fallback = Map.fetch!(state.relations, key)

        task =
          Task.Supervisor.async_nolink(Antenna.TaskSupervisor, fn ->
            fetch_relation(key, fallback)
          end)

        state =
          state
          |> put_in([:statuses, key], :loading)
          |> put_in([:reasons, key], nil)
          |> put_in([:tasks, task.ref], key)
          |> put_in([:last_attempt_at, key], System.monotonic_time(:millisecond))

        {:noreply, broadcast(state, key)}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.fetch(state.tasks, ref) do
      {:ok, key} ->
        Process.demonitor(ref, [:flush])

        state =
          state
          |> Map.update!(:tasks, &Map.delete(&1, ref))
          |> apply_result(key, result)

        {:noreply, broadcast(state, key)}

      :error ->
        {:noreply, state}
    end
  end

  # タスクが落ちたときも必ず状態を戻す。戻さないと :loading のまま固まり、
  # 収集ボタンが二度と押せなくなる
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.fetch(state.tasks, ref) do
      {:ok, key} ->
        Logger.error("関連図の収集タスクが落ちた: #{inspect(reason)}")

        state =
          state
          |> Map.update!(:tasks, &Map.delete(&1, ref))
          |> apply_result(key, {:error, :collection_crashed})

        {:noreply, broadcast(state, key)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp apply_result(state, key, {:ok, relation}) do
    state
    |> put_in([:relations, key], relation)
    |> put_in([:statuses, key], :ready)
    |> put_in([:reasons, key], nil)
    |> put_in([:collected_at, key], DateTime.utc_now())
  end

  defp apply_result(state, key, {:error, reason}) do
    status = if state.collected_at[key], do: :stale, else: :unavailable

    state
    |> put_in([:statuses, key], status)
    |> put_in([:reasons, key], reason)
  end

  defp throttled?(state, key) do
    case state.last_attempt_at[key] do
      nil -> false
      at -> System.monotonic_time(:millisecond) - at < @min_interval_ms
    end
  end

  defp topic(key), do: "relations:" <> key

  defp broadcast(state, key) do
    Phoenix.PubSub.broadcast(Antenna.PubSub, topic(key), {:relation_updated, public(state, key)})
    state
  end

  defp public(state, key) do
    state.relations
    |> Map.fetch!(key)
    |> Map.put(:status, Map.fetch!(state.statuses, key))
    |> Map.put(:collected_at, Map.get(state.collected_at, key))
    |> Map.put(:reason, Map.get(state.reasons, key))
  end

  defp fetch_relation(key, fallback) do
    with base_url when is_binary(base_url) <- chiezo_base_url(),
         {:ok, content} <- ask_chiezo(base_url, key) do
      decode_relation(content, key, fallback)
    else
      nil -> {:error, :chiezo_not_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  defp chiezo_base_url do
    case System.get_env("CHIEZO_BASE_URL") do
      nil -> nil
      "" -> nil
      value -> String.trim_trailing(String.trim(value), "/")
    end
  end

  defp ask_chiezo(base_url, key) do
    payload =
      Jason.encode!(%{
        backend: System.get_env("CHIEZO_RELATIONS_BACKEND", "claude"),
        model: System.get_env("CHIEZO_RELATIONS_MODEL"),
        messages: [
          %{role: "system", content: system_prompt()},
          %{role: "user", content: user_prompt(key)}
        ],
        web: true
      })

    options = [
      headers: [{"user-agent", @user_agent}],
      content_type: "application/json",
      timeout: @request_timeout,
      connect_timeout: @connect_timeout
    ]

    case Http.post(base_url <> "/v1/ai/complete", payload, options) do
      {:ok, %{status: 200, body: body}} -> decode_completion(body)
      {:ok, %{status: status}} -> {:error, {:chiezo_status, status}}
      {:error, _reason} -> {:error, :chiezo_unavailable}
    end
  end

  defp decode_completion(body) do
    case Jason.decode(body) do
      {:ok, %{"content" => content}} when is_binary(content) and content != "" ->
        {:ok, content}

      _ ->
        {:error, :chiezo_unexpected_body}
    end
  end

  defp system_prompt do
    """
    あなたは公開情報を検証して関連図データを作る編集者です。推測、未確認の親族関係、未成年者、私生活の住所・連絡先は含めません。
    web検索で確認できた公開情報だけを使い、各関係には出典URLを対応させます。
    応答はJSONオブジェクトだけにしてください。前置き、説明、コードブロックの囲みは付けません。
    画面は日本語なので、名前・肩書き・関係の説明・出典名はすべて日本語で書きます。
    出典は日本語の資料を優先し、無ければ原語のもので構いません。
    """
  end

  defp user_prompt("people") do
    """
    松田優作、松田美由紀、松田龍平、松田翔太の家族関係と、ツービート、ビートたけし、ビートきよしのコンビ関係について、公開されている情報だけで小さな関連図にしてください。
    JSON: {"nodes":[{"id":"英数字","name":"名前","note":"短い肩書き"}],"edges":[{"from":"id","to":"id","label":"親子|配偶者|メンバー","kind":"family|duo"}],"sources":[{"label":"出典名","url":"https://..."}]}。
    ノードは4〜10件、エッジは出典で確認できるものだけ、sourcesは2〜6件。本文や口コミは転載しません。
    labelは図の線の上に置くので、#{@max_label_chars}文字以内の短い語にしてください。
    """
  end

  defp user_prompt("painters") do
    """
    ウジェーヌ・ドラクロワ、エドゥアール・マネ、クロード・モネ、フィンセント・ファン・ゴッホ、アンリ・マティスについて、公開資料で説明できる影響関係を時代順に小さな関連図にしてください。
    JSON: {"nodes":[{"id":"英数字","name":"名前","note":"様式や地域","years":"活躍年代の目安"}],"edges":[{"from":"id","to":"id","label":"影響の要約","kind":"influence"}],"sources":[{"label":"出典名","url":"https://..."}]}。
    ノードは4〜8件、矢印は影響を与えた側から受けた側へ、各関係は出典で確認できるものだけ、sourcesは2〜6件。
    labelは図の線の上に置くので、#{@max_label_chars}文字以内の短い語にしてください。
    """
  end

  @doc false
  # AI の応答を図のデータへ直す。ここだけを取り出してテストできるようにしてある
  def decode_relation(content, key, fallback) do
    key = valid_key(key)

    case Enum.find_value(json_candidates(content), &decode_payload(&1, key, fallback)) do
      nil -> {:error, :invalid_ai_response}
      relation -> {:ok, relation}
    end
  end

  defp decode_payload(candidate, key, fallback) do
    with {:ok, %{"nodes" => nodes, "edges" => edges, "sources" => sources}} <-
           Jason.decode(candidate),
         parsed_nodes when length(parsed_nodes) >= 2 <- parse_nodes(nodes, key),
         parsed_edges when parsed_edges != [] <- parse_edges(edges, parsed_nodes, key),
         parsed_sources when parsed_sources != [] <- parse_sources(sources) do
      laid_out = layout_nodes(parsed_nodes, key)

      %{
        fallback
        | nodes: laid_out,
          edges: parsed_edges,
          sources: parsed_sources,
          width: canvas_width(length(laid_out), key),
          height: canvas_height(length(laid_out), key)
      }
    else
      _ -> nil
    end
  end

  # 応答は素の JSON とは限らない。コードブロックで囲む相手が多いので、
  # 囲みを外したものと、最初の { から最後の } までを切り出したものも試す
  @doc false
  def json_candidates(content) when is_binary(content) do
    trimmed = String.trim(content)

    [trimmed, strip_code_fence(trimmed), between_braces(trimmed)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  def json_candidates(_content), do: []

  defp strip_code_fence("```" <> rest) do
    rest
    |> String.replace(~r/\A[a-zA-Z0-9_+-]*[ \t]*\r?\n/, "")
    |> String.replace(~r/\r?\n?[ \t]*```[\s]*\z/, "")
    |> String.trim()
  end

  defp strip_code_fence(_text), do: nil

  defp between_braces(text) do
    case Regex.run(~r/\{.*\}/s, text) do
      [json] -> json
      _ -> nil
    end
  end

  defp parse_nodes(nodes, key) when is_list(nodes) do
    nodes
    |> Enum.take(Map.fetch!(@max_nodes, key))
    |> Enum.flat_map(fn
      node when is_map(node) ->
        id = node["id"]
        name = node["name"]

        if is_binary(id) and id =~ ~r/^[a-zA-Z0-9_-]{1,40}$/ and is_binary(name) and
             String.trim(name) != "" do
          [
            %{
              id: id,
              name: short_text(name, 60),
              note: short_text(node["note"], 30),
              years: short_text(node["years"], 20),
              kind: node_kind(key)
            }
          ]
        else
          []
        end

      _node ->
        []
    end)
    |> Enum.uniq_by(& &1.id)
  end

  defp parse_nodes(_nodes, _key), do: []

  defp parse_edges(edges, nodes, key) when is_list(edges) do
    ids = MapSet.new(nodes, & &1.id)
    allowed = if key == "people", do: ["family", "duo"], else: ["influence"]

    edges
    |> Enum.take(@max_edges)
    |> Enum.flat_map(fn
      edge when is_map(edge) ->
        from = edge["from"]
        to = edge["to"]
        kind = edge["kind"]

        if is_binary(from) and is_binary(to) and from != to and MapSet.member?(ids, from) and
             MapSet.member?(ids, to) and kind in allowed do
          [
            %{
              from: from,
              to: to,
              label: short_text(edge["label"], @max_label_chars),
              kind: edge_kind(kind)
            }
          ]
        else
          []
        end

      _edge ->
        []
    end)
    |> Enum.uniq_by(&{&1.from, &1.to})
  end

  defp parse_edges(_edges, _nodes, _key), do: []

  defp edge_kind("family"), do: :family
  defp edge_kind("duo"), do: :duo
  defp edge_kind("influence"), do: :influence

  defp parse_sources(sources) when is_list(sources) do
    sources
    |> Enum.take(@max_sources)
    |> Enum.flat_map(fn
      source when is_map(source) ->
        with label when is_binary(label) <- source["label"],
             url when is_binary(url) <- source["url"],
             %URI{scheme: scheme, host: host} when is_binary(host) and host != "" <-
               URI.parse(url),
             true <- scheme in ["http", "https"] do
          [%{label: short_text(label, 100), url: url}]
        else
          _ -> []
        end

      _source ->
        []
    end)
    |> Enum.uniq_by(& &1.url)
  end

  defp parse_sources(_sources), do: []

  # 面の大きさはノード数から決める。固定の面へ詰め込むと、多いときに
  # 枠の外へ出て見えなくなる（人物側は最大10件で3段になる）
  @doc false
  def canvas_width(count, "painters"), do: max(@canvas_width, 200 * count)
  def canvas_width(_count, _key), do: @canvas_width

  @doc false
  def canvas_height(_count, "painters"), do: @canvas_height
  def canvas_height(count, _key), do: max(@canvas_height, 200 * rows(count))

  defp columns(count), do: min(4, max(count, 1))
  defp rows(count), do: ceil(count / columns(count))

  # 左から右へ流す。年代の帯を出すぶん、上下2段に振って重なりを避ける
  @doc false
  def layout_nodes(nodes, "painters") do
    count = length(nodes)
    width = canvas_width(count, "painters")
    cell = width / count

    Enum.with_index(nodes, fn node, index ->
      Map.merge(node, %{
        x: cell * (index + 0.5),
        y: if(rem(index, 2) == 0, do: 190, else: 350)
      })
    end)
  end

  def layout_nodes(nodes, _key) do
    count = length(nodes)
    columns = columns(count)
    cell_width = @canvas_width / columns
    cell_height = canvas_height(count, "people") / rows(count)

    Enum.with_index(nodes, fn node, index ->
      Map.merge(node, %{
        x: cell_width * (rem(index, columns) + 0.5),
        y: cell_height * (div(index, columns) + 0.5)
      })
    end)
  end

  defp node_kind("painters"), do: :artist
  defp node_kind(_key), do: :person

  defp short_text(value, max) when is_binary(value) do
    trimmed = value |> String.trim() |> String.replace(~r/\s+/, " ")

    cond do
      trimmed == "" -> nil
      String.length(trimmed) <= max -> trimmed
      # 切ったことが分かるようにする。切れた文がそのまま出ると、
      # 相手がそう書いたのか途中で切れたのかが読めない
      true -> String.slice(trimmed, 0, max - 1) <> "…"
    end
  end

  defp short_text(_value, _max), do: nil
end
