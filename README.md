# sapari-cicd-template

FE/BE 공용 **GitLab CI/CD Components**. 앱 레포는 로직 없이 `include`만 한다.
**스캔은 GitLab 내장 보안 템플릿**으로, 내장이 없는 빌드/서명(SBOM 포함)/검증/배포트리거만 컴포넌트로 둔다.
배포는 CI가 안 함 — `bump`가 `sapari-helm-manifest`의 이미지를 **digest로 갱신**하면 ArgoCD가 배포.

## 동작 원리 (중요)

`include: component`는 별도 파이프라인이 아니라 **앱 레포 파이프라인에 병합(inline)** 된다.
→ 컴포넌트 잡도 **앱 레포 컨텍스트**에서 실행되므로:
- `$CI_COMMIT_SHORT_SHA`, `$CI_REGISTRY_IMAGE`, `$CI_PROJECT_NAME` 등 predefined 변수 **그대로 사용**(재전달 불필요).
- 잡 간 런타임 값(예: 이미지 digest)은 **dotenv(`artifacts:reports:dotenv`) + `needs`** 로 공유.
- `$[[ inputs.x ]]`는 파이프라인 **생성 시** 치환되는 설정값(런타임 변수와 다른 계층).

## 컴포넌트 (커스텀 — 내장 없음)

| 컴포넌트 | 역할 | 비고 |
|---|---|---|
| `validate-node` | yarn install + lint + tsc | Node/Yarn Berry |
| `audit-yarn` | `yarn npm audit` 의존성 취약점 게이트(severity 기준 실패) | gemnasium 의 Yarn Berry 미지원 대체 |
| `build` | BuildKit 빌드 + push(`:sha`,`:main`) + **digest(dotenv)** | dind 필요 |
| `sign` | cosign keyless 서명 + 이미지 SBOM(trivy·CycloneDX) attest | digest 기준 |
| `bump` | `sapari-helm-manifest` 이미지를 **`@sha256:digest`** 로 write-back | needs build,sign |
| `verify` | manifest 의 digest 가 **공식 파이프라인 서명** 이미지인지 cosign 검증 | ★ GitOps repo 에서 include |
| `digest-diff` | Dockerfile 베이스 digest 변경 MR 에 old↔new **CVE diff** 산출(trivy) | 정보성(allow_failure) — Renovate MR 사유 구체화 |
| `promote` | verify 통과 커밋만 **release 브랜치로 ff-push** (ArgoCD 는 release 를 sync) | ★ GitOps repo 에서 include — verify 를 차단형으로 |

스캔은 **GitLab 내장**을 앱 레포에서 직접 include:
`Security/Secret-Detection` · `Security/Container-Scanning`.
SBOM 은 `sign` 이 푸시된 이미지(digest)를 trivy 로 분석해 직접 생성·attest 한다
(런타임 내용물 기준 — 소스 의존성 SBOM 이 따로 필요하면 앱 repo 에서 `trivy fs` 권장).

> 레거시(선택): `build-buildx` + `scan`(커스텀 Trivy) + `publish-docker` 는 **publish 전 하드 게이트**가
> 필요할 때 쓰는 대안 경로. 내장 스캐너는 Free 티어에서 리포트만(파이프라인 강제 실패는 Ultimate
> Scan Result Policy 필요)이라, 하드 게이트가 꼭 필요하면 이 경로를 쓴다.

## 파이프라인 흐름 (권장 = 내장 스캐너)

```
validate(+audit) → build(push+digest) → test(내장: container/secret scan) → sign(digest 서명+SBOM attest) → bump(GitOps digest)
                                                            └ main 에서만: build/container-scan/sign/bump ┘
bump 커밋(main) → (GitOps repo 파이프라인) verify: 서명 검증 → promote: release 로 ff-push
                → ArgoCD 가 release 를 sync 해 배포 (verify 실패 커밋은 release 에 못 들어감)
```

## 사용 예 (앱 레포 .gitlab-ci.yml)

