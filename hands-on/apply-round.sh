#!/bin/bash
set -euo pipefail
export AWS_PAGER=""

# AWS Deep Cuts - FlexMatch ハンズオンの 1 ラウンド分の申し込み
# members.csv の参加者 24 人を、1 人ずつ start-matchmaking で申し込みます。
# このスクリプトがしているのは、README の手順 4 で 1 人だけ実行した start-matchmaking を、24 人分繰り返すことだけです。
#
# 使い方:
#   bash ./apply-round.sh <ラウンドの番号>
#   bash ./apply-round.sh <ラウンドの番号> --pair <プレイヤー ID>,<プレイヤー ID>
#     --pair を付けると、指定した 2 人を 1 枚のチケットで申し込み、残りの 22 人を 1 人 1 枚で申し込みます。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly RESOURCE_FILE="${SCRIPT_DIR}/resource-ids.env"
readonly MEMBERS_FILE="${SCRIPT_DIR}/members.csv"

usage() {
  echo "使い方: bash ./apply-round.sh <ラウンドの番号 1〜6> [--pair <プレイヤー ID>,<プレイヤー ID>]" >&2
  echo "  例: bash ./apply-round.sh 1" >&2
  echo "  例: bash ./apply-round.sh 4 --pair member-01,member-02" >&2
  exit 1
}

