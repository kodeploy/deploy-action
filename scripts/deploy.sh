#!/usr/bin/env bash
# 5~6단계: kodeploy deploy 실행 → 출력 채우기 → exit code 정하기.
# 입력은 env로만 받는다 (action.yml): KODEPLOY_SERVER/APP/AUDIENCE(CLI가 직접 읽는다), KD_BIN, KD_TIMEOUT, KD_SETTLE, KD_WAIT, KD_FAIL_ON_SUPERSEDED
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$here/lib.sh"

case ${KD_WAIT:-true} in
  true) wait_flag=() ;;
  false) wait_flag=(--no-wait) ;;
  *)
    kd_error "wait는 true나 false여야 해요: ${KD_WAIT}"
    exit 2
    ;;
esac
case ${KD_FAIL_ON_SUPERSEDED:-false} in
  true | false) ;;
  *)
    kd_error "fail-on-superseded는 true나 false여야 해요: ${KD_FAIL_ON_SUPERSEDED}"
    exit 2
    ;;
esac

tmp=$(mktemp -d "${RUNNER_TEMP:-/tmp}/kodeploy.XXXXXX")
result="$tmp/result.json"
held="$tmp/annotations"
: >"$held"

# stdout(json 결과)은 파일로, stderr(진행 상황)는 로그로 흘린다. CLI의 ::error는 잠깐 붙잡아 둔다.
# ${arr[@]+...}: bash 3.2에서 빈 배열을 set -u로 펼치면 오류라서
"$KD_BIN" deploy --output json --timeout "${KD_TIMEOUT:-25m}" --settle "${KD_SETTLE:-60s}" ${wait_flag[@]+"${wait_flag[@]}"} \
  2>&1 >"$result" | kd_hold_annotations "$held" >&2
code=${PIPESTATUS[0]}

if ! command -v jq >/dev/null 2>&1; then
  kd_warning "러너에 jq가 없어 result·build-ids·source-sha 출력을 채우지 못했어요 (exit-code만 채웠어요)"
fi
kd_outputs "$result" "$code" >>"$GITHUB_OUTPUT"
final=$(kd_final_code "$code" "${KD_FAIL_ON_SUPERSEDED:-false}")

if [[ $code == 3 && $final == 0 ]]; then
  # CLI가 이미 이스케이프한 값이라 그대로 싣는다
  msg=$(sed -n 's/^::error[^:]*::\(.*\)$/\1/p' "$held" | head -n 1)
  printf '::notice title=kodeploy::%s — fail-on-superseded가 false라 성공으로 끝내요\n' "${msg:-다른 배포에 밀렸어요}"
elif [[ $final != 0 ]]; then
  if [[ -s $held ]]; then
    cat "$held"
  else
    kd_error "kodeploy deploy가 exit ${code}로 끝났어요"
  fi
fi
rm -rf "$tmp"
exit "$final"
