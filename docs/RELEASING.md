# 브랜치와 릴리스 절차

## 브랜치
- `develop` — 작업이 모이는 브랜치. 기능·수정 PR은 모두 `develop` 을 대상으로 연다.
  머지되면 작업 브랜치는 workflow(`delete-merged-branch.yml`)가 지운다. 그 브랜치를 base로 하는
  열린 PR(쌓인 PR)이 있으면 남겨 둔다. force push·삭제 금지(관리자는 예외).
- `main` — 배포본. 플러그인 마켓플레이스가 읽는 브랜치라 **`develop` 에서 오는 release PR로만**
  바뀐다. force push·삭제 금지, PR 필수(관리자는 예외).

## 릴리스
1. `develop` 에서 버전업 커밋을 만든다(PR 또는 직접 push).
   - `pubspec.yaml` 의 `version`
   - `.claude-plugin/plugin.json` 의 `version`
   - `CHANGELOG.md`: `[Unreleased]` 아래 내용을 `## [X.Y.Z] - YYYY-MM-DD` 로 확정하고,
     하단 비교 링크(`[Unreleased]`, `[X.Y.Z]`)를 갱신
2. `develop` → `main` PR을 연다. 제목은 정확히 `release: vX.Y.Z`.
3. 검사(`.github/workflows/release.yml` 의 `release-gate`)가 확인하는 것:
   - 출발 브랜치가 `develop` 인지
   - 제목 버전 = `pubspec.yaml` = `plugin.json` = CHANGELOG 절 제목
   - `vX.Y.Z` 태그가 아직 없는지
   CI(`test`)와 함께 통과해야 머지할 수 있다.
4. 머지하면 workflow가 머지 커밋에 `vX.Y.Z` 태그를 달고, CHANGELOG의 해당 절을 본문으로
   GitHub Release를 만든다. `main` 에 커밋은 하지 않는다.
5. 로컬 적용: `/plugin update emu` 후 `/emu-setup` (또는 `claude plugin update emu@emu` 후
   플러그인 캐시에서 `./build.sh` 와 PATH 심링크 갱신).

`emu version`/`emu update` 의 최신 버전 확인은 GitHub 태그를 본다.
