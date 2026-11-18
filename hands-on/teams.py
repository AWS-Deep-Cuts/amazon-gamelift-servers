#!/usr/bin/env python3
"""AWS Deep Cuts - FlexMatch ハンズオンの結果を表にする補助スクリプト

resource-ids.env のチケット ID の接頭辞と申し込みの時刻を使い、このラウンドのイベントをロググループから読みます。
MatchmakingSucceeded の detail.gameSessionInfo.players[].team をチームの表にし、時系列とルールごとの合格数と不合格数も表示します。

使い方:
  python3 teams.py <ラウンドの番号>                 ロググループのイベントから、チームの表を表示する
  python3 teams.py <ラウンドの番号> --raw           MatchmakingSucceeded のイベントの JSON を表示する
  python3 teams.py <ラウンドの番号> --from-tickets  イベントが届かない場合の予備。DescribeMatchmaking を 1 回だけ呼ぶ
  python3 teams.py <ラウンドの番号> --timeout 秒    イベントを待つ上限の秒数を変える。既定は 240 秒
  python3 teams.py trial                            README の手順 4 の試しのチケットのイベントを表示する
"""

import argparse
import csv
import json
import os
import re
import sys
import time
from datetime import datetime, timezone

import boto3
from botocore.exceptions import BotoCoreError, ClientError

HERE = os.path.dirname(os.path.abspath(__file__))
RESOURCE_FILE = os.path.join(HERE, "resource-ids.env")
MEMBERS_FILE = os.path.join(HERE, "members.csv")
FINAL_TYPES = ("MatchmakingSucceeded", "MatchmakingTimedOut", "MatchmakingCancelled", "MatchmakingFailed")


def load_env():
    """resource-ids.env を読む。同じキーが複数あれば、最後の値を使う。"""
    if not os.path.exists(RESOURCE_FILE):
        sys.exit("❌ Error: resource-ids.env が見つかりません。hands-on ディレクトリで bash ./setup.sh を実行してください。")
    env = {}
    with open(RESOURCE_FILE, encoding="utf-8") as f:
        for line in f:
            m = re.match(r'^([A-Z0-9_]+)="?(.*?)"?\s*$', line)
            if m:
                env[m.group(1)] = m.group(2)
    return env


def load_members():
    with open(MEMBERS_FILE, encoding="utf-8") as f:
        return {row["player_id"]: row for row in csv.DictReader(f)}


def parse_time(value):
    """イベントの time や startTime を、UNIX 時刻の秒に変換する。"""
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return value / 1000 if value > 1e11 else float(value)
    text = str(value).replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(text).timestamp()
    except ValueError:
        return None


def ticket_ids_of(event):
    return {t.get("ticketId") for t in event.get("detail", {}).get("tickets", []) or []}


def round_tickets(env, members, round_name):
    """ラウンドのチケット ID の一覧と、申し込みを始めた時刻（ミリ秒）を返す。"""
    if round_name == "trial":
        if "TRIAL_TICKET" not in env:
            sys.exit("❌ Error: resource-ids.env に TRIAL_TICKET がありません。README の手順 4-1 を実行してください。")
        return [env["TRIAL_TICKET"]], int(env.get("TRIAL_START_MS", "0")), None
    prefix = env.get(f"R{round_name}_PREFIX")
    if not prefix:
        sys.exit(f"❌ Error: ラウンド {round_name} の申し込みの記録がありません。先に bash ./apply-round.sh {round_name} を実行してください。")
    pair = env.get(f"R{round_name}_PAIR")
    pair_ids = pair.split(",") if pair else []
    tickets = [f"{prefix}-pair"] if pair_ids else []
    tickets += [f"{prefix}-{pid}" for pid in members if pid not in pair_ids]
    return tickets, int(env[f"R{round_name}_START_MS"]), pair_ids


def read_events(logs, log_group, start_ms, tickets):
    """ロググループからイベントを読み、このラウンドのチケットのイベントだけを返す。"""
    events = {}
    paginator = logs.get_paginator("filter_log_events")
    for page in paginator.paginate(logGroupName=log_group, startTime=start_ms - 60000):
        for record in page.get("events", []):
            try:
                event = json.loads(record["message"])
            except ValueError:
                continue
            if ticket_ids_of(event) & tickets:
                events[event.get("id", record["eventId"])] = event
    return sorted(events.values(), key=lambda e: parse_time(e.get("time")) or 0)


def teams_from_event(event):
    """MatchmakingSucceeded のイベントから、プレイヤー ID とチームの組を読む。"""
    detail = event.get("detail", {})
    players = (detail.get("gameSessionInfo") or {}).get("players") or []
    assigned = {p["playerId"]: p.get("team") for p in players if p.get("team")}
    if not assigned:  # gameSessionInfo に無ければ、tickets[].players[] から読む
        for ticket in detail.get("tickets", []) or []:
            for p in ticket.get("players", []) or []:
                if p.get("team"):
                    assigned[p["playerId"]] = p["team"]
    return assigned


