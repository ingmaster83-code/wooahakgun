#!/usr/bin/env python3
"""
build_data.py (우아학군) - 학교 위치(CSV) × 우아아파트 단지(좌표 변환 캐시) 로 학교-단지 근접 관계를 계산해 _rawdata 를 만든다.

입력: data/raw/school_locations.csv (한국교육시설안전원 초중등학교위치), data/geo_cache.json (geocode_apts.py),
      ../wooaapt/_rawdata/apts_*.json, trades_*.json (단지·실거래 요약)
출력: _rawdata/schools.json (학교 + 가까운 단지), _rawdata/apts_{시도}.json (단지 + 가까운 학교), search_index.json
거리는 하버사인 직선거리(m). 도보 시간은 직선거리×1.25÷80m/분 으로 근사(실제 통학구역·보행 경로와 다를 수 있음).
"""
import csv, json, math, re, sys
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np

sys.stdout.reconfigure(encoding="utf-8")
ROOT = Path(__file__).parent.parent
AAPT = ROOT.parent / "wooaapt" / "_rawdata"
LEVELS = {"초등학교": "초", "중학교": "중", "고등학교": "고"}
NEAR_SCHOOL_R = 3000      # 단지별 가까운 학교 탐색 반경(m)
SCHOOL_APT_R = 1000       # 학교별 주변 단지 반경(m)
MAX_APTS_PER_SCHOOL = 40
CHOPUMA_M = 300           # 초품아 기준(직선 m)
MIN_TRADE_ONLY = 5        # 실거래 전용 단지는 36개월 매매가 이 이상일 때만 페이지 생성


def walk_min(m):
    return max(1, int(round(m * 1.25 / 80)))


def slugify(name, seq):
    base = re.sub(r"[^\w가-힣]+", "-", name or "").strip("-")[:22]
    return re.sub(r"-+", "-", f"{base}-{seq}")


def school_region(addr):
    """학교 지번주소 -> (시도 전체명, 시군구 표기(wooaapt 방식), 동)"""
    toks = (addr or "").split()
    if len(toks) < 3:
        return None, None, None
    sido, sg = toks[0], toks[1]
    rest = toks[2:]
    if sg.endswith("시") and rest and rest[0].endswith("구"):
        sg = sg[:-1] + rest[0]
        rest = rest[1:]
    dong = next((t for t in rest[:3] if re.search(r"(동|읍|면|가)$", t)), "")
    return sido, sg, dong


