#!/bin/bash
set -euo pipefail
export AWS_PAGER=""

# AWS Deep Cuts - Amazon GameLift Servers の FlexMatch ハンズオンの事前準備
# FlexMatch そのものの操作（ルールセットとマッチメイキング設定の作成・申し込みなど）と、
# EventBridge のルールの作成は、README の手順で 1 コマンドずつ実行します。
# このスクリプトは、その前提になる次の 2 つだけを作成します。
#   1. CloudWatch Logs のロググループ   … FlexMatch のイベントを保存する（保持期間 7 日）
#   2. CloudWatch Logs のリソースポリシー … EventBridge のルール aws-deepcuts-flexmatch-events から、
#                                          このロググループへの書き込みだけを許可する
# ルールセット・マッチメイキング設定・EventBridge のルールは作成しません。

readonly PROJECT_NAME="aws-deepcuts"
readonly REGION="ap-northeast-1"   # FlexMatch のスタンドアロンモードの料金が Price List にあるリージョン（2026 年 11 月時点）
readonly LOG_GROUP="/aws/events/${PROJECT_NAME}-flexmatch"
readonly LOGS_POLICY_NAME="${PROJECT_NAME}-flexmatch-events"
readonly EVENT_RULE_NAME="${PROJECT_NAME}-flexmatch-events"
readonly CONFIG_NAME="${PROJECT_NAME}-study-teams"
readonly RULE_SET_PREFIX="${PROJECT_NAME}-teams"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly RESOURCE_FILE="${SCRIPT_DIR}/resource-ids.env"
readonly MEMBERS_FILE="${SCRIPT_DIR}/members.csv"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AWS Deep Cuts - FlexMatch 事前準備"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ─── [1/4] 前提の確認 ─────────────────────────────────────────
echo "[1/4] 前提を確認..."
if [[ -f "${RESOURCE_FILE}" ]]; then
  echo "❌ Error: ${RESOURCE_FILE} が既に存在します。前回の環境が残っています。" >&2
  echo "   先に bash ./cleanup.sh を実行してください。" >&2
  exit 1
fi
command -v python3 >/dev/null || { echo "❌ Error: python3 コマンドが見つかりません。" >&2; exit 1; }
if ! python3 -c 'import boto3' >/dev/null 2>&1; then
  echo "❌ Error: Python の boto3 が見つかりません。teams.py が使います。" >&2
  echo "   python3 -m pip install --user boto3 を実行してから、もう一度実行してください。" >&2
  exit 1
fi
if [[ ! -f "${MEMBERS_FILE}" ]]; then
  echo "❌ Error: ${MEMBERS_FILE} が見つかりません。hands-on ディレクトリで実行してください。" >&2
  exit 1
fi
MEMBER_COUNT=$(tail -n +2 "${MEMBERS_FILE}" | grep -c '^member-' || true)
if [[ "${MEMBER_COUNT}" != "24" ]]; then
  echo "❌ Error: members.csv の参加者が 24 人ではなく、${MEMBER_COUNT} 人です。元の内容に戻してください。" >&2
  exit 1
fi
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
  echo "❌ Error: AWS の認証情報を取得できません。CloudShell で実行しているか確認してください。" >&2
  exit 1
}
echo "  アカウント: ${ACCOUNT_ID} / リージョン: ${REGION}"

# 同じ名前のマッチメイキング設定やロググループが残っていると、README の手順の途中で失敗するため、ここで止める
EXISTING_CONFIG=$(aws gamelift describe-matchmaking-configurations --region "${REGION}" \
  --names "${CONFIG_NAME}" --query 'length(Configurations)' --output text 2>/dev/null || echo "0")
if [[ "${EXISTING_CONFIG}" != "0" ]]; then
  echo "❌ Error: マッチメイキング設定 ${CONFIG_NAME} が既に存在します。前回の環境が残っています。" >&2
  echo "   先に bash ./cleanup.sh を実行してください。" >&2
  exit 1
fi
EXISTING_LOG_GROUP=$(aws logs describe-log-groups --region "${REGION}" --log-group-name-prefix "${LOG_GROUP}" \
  --query "length(logGroups[?logGroupName=='${LOG_GROUP}'])" --output text)