def final_types(events, tickets):
    """チケットごとに、最後に届いたイベントの種類（終わりを表すもの）を返す。"""
    result = {}
    for event in events:
        kind = event.get("detail", {}).get("type")
        if kind in FINAL_TYPES:
            for tid in ticket_ids_of(event) & tickets:
                result[tid] = kind
    return result


def print_teams(assigned, members, pair_ids):
    """チームの表と、経験年数の平均の差を表示する。"""
    overall = sum(int(m["years"]) for m in members.values()) / len(members)
    teams = {}
    for pid, team in assigned.items():
        teams.setdefault(team, []).append(pid)
    order = ["red", "blue", "green", "yellow"]
    max_diff = 0.0
    for team in sorted(teams, key=lambda t: order.index(t) if t in order else len(order)):
        pids = sorted(p for p in teams[team] if p in members)
        avg = sum(int(members[p]["years"]) for p in pids) / len(pids) if pids else 0.0
        diff = avg - overall
        max_diff = max(max_diff, abs(diff))
        infra = sum(int(members[p]["infra"]) for p in pids)
        print(f"{team:<7} {len(pids)} 人 / 経験年数の平均 {avg:5.2f} 年 / 全員の平均との差 {diff:+.2f} 年 / インフラが得意な人 {infra} 人")
        print("        " + ", ".join(f"{p}({members[p]['years']}年, {members[p]['role']})" for p in pids))
    print("")
    print(f"全員の経験年数の平均: {overall:.2f} 年 / 全員の平均との差の最大値: {max_diff:.2f} 年")
    if pair_ids:
        a, b = pair_ids
        same = assigned.get(a) is not None and assigned.get(a) == assigned.get(b)
        print(f"{a} と {b} は同じチームか: {'はい' if same else 'いいえ'} / {a}: {assigned.get(a)} / {b}: {assigned.get(b)}")


def print_timeline(events, start_ms):
    """イベントの時系列。同じ種類のイベントが続く場合は 1 行にまとめる。"""
    print("イベントの時系列。秒数は、最初のチケットを申し込んでからの経過時間")
    rows = []
    for event in events:
        kind = event.get("detail", {}).get("type", "?")
        # イベントの time は秒の単位のため、申し込みと同じ秒のイベントは負の値になることがある。0 にそろえる
        sec = max(0.0, (parse_time(event.get("time")) or start_ms / 1000) - start_ms / 1000)
        count = len(event.get("detail", {}).get("tickets", []) or [])
        if rows and rows[-1][0] == kind:
            rows[-1][2] = sec
            rows[-1][3] += 1
            rows[-1][4] += count
        else:
            rows.append([kind, sec, sec, 1, count])
    for kind, first, last, n, count in rows:
        span = f"{first:.0f} 秒" if round(first) == round(last) else f"{first:.0f}〜{last:.0f} 秒"
        print(f"  {span:>10}  {kind:<22} イベント {n} 件・含まれるチケット {count} 枚")
    print("")


def format_count(value):
    """イベントの合格数と不合格数は 65.0 のような小数で届くため、整数なら整数で表示する。"""
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return str(value)


def print_rule_metrics(events, match_ids):
    """PotentialMatchCreated のイベントにある、ルールごとの合格数と不合格数を表示する。

    PotentialMatchCreated のイベントが無い場合（ラウンド 5 のように、マッチ案ができなかった場合）は、
    MatchmakingTimedOut のイベントにも ruleEvaluationMetrics が入るため、そちらから表示する。
    """
    source = "PotentialMatchCreated"
    potentials = [e for e in events if e.get("detail", {}).get("type") == source]
    chosen = [e for e in potentials if e.get("detail", {}).get("matchId") in match_ids] or potentials[-1:]
    if not chosen:
        timed_out = [e for e in events if e.get("detail", {}).get("type") == "MatchmakingTimedOut"
                     and e.get("detail", {}).get("ruleEvaluationMetrics")]
        if timed_out:
            source = "MatchmakingTimedOut"
            chosen = timed_out[-1:]
    metrics = chosen[0].get("detail", {}).get("ruleEvaluationMetrics") if chosen else None
    print(f"ルールごとの合格数と不合格数。{source} のイベントの ruleEvaluationMetrics から")
    if not metrics:
        print("  イベントに含まれていません。")
    else:
        for m in metrics:
            print(f"  {m.get('ruleName'):<14} 合格数 passedCount: {format_count(m.get('passedCount'))}"
                  f" / 不合格数 failedCount: {format_count(m.get('failedCount'))}")
    print("")


