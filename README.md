# kodeploy/deploy-action

이 워크플로가 돈 커밋을 KoDeploy 앱에 지금 설정 그대로 다시 배포하는 GitHub Action이다.

GitHub Actions OIDC ID 토큰을 KoDeploy의 짧은 CI 토큰으로 바꿔 쓰기 때문에 저장소에 비밀을 넣지 않는다. 안에서는 [kodeploy CLI](https://github.com/kodeploy/kodeploy/tree/main/cli)를 받아 `kodeploy deploy`를 실행한다.

## 사용 예

```yaml
name: deploy

on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      id-token: write   # GitHub OIDC ID 토큰 (필수)
      contents: read
    concurrency:
      group: deploy-${{ github.ref }}
      cancel-in-progress: false   # 배포 중인 것을 끊지 않고 다음 것을 기다리게 한다
    steps:
      - uses: kodeploy/deploy-action@v1
        with:
          app: ${{ vars.KODEPLOY_APP_ID }}
```

체크아웃은 필요 없다. 무엇을 빌드할지는 KoDeploy가 앱의 라이브 설정과 이 워크플로의 커밋(`GITHUB_SHA`)으로 정한다.

## 준비

1. KoDeploy 앱 설정 > GitHub Actions에서 "GitHub Actions 배포 허용"을 켠다. 꺼져 있으면 exit 125다.
2. 저장소 Settings > Secrets and variables > Actions > Variables에 `KODEPLOY_APP_ID`(앱 id)를 넣는다. 앱 id는 비밀이 아니라 variable이면 된다.
3. 배포 잡에 `permissions: id-token: write`를 준다. 없으면 액션이 첫 단계에서 실패한다.
4. 앱은 웹에서 한 번 이상 배포돼 있어야 한다. 첫 배포(설정 정하기)는 웹의 배포 폼으로 한다.

워크플로의 저장소·브랜치가 앱의 배포 저장소·브랜치와 같아야 한다. 다르면 403이다. 그 슬롯은 이 커밋으로, 앱의 다른 슬롯(다른 저장소나 같은 저장소의 다른 브랜치를 쓰는 정적 슬롯 등)은 지금 떠 있는 커밋으로 다시 빌드된다.

## 입력

| 이름 | 기본값 | 설명 |
|---|---|---|
| `app` | (필수) | KoDeploy 앱 id |
| `server` | `https://api.kodeploy.com` | KoDeploy API 주소 |
| `audience` | `kodeploy` | OIDC ID 토큰의 audience |
| `cli-version` | `0.1.0` | kodeploy CLI 버전. 기본값은 체크섬이 이 저장소에 고정돼 있다 |
| `timeout` | `25m` | 요청부터 안정화까지 전체 시간 제한 |
| `settle` | `60s` | 모두 `running`이 된 뒤 더 지켜볼 시간. `0`이면 바로 성공 |
| `wait` | `true` | `false`면 빌드를 요청만 하고 기다리지 않는다 (result `requested`) |
| `fail-on-superseded` | `false` | `true`면 다른 배포에 밀렸을 때(exit 3) 잡을 실패시킨다 |

## 출력

CLI의 `--output json` 결과에서 채운다.

| 이름 | 설명 |
|---|---|
| `result` | `success`, `failed`, `superseded`, `timeout`, `interrupted`, `requested`, `error` |
| `exit-code` | CLI의 exit code. 밀림을 성공으로 끝냈어도 `3`이다 |
| `build-ids` | 이번 요청이 만든 빌드 id, 쉼표로 구분 |
| `source-sha` | 이 워크플로 커밋으로 빌드된 빌드의 `source_sha`. `wait: false`면 비어 있다 |

```yaml
      - id: kd
        uses: kodeploy/deploy-action@v1
        with:
          app: ${{ vars.KODEPLOY_APP_ID }}
      - run: echo "builds $BUILDS"
        env:
          BUILDS: ${{ steps.kd.outputs.build-ids }}
```

## exit code

| 코드 | 뜻 | 액션 |
|---|---|---|
| 0 | 성공 (모든 빌드 `running`, 안정화 통과) | 성공 |
| 1 | 배포 실패 (`failed`, 안정화 중 `failed` 포함) | 실패 |
| 2 | 사용법 오류, 다시 보내도 같은 409(첫 배포 아님 등), 400·422 | 실패 |
| 3 | 다른 배포에 밀림 (실패 없이 `cancelled`) | 기본은 notice를 남기고 성공. `fail-on-superseded: true`면 실패 |
| 4 | 시간 제한(`timeout`) 초과. 빌드는 서버에서 계속 진행된다 | 실패 |
| 125 | 인증, 권한, 연결 오류 (허용 꺼짐, 다른 브랜치 등) | 실패 |
| 130 | 중단 (잡 취소) | 실패 |

실패하면 이유가 `::error` 주석으로, 결과 표가 잡 요약(step summary)으로 남는다.

같은 앱에 배포가 겹치면 먼저 시작한 쪽의 빌드가 취소되고(밀림, exit 3) 나중 것이 이어서 배포한다. 위 예처럼 `concurrency`를 걸면 같은 브랜치의 배포 잡끼리는 차례로 돌아 서로 밀어내지 않는다. 밀림은 웹 배포처럼 다른 곳에서 시작한 배포와 겹칠 때 생긴다.

## 체크섬을 고정해 둔 이유

액션은 실행할 때마다 GitHub 릴리스에서 CLI 바이너리를 받는다. 릴리스에 같이 올라간 `checksums.txt`로만 확인하면, 릴리스 파일을 바꿀 수 있는 사람은 바이너리와 체크섬을 함께 바꿀 수 있다. 그러면 확인은 통과하고, 바뀐 바이너리가 `id-token: write` 권한이 있는 잡 안에서 돈다.

그래서 기본 `cli-version`의 sha256은 이 저장소의 `checksums/<버전>.txt`에 커밋해 두고 그 값과 비교한다. 액션을 태그(`@v1.0.0`)나 커밋 SHA로 고정하면, 실행되는 CLI 바이트도 그 커밋이 정한 값으로 고정된다.

`cli-version`을 고정되지 않은 버전으로 바꾸면 릴리스의 `checksums.txt`로 확인하고 `::warning`을 남긴다. 체크섬이 다르거나 목록에 파일이 없으면 풀기 전에 실패한다.

## 버전

- `@v1`: 1.x의 최신을 따라간다.
- `@v1.0.0`: 그 릴리스에 고정된다. 커밋 SHA로 고정하면 더 엄격하다.

## 지원 러너

GitHub 호스트 러너와 셀프 호스트 러너 중 Linux, macOS의 X64, ARM64. Windows는 지원하지 않는다. `bash`, `curl`, `tar`가 필요하다. `jq`가 없으면 출력 중 `exit-code`만 채운다.

## 개발

```sh
test/run.sh        # 셸 단위 테스트 (플랫폼 매핑, 체크섬 확인, 출력, exit code 정책)
```

CI는 actionlint, shellcheck, 단위 테스트(Linux, macOS), 실제 릴리스 설치 확인을 돈다.