def main():
    geo = json.loads((ROOT / "data" / "geo_cache.json").read_text(encoding="utf-8"))
    schools = []
    with open(ROOT / "data" / "raw" / "school_locations.csv", encoding="utf-8-sig") as f:
        for r in csv.DictReader(f):
            if r["운영상태"] != "운영" or r["학교급구분"] not in LEVELS:
                continue
            try:
                lat, lng = float(r["위도"]), float(r["경도"])
            except ValueError:
                continue
            schools.append({"id": r["학교ID"], "name": r["학교명"], "level": r["학교급구분"], "lv": LEVELS[r["학교급구분"]], "type": r["설립형태"],
                            "founded": r["설립일자"], "jibun": r["소재지지번주소"], "road": r["소재지도로명주소"], "office": r["교육지원청명"],
                            "sidoOffice": r["시도교육청명"], "lat": lat, "lng": lng})
    # 단지
    aptrecs = []
    apts_k = {}
    for f in AAPT.glob("apts_*.json"):
        for a in json.loads(f.read_text(encoding="utf-8")):
            apts_k[a["code"]] = a
    trades_by_code, trade_only = {}, []
    for f in AAPT.glob("trades_*.json"):
        for t in json.loads(f.read_text(encoding="utf-8")):
            if t["code"]:
                trades_by_code[t["code"]] = t
            else:
                trade_only.append(t)

    def rep(t):
        if not t or not t.get("tg"):
            return None
        g = t["tg"][0]
        return {"a": g["a"], "py": g["py"], "avg": g["avg12"], "n12": t.get("n12", 0)}

    for code, a in apts_k.items():
        c = geo.get(f"K:{code}")
        if not c:
            continue
        t = trades_by_code.get(code)
        aptrecs.append({"key": f"K:{code}", "slug": a["slug"], "src": "apt", "name": a["aptName"], "do": a["doShort"], "sg": a["sigungu"], "dong": a.get("dong") or "",
                        "ho": a.get("hoCnt") or 0, "by": int((a.get("usedate") or "0")[:4] or 0), "lat": c[0], "lng": c[1], "rep": rep(t), "addr": a.get("doroAddr") or a.get("addr") or ""})
    # 같은 시군구·동에 같은 이름의 K-apt 단지가 이미 있으면 같은 단지가 매칭 안 된 것이므로 제외
    kapt_names = {(r["do"], r["sg"], r["dong"], r["name"]) for r in aptrecs}
    dup_skipped = 0
    for t in trade_only:
        c = geo.get(f"T:{t['seq']}")
        if not c or t.get("n36", 0) < MIN_TRADE_ONLY:
            continue
        if (t["doShort"], t["sigungu"], t["dong"], t["name"]) in kapt_names:
            dup_skipped += 1
            continue
        aptrecs.append({"key": f"T:{t['seq']}", "slug": slugify(t["name"], t["seq"]), "src": "trade", "name": t["name"], "do": t["doShort"], "sg": t["sigungu"], "dong": t["dong"],
                        "ho": 0, "by": t.get("by") or 0, "lat": c[0], "lng": c[1], "rep": rep(t), "seq": t["seq"], "addr": f"{t['doShort']} {t['sigungu']} {t['dong']} {t['jibun']}"})
    print(f"K-apt 동명 중복 제외 {dup_skipped:,}")
    print(f"학교 {len(schools):,} / 단지(좌표 확보) {len(aptrecs):,} (K-apt {sum(1 for x in aptrecs if x['src']=='apt'):,}, 실거래 전용 {sum(1 for x in aptrecs if x['src']=='trade'):,})")

    # 좌표 배열
    slat = np.radians(np.array([s["lat"] for s in schools]))
    slng = np.radians(np.array([s["lng"] for s in schools]))
    alat = np.radians(np.array([a["lat"] for a in aptrecs]))
    alng = np.radians(np.array([a["lng"] for a in aptrecs]))
    lv = np.array([s["lv"] for s in schools])

    def dist_matrix(ai, si):
        dlat = slat[si][None, :] - alat[ai][:, None]
        dlng = slng[si][None, :] - alng[ai][:, None]
        h = np.sin(dlat / 2) ** 2 + np.cos(alat[ai])[:, None] * np.cos(slat[si])[None, :] * np.sin(dlng / 2) ** 2
        return 12742000 * np.arcsin(np.sqrt(h))

    # 단지 -> 가까운 학교
    near_school = [dict() for _ in aptrecs]
    school_apts = defaultdict(list)       # school idx -> [(dist, apt idx)]
    CH = 400
    idx_by_lv = {l: np.where(lv == l)[0] for l in LEVELS.values()}
    for l, si in idx_by_lv.items():
        for s0 in range(0, len(aptrecs), CH):
            ai = np.arange(s0, min(s0 + CH, len(aptrecs)))
            d = dist_matrix(ai, si)
            for r in range(d.shape[0]):
                row = d[r]
                order = np.argsort(row)[:3]
                lst = [[int(si[j]), int(row[j])] for j in order if row[j] <= NEAR_SCHOOL_R]
                near_school[ai[r]][l] = lst
                c500 = int((row <= 500).sum())
                c1k = int((row <= 1000).sum())
                near_school[ai[r]][l + "_n500"] = c500
                near_school[ai[r]][l + "_n1k"] = c1k
                for j in np.where(row <= SCHOOL_APT_R)[0]:
                    school_apts[int(si[j])].append((int(row[j]), int(ai[r])))
        print(f"  {l} 완료", flush=True)

    # 학교 -> 근처 같은급 학교
    nearby_sch = {}
    for l, si in idx_by_lv.items():
        for s0 in range(0, len(si), CH):
            part = si[s0:s0 + CH]
            dlat = slat[si][None, :] - slat[part][:, None]
            dlng = slng[si][None, :] - slng[part][:, None]
            h = np.sin(dlat / 2) ** 2 + np.cos(slat[part])[:, None] * np.cos(slat[si])[None, :] * np.sin(dlng / 2) ** 2
            d = 12742000 * np.arcsin(np.sqrt(h))
            for r in range(d.shape[0]):
                order = np.argsort(d[r])[1:5]
                nearby_sch[int(part[r])] = [[int(si[j]), int(d[r][j])] for j in order if d[r][j] <= 5000]

    # 출력: 학교
    out_schools = []
    for i, s in enumerate(schools):
        lst = sorted(school_apts.get(i, []))
        rec = dict(s)
        rec["idx"] = i
        sido, sg, dong = school_region(s["jibun"])
        rec["sido"], rec["sg"], rec["dong"] = sido, sg, dong
        rec["n500"] = sum(1 for d, _ in lst if d <= 500)
        rec["n1k"] = len(lst)
        rec["apts"] = [[a, d] for d, a in lst[:MAX_APTS_PER_SCHOOL]]
        rec["near"] = nearby_sch.get(i, [])
        out_schools.append(rec)
    # 출력: 단지
    out_apts = []
    for i, a in enumerate(aptrecs):
        rec = {k: v for k, v in a.items() if k not in ("lat", "lng")}
        rec["idx"] = i
        rec["lat"], rec["lng"] = a["lat"], a["lng"]
        rec["ns"] = near_school[i]
        out_apts.append(rec)

    out_dir = ROOT / "_rawdata"
    out_dir.mkdir(exist_ok=True)
    for old in out_dir.glob("*.json"):
        old.unlink()
    (out_dir / "schools.json").write_text(json.dumps(out_schools, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    by_do = defaultdict(list)
    for a in out_apts:
        by_do[a["do"]].append(a)
    for do, lst in by_do.items():
        (out_dir / f"apts_{do}.json").write_text(json.dumps(lst, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    chop = sum(1 for a in out_apts if a["ns"].get("초") and a["ns"]["초"][0][1] <= CHOPUMA_M)
    sz = sum(f.stat().st_size for f in out_dir.glob("*.json")) / 1e6
    print(f"저장: 학교 {len(out_schools):,}, 단지 {len(out_apts):,}, 초품아(≤{CHOPUMA_M}m) 단지 {chop:,} / {sz:.1f}MB")


if __name__ == "__main__":
    main()
