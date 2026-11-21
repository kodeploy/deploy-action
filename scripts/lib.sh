# shellcheck shell=bash
# KoDeploy deploy action의 함수 모음. scripts/install.sh, scripts/deploy.sh, test/run.sh가 source한다.
# bash 3.2(macOS 기본)에서도 돌게 쓴다 — 연관 배열, ${var,,}, process substitution 없이.

KD_RELEASE_BASE="https://github.com/kodeploy/kodeploy/releases/download"

# 워크플로 명령 값 이스케이프 (%, \r, \n)
kd_escape() {
  # 치환 값을 변수로 둔다 — 따옴표를 ${//} 안에 쓰면 bash 버전마다 다르게 풀린다
  local s=$1 pct='%' pct_enc='%25' cr=$'\r' cr_enc='%0D' nl=$'\n' nl_enc='%0A'
  s=${s//$pct/$pct_enc}
  s=${s//$cr/$cr_enc}
  s=${s//$nl/$nl_enc}
  printf '%s' "$s"
}

kd_error() { printf '::error title=kodeploy::%s\n' "$(kd_escape "$1")"; }
kd_warning() { printf '::warning title=kodeploy::%s\n' "$(kd_escape "$1")"; }
kd_notice() { printf '::notice title=kodeploy::%s\n' "$(kd_escape "$1")"; }

# kd_platform <runner.os> <runner.arch> → "linux amd64" 같은 두 단어. 받지 않는 러너면 1.
kd_platform() {
  local os arch
  case "$1" in
    Linux) os=linux ;;
    macOS) os=darwin ;;
    *) return 1 ;;
  esac
  case "$2" in
    X64) arch=amd64 ;;
    ARM64) arch=arm64 ;;
    *) return 1 ;;
  esac
  printf '%s %s\n' "$os" "$arch"
}

# kd_version <입력> → 0.1.0 형식. v0.1.0, cli-v0.1.0도 받는다. 그 밖이면 1.
kd_version() {
  local v=${1#cli-}
  v=${v#v}
  [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  printf '%s\n' "$v"
}

kd_asset() { printf 'kodeploy_%s_%s_%s.tar.gz\n' "$1" "$2" "$3"; }

# kd_expected_sha <checksums 파일> <자산 이름> → sha256. 그 자산의 줄이 없거나 값이 sha256 형식이 아니면 1.
kd_expected_sha() {
  local sum name
  while read -r sum name || [[ -n $sum ]]; do
    name=${name#\*}
    if [[ $name == "$2" ]]; then
      [[ $sum =~ ^[0-9a-f]{64}$ ]] || return 1
      printf '%s\n' "$sum"
      return 0
    fi
  done <"$1"
  return 1
}

kd_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# kd_verify <파일> <기대 sha256> — 같으면 0
kd_verify() {
  local got
  got=$(kd_sha256 "$1") || return 1
  [[ -n $2 && $got == "$2" ]]
}

# kd_install <버전> <os> <arch> <릴리스 주소> <고정 체크섬 폴더> <설치 폴더>
# 받은 tar.gz를 체크섬으로 확인한 뒤에만 푼다. 체크섬은 고정 폴더의 <버전>.txt가 있으면 그것, 없으면 릴리스의 checksums.txt(경고).
kd_install() {
  local ver=$1 os=$2 arch=$3 base=$4 pinned=$5 dest=$6
  local asset url tmp sums expected
  asset=$(kd_asset "$ver" "$os" "$arch")
  url="$base/cli-v$ver"
  tmp=$(mktemp -d)
  if ! curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/$asset" "$url/$asset"; then
    kd_error "kodeploy CLI를 받지 못했어요: $url/$asset"
    rm -rf "$tmp"
    return 1
  fi
  if [[ -f "$pinned/$ver.txt" ]]; then
    sums="$pinned/$ver.txt"
  else
    if ! curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/checksums.txt" "$url/checksums.txt"; then
      kd_error "체크섬 목록을 받지 못했어요: $url/checksums.txt"
      rm -rf "$tmp"
      return 1
    fi
    sums="$tmp/checksums.txt"
    kd_warning "cli-version $ver는 이 액션에 체크섬이 고정돼 있지 않아 릴리스의 checksums.txt로 확인했어요. 릴리스 파일이 바뀌면 같이 바뀌니, 고정된 기본 버전을 쓰는 것이 안전해요"
  fi
  if ! expected=$(kd_expected_sha "$sums" "$asset"); then
    kd_error "체크섬 목록에 $asset 이 없어요"
    rm -rf "$tmp"
    return 1
  fi
  if ! kd_verify "$tmp/$asset" "$expected"; then
    kd_error "kodeploy CLI 체크섬이 맞지 않아요: $asset (기대 $expected, 받은 파일 $(kd_sha256 "$tmp/$asset"))"
    rm -rf "$tmp"
    return 1
  fi
  mkdir -p "$dest"
  if ! tar -xzf "$tmp/$asset" -C "$dest" kodeploy; then
    kd_error "kodeploy CLI 압축을 풀지 못했어요: $asset"
    rm -rf "$tmp"
    return 1
  fi
  chmod +x "$dest/kodeploy"
  rm -rf "$tmp"
}

# kd_hold_annotations <파일> — CLI stderr를 그대로 흘리되 ::error 줄만 파일에 모아 둔다.
# 실패로 끝낼지는 exit code를 본 뒤 정한다 (다른 배포에 밀림을 성공으로 끝낼 때 빨간 주석이 남지 않게).
kd_hold_annotations() {
  local line
  while IFS= read -r line || [[ -n $line ]]; do
    case $line in
      '::error '* | '::error::'*) printf '%s\n' "$line" >>"$1" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done
}

# kd_final_code <CLI exit code> <fail-on-superseded> → 이 액션의 exit code
kd_final_code() {
  if [[ $1 == 3 && $2 != true ]]; then
    echo 0
  else
    echo "$1"
  fi
}

# kd_outputs <CLI json 결과 파일> <CLI exit code> — $GITHUB_OUTPUT에 쓸 name=value 줄만 쓴다 (경고 같은 다른 줄은 쓰지 않는다)
# source-sha: 워크플로 커밋(requested_sha)으로 빌드된 빌드가 있으면 그 값, 없으면 처음 나오는 source_sha, 아직 없으면 빈 값.
# jq가 없거나 결과가 json이 아니면 exit-code만 채운다.
kd_outputs() {
  local file=$1 code=$2 result="" ids="" sha=""
  if command -v jq >/dev/null 2>&1 && [[ -s $file ]] && jq -e 'type == "object"' "$file" >/dev/null 2>&1; then
    result=$(jq -r '.result // ""' "$file")
    ids=$(jq -r '[.builds[]?.build_id] | join(",")' "$file")
    sha=$(jq -r '.requested_sha as $r | [.builds[]?.source_sha | select(. != null)] as $s
      | if ($r != null and any($s[]; . == $r)) then $r else ($s[0] // "") end' "$file")
  fi
  # 한 줄 값만 (줄바꿈이 섞이면 다음 출력으로 읽힌다)
  [[ $result =~ ^[a-z]*$ ]] || result=""
  [[ $ids =~ ^[A-Za-z0-9,_-]*$ ]] || ids=""
  [[ $sha =~ ^[0-9a-f]*$ ]] || sha=""
  printf 'result=%s\nexit-code=%s\nbuild-ids=%s\nsource-sha=%s\n' "$result" "$code" "$ids" "$sha"
}
