#!/usr/bin/env bash
# 1~4단계: 권한 확인 → 러너 플랫폼 → CLI 받기 → 체크섬 확인. 성공하면 $GITHUB_OUTPUT에 bin=<kodeploy 경로>.
# 입력은 env로만 받는다 (action.yml): KD_APP, KD_CLI_VERSION
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$here/lib.sh"

if [[ -z ${ACTIONS_ID_TOKEN_REQUEST_URL:-} ]]; then
  kd_error "permissions: id-token: write가 필요해요. 배포 잡에 permissions: { id-token: write, contents: read }를 넣어 주세요"
  exit 1
fi
if [[ -z ${KD_APP:-} ]]; then
  kd_error "app 입력이 비어 있어요. 앱 설정의 앱 id를 넣어 주세요 (예: app: \${{ vars.KODEPLOY_APP_ID }})"
  exit 1
fi

if ! platform=$(kd_platform "${RUNNER_OS:-}" "${RUNNER_ARCH:-}"); then
  kd_error "지원하지 않는 러너예요: ${RUNNER_OS:-?}/${RUNNER_ARCH:-?} (Linux·macOS의 X64·ARM64만 돼요)"
  exit 1
fi
read -r os arch <<<"$platform"

if ! ver=$(kd_version "${KD_CLI_VERSION:-}"); then
  kd_error "cli-version은 0.1.0 같은 버전이어야 해요: ${KD_CLI_VERSION:-}"
  exit 1
fi

dest="${RUNNER_TEMP:-/tmp}/kodeploy-cli-$ver-$os-$arch"
kd_install "$ver" "$os" "$arch" "$KD_RELEASE_BASE" "$here/../checksums" "$dest"
echo "kodeploy: CLI $ver ($os/$arch) 체크섬 확인 완료"
echo "bin=$dest/kodeploy" >>"$GITHUB_OUTPUT"
