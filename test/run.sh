#!/usr/bin/env bash
# 셸 단위 테스트 — 바깥 의존 없이 bash와 curl(file://), tar, jq만 쓴다. 사용: test/run.sh
set -uo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$root/scripts/lib.sh"

failures=0
passes=0
pass() { passes=$((passes + 1)); }
fail() {
  failures=$((failures + 1))
  printf 'FAIL: %s\n' "$1"
}
eq() { if [[ $2 == "$3" ]]; then pass; else fail "$1: want [$3] got [$2]"; fi; }
has() { if [[ $2 == *"$3"* ]]; then pass; else fail "$1: [$3] not in [$2]"; fi; }
lacks() { if [[ $2 != *"$3"* ]]; then pass; else fail "$1: [$3] should not be in [$2]"; fi; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- 플랫폼 매핑 -------------------------------------------------------------
eq "Linux X64" "$(kd_platform Linux X64)" "linux amd64"
eq "Linux ARM64" "$(kd_platform Linux ARM64)" "linux arm64"
eq "macOS X64" "$(kd_platform macOS X64)" "darwin amd64"
eq "macOS ARM64" "$(kd_platform macOS ARM64)" "darwin arm64"
for bad in "Windows X64" "Windows ARM64" "Linux ARM" "Linux X86" "linux X64" " X64" "Linux "; do
  # shellcheck disable=SC2086 # 일부러 두 인자로 나눈다
  if kd_platform ${bad% *} "${bad#* }" >/dev/null; then fail "platform [$bad] should be rejected"; else pass; fi
done

# --- 버전 ---------------------------------------------------------------------
eq "version plain" "$(kd_version 0.1.0)" "0.1.0"
eq "version v" "$(kd_version v1.2.3)" "1.2.3"
eq "version cli-v" "$(kd_version cli-v0.10.2)" "0.10.2"
for bad in latest 0.1 "" "../0.1.0" "0.1.0; rm -rf /" "0.1.0-rc1"; do
  if kd_version "$bad" >/dev/null; then fail "version [$bad] should be rejected"; else pass; fi
done

# --- 체크섬 목록 읽기 -----------------------------------------------------------
sums="$work/sums.txt"
cat >"$sums" <<'EOF'
1111111111111111111111111111111111111111111111111111111111111111  kodeploy_0.1.0_linux_amd64.tar.gz
2222222222222222222222222222222222222222222222222222222222222222 *kodeploy_0.1.0_darwin_arm64.tar.gz
nothex  kodeploy_0.1.0_linux_arm64.tar.gz
EOF
eq "expected sha" "$(kd_expected_sha "$sums" kodeploy_0.1.0_linux_amd64.tar.gz)" "$(printf '1%.0s' {1..64})"
eq "expected sha binary mode" "$(kd_expected_sha "$sums" kodeploy_0.1.0_darwin_arm64.tar.gz)" "$(printf '2%.0s' {1..64})"
if kd_expected_sha "$sums" kodeploy_0.1.0_linux_arm64.tar.gz >/dev/null; then fail "malformed sha accepted"; else pass; fi
if kd_expected_sha "$sums" kodeploy_0.1.0_darwin_amd64.tar.gz >/dev/null; then fail "missing asset accepted"; else pass; fi
if kd_expected_sha "$sums" linux_amd64.tar.gz >/dev/null; then fail "suffix match accepted"; else pass; fi

# --- 체크섬 확인 ----------------------------------------------------------------
printf 'hello\n' >"$work/blob"
good=$(kd_sha256 "$work/blob")
eq "sha256 of hello" "$good" "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"
if kd_verify "$work/blob" "$good"; then pass; else fail "verify good"; fi
if kd_verify "$work/blob" "${good%?}0"; then fail "verify wrong sha passed"; else pass; fi
if kd_verify "$work/blob" ""; then fail "verify empty sha passed"; else pass; fi

# --- 설치 (가짜 릴리스, file://) ---------------------------------------------------
release="$work/release"
mkdir -p "$release/cli-v9.9.9" "$work/bin-src"
printf '#!/bin/sh\necho "kodeploy 9.9.9"\n' >"$work/bin-src/kodeploy"
chmod +x "$work/bin-src/kodeploy"
asset=kodeploy_9.9.9_linux_amd64.tar.gz
tar -czf "$release/cli-v9.9.9/$asset" -C "$work/bin-src" kodeploy
real=$(kd_sha256 "$release/cli-v9.9.9/$asset")
printf '%s  %s\n' "$real" "$asset" >"$release/cli-v9.9.9/checksums.txt"
base="file://$release"

pinned="$work/pinned-good"
mkdir -p "$pinned"
printf '%s  %s\n' "$real" "$asset" >"$pinned/9.9.9.txt"
out=$(kd_install 9.9.9 linux amd64 "$base" "$pinned" "$work/dest-good" 2>&1)
eq "install pinned ok exit" "$?" "0"
eq "installed binary runs" "$("$work/dest-good/kodeploy")" "kodeploy 9.9.9"
lacks "pinned install has no warning" "$out" "::warning"

pinned="$work/pinned-bad"
mkdir -p "$pinned"
printf '%s  %s\n' "$(printf '0%.0s' {1..64})" "$asset" >"$pinned/9.9.9.txt"
out=$(kd_install 9.9.9 linux amd64 "$base" "$pinned" "$work/dest-bad" 2>&1)
eq "install with wrong pinned sha fails" "$?" "1"
has "wrong sha error" "$out" "::error title=kodeploy::kodeploy CLI 체크섬이 맞지 않아요"
if [[ -e $work/dest-bad/kodeploy ]]; then fail "binary unpacked despite bad checksum"; else pass; fi

out=$(kd_install 9.9.9 linux amd64 "$base" "$work/no-pins" "$work/dest-unpinned" 2>&1)
eq "install unpinned ok exit" "$?" "0"
has "unpinned warns" "$out" "::warning title=kodeploy::cli-version 9.9.9는 이 액션에 체크섬이 고정돼 있지 않아"
eq "unpinned binary runs" "$("$work/dest-unpinned/kodeploy")" "kodeploy 9.9.9"

printf '%s  %s\n' "$(printf 'f%.0s' {1..64})" "$asset" >"$release/cli-v9.9.9/checksums.txt"
out=$(kd_install 9.9.9 linux amd64 "$base" "$work/no-pins" "$work/dest-tampered" 2>&1)
eq "install with wrong release checksums fails" "$?" "1"
if [[ -e $work/dest-tampered/kodeploy ]]; then fail "binary unpacked despite tampered release checksums"; else pass; fi

out=$(kd_install 9.9.9 darwin arm64 "$base" "$work/pinned-good" "$work/dest-missing" 2>&1)
eq "install missing asset fails" "$?" "1"
has "missing asset error" "$out" "kodeploy CLI를 받지 못했어요"

# --- exit code 정책 -------------------------------------------------------------
eq "superseded allowed" "$(kd_final_code 3 false)" "0"
eq "superseded fails when asked" "$(kd_final_code 3 true)" "3"
eq "failure stays" "$(kd_final_code 1 false)" "1"
eq "timeout stays" "$(kd_final_code 4 false)" "4"
eq "success" "$(kd_final_code 0 true)" "0"

# --- 출력 ----------------------------------------------------------------------
cat >"$work/success.json" <<'EOF'
{"result":"success","exit_code":0,"app_id":"a","requested_sha":"3f9a1c2b0123456789abcdef0123456789abcdef","builds":[{"build_id":"8e7d6c5b","slot":"server","status":"running","source_sha":"3f9a1c2b0123456789abcdef0123456789abcdef","error":null},{"build_id":"0a1b2c3d","slot":"static","status":"running","source_sha":"c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3","error":null}],"message":"성공"}
EOF
eq "outputs success" "$(kd_outputs "$work/success.json" 0)" "$(printf 'result=success\nexit-code=0\nbuild-ids=8e7d6c5b,0a1b2c3d\nsource-sha=3f9a1c2b0123456789abcdef0123456789abcdef')"

cat >"$work/static-first.json" <<'EOF'
{"result":"success","exit_code":0,"app_id":"a","requested_sha":"3f9a1c2b0123456789abcdef0123456789abcdef","builds":[{"build_id":"x1","slot":"static","status":"running","source_sha":"c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3","error":null},{"build_id":"x2","slot":"server","status":"running","source_sha":"3f9a1c2b0123456789abcdef0123456789abcdef","error":null}]}
EOF
has "source-sha picks the workflow commit" "$(kd_outputs "$work/static-first.json" 0)" "source-sha=3f9a1c2b0123456789abcdef0123456789abcdef"

cat >"$work/nowait.json" <<'EOF'
{"result":"requested","exit_code":0,"app_id":"a","requested_sha":"3f9a1c2b0123456789abcdef0123456789abcdef","builds":[{"build_id":"8e7d6c5b","slot":"server","status":"queued","source_sha":null,"error":null}]}
EOF
eq "outputs no-wait" "$(kd_outputs "$work/nowait.json" 0)" "$(printf 'result=requested\nexit-code=0\nbuild-ids=8e7d6c5b\nsource-sha=')"

printf '{"result":"error","exit_code":125,"app_id":"a","requested_sha":null,"builds":[],"message":"x"}\n' >"$work/error.json"
eq "outputs error" "$(kd_outputs "$work/error.json" 125)" "$(printf 'result=error\nexit-code=125\nbuild-ids=\nsource-sha=')"

printf 'not json\n' >"$work/garbage.json"
eq "outputs garbage" "$(kd_outputs "$work/garbage.json" 2)" "$(printf 'result=\nexit-code=2\nbuild-ids=\nsource-sha=')"
: >"$work/empty.json"
eq "outputs empty" "$(kd_outputs "$work/empty.json" 130)" "$(printf 'result=\nexit-code=130\nbuild-ids=\nsource-sha=')"

printf '{"result":"success\\nx=y","builds":[{"build_id":"a\\nb"}]}\n' >"$work/newline.json"
lacks "newline in a value cannot add an output" "$(kd_outputs "$work/newline.json" 0)" "x=y"

# --- install.sh 앞 단계 (받기 전에 끝나는 경우) ---------------------------------------
run_install() {
  env -i PATH="$PATH" HOME="$HOME" RUNNER_TEMP="$work" GITHUB_OUTPUT="$work/install-out" "$@" bash "$root/scripts/install.sh" 2>&1
}
out=$(run_install KD_APP=a KD_CLI_VERSION=0.1.0 RUNNER_OS=Linux RUNNER_ARCH=X64)
eq "no id-token permission exit" "$?" "1"
has "no id-token permission message" "$out" "::error title=kodeploy::permissions: id-token: write가 필요해요"
out=$(run_install ACTIONS_ID_TOKEN_REQUEST_URL=http://x KD_APP=a KD_CLI_VERSION=0.1.0 RUNNER_OS=Windows RUNNER_ARCH=X64)
eq "windows exit" "$?" "1"
has "windows message" "$out" "지원하지 않는 러너예요: Windows/X64"
out=$(run_install ACTIONS_ID_TOKEN_REQUEST_URL=http://x KD_APP= KD_CLI_VERSION=0.1.0 RUNNER_OS=Linux RUNNER_ARCH=X64)
eq "empty app exit" "$?" "1"
has "empty app message" "$out" "app 입력이 비어 있어요"
out=$(run_install ACTIONS_ID_TOKEN_REQUEST_URL=http://x KD_APP=a KD_CLI_VERSION=latest RUNNER_OS=Linux RUNNER_ARCH=X64)
eq "bad version exit" "$?" "1"
has "bad version message" "$out" "cli-version은 0.1.0 같은 버전이어야 해요"

# --- deploy.sh (가짜 CLI) -----------------------------------------------------------
fake="$work/fake-kodeploy"
cat >"$fake" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FAKE_ARGS"
echo "kodeploy: 재배포 요청 app=$KODEPLOY_APP" >&2
if [[ -n ${FAKE_ERROR:-} ]]; then printf '::error title=kodeploy::%s\n' "$FAKE_ERROR" >&2; fi
cat "$FAKE_JSON"
exit "${FAKE_EXIT:-0}"
EOF
chmod +x "$fake"

run_deploy() {
  : >"$work/deploy-out"
  env -i PATH="$PATH" HOME="$HOME" RUNNER_TEMP="$work" GITHUB_OUTPUT="$work/deploy-out" KD_BIN="$fake" \
    FAKE_ARGS="$work/args" KODEPLOY_APP=app-1 "$@" bash "$root/scripts/deploy.sh" 2>"$work/deploy-err"
}

out=$(run_deploy FAKE_JSON="$work/success.json" FAKE_EXIT=0)
eq "deploy success exit" "$?" "0"
eq "deploy success outputs" "$(cat "$work/deploy-out")" "$(kd_outputs "$work/success.json" 0)"
eq "deploy default args" "$(tr '\n' ' ' <"$work/args")" "deploy --output json --timeout 25m --settle 60s "
has "progress goes to the log" "$(cat "$work/deploy-err")" "kodeploy: 재배포 요청 app=app-1"

printf '{"result":"superseded","exit_code":3,"app_id":"a","requested_sha":null,"builds":[{"build_id":"b1","slot":"server","status":"cancelled","source_sha":null,"error":null}],"message":"다른 배포에 밀렸어요"}\n' >"$work/superseded.json"
out=$(run_deploy FAKE_JSON="$work/superseded.json" FAKE_EXIT=3 FAKE_ERROR="다른 배포에 밀렸어요 [server b1]")
eq "superseded is green by default" "$?" "0"
has "superseded notice" "$out" "::notice title=kodeploy::다른 배포에 밀렸어요 [server b1] — fail-on-superseded가 false라 성공으로 끝내요"
lacks "superseded leaves no error annotation" "$out$(cat "$work/deploy-err")" "::error"
has "superseded exit-code output stays 3" "$(cat "$work/deploy-out")" "exit-code=3"
has "superseded result output" "$(cat "$work/deploy-out")" "result=superseded"

out=$(run_deploy FAKE_JSON="$work/superseded.json" FAKE_EXIT=3 FAKE_ERROR="다른 배포에 밀렸어요" KD_FAIL_ON_SUPERSEDED=true)
eq "superseded fails when asked" "$?" "3"
has "superseded error re-emitted" "$out" "::error title=kodeploy::다른 배포에 밀렸어요"

printf '{"result":"failed","exit_code":1,"app_id":"a","requested_sha":null,"builds":[{"build_id":"b1","slot":"server","status":"failed","source_sha":null,"error":"build: exit 1"}]}\n' >"$work/failed.json"
out=$(run_deploy FAKE_JSON="$work/failed.json" FAKE_EXIT=1 FAKE_ERROR="배포 실패 — [server b1] build: exit 1")
eq "failure exit" "$?" "1"
has "failure error re-emitted" "$out" "::error title=kodeploy::배포 실패 — [server b1] build: exit 1"

out=$(run_deploy FAKE_JSON="$work/empty.json" FAKE_EXIT=125)
eq "error without annotation exit" "$?" "125"
has "error without annotation gets one" "$out" "::error title=kodeploy::kodeploy deploy가 exit 125로 끝났어요"

run_deploy FAKE_JSON="$work/nowait.json" KD_WAIT=false KD_TIMEOUT=5m KD_SETTLE=0 >/dev/null
eq "no-wait args" "$(tr '\n' ' ' <"$work/args")" "deploy --output json --timeout 5m --settle 0 --no-wait "

out=$(run_deploy FAKE_JSON="$work/success.json" KD_WAIT=yes)
eq "bad wait exit" "$?" "2"
has "bad wait message" "$out" "wait는 true나 false여야 해요"

# 입력값은 인자 하나로만 넘어가고 셸로 해석되지 않는다
# shellcheck disable=SC2016 # 일부러 펼치지 않은 $(...)를 넘긴다
run_deploy FAKE_JSON="$work/success.json" KD_TIMEOUT='25m $(touch '"$work"'/pwned); touch '"$work"'/pwned2' >/dev/null
if [[ -e $work/pwned || -e $work/pwned2 ]]; then fail "timeout input was executed"; else pass; fi
# shellcheck disable=SC2016
eq "timeout input stays one argument" "$(sed -n 5p "$work/args")" '25m $(touch '"$work"'/pwned); touch '"$work"'/pwned2'

# --- action.yml 규칙 --------------------------------------------------------------
if grep -nE '^\s*run:.*\$\{\{' "$root/action.yml"; then fail "action.yml run: uses an expression"; else pass; fi
default_ver=$(awk '/^  cli-version:/{f=1} f && /default:/{print $2; exit}' "$root/action.yml")
if [[ -f $root/checksums/$default_ver.txt ]]; then pass; else fail "no pinned checksums for default cli-version [$default_ver]"; fi
for os_arch in linux_amd64 linux_arm64 darwin_amd64 darwin_arm64; do
  if kd_expected_sha "$root/checksums/$default_ver.txt" "kodeploy_${default_ver}_${os_arch}.tar.gz" >/dev/null; then pass; else fail "pinned checksums lack $os_arch"; fi
done

printf '%d passed, %d failed\n' "$passes" "$failures"
[[ $failures -eq 0 ]]
