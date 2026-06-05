# sapari-cicd-template

FE/BE 공용 **GitLab CI/CD Components**. 앱 레포는 로직 없이 `include`만 한다.
**스캔·SBOM은 GitLab 내장 보안 템플릿**으로, 내장이 없는 빌드/서명/배포트리거만 컴포넌트로 둔다.
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
| `build` | BuildKit 빌드 + push(`:sha`,`:main`) + **digest(dotenv)** | dind 필요 |
| `sign` | cosign keyless 서명 + 내장 SBOM attest | digest 기준 |
| `bump` | `sapari-helm-manifest` 이미지를 **`@sha256:digest`** 로 write-back | needs build,sign |

스캔/SBOM은 **GitLab 내장**을 앱 레포에서 직접 include:
`Security/Secret-Detection` · `Security/Dependency-Scanning`(SBOM) · `Security/Container-Scanning`.

> 레거시(선택): `build-buildx` + `scan`(커스텀 Trivy) + `publish-docker` 는 **publish 전 하드 게이트**가
> 필요할 때 쓰는 대안 경로. 내장 스캐너는 Free 티어에서 리포트만(파이프라인 강제 실패는 Ultimate
> Scan Result Policy 필요)이라, 하드 게이트가 꼭 필요하면 이 경로를 쓴다.

## 파이프라인 흐름 (권장 = 내장 스캐너)

```
validate → build(push+digest) → test(내장: container/dependency/secret scan) → sign(digest+SBOM) → bump(GitOps digest)
                                                                     └ main 에서만: build/container-scan/sign/bump ┘
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
  - template: Security/Secret-Detection.gitlab-ci.yml
  - template: Security/Dependency-Scanning.gitlab-ci.yml
  - template: Security/Container-Scanning.gitlab-ci.yml
variables:
  CS_IMAGE: $CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA
  CS_REGISTRY_USER: $CI_REGISTRY_USER
  CS_REGISTRY_PASSWORD: $CI_REGISTRY_PASSWORD
```

## 필요한 CI/CD 변수 (사용하는 앱 레포)

| 변수 | 용도 |
|---|---|
| `MANIFEST_WRITE_TOKEN` | `bump`가 `sapari-helm-manifest`에 push (Project/Group Access Token, `write_repository`, Masked) |
| 레지스트리 push | `$CI_JOB_TOKEN` 자동(같은 그룹 registry) |

## BE 추가 시
`validate-gradle` · `build-jib` · `publish-crane`(Jib/crane은 데몬리스 → dind 불필요)만 추가하면
scan/sign/bump 는 그대로 공용.

## 릴리스 (Catalog 핀 버전)
```bash
git tag 1.0.0 && git push origin 1.0.0   # .gitlab-ci.yml 의 release 잡이 카탈로그 게시 → include @1.0.0
```