def show_from_logs(args, env, members, tickets, start_ms, pair_ids):
    logs = boto3.client("logs", region_name=env["REGION"])
    ticket_set = set(tickets)
    deadline = time.time() + args.timeout
    events = []
    while True:
        events = read_events(logs, env["LOG_GROUP"], start_ms, ticket_set)
        done = final_types(events, ticket_set)
        print(f"\r  イベントを待っています… 届いたイベント {len(events)} 件・終わったチケット {len(done)} / {len(tickets)} 枚",
              end="", file=sys.stderr, flush=True)
        if len(done) == len(tickets) or time.time() >= deadline:
            print("", file=sys.stderr)
            break
        time.sleep(5)

    if not events:
        print(f"EventBridge からイベントが届いていません。python3 teams.py {args.round} --from-tickets で、チケットから結果を表示できます。")
        return

    if args.raw:
        succeeded = [e for e in events if e.get("detail", {}).get("type") == "MatchmakingSucceeded"]
        print(json.dumps(succeeded[0] if succeeded else events[-1], indent=2, ensure_ascii=False))
        return

    title = "試しのチケットのイベント" if args.round == "trial" else f"ラウンド {args.round} のチーム発表"
    print(f"━━━━━━━━ {title} ━━━━━━━━")
    print_timeline(events, start_ms)
    if args.round == "trial":
        return

    succeeded = [e for e in events if e.get("detail", {}).get("type") == "MatchmakingSucceeded"]
    if succeeded:
        assigned = {}
        for event in succeeded:
            assigned.update(teams_from_event(event))
        match_ids = {e.get("detail", {}).get("matchId") for e in succeeded}
        print(f"マッチの数: {len(match_ids)}")
        print_teams(assigned, members, pair_ids)
        print("")
        print_rule_metrics(events, match_ids)
        last_start = max(((parse_time(t.get("startTime")) or 0) for e in succeeded for t in e["detail"].get("tickets", []) or []), default=0)
        done_at = parse_time(succeeded[0].get("time"))
        if last_start and done_at:
            # イベントの time は秒の単位のため、1 秒以内に成立すると負の値になることがある。0 にそろえる
            print(f"最後のチケットの申し込みから MatchmakingSucceeded までの秒数: {max(0.0, done_at - last_start):.0f} 秒")
    else:
        print("MatchmakingSucceeded のイベントは届いていません。")
        print_rule_metrics(events, set())

    done = final_types(events, ticket_set)
    counts = {}
    for kind in done.values():
        counts[kind] = counts.get(kind, 0) + 1
    print("最後に届いたイベントの種類ごとのチケットの数: " + "、".join(f"{k} {v} 枚" for k, v in counts.items()))
    if len(done) == len(tickets):
        print("すべてのチケットが終わりました。次のラウンドに進めます。")
    else:
        print(f"まだ終わっていないチケットが {len(tickets) - len(done)} 枚あります。1 分ほど待ってから、もう一度実行してください。")


def show_from_tickets(args, env, members, tickets, start_ms, pair_ids):
    """予備の方法。DescribeMatchmaking を、チケット 10 件ずつ 1 回だけ呼び出す。"""
    waited = time.time() - start_ms / 1000
    if args.round != "trial" and waited < 150:
        print(f"まだ処理中のチケットがある可能性があります。申し込みから {waited:.0f} 秒です。2 分以上たってから再実行してください。")
        return
    gamelift = boto3.client("gamelift", region_name=env["REGION"])
    found = []
    for i in range(0, len(tickets), 10):
        found += gamelift.describe_matchmaking(TicketIds=tickets[i:i + 10]).get("TicketList", [])
    title = "試しのチケット" if args.round == "trial" else f"ラウンド {args.round} のチーム発表"
    print(f"━━━━━━━━ {title} ━━━━━━━━")
    print("DescribeMatchmaking の結果から表示します。")
    counts = {}
    for ticket in found:
        counts[ticket.get("Status")] = counts.get(ticket.get("Status"), 0) + 1
    print("チケットの状態ごとの数: " + "、".join(f"{k} {v} 枚" for k, v in counts.items()))
    assigned = {p["PlayerId"]: p["Team"] for t in found for p in t.get("Players", []) if p.get("Team")}
    if assigned:
        print("")
        print_teams(assigned, members, pair_ids)
    print("")
    print("ルールごとの合格数と不合格数は、イベントにだけ含まれるため、この方法では表示できません。")


def main():
    parser = argparse.ArgumentParser(description="FlexMatch のイベントから、チームの表を表示します。")
    parser.add_argument("round", help="ラウンドの番号 1〜6、または trial")
    parser.add_argument("--raw", action="store_true", help="MatchmakingSucceeded のイベントの JSON を表示する")
    parser.add_argument("--from-tickets", action="store_true", help="DescribeMatchmaking を 1 回だけ呼び出して表示する")
    parser.add_argument("--timeout", type=int, default=240, help="イベントを待つ上限の秒数。既定は 240 秒")
    args = parser.parse_args()
    if args.round != "trial" and not re.fullmatch(r"[1-6]", args.round):
        parser.error("ラウンドの番号は 1〜6、または trial を指定してください。")

    env = load_env()
    members = load_members()
    tickets, start_ms, pair_ids = round_tickets(env, members, args.round)
    try:
        if args.from_tickets:
            show_from_tickets(args, env, members, tickets, start_ms, pair_ids)
        else:
            show_from_logs(args, env, members, tickets, start_ms, pair_ids)
    except (ClientError, BotoCoreError) as error:
        sys.exit(f"❌ Error: AWS の API の呼び出しに失敗しました: {error}")


if __name__ == "__main__":
    main()
