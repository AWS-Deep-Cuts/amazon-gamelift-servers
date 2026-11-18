#!/bin/bash
set -euo pipefail
export AWS_PAGER=""

# AWS Deep Cuts - Amazon GameLift Servers の FlexMatch ハンズオンの後片付け
# 手順の中で作成したチケット・マッチメイキング設定・ルールセット・EventBridge のルールと、
# setup.sh が作成したリソースポリシーとロググループを、すべて削除します。
# 削除の順序には理由があります。
#   - 処理中のチケットが使っているマッチメイキング設定は削除できない → 先にチケットを止める
#   - マッチメイキング設定が使っているルールセットは削除できない     → 先に設定を削除する

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly RESOURCE_FILE="${SCRIPT_DIR}/resource-ids.env"
readonly MEMBERS_FILE="${SCRIPT_DIR}/members.csv"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AWS Deep Cuts - FlexMatch 後片付け"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# resource-ids.env が無い場合（setup.sh が途中で止まった場合など）は、setup.sh と同じ既定の名前で探して削除する
if [[ -f "${RESOURCE_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${RESOURCE_FILE}"
else
  echo "  ${RESOURCE_FILE} が見つからないため、既定の名前で探して削除します。"
  echo ""
fi
REGION="${REGION:-ap-northeast-1}"
LOG_GROUP="${LOG_GROUP:-/aws/events/aws-deepcuts-flexmatch}"
LOGS_POLICY_NAME="${LOGS_POLICY_NAME:-aws-deepcuts-flexmatch-events}"
EVENT_RULE_NAME="${EVENT_RULE_NAME:-aws-deepcuts-flexmatch-events}"
CONFIG_NAME="${CONFIG_NAME:-aws-deepcuts-study-teams}"
RULE_SET_PREFIX="${RULE_SET_PREFIX:-aws-deepcuts-teams}"

# ─── [1/6] 処理中のチケットを止める ─────────────────────────────
echo "[1/6] 処理中のチケットを止める..."
TICKET_IDS=()
if [[ -f "${RESOURCE_FILE}" ]]; then
  # ラウンドをやり直した場合は R<番号>_PREFIX が複数行あるため、source した値ではなく、すべての行を読む
  while IFS= read -r PREFIX; do
    TICKET_IDS+=("${PREFIX}-pair")
    while IFS=, read -r PLAYER_ID _; do
      if [[ "${PLAYER_ID}" == member-* ]]; then
        TICKET_IDS+=("${PREFIX}-${PLAYER_ID}")
      fi
    done < <(tail -n +2 "${MEMBERS_FILE}")
  done < <(sed -n -E 's/^R[0-9]+_PREFIX="?([^"]*)"?$/\1/p' "${RESOURCE_FILE}")
  while IFS= read -r TICKET; do
    TICKET_IDS+=("${TICKET}")
  done < <(sed -n -E 's/^TRIAL_TICKET="?([^"]*)"?$/\1/p' "${RESOURCE_FILE}")
fi
STOPPED=0
# DescribeMatchmaking は 1 回に 10 件まで。状態を確かめるために、10 件ずつ 1 回だけ呼び出す
for ((i = 0; i < ${#TICKET_IDS[@]}; i += 10)); do
  ACTIVE=$(aws gamelift describe-matchmaking --region "${REGION}" --ticket-ids "${TICKET_IDS[@]:i:10}" \
    --query "TicketList[?Status=='QUEUED' || Status=='SEARCHING' || Status=='REQUIRES_ACCEPTANCE' || Status=='PLACING'].TicketId" \
    --output text 2>/dev/null || true)
  for TICKET in ${ACTIVE}; do
    [[ "${TICKET}" == "None" ]] && continue
    if aws gamelift stop-matchmaking --region "${REGION}" --ticket-id "${TICKET}" 2>/dev/null; then
      echo "  停止: ${TICKET}"
      STOPPED=$((STOPPED + 1))
    fi
  done
done
if [[ "${STOPPED}" == "0" ]]; then
  echo "  処理中のチケットはありません"
fi
echo ""

# ─── [2/6] マッチメイキング設定を削除 ───────────────────────────
echo "[2/6] マッチメイキング設定を削除..."
config_exists() {
  local out
  if out=$(aws gamelift describe-matchmaking-configurations --region "${REGION}" --names "${CONFIG_NAME}" \
    --query 'length(Configurations)' --output text 2>&1); then
    [[ "${out}" != "0" ]]
  else
    # 指定した名前の設定が無いと、API は空の一覧ではなく InvalidRequestException を返す。これは「無い」と判定する
    # それ以外のエラー（権限が無い、通信できないなど）は、確かめられなかったため「残っている」と判定する
    [[ "${out}" != *InvalidRequestException* && "${out}" != *NotFoundException* ]]
  fi
}
if config_exists; then
  # 止めたチケットが終わるまでは削除できないことがあるため、10 秒おきに最大 3 分試す
  DELETED=""
  for _ in $(seq 1 18); do
    # 成功すると API は空の JSON を返し、AWS CLI は何も表示しない。成否は終了コードで判定する
    if aws gamelift delete-matchmaking-configuration --region "${REGION}" --name "${CONFIG_NAME}" 2>/dev/null \
       || ! config_exists; then
      DELETED="yes"
      break
    fi
    echo "  処理中のチケットが終わるのを待っています。10 秒後に再試行します..."
    sleep 10
  done
  if [[ -n "${DELETED}" ]]; then
    echo "  削除: ${CONFIG_NAME}"
  else
    echo "  ⚠️  削除できませんでした。数分待ってから、もう一度 bash ./cleanup.sh を実行してください。" >&2
  fi
else
  echo "  対象なし"
fi
echo ""

# ─── [3/6] ルールセットを削除 ───────────────────────────────────
echo "[3/6] ルールセットを削除..."
# 名前が aws-deepcuts-teams- で始まるルールセットを探す。予備のルールセット（-r2b など）も対象になる
RULE_SETS=$(aws gamelift describe-matchmaking-rule-sets --region "${REGION}" \
  --query "RuleSets[?starts_with(RuleSetName, '${RULE_SET_PREFIX}-')].RuleSetName" --output text 2>/dev/null || true)
if [[ -z "${RULE_SETS}" || "${RULE_SETS}" == "None" ]]; then
  echo "  対象なし"
else
  for RULE_SET in ${RULE_SETS}; do
    if aws gamelift delete-matchmaking-rule-set --region "${REGION}" --name "${RULE_SET}" 2>/dev/null; then
      echo "  削除: ${RULE_SET}"
    else
      echo "  ⚠️  削除できませんでした: ${RULE_SET}" >&2
    fi
  done
fi
echo ""

# ─── [4/6] EventBridge のルールを削除 ───────────────────────────
echo "[4/6] EventBridge のルールを削除..."
if aws events describe-rule --region "${REGION}" --name "${EVENT_RULE_NAME}" >/dev/null 2>&1; then
  # ターゲットが残っている EventBridge のルールは削除できないため、先にターゲットを外す
  aws events remove-targets --region "${REGION}" --rule "${EVENT_RULE_NAME}" --ids logs >/dev/null 2>&1 || true
  if aws events delete-rule --region "${REGION}" --name "${EVENT_RULE_NAME}" 2>/dev/null; then
    echo "  削除: ${EVENT_RULE_NAME}"
  else
    echo "  ⚠️  削除できませんでした: ${EVENT_RULE_NAME}" >&2
  fi
else
  echo "  対象なし"
fi
echo ""

# ─── [5/6] リソースポリシーとロググループを削除 ─────────────────
echo "[5/6] リソースポリシーとロググループを削除..."
if aws logs delete-resource-policy --region "${REGION}" --policy-name "${LOGS_POLICY_NAME}" 2>/dev/null; then
  echo "  削除: リソースポリシー ${LOGS_POLICY_NAME}"
fi
if aws logs delete-log-group --region "${REGION}" --log-group-name "${LOG_GROUP}" 2>/dev/null; then
  echo "  削除: ロググループ ${LOG_GROUP}"
fi
rm -f "${SCRIPT_DIR:?}"/round*.txt
echo ""

# ─── [6/6] 残っているリソースを確認 ─────────────────────────────
echo "[6/6] 残っているリソースを確認..."
LEFT=0
if config_exists; then
  echo "  ⚠️  マッチメイキング設定が残っています: ${CONFIG_NAME}"; LEFT=1
fi
REMAINING_RULE_SETS=$(aws gamelift describe-matchmaking-rule-sets --region "${REGION}" \
  --query "RuleSets[?starts_with(RuleSetName, '${RULE_SET_PREFIX}-')].RuleSetName" --output text 2>/dev/null || echo "unknown")
if [[ -n "${REMAINING_RULE_SETS}" && "${REMAINING_RULE_SETS}" != "None" ]]; then
  echo "  ⚠️  ルールセットが残っています: ${REMAINING_RULE_SETS}"; LEFT=1
fi
if aws events describe-rule --region "${REGION}" --name "${EVENT_RULE_NAME}" >/dev/null 2>&1; then
  echo "  ⚠️  EventBridge のルールが残っています: ${EVENT_RULE_NAME}"; LEFT=1
fi
REMAINING_LOG_GROUPS=$(aws logs describe-log-groups --region "${REGION}" --log-group-name-prefix "${LOG_GROUP}" \
  --query "length(logGroups[?logGroupName=='${LOG_GROUP}'])" --output text 2>/dev/null || echo "unknown")
if [[ "${REMAINING_LOG_GROUPS}" != "0" ]]; then
  echo "  ⚠️  ロググループが残っています: ${LOG_GROUP}"; LEFT=1
fi
REMAINING_POLICIES=$(aws logs describe-resource-policies --region "${REGION}" \
  --query "length(resourcePolicies[?policyName=='${LOGS_POLICY_NAME}'])" --output text 2>/dev/null || echo "unknown")
if [[ "${REMAINING_POLICIES}" != "0" ]]; then
  echo "  ⚠️  リソースポリシーが残っています: ${LOGS_POLICY_NAME}"; LEFT=1
fi
if [[ "${LEFT}" == "1" ]]; then
  echo ""
  echo "❌ 削除できなかったリソースがあります。数分待ってから、もう一度 bash ./cleanup.sh を実行してください。" >&2
  exit 1
fi
echo "  なし"
rm -f "${RESOURCE_FILE}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ すべてのリソースの削除が完了しました！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