```yaml
stages: [validate, build, test, sign, bump]
include:
  - component: $CI_SERVER_FQDN/sagopanda/sapari-cicd-template/validate-node@main
  - component: $CI_SERVER_FQDN/sagopanda/sapari-cicd-template/build@main
  - component: $CI_SERVER_FQDN/sagopanda/sapari-cicd-template/sign@main
  - component: $CI_SERVER_FQDN/sagopanda/sapari-cicd-template/bump@main
    inputs: { manifest_file: components/frontend/deployment.yaml, container_name: web }
  - component: $CI_SERVER_FQDN/sagopanda/sapari-cicd-template/audit-yarn@main
  - component: $CI_SERVER_FQDN/sagopanda/sapari-cicd-template/digest-diff@main   # digest 변경 MR 에 CVE diff
  - template: Security/Secret-Detection.gitlab-ci.yml
  # Dependency-Scanning(gemnasium) 은 Yarn Berry yarn.lock v9 미지원(FATAL) → audit-yarn 으로 대체
  - template: Security/Container-Scanning.gitlab-ci.yml
variables:
  CS_IMAGE: $CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA
  CS_REGISTRY_USER: $CI_REGISTRY_USER
  CS_REGISTRY_PASSWORD: $CI_REGISTRY_PASSWORD

# container_scanning 은 build 가 push 한 뒤(main)에만 — 이 override 없으면
# MR 파이프라인에서 존재하지 않는 이미지를 스캔하려다 실패한다.
container_scanning:
  needs: [{job: build}]
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
```

## 사용 예 (GitOps repo = sapari-helm-manifest .gitlab-ci.yml)

`verify` 만은 앱 레포가 아니라 **GitOps repo** 에서 include — `manifest_glob` 의 모든 자사 이미지에
대해 "소유 프로젝트의 main 공식 파이프라인 서명"인지 검증하고, 아니면 파이프라인 실패.
**신원은 컨벤션으로 자동 유도** (이미지 `registry.gitlab.com/sagopanda/<repo>` ↔ 서명자
`gitlab.com/sagopanda/<repo>//.gitlab-ci.yml@refs/heads/main`) → **BE 등 새 앱 추가 시 include 수정 불필요.**

```yaml
include:
  - component: $CI_SERVER_FQDN/sagopanda/sapari-cicd-template/verify@main
    # 기본값으로 충분: manifest_glob="components/*/*.yaml components/*/*/*.yaml"(전체 커버),
    # registry_namespace=sagopanda. 경로 구조가 다르면 manifest_glob / image_expr override
  - component: $CI_SERVER_FQDN/sagopanda/sapari-cicd-template/promote@main
    # 파이프라인(verify 포함) 통과 커밋만 release 로 ff-push. PROMOTE_TOKEN 필요(env scope `release`)
```

새 앱 repo 추가 시 1회 설정: 앱 repo **Settings → CI/CD → Job token permissions** 에 GitOps repo 허용
— verify 잡이 GitOps repo 의 `CI_JOB_TOKEN` 으로 **앱 repo 소유** registry 의 서명을 읽는
inbound allowlist 구조(자원 주인이 허용을 선언, 토큰 전달 아님).
한계: 같은 repo CI 라 main push 권한자는 우회 가능 → **main 브랜치 보호 필수**, 클러스터 측
admission 검증(Kyverno `verifyImages`)과 묶어야 완성.

## 필요한 CI/CD 변수 (사용하는 앱 레포)

| 변수 | 용도 |
|---|---|
| `MANIFEST_WRITE_TOKEN` | `bump`가 `sapari-helm-manifest`에 push (Project/Group Access Token, `write_repository`). **Masked + Protected + environment scope `gitops`** — bump 잡만 `environment: gitops` 라서 토큰이 다른 잡(yarn install 등 의존성 코드 실행 지점)에 노출되지 않음 |
| 레지스트리 push | `$CI_JOB_TOKEN` 자동(같은 그룹 registry) |

## BE 추가 시
`validate-gradle` · `build-jib` · `publish-crane`(Jib/crane은 데몬리스 → dind 불필요)만 추가하면
sign/bump/verify 는 그대로 공용 (verify 는 GitOps repo 쪽도 수정 불필요 — 자동 발견).

## 릴리스 (Catalog 핀 버전)
```bash
git tag 1.0.0 && git push origin 1.0.0   # .gitlab-ci.yml 의 release 잡이 카탈로그 게시 → include @1.0.0
```
