#!/usr/bin/env python3
"""
geocode_apts.py - 우아아파트(wooaapt)의 단지(K-apt 단지 + 실거래 전용 단지) 주소를 카카오 로컬 API로 좌표 변환해 data/geo_cache.json 에 캐시한다.

- 입력: ../wooaapt/_rawdata/apts_*.json (K-apt), trades_*.json (실거래 전용 단지: 동+지번), apt_detail.json (도로명·지번 주소)
- 질의 순서: 도로명주소 -> 지번주소(단지명 제거). 실패하면 null 로 캐시(재시도 방지).
- 키: 환경변수 KAKAO_REST_KEY (없으면 ../hosppass/.env 의 KAKAO_REST_KEY — 로컬 전용)
사용: python scripts/geocode_apts.py
"""
import json, os, re, sys, threading, time
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import requests

sys.stdout.reconfigure(encoding="utf-8")
ROOT = Path(__file__).parent.parent
AAPT = ROOT.parent / "wooaapt" / "_rawdata"
CACHE = ROOT / "data" / "geo_cache.json"
URL = "https://dapi.kakao.com/v2/local/search/address.json"


def get_key():
    k = os.environ.get("KAKAO_REST_KEY")
    if k:
        return k
    env = ROOT.parent / "hosppass" / ".env"
    if env.exists():
        for line in env.read_text(encoding="utf-8").splitlines():
            if line.startswith("KAKAO_REST_KEY="):
                return line.split("=", 1)[1].strip()
    raise SystemExit("KAKAO_REST_KEY 가 필요합니다.")


KEY = get_key()
sess = requests.Session()
sess.headers["Authorization"] = "KakaoAK " + KEY
cache = json.loads(CACHE.read_text(encoding="utf-8")) if CACHE.exists() else {}
lock = threading.Lock()


def query(q):
    for attempt in range(5):
        try:
            r = sess.get(URL, params={"query": q}, timeout=15)
            if r.status_code == 200:
                docs = r.json().get("documents", [])
                if docs:
                    return [round(float(docs[0]["y"]), 6), round(float(docs[0]["x"]), 6)]
                return None
            if r.status_code in (429, 500, 502, 503):
                time.sleep(1.5 * (attempt + 1))
                continue
            return None
        except requests.RequestException:
            time.sleep(1.5 * (attempt + 1))
    return None


def geocode(key_and_queries):
    key, qs = key_and_queries
    if key in cache:
        return
    res = None
    for q in qs:
        res = query(q)
        if res:
            break
    with lock:
        cache[key] = res


def strip_name(addr):
    """'서울특별시 종로구 내수동 73- 경희궁의아침4단지' -> '서울특별시 종로구 내수동 73'"""
    m = re.match(r"^(.*?\S+(?:동|읍|면|리|가)\s+\d+(?:-\d+)?)-?(?:\s|$)", addr or "")
    return m.group(1) if m else (addr or "")


def main():
    detail = json.loads((AAPT / "apt_detail.json").read_text(encoding="utf-8"))
    apts = {}
    for f in AAPT.glob("apts_*.json"):
        for a in json.loads(f.read_text(encoding="utf-8")):
            apts[a["code"]] = a
    # (시도 단축, wooaapt 시군구) -> 실제 주소 토큰(시도 전체명, 시군구 표기)
    real = defaultdict(Counter)
    for code, a in apts.items():
        toks = (a.get("addr") or "").split()
        if len(toks) >= 3:
            sg = toks[1]
            if sg.endswith("시") and toks[2].endswith("구"):
                sg = sg + " " + toks[2]
            real[(a["doShort"], a["sigungu"])][(toks[0], sg)] += 1

    todo = []
    for code, a in apts.items():
        qs = []
        if a.get("doroAddr"):
            qs.append(a["doroAddr"])
        s = strip_name(a.get("addr"))
        if s:
            qs.append(s)
        if qs:
            todo.append((f"K:{code}", qs))
    for f in AAPT.glob("trades_*.json"):
        for t in json.loads(f.read_text(encoding="utf-8")):
            if t.get("code"):
                continue
            r = real.get((t["doShort"], t["sigungu"]))
            if not r or not t.get("jibun"):
                continue
            sido, sg = r.most_common(1)[0][0]
            todo.append((f"T:{t['seq']}", [f"{sido} {sg} {t['dong']} {t['jibun'].rstrip('-')}"]))
    pending = [x for x in todo if x[0] not in cache]
    print(f"단지 {len(todo):,}건 중 미처리 {len(pending):,}건", flush=True)
    done = 0
    with ThreadPoolExecutor(max_workers=8) as ex:
        for _ in ex.map(geocode, pending):
            done += 1
            if done % 2000 == 0:
                with lock:
                    CACHE.write_text(json.dumps(cache, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
                print(f"  {done:,}/{len(pending):,}", flush=True)
    CACHE.parent.mkdir(exist_ok=True)
    CACHE.write_text(json.dumps(cache, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    ok = sum(1 for k, _ in todo if cache.get(k))
    print(f"완료: 좌표 확보 {ok:,}/{len(todo):,} ({ok / max(1, len(todo)):.1%})")


if __name__ == "__main__":
    main()
