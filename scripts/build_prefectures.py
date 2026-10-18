#!/usr/bin/env python3
"""県の境界（priv/geo/japan_prefectures.json）を Natural Earth から作る。

手元で一度だけ回し、出来たものをリポジトリに置く（アプリは外へ取りに行かない）。
出どころ・ライセンス・作り方の説明は docs/datasets.md「県の地図」。

    python3 -I scripts/build_prefectures.py --cache <取得したファイルを置く空のディレクトリ>

- 元は Natural Earth の ne_10m_admin_1_states_provinces（パブリックドメイン）。
  取ったファイルは --cache に置き、2 回目からはそれを読む（取り直さない）
- 日本の 47 県（adm0_a3 = JPN）を JIS の番号（iso_3166_2 の JP-01〜47）で拾い、
  名前は Chidori の区画の鍵と同じ書き方（北海道・東京都・京都府…）にする
- 間引きは境目を共有したまま行う（隣り合う県で同じ線を 1 度だけ間引く）。
  県ごとに別々に間引くと、隣との境目に隙間や重なりが出る
- 地図の枠（Chidori.Datasets.Map の範囲を描く地図と同じ 北緯 24.0〜45.8・東経 122.5〜146.0）
  の外にある島（沖ノ鳥島・南鳥島）と、間引くと面にならない小さな島は落とす

外へのリクエストは 1 回だけで、User-Agent にプロジェクトの名前を名乗る（連絡先は入れない）。
"""

import argparse
import json
import math
import os
import sys
import urllib.request

VERSION = "v5.1.2"
URL = (
    "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/"
    f"{VERSION}/geojson/ne_10m_admin_1_states_provinces.geojson"
)
USER_AGENT = "chidori-geo-build (+https://github.com/rtcode337/chidori)"
FILE = "ne_10m_admin_1_states_provinces.geojson"

# JIS X 0401 の番号順（Chidori.Datasets.Gourmet の @prefectures と同じ並び）
PREFECTURES = """
北海道 青森県 岩手県 宮城県 秋田県 山形県 福島県 茨城県 栃木県 群馬県
埼玉県 千葉県 東京都 神奈川県 新潟県 富山県 石川県 福井県 山梨県 長野県
岐阜県 静岡県 愛知県 三重県 滋賀県 京都府 大阪府 兵庫県 奈良県 和歌山県
鳥取県 島根県 岡山県 広島県 山口県 徳島県 香川県 愛媛県 高知県 福岡県
佐賀県 長崎県 熊本県 大分県 宮崎県 鹿児島県 沖縄県
""".split()

# 地図の枠（南, 西, 北, 東）
FRAME = (24.0, 122.5, 45.8, 146.0)

# 間引きの幅（度）。白地図（japan_coast.json）の 0.012 より細かくする ——
# 県は寄って押すので、境目が粗いと隣の県を押してしまう
TOLERANCE = 0.004

# 書き出す桁（0.001 度 ≒ 100 m）
PLACES = 3


