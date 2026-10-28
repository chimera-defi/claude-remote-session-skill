#!/usr/bin/env python3
"""Local, stdlib-only Claude Code usage audit; no API calls or file writes.

Usage: python3 scripts/usage-audit.py [ROOT ...] --days 7
Roots default to the projects directory under CLAUDE_CONFIG_DIR (or the usual
Claude config directory). Explicit roots may point at archived transcript stores.
--session (or AUDIT_ONLY_SESSION) selects just one session, including its subagents,
with priority over exclusions. --exclude-session is repeatable and overrides the
AUDIT_EXCLUDE_SESSION default (falling back to CLAUDE_SESSION_ID).
Sessions starting with the original audit prompt are also excluded by default.

All output is aggregate: anonymous projects and fixed label categories only.
Weights and context buckets are estimates, not invoices or ground truth.
The separate Codex lane uses cumulative file totals and only an mtime window.
"""
import argparse
import bisect
import glob
import heapq
import json
import math
import os
import re
import sys
from collections import defaultdict
from datetime import datetime, timezone, timedelta

NEEDLE = "Audit my Claude Code usage"


class AuditParser(argparse.ArgumentParser):
    def error(self, message):
        # argparse's normal error includes arbitrary user-supplied values/paths.
        self.exit(2, "usage-audit: invalid arguments; use --help\n")


def positive_days(value):
    days = float(value)
    if not math.isfinite(days) or days <= 0 or days > 365000:
        raise ValueError("invalid window")
    return days


def safe_model(model):
    if not isinstance(model, str):
        return "unknown"
    # Never render arbitrary transcript metadata as a label.
    match = re.fullmatch(r"(?:claude-)?(opus|sonnet|haiku|fable)(?:-([0-9]+(?:[-.][0-9]+)*))?", model)
    if match:
        return match.group(0)
    return "other"


def safe_tool(name):
    if name in ("Read", "Bash", "WebFetch", "WebSearch"):
        return name
    if isinstance(name, str) and name.startswith("mcp__"):
        return "MCP"
    return "other"


def safe_entry(entry):
    return entry if entry in ("cli", "desktop", "sdk") else "other"


def has_needle(row):
    message = row.get("message")
    if not isinstance(message, dict):
        return False
    content = message.get("content")
    if isinstance(content, str):
        return NEEDLE in content
    return isinstance(content, list) and any(
        isinstance(block, dict) and block.get("type") == "text"
        and isinstance(block.get("text"), str)
        and NEEDLE in block["text"] for block in content
    )


def pts(s):
    if not isinstance(s, str): return None
    try:
        value = datetime.fromisoformat(s.replace("Z", "+00:00"))
        if value.tzinfo is None: value = value.replace(tzinfo=timezone.utc)
        return value.timestamp()
    except (TypeError, ValueError):
        return None

def rr_of(model):
    m = model.lower() if isinstance(model, str) else ""
    if re.search(r"opus-5[-.]5|sonnet-5[-.]5", m): return 0.05
    if "fable" in m: return 0.025
    return 0.1

SZ = re.compile(r"([\d][\d,]*(?:\.\d+)?)\s*(KB|MB|GB|bytes|B|chars|characters)\b")
def preview_size(txt):
    m = SZ.search(txt[:2500])
    if not m: return None
    try: v = float(m.group(1).replace(",", ""))
    except (TypeError, ValueError): return None
    return int(v * {"KB":1024,"MB":1048576,"GB":1<<30}.get(m.group(2), 1))

def content_chars(c):
    if isinstance(c, str): return len(c), c
    n = 0; head = ""
    if isinstance(c, list):
        for b in c:
            if isinstance(b, dict):
                if b.get("type") == "text":
                    t = b.get("text", ""); n += len(t)
                    if not head: head = t[:2500]
                elif b.get("type") == "image": n += 6000
                else: n += 200
    return n, head


