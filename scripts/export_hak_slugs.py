#!/usr/bin/env python3
"""export_hak_slugs.py - 우아학군에 페이지가 있는 단지 목록을 우아아파트 _data/hak_slugs.json 으로 내보낸다.
우아아파트 상세(K-apt /apt/{slug}/, 실거래 전용 /trade/{slug}/)에서 우아학군 링크를 걸 때 404 가 나지 않도록 존재 여부 확인용.
키: "apt:{우아아파트 slug}" | "trade:{우아아파트 slug}" → 우아학군 /apt/{slug}/ 의 slug.
우아아파트(Ruby)의 실거래 전용 slug 규칙(TradeGenerator.slug_of)과 우아학군(Python)의 규칙이 `_` 등에서 달라 키는 Ruby 규칙으로 다시 계산한다.
우아학군 데이터(build_data.py)를 갱신한 뒤 다시 실행하고 우아아파트에 커밋한다."""
import json, re, sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")
ROOT = Path(__file__).parent.parent
OUT = ROOT.parent / "wooaapt" / "_data" / "hak_slugs.json"


def ruby_slug_of(name, seq):
    """wooaapt/_plugins/trade_generator.rb TradeGenerator.slug_of 와 같은 규칙."""
    base = "".join(c if c.isalnum() else "-" for c in (name or ""))     # [^\p{Hangul}\p{Alnum}]+ → '-'
    base = re.sub(r"-+", "-", base).strip("-")[:22]
    return re.sub(r"-+", "-", f"{base}-{seq}")


keys = {}
for f in sorted((ROOT / "_rawdata").glob("apts_*.json")):
    for a in json.loads(f.read_text(encoding="utf-8")):
        if a["src"] == "apt":
            keys[f"apt:{a['slug']}"] = a["slug"]
        else:
            keys[f"trade:{ruby_slug_of(a['name'], a['seq'])}"] = a["slug"]
OUT.parent.mkdir(exist_ok=True)
OUT.write_text(json.dumps(keys, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
print(f"{len(keys):,}건 → {OUT} ({OUT.stat().st_size / 1e6:.1f}MB)")