if [[ "${EXISTING_LOG_GROUP}" != "0" ]]; then
  echo "❌ Error: ロググループ ${LOG_GROUP} が既に存在します。前回の環境が残っています。" >&2
  echo "   先に bash ./cleanup.sh を実行してください。" >&2
  exit 1
fi

# 作成したリソースの情報は、作成する前に resource-ids.env へ書き出す。
# 途中で失敗しても、cleanup.sh がこのファイルを読んで、作成済みのリソースを削除できるようにするため。
LOG_GROUP_ARN="arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:${LOG_GROUP}"
EVENT_RULE_ARN="arn:aws:events:${REGION}:${ACCOUNT_ID}:rule/${EVENT_RULE_NAME}"
cat > "${RESOURCE_FILE}" <<EOF
# AWS Deep Cuts FlexMatch - リソース情報（setup.sh が作成。README の手順と apply-round.sh が行を追記します）
REGION="${REGION}"
ACCOUNT_ID="${ACCOUNT_ID}"
LOG_GROUP="${LOG_GROUP}"
LOG_GROUP_ARN="${LOG_GROUP_ARN}"
LOGS_POLICY_NAME="${LOGS_POLICY_NAME}"
EVENT_RULE_NAME="${EVENT_RULE_NAME}"
EVENT_RULE_ARN="${EVENT_RULE_ARN}"
CONFIG_NAME="${CONFIG_NAME}"
RULE_SET_PREFIX="${RULE_SET_PREFIX}"
EOF
echo "  リソース情報の保存先: ${RESOURCE_FILE}"
echo ""

# ─── [2/4] CloudWatch Logs のロググループ ───────────────────────
echo "[2/4] イベントを保存するロググループを作成..."
aws logs create-log-group --region "${REGION}" --log-group-name "${LOG_GROUP}" --tags "Project=${PROJECT_NAME}"
aws logs put-retention-policy --region "${REGION}" --log-group-name "${LOG_GROUP}" --retention-in-days 7
echo "  作成: ${LOG_GROUP} / 保持期間 7 日"
echo ""

# ─── [3/4] CloudWatch Logs のリソースポリシー ───────────────────
# EventBridge がロググループに書き込むには、ロググループの側でサービスのプリンシパルに書き込みを許可する。
# 許可できるのは logs:CreateLogStream と logs:PutLogEvents だけ（PutResourcePolicy の API の説明）。
# PutLogEvents は、aws:SourceArn の条件で、README の手順 2 で作成する EventBridge のルールからの書き込みに絞る。
echo "[3/4] EventBridge からの書き込みを許可するリソースポリシーを作成..."
POLICY_DOCUMENT=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EventBridgeCreateLogStream",
      "Effect": "Allow",
      "Principal": { "Service": ["events.amazonaws.com", "delivery.logs.amazonaws.com"] },
      "Action": "logs:CreateLogStream",
      "Resource": "${LOG_GROUP_ARN}:*"
    },
    {
      "Sid": "EventBridgePutLogEvents",
      "Effect": "Allow",
      "Principal": { "Service": ["events.amazonaws.com", "delivery.logs.amazonaws.com"] },
      "Action": "logs:PutLogEvents",
      "Resource": "${LOG_GROUP_ARN}:*:*",
      "Condition": { "ArnEquals": { "aws:SourceArn": "${EVENT_RULE_ARN}" } }
    }
  ]
}
EOF
)
aws logs put-resource-policy --region "${REGION}" --policy-name "${LOGS_POLICY_NAME}" \
  --policy-document "${POLICY_DOCUMENT}" >/dev/null
echo "  作成: ${LOGS_POLICY_NAME}"
echo ""

# ─── [4/4] 完了 ───────────────────────────────────────────────
echo "[4/4] 作成したリソースを確認..."
echo "  ロググループ:       ${LOG_GROUP_ARN}"
echo "  リソースポリシー:   ${LOGS_POLICY_NAME}"
echo "  書き込みを許可する EventBridge のルール: ${EVENT_RULE_ARN}"
echo "  この EventBridge のルールは、README の手順 2 で作成します。"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ セットアップが完了しました！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "作成したロググループは、マネジメントコンソールの次の画面で確認できます。"
echo "  https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#logsV2:log-groups"
echo ""
echo "次のステップ: README の手順 1 に戻り、次のコマンドで変数を読み込んでください。"
echo "  source ./resource-ids.env"