def main(argv=None):
    parser = AuditParser(prog="usage-audit", description=__doc__)
    parser.add_argument("roots", nargs="*", metavar="ROOT")
    parser.add_argument("--days", type=positive_days, default=7.0, help="UTC lookback window (default: 7)")
    parser.add_argument("--session", default=os.environ.get("AUDIT_ONLY_SESSION"), metavar="ID")
    parser.add_argument("--exclude-session", action="append", default=None, metavar="ID")
    args = parser.parse_args(argv)
    if args.exclude_session is None:
        args.exclude_session = [os.environ.get("AUDIT_EXCLUDE_SESSION") or os.environ.get("CLAUDE_SESSION_ID")]
    config_dir = os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude")
    roots = list(dict.fromkeys(os.path.realpath(r) for r in (args.roots or [os.path.join(config_dir, "projects")])))
    now = datetime.now(timezone.utc)
    cutoff = now - timedelta(days=args.days)
    cut_iso = cutoff.isoformat().replace("+00:00", "")
    cut_epoch = cutoff.timestamp()
    gaps = defaultdict(int)
    files = []
    for r in roots:
        if not os.path.isdir(r): gaps["root_missing"] += 1; continue
        for dp, dn, fn in os.walk(r):
            for f in fn:
                if f.endswith(".jsonl"):
                    p = os.path.join(dp, f)
                    try: mt = os.path.getmtime(p)
                    except OSError: gaps["stat_fail"] += 1; continue
                    if mt >= cut_epoch: files.append((r, p, mt))
                    else: gaps["files_older_than_window_skipped"] += 1

    tool_names = {}          # tool_use_id -> name
    best = {}                # key -> record dict (dedup)
    raw_calls = defaultdict(list)
    overcount_w = 0.0; overcount_n = 0
    fmeta = {}               # path -> dict
    events = defaultdict(list)  # path -> [(ts, bucket|None, tid, size)]
    flagged = []             # (mtime, path, sessionId)
    first_user_needle = set()  # sessionIds whose first user line holds the needle
    indep_w = 0.0            # independent per-call total (deduped winners recomputed directly)
    needle_hits = 0
    preview_hits = 0; result_n = 0

    def weigh(model, inp, cr, w5, w1, out):
        return inp + 1.25*w5 + 2*w1 + 5*out + rr_of(model)*cr

    for root, p, mt in files:
        meta = {"root": root, "sid": None, "cwd": "", "entry": "", "sub": ("/subagents/" in p or os.path.basename(p).startswith("agent-"))}
        fmeta[p] = meta
        ev = events[p]
        try: fh = open(p, "r", errors="replace")
        except OSError: gaps["open_fail"] += 1; continue
        with fh:
            for line_number, line in enumerate(fh):
                try: d = json.loads(line)
                except (TypeError, ValueError): gaps["bad_json_line"] += 1; continue
                if not isinstance(d, dict): continue
                isA = d.get("type") == "assistant"; isU = d.get("type") == "user"
                if not (isA or isU): continue
                if isU and not meta.get("seen_user"):
                    meta["seen_user"] = True
                    if has_needle(d): first_user_needle.add(d.get("sessionId"))
                if isU and has_needle(d):
                    needle_hits += 1
                    flagged.append((mt, p, d.get("sessionId")))
                ts = pts(d.get("timestamp"))
                if ts is None:
                    gaps["invalid_timestamp"] += 1
                    continue
                if meta["sid"] is None and d.get("sessionId"):
                    meta["sid"] = d["sessionId"]; meta["cwd"] = os.path.basename(d.get("cwd") or "").lower(); meta["entry"] = d.get("entrypoint") or ""
                msg = d.get("message")
                if not isinstance(msg, dict): continue
                if isA:
                    model = msg.get("model")
                    content = msg.get("content")
                    if isinstance(content, list):
                        for b in content:
                            if isinstance(b, dict) and b.get("type") == "tool_use":
                                tool_names[b.get("id")] = b.get("name") or "other"
                    if model == "<synthetic>": continue
                    u = msg.get("usage")
                    if not isinstance(u, dict) or not u: gaps["assistant_no_usage"] += 1; continue
                    cc = u.get("cache_creation") or {}
                    if not isinstance(cc, dict): cc = {}
                    cw = u.get("cache_creation_input_tokens") or 0
                    w5 = cc.get("ephemeral_5m_input_tokens"); w1 = cc.get("ephemeral_1h_input_tokens")
                    if w5 is None and w1 is None: w5, w1 = cw, 0
                    w5 = w5 or 0; w1 = w1 or 0
                    if w5 + w1 != cw and cw: w5 = cw - w1
                    out = u.get("output_tokens") or 0
                    thk = (u.get("output_tokens_details") or {}).get("thinking_tokens") or 0
                    inp = u.get("input_tokens") or 0; cr = u.get("cache_read_input_tokens") or 0
                    if cut_epoch <= ts <= now.timestamp():
                        raw_calls[p].append(weigh(model, inp, cr, w5, w1, out))
                    key = (d.get("sessionId"), msg.get("id") or d.get("requestId") or d.get("uuid") or (p, line_number))
                    rec = {"ts": ts, "model": model or "unknown", "inp": inp, "cr": cr, "w5": w5, "w1": w1, "cw": w5+w1, "out": out, "thk": thk, "path": p}
                    old = best.get(key)
                    if old is None: best[key] = rec
                    else:
                        mn = min(old["ts"], ts)
                        if out > old["out"]: rec["ts"] = mn; best[key] = rec
                        else: old["ts"] = mn
                else:
                    content = msg.get("content")
                    if isinstance(content, str):
                        ev.append((ts, "user", None, len(content)))
                    elif isinstance(content, list):
                        ut = 0
                        for b in content:
                            if not isinstance(b, dict): continue
                            if b.get("type") == "tool_result":
                                n, head = content_chars(b.get("content"))
                                result_n += 1
                                if "tool-results" in head or "Output too large" in head:
                                    ps = preview_size(head)
                                    if ps: n = ps; preview_hits += 1
                                ev.append((ts, "tool", b.get("tool_use_id"), n))
                            elif b.get("type") == "text":
                                ut += len(b.get("text", ""))
                        if ut: ev.append((ts, "user", None, ut))

    # exclusion of audit session
    # Explicit IDs plus sessions whose FIRST user message is the audit prompt.
    # Later needle mentions inside other sessions (e.g. verification work) no longer exclude them.
    excl_sids = set(args.exclude_session) | first_user_needle
    excl_sids.discard(None)
    needle_not_excluded = len({s_ for _, _, s_ in flagged if s_ and s_ not in excl_sids})
    excl_calls = 0

    def tool_bucket(name):
        if name == "Read": return "tool:Read"
        if name == "Bash": return "tool:Bash"
        if name and name.startswith("mcp__"): return "tool:MCP"
        if name in ("WebFetch", "WebSearch"): return "tool:web"
        return "tool:other"

    # group winners by stream
    streams = defaultdict(list)
    for rec in best.values(): streams[rec["path"]].append(rec)

    BK = ["fixed","tool:Read","tool:Bash","tool:MCP","tool:web","tool:other","user","asst_reread","out","other"]
    bucket = defaultdict(float)
    by_proj = defaultdict(lambda: [0.0, 0, 0])      # weighted, calls, tokens
    by_prefix = defaultdict(lambda: [0.0, 0, set()])
    by_model = defaultdict(lambda: [0, 0.0, 0])      # calls, weighted, tokens
    sub_w = 0.0; tot_w = 0.0; h2_w = 0.0; h2_calls = 0; calls_n = 0
    sess_first = {}; sess_last = {}; sess_w = defaultdict(float)
    sess_info = {}
    entry_w = defaultdict(float)

    # session first-call times across all streams (excluding nothing)
    for p, recs in streams.items():
        sid = fmeta[p]["sid"] or p
        for r in recs:
            t = r["ts"]
            if t is None: continue
            r["t"] = t
            sess_first[sid] = min(sess_first.get(sid, t), t)
            sess_last[sid] = max(sess_last.get(sid, 0), t)

    project_ids = {}

    def projname(meta, p):
        # Group by directory internally; never expose even a sanitized path component.
        project = (meta["root"], os.path.relpath(p, meta["root"]).split(os.sep)[0])
        return project_ids.setdefault(project, f"project-{len(project_ids) + 1}")

    def prefix_of(meta, p):
        return "desktop" if "desktop" in meta["entry"].lower() else "other"

    top_heap = []; seen_tid = set()
    for p, recs in streams.items():
        meta = fmeta[p]; sid = meta["sid"] or p
        _only = args.session
        if (_only and sid != _only) or (not _only and sid in excl_sids):
            excl_calls += len(recs); continue
        overcount_n += len(raw_calls[p]); overcount_w += sum(raw_calls[p])
        recs.sort(key=lambda r: r.get("t", 0))
        evs = sorted(events[p], key=lambda e: e[0])
        ets = [e[0] for e in evs]
        for index, e in enumerate(evs):
            tid = e[2] or (p, index)
            if e[1] == "tool" and cut_epoch <= e[0] <= now.timestamp() and tid not in seen_tid:
                seen_tid.add(tid)
                nm = safe_tool(tool_names.get(e[2], "other"))
                heapq.heappush(top_heap, (e[3]/4, nm))
                if len(top_heap) > 5: heapq.heappop(top_heap)
        proj = projname(meta, p); pref = prefix_of(meta, p)
        items = []; tot = defaultdict(float); fixed0 = 0.0
        prevC = None; prev_ts = float("-inf"); prev_out = 0
        def add(b, s):
            if s <= 0: return
            if items and items[-1][0] == b: items[-1][1] += s
            else: items.append([b, s])
            tot[b] += s
        for i, r in enumerate(recs):
            C = r["inp"] + r["cr"] + r["cw"]
            lo = bisect.bisect_right(ets, prev_ts) if i else 0
            hi = bisect.bisect_left(ets, r["ts"])
            pre = []
            if i and prev_out: pre.append(("asst_reread", prev_out))
            for e in evs[lo:hi]:
                if e[1] == "user": pre.append(("user", e[3]/4))
                else: pre.append((tool_bucket(tool_names.get(e[2], "other")), e[3]/4))
            sp = sum(s for _, s in pre)
            if i == 0:
                sc = min(1.0, C/sp) if sp else 1.0
                fixed0 = max(C - sp*sc, 0.0); add("fixed", fixed0)
                for b, s in pre: add(b, s*sc)
            elif C < 0.8*prevC:
                items = []; tot.clear()
                add("fixed", min(fixed0, C)); add("other", C - min(fixed0, C))
            else:
                G = C - prevC
                if G > 0:
                    sc = min(1.0, G/sp) if sp else 1.0
                    for b, s in pre: add(b, s*sc)
                    add("other", G - sp*sc)
                elif G < 0:
                    nf = sum(s for b, s in items if b != "fixed")
                    fx = min(tot["fixed"], C)
                    kf = fx/tot["fixed"] if tot["fixed"] else 0
                    tgt = max(C - fx, 0.0)
                    k = tgt/nf if nf else 0
                    for it in items:
                        it[1] *= kf if it[0] == "fixed" else k
                    tot.clear()
                    for b, s in items: tot[b] += s
            # normalise rounding
            prevC = C; prev_ts = r["ts"]; prev_out = r["out"]
            inwin = cut_epoch <= r["ts"] <= now.timestamp()
            if not inwin: continue
            rr = rr_of(r["model"]); fresh = r["inp"]; cw = r["cw"]
            wm = (1.25*r["w5"] + 2*r["w1"])/cw if cw else 0
            cost = defaultdict(float); visited = defaultdict(float)
            d = 0.0; lim = fresh + cw
            for b, s in reversed(items):
                if d >= lim: break
                d0, d1 = d, d + s
                f = max(0.0, min(d1, fresh) - d0)
                w = max(0.0, min(d1, lim) - max(d0, fresh))
                rd = s - f - w
                cost[b] += f + w*wm + rd*rr; visited[b] += s
                d = d1
            for b, s in tot.items():
                rem = s - visited.get(b, 0.0)
                if rem > 0: cost[b] += rem*rr
            cost["out"] += 5*r["out"]
            w_call = sum(cost.values())
            for b, v in cost.items(): bucket[b] += v
            tot_w += w_call; calls_n += 1
            indep_w += weigh(r["model"], r["inp"], r["cr"], r["w5"], r["w1"], r["out"])
            tokens = C + r["out"]
            if meta["sub"]: sub_w += w_call
            if r["t"] - sess_first[sid] > 7200: h2_w += w_call; h2_calls += 1
            bp = by_proj[proj]; bp[0] += w_call; bp[1] += 1; bp[2] += tokens
            bf = by_prefix[pref]; bf[0] += w_call; bf[1] += 1; bf[2].add(sid)
            bm = by_model[safe_model(r["model"])]; bm[0] += 1; bm[1] += w_call; bm[2] += tokens
            sess_w[sid] += w_call; entry_w[safe_entry(meta["entry"])] += w_call
            sess_info[sid] = (proj, pref)

    n_sess = len(sess_w)
    over2h = sum(1 for s in sess_w if sess_last[s] - sess_first[s] > 7200)
    fmt = lambda x: f"{x:,.0f}"
    L = []
    L.append(f"Claude Code usage audit, last {args.days:g}d (cutoff {cut_iso}Z), roots={len(roots)}")
    L.append(f"Files scanned {len(files)}; deduped calls {len(best)}; counted calls {calls_n}; sessions {n_sess}; excluded or unselected calls {excl_calls} (needle line matches {needle_hits}; exclusion IDs {len(excl_sids)}; sessions mentioning needle but kept {needle_not_excluded})")
    L.append(f"TOTAL weighted (estimate): {fmt(tot_w)}")
    L.append(f"Independent total (direct weigh() per counted call, no bucket model): {fmt(indep_w)} vs {fmt(tot_w)} diff {fmt(indep_w-tot_w)} ({100*(indep_w-tot_w)/tot_w if tot_w else 0:+.3f}%)")
    for b in BK: L.append(f"  {b:12s} {fmt(bucket[b]):>16s}  {100*bucket[b]/tot_w if tot_w else 0:5.1f}%")
    L.append(f"Subagent share: {fmt(sub_w)} ({100*sub_w/tot_w if tot_w else 0:.1f}%)")
    L.append(f"After hour 2 of session: {fmt(h2_w)} ({100*h2_w/tot_w if tot_w else 0:.1f}%), {h2_calls} calls; sessions over 2h: {over2h}/{n_sess}")
    L.append(f"Overcount if every line summed: {fmt(overcount_w)} over {overcount_n} lines vs {fmt(tot_w)} ({overcount_w/tot_w if tot_w else 0:.2f}x)")
    L.append("By session category (weighted, %, calls, sessions):")
    for k, v in sorted(by_prefix.items(), key=lambda x: -x[1][0]): L.append(f"  {k:22s} {fmt(v[0]):>15s} {100*v[0]/tot_w if tot_w else 0:5.1f}% {v[1]:>7d} {len(v[2]):>5d}")
    L.append("By entrypoint (weighted %): " + ", ".join(f"{k}={100*v/tot_w if tot_w else 0:.0f}%" for k, v in sorted(entry_w.items(), key=lambda x: -x[1])[:5]))
    L.append("By project (top 12; weighted, %, calls):")
    for k, v in sorted(by_proj.items(), key=lambda x: -x[1][0])[:12]: L.append(f"  {k:40s} {fmt(v[0]):>15s} {100*v[0]/tot_w if tot_w else 0:5.1f}% {v[1]:>7d}")
    L.append(f"  ({len(by_proj)} projects total)")
    L.append("By model (calls, weighted, tokens):")
    for k, v in sorted(by_model.items(), key=lambda x: -x[1][1]): L.append(f"  {k[:30]:30s} {v[0]:>7d} {fmt(v[1]):>15s} {fmt(v[2]):>16s}")
    L.append("Top 5 biggest tool results (name, ~tokens):")
    for s, nm in sorted(top_heap, reverse=True): L.append(f"  {nm}: {fmt(s)}")

    UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$")
    n_sub_files = sum(1 for p_ in files if fmeta[p_[1]]["sub"])
    L.append(f"Window: UTC, cutoff {cut_iso}Z on both file mtime and call timestamps. In-window files {len(files)} of which subagent files {n_sub_files}; subagent usage is counted from those files.")
    L.append("Coverage (other locations checked; counts only):")
    home = os.path.expanduser("~")
    scanned = set(roots)
    cands = [os.path.join(config_dir, "projects"), os.path.join(config_dir, "worktrees"), home+"/.sessions"]
    cands += sorted(glob.glob(home+"/.claude-*")) + sorted(glob.glob(home+"/.config/claude*"))
    for location_index, c in enumerate(dict.fromkeys(cands), 1):
        rp = os.path.realpath(c)
        if not os.path.exists(c): L.append(f"  {location_index}: absent"); continue
        if rp in scanned or any(rp.startswith(x+os.sep) for x in scanned):
            L.append(f"  {location_index}: same store as scanned root (symlink/mirror)"); continue
        tot_j = uu = uu7 = 0; err = False
        def _e(_x):
            nonlocal err; err = True
        for dp, dn, fn in os.walk(c, onerror=_e):
            for f in fn:
                if f.endswith(".jsonl"):
                    tot_j += 1
                    if UUID.match(f):
                        uu += 1
                        try:
                            if os.path.getmtime(os.path.join(dp, f)) >= cut_epoch: uu7 += 1
                        except OSError: pass
        note = " (unreadable parts)" if err else ""
        L.append(f"  {location_index}: {tot_j} jsonl, {uu} uuid-named transcripts ({uu7} in window){note}" + ("  <-- NOT SCANNED, GAP" if uu else ""))
        if uu: gaps["unscanned_uuid_transcripts"] += uu
    # codex: separate lane, cumulative total_token_usage from last token_count per file
    cx_files = cx_win = 0; cx_in = cx_cached = cx_out = 0; cx_w = 0.0
    cx_models = defaultdict(int)
    for dp, dn, fn in os.walk(home+"/.codex/sessions"):
        for f in fn:
            if not f.endswith(".jsonl"): continue
            cx_files += 1; p = os.path.join(dp, f)
            try:
                if os.path.getmtime(p) < cut_epoch: continue
            except OSError: continue
            cx_win += 1; last = None; mdl = None
            try:
                for line in open(p, errors="replace"):
                    if '"token_count"' in line:
                        try: pl = json.loads(line).get("payload") or {}
                        except (TypeError, ValueError): continue
                        inf = pl.get("info")
                        if pl.get("type") == "token_count" and inf and inf.get("total_token_usage"): last = inf["total_token_usage"]
                    elif mdl is None and '"turn_context"' in line:
                        try: mdl = (json.loads(line).get("payload") or {}).get("model")
                        except (TypeError, ValueError): pass
            except OSError: continue
            if last:
                i_, c_, o_ = last.get("input_tokens") or 0, last.get("cached_input_tokens") or 0, last.get("output_tokens") or 0
                cx_in += i_; cx_cached += c_; cx_out += o_
                cx_w += (i_ - c_) + 0.1*c_ + 5*o_
                cx_models[safe_model(mdl)] += 1
    L.append(f"Codex lane (separate, not in totals above): {cx_files} session files, {cx_win} with mtime in window; summed final cumulative usage: input {fmt(cx_in)} (cached {fmt(cx_cached)}), output {fmt(cx_out)}; rough weighted {fmt(cx_w)} using fresh=1, cached=0.1, output=5 (OpenAI weights differ; files straddling the cutoff include earlier usage)")
    L.append("  codex files by model: " + ", ".join(f"{k}={v}" for k, v in sorted(cx_models.items(), key=lambda x: -x[1])[:6]))
    L.append("Data gaps:")
    L.append("  other user stores and live process environments are not inspected")
    L.append("  coverage of alternate configuration stores is heuristic; explicit roots are recommended")
    L.append(f"  tool results seen {result_n}; sized from saved-output preview {preview_hits}; other sizes are chars/4 estimates")
    L.append("  top tool-result sizes come from saved-output preview text (regex), unverified; top results deduplicated by tool_use_id within the window")
    L.append("  bucket attribution is a model (context growth capped, compaction = drop >20%); not logged ground truth")
    L.append("  first call of a stream charges its unexplained prefix to fixed overhead (resumed/forked streams inflate it)")
    L.append("  weights are estimates (cache read 0.05 Opus/Sonnet 5.5, 0.025 Fable, 0.1 other); image blocks ~1500 tok each")
    for k, v in sorted(gaps.items()): L.append(f"  {k}: {v}")
    L.append("  project labels are anonymous report-local numbers; no transcript text or paths printed")
    print("\n".join(L))
    print(f"\nSESSIONS={n_sess} TOTAL_WEIGHTED={tot_w:.0f}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        # Never expose a filename, transcript fragment, or exception value.
        print("usage-audit: unable to audit input (details suppressed)", file=sys.stderr)
        sys.exit(1)