def fetch(cache):
    path = os.path.join(cache, FILE)
    if not os.path.exists(path):
        request = urllib.request.Request(URL, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(request, timeout=120) as response, open(path, "wb") as out:
            out.write(response.read())
    with open(path, encoding="utf-8") as source:
        return json.load(source)


def key(point):
    return (round(point[0], 7), round(point[1], 7))


def rings_of(geometry):
    polygons = geometry["coordinates"]
    if geometry["type"] == "Polygon":
        polygons = [polygons]
    for polygon in polygons:
        for ring in polygon:
            points = []
            for point in ring:
                k = key(point)
                if not points or points[-1] != k:
                    points.append(k)
            if len(points) > 1 and points[0] == points[-1]:
                points.pop()
            if len(points) >= 3:
                yield points


def perpendicular(point, start, end):
    (x, y), (x1, y1), (x2, y2) = point, start, end
    dx, dy = x2 - x1, y2 - y1
    if dx == 0 and dy == 0:
        return math.hypot(x - x1, y - y1)
    t = max(0.0, min(1.0, ((x - x1) * dx + (y - y1) * dy) / (dx * dx + dy * dy)))
    return math.hypot(x - (x1 + t * dx), y - (y1 + t * dy))


def douglas_peucker(points):
    """端の 2 点を残して間引く（再帰を使わない形。長い海岸線で深さが足りなくなるため）。"""
    if len(points) <= 2:
        return list(points)
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        first, last = stack.pop()
        far, index = 0.0, None
        for i in range(first + 1, last):
            distance = perpendicular(points[i], points[first], points[last])
            if distance > far:
                far, index = distance, i
        if index is not None and far > TOLERANCE:
            keep[index] = True
            stack.append((first, index))
            stack.append((index, last))
    return [p for p, k in zip(points, keep) if k]


def simplify_arc(arc, cache):
    """同じ線は向きによらず同じ結果にする（隣の県と境目を揃えるため）。"""
    forward = tuple(arc)
    backward = forward[::-1]
    canonical = min(forward, backward)
    if canonical not in cache:
        cache[canonical] = douglas_peucker(list(canonical))
    done = cache[canonical]
    return done if canonical == forward else done[::-1]


def area(points):
    return abs(
        sum(
            points[i][0] * points[(i + 1) % len(points)][1]
            - points[(i + 1) % len(points)][0] * points[i][1]
            for i in range(len(points))
        )
    ) / 2


def inside_frame(points):
    south, west, north, east = FRAME
    return any(south <= lat <= north and west <= lon <= east for lon, lat in points)


def build(data):
    features = {}
    for feature in data["features"]:
        props = feature["properties"]
        code = props.get("iso_3166_2") or ""
        if props.get("adm0_a3") == "JPN" and code.startswith("JP-"):
            features[int(code[3:])] = feature

    missing = [i for i in range(1, 48) if i not in features]
    if missing:
        sys.exit(f"県が足りません: {missing}")

    rings = {number: list(rings_of(features[number]["geometry"])) for number in features}

    # 境目の分かれ目（3 つ以上の線が出会う点）。隣り合う 2 つの点のどちらとも違う相手が
    # 付いた点がそれに当たる。ここで線を切り、線ごとに間引く
    neighbours = {}
    for ring_list in rings.values():
        for ring in ring_list:
            n = len(ring)
            for i, point in enumerate(ring):
                neighbours.setdefault(point, set()).update((ring[i - 1], ring[(i + 1) % n]))
    junction = {point for point, around in neighbours.items() if len(around) > 2}

    arcs = {}
    out = []
    for number in range(1, 48):
        kept = []
        for ring in rings[number]:
            if not inside_frame(ring):
                continue
            cuts = [i for i, p in enumerate(ring) if p in junction]
            if not cuts:
                # 境目を持たない輪（島）。いちばん遠い 2 点で 2 本に切って間引く
                far = max(range(len(ring)), key=lambda i: math.dist(ring[0], ring[i]))
                halves = [ring[: far + 1], ring[far:] + [ring[0]]]
                simplified = []
                for half in halves:
                    simplified.extend(douglas_peucker(half)[:-1])
                if len(simplified) < 3:
                    continue
            else:
                start = cuts[0]
                rotated = ring[start:] + ring[:start]
                cut_at = [i - start if i >= start else i - start + len(ring) for i in cuts]
                cut_at.append(len(ring))
                rotated.append(rotated[0])
                simplified = []
                for a, b in zip(cut_at, cut_at[1:]):
                    simplified.extend(simplify_arc(rotated[a : b + 1], arcs)[:-1])

            rounded = []
            for lon, lat in simplified:
                point = [round(lon, PLACES), round(lat, PLACES)]
                if not rounded or rounded[-1] != point:
                    rounded.append(point)
            if len(rounded) > 1 and rounded[0] == rounded[-1]:
                rounded.pop()
            # 間引いて面にならなかった小さな島は落とす（図の上で 1px に届かない）
            if len(rounded) < 3 or area(rounded) == 0:
                continue
            rounded.append(rounded[0])
            kept.append(rounded)

        if not kept:
            sys.exit(f"{PREFECTURES[number - 1]} の輪が残りませんでした")
        out.append(
            {"name": PREFECTURES[number - 1], "code": f"JP-{number:02d}", "rings": kept}
        )

    return {
        "source": f"Natural Earth (public domain) — ne_10m_admin_1_states_provinces {VERSION}",
        "url": "https://www.naturalearthdata.com/",
        "note": (
            "日本の 47 県（JIS の番号順）。境目を共有したまま "
            f"{TOLERANCE} 度で間引き、{PLACES} 桁に丸めたもの。北緯 {FRAME[0]}〜{FRAME[2]}・"
            f"東経 {FRAME[1]}〜{FRAME[3]} の外の島は入れていない。座標は [経度, 緯度]。"
            "作り方は scripts/build_prefectures.py。"
        ),
        "prefectures": out,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--cache", required=True, help="取得したファイルを置くディレクトリ")
    parser.add_argument("--out", default="priv/geo/japan_prefectures.json")
    args = parser.parse_args()

    result = build(fetch(args.cache))
    with open(args.out, "w", encoding="utf-8") as out:
        json.dump(result, out, ensure_ascii=False, separators=(",", ":"))
        out.write("\n")

    points = sum(len(r) for p in result["prefectures"] for r in p["rings"])
    rings = sum(len(p["rings"]) for p in result["prefectures"])
    print(f"{args.out}: 47 県・{rings} 輪・{points} 点・{os.path.getsize(args.out):,} バイト")


if __name__ == "__main__":
    main()