# ─── 引数の確認 ─────────────────────────────────────────────
[[ $# -ge 1 ]] || usage
ROUND="$1"
shift
[[ "${ROUND}" =~ ^[1-6]$ ]] || usage
PAIR=""
if [[ $# -gt 0 ]]; then
  [[ "$1" == "--pair" && $# -eq 2 ]] || usage
  PAIR="$2"
  [[ "${PAIR}" =~ ^member-[0-9]{2},member-[0-9]{2}$ ]] || usage
fi

if [[ ! -f "${RESOURCE_FILE}" ]]; then
  echo "❌ Error: ${RESOURCE_FILE} が見つかりません。先に bash ./setup.sh を実行してください。" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${RESOURCE_FILE}"

# members.csv の 1 行から、start-matchmaking の --players に渡す 1 人分の JSON を作る。
# FlexMatch に渡すのは、ルールセットの playerAttributes で宣言した years と infra だけ。role は渡さない。
player_json() {
  local id="$1" line years infra
  line=$(grep "^${id}," "${MEMBERS_FILE}" || true)
  if [[ -z "${line}" ]]; then
    echo "❌ Error: ${id} は members.csv にありません。" >&2
    exit 1
  fi
  years=$(echo "${line}" | cut -d, -f2)
  infra=$(echo "${line}" | cut -d, -f4)
  echo "{\"PlayerId\": \"${id}\", \"PlayerAttributes\": {\"years\": {\"N\": ${years}}, \"infra\": {\"N\": ${infra}}}}"
}

PAIR_A=""
PAIR_B=""
if [[ -n "${PAIR}" ]]; then
  PAIR_A="${PAIR%%,*}"
  PAIR_B="${PAIR##*,}"
  if [[ "${PAIR_A}" == "${PAIR_B}" ]]; then
    echo "❌ Error: --pair には、異なる 2 人のプレイヤー ID を指定してください。" >&2
    exit 1
  fi
  # 2 人が members.csv にあることを、申し込む前に確かめる
  player_json "${PAIR_A}" >/dev/null
  player_json "${PAIR_B}" >/dev/null
fi

# ─── いま設定が使っているルールセット ──────────────────────────
# ルールセットの差し替えを忘れていないかを、申し込む前に表示する
read -r CURRENT_RULE_SET TIMEOUT_SECONDS < <(aws gamelift describe-matchmaking-configurations \
  --region "${REGION}" --names "${CONFIG_NAME}" \
  --query 'Configurations[0].[RuleSetName, RequestTimeoutSeconds]' --output text) || true
if [[ -z "${CURRENT_RULE_SET:-}" || "${CURRENT_RULE_SET}" == "None" || ! "${TIMEOUT_SECONDS:-}" =~ ^[0-9]+$ ]]; then
  echo "❌ Error: マッチメイキング設定 ${CONFIG_NAME} が見つかりません。README の手順 3 で作成してください。" >&2
  exit 1
fi

PREFIX="r${ROUND}-$(date +%H%M%S)"
START_MS=$(date +%s%3N)

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ラウンド ${ROUND} の申し込み"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  マッチメイキング設定: ${CONFIG_NAME}"
echo "  いま設定が使っているルールセット: ${CURRENT_RULE_SET}"
echo "  申し込みのタイムアウト: ${TIMEOUT_SECONDS} 秒"
echo "  チケット ID の接頭辞: ${PREFIX}"
if [[ -n "${PAIR}" ]]; then
  echo "  1 枚のチケットで一緒に申し込む 2 人: ${PAIR_A} と ${PAIR_B}"
fi
echo ""

# 途中で止まっても、teams.py と cleanup.sh がこのラウンドのチケットを探せるように、申し込む前に追記する
{
  echo "R${ROUND}_PREFIX=\"${PREFIX}\""
  echo "R${ROUND}_START_MS=\"${START_MS}\""
  if [[ -n "${PAIR}" ]]; then
    echo "R${ROUND}_PAIR=\"${PAIR}\""
  fi
} >> "${RESOURCE_FILE}"

TICKETS=0
PLAYERS=0
FIRST_MS=""
LAST_MS=""

# 1 枚のチケットを申し込む。失敗したら、エラーを表示して止める。
apply_ticket() {
  local ticket_id="$1" players_json="$2" label="$3" status
  [[ -n "${FIRST_MS}" ]] || FIRST_MS=$(date +%s%3N)
  if ! status=$(aws gamelift start-matchmaking \
      --region "${REGION}" \
      --configuration-name "${CONFIG_NAME}" \
      --ticket-id "${ticket_id}" \
      --players "${players_json}" \
      --query MatchmakingTicket.Status --output text 2>&1); then
    echo "❌ Error: ${label} の申し込みに失敗しました。" >&2
    echo "${status}" >&2
    echo "   すでに申し込んだチケットは、申し込みのタイムアウトの ${TIMEOUT_SECONDS} 秒が過ぎると終わります。" >&2
    echo "   原因を修正してから、このラウンドをやり直してください。" >&2
    exit 1
  fi
  LAST_MS=$(date +%s%3N)
  echo "  ${label} → ${status}"
  TICKETS=$((TICKETS + 1))
}

# --pair の 2 人を、1 枚のチケットで申し込む
if [[ -n "${PAIR}" ]]; then
  apply_ticket "${PREFIX}-pair" "[$(player_json "${PAIR_A}"), $(player_json "${PAIR_B}")]" "${PAIR_A} と ${PAIR_B}"
  PLAYERS=$((PLAYERS + 2))
  sleep 0.2
fi

# 残りの参加者を、1 人 1 枚のチケットで申し込む
while IFS=, read -r PLAYER_ID _; do
  [[ "${PLAYER_ID}" == member-* ]] || continue
  [[ "${PLAYER_ID}" == "${PAIR_A}" || "${PLAYER_ID}" == "${PAIR_B}" ]] && continue
  apply_ticket "${PREFIX}-${PLAYER_ID}" "[$(player_json "${PLAYER_ID}")]" "${PLAYER_ID}"
  PLAYERS=$((PLAYERS + 1))
  sleep 0.2
done < <(tail -n +2 "${MEMBERS_FILE}")

ELAPSED=$(( (LAST_MS - FIRST_MS + 500) / 1000 ))
REMAINING=$(( TIMEOUT_SECONDS - ELAPSED ))
echo ""
echo "申し込みに ${ELAPSED} 秒かかりました。最初のチケットは、あと ${REMAINING} 秒で申し込みのタイムアウトになります。"
if (( ELAPSED >= 60 )); then
  echo "⚠️  申し込みに時間がかかりました。マッチが成立しない場合は、README のトラブルシューティングを参照してください。"
fi
echo ""
echo "チケット ${TICKETS} 枚・プレイヤー ${PLAYERS} 人を申し込みました。結果は python3 teams.py ${ROUND} で表示します。"
