# Changelog

이 파일은 emu의 릴리스 히스토리를 기록한다. 형식은 대략
[Keep a Changelog](https://keepachangelog.com/)를 따르고, 버전은
[Semantic Versioning](https://semver.org/)을 따른다.

## [Unreleased]

### Fixed
- hot reload/restart 를 기다리는 동안 flutter 프로세스가 죽으면 상태가 다시 `running` 으로 덮여 `/api/status`·대시보드·에이전트가
  죽은 앱을 실행 중으로 보던 문제. 이제 프로세스가 죽었으면 `failed`/`stopped` 가 그대로 남고, 이미 죽은 앱에 reload 를 보내도
  `running` 이 되지 않는다. 프로세스가 살아 있는데 reload 가 오류로 끝나면 `running` 은 유지하되 `lastReloadAt` 은 갱신하지 않는다.

## [0.17.2] - 2026-10-27

### Fixed
- 대시보드 페이지에서 버튼(행 버튼·툴바·체크)을 누를 때마다 블록이 두세 번 깜빡이던 문제. 실행이 시작·끝날 때 모든 목록을
  다시 그리고, 끝나면 모든 블록을 흐리게 한 채 다시 받고, 명령이 감시 파일을 썼으면 0.5초쯤 뒤 한 번 더 그랬다. 이제 실행
  중 표시는 행 버튼·체크박스만 그 자리에서 바꾸고, 다시 받는 동안 블록을 흐리게 하지 않으며, 결과가 같으면 다시 그리지 않는다.

### Changed
- 대시보드 페이지로 돌아오면 블록이 지난번 내용을 바로 보이고 뒤에서 다시 받는다(전에는 다시 받는 동안 흐렸다). 흐리게
  보이는 것은 처음 받을 때와 고른 행·세그먼트가 바뀌었을 때뿐이다 — 고른 행의 다른 값만 바뀌었으면 흐리지 않는다. 토글 상태가
  그대로면 페이지 바를 다시 그리지 않는다.

## [0.17.1] - 2026-10-27

### Changed
- 대시보드 Logs 툴바를 좁은 폭에서도 한 줄에 들어가게 정리. 레벨 필터는 버튼 줄 대신 드롭다운(현재 값 표시),
  `autoscroll`·`bulk`·`fold`·`expand all`/`collapse all`·`clear`·`copy` 는 `⋯` 더보기 메뉴로(허브 행 메뉴와 같은
  모양 — 체크 항목은 ✓ 로 토글, `expand all` 은 fold 일 때만·검색 중 비활성, 방향키·Home/End 로 이동, Esc·Tab·
  바깥 클릭으로 닫힘, 화면 밖으로 안 나가게 배치). 검색창·regex 는 툴바에 그대로 두고 검색창이 남는 폭을 차지한다.
  저장 규칙(`bulk`·`fold` 만 브라우저에 기억)과 카운트는 그대로.

## [0.17.0] - 2026-10-27

### Added
- 대시보드 Logs 탭 `fold` — 시간(보이는 초)·레벨·소스가 같은 연속된 줄을 첫 줄 + `▸ N lines` 로 접는다. 눌러
  묶음 하나를, `expand all`/`collapse all` 로 전부(그 뒤 생기는 묶음도) 펴고 접는다. 직전 묶음을 잇는 새 줄은
  그 묶음에 더해지고(펴진 상태 유지), 검색 중엔 접힌 줄도 맞으면 보인다. 기본 끔, 브라우저에 기억.
- 허브의 업데이트 버튼. 새 릴리스가 있으면 버전 창의 **Update** 가 `emu update --yes` 와 같은 절차(새 버전 받기 →
  emu 다시 빌드 → macOS 앱 갱신)를 허브 프로세스에서 돌리고, 단계마다 진행 상황과 실패 이유를 보인 뒤 새
  바이너리로 같은 포트에 허브를 다시 띄운다(새 허브가 안 뜨면 옛 허브가 다시 받는다). 페이지는 스스로 다시 붙고,
  macOS 앱은 다시 빌드됐으면 스스로 다시 열린다. API `POST /api/update`(본문 없음 — 무엇을 돌릴지는 서버가
  정함, 동시에 하나, 거절은 409)·`GET /api/update`, 진행은 stream 의 `{type: "update"}`.
- 허브 버전 창의 "What changed" 를 markdown 으로 렌더링 — 머리글·목록(들여쓴 이어지는 줄)·`code`·굵게·http(s)
  링크만 태그로 바꾸고 나머지는 모두 escape(원격 CHANGELOG 는 믿지 않음). 길면 스크롤.

### Changed
- 대시보드 Logs 탭이 들어온 줄을 프레임마다 한 번에 그린다(`bulk`, 기본 켬·브라우저에 기억). 줄마다 하던
  레이아웃 읽기·스크롤·전체 다시 세기를 묶음당 한 번으로(카운트는 증분), MAX_ROWS 정리도 한 번에 — 화면에
  5,000줄이 있을 때 5,000줄 burst 가 다 그려지기까지 약 22초 → 0.1초. 끄면 전처럼 한 줄씩.
- `emu update` 가 Claude Code 플러그인 설치에서도 동작한다: `claude plugin marketplace update` +
  `claude plugin update` 로 새 버전을 받아 새 캐시 폴더에서 `build.sh` 로 빌드하고, 옛 바이너리를 가리키던 PATH
  심링크를 rename 으로 옮긴다. `claude` CLI 가 없으면 전처럼 `/plugin update emu` + `/emu-setup` 을 안내한다.
  `--json` 은 단계를 stderr 로, 결과에 `install`·`binary`·`linked`·`app` 을 더한다. 두 업데이트가 겹치지 않게
  `~/.emu/update.lock`.
- `build.sh` 는 임시 파일로 컴파일한 뒤 `emu` 로 rename — 실행 중인 emu(허브)의 파일을 덮어쓰지 않는다.
- `emu app install --if-changed` 는 앱이 실행하는 emu 바이너리 경로가 바뀌어도 다시 빌드한다.

### Fixed
- 대시보드가 서버에 다시 붙을 때(연결 끊김 뒤) 서버가 다시 보내는 최근 500줄이 Logs 탭에 한 번 더 쌓이던 것 — 이미 받은
  줄(seq)은 버린다.

## [0.16.0] - 2026-10-27

### Added
- 대시보드 페이지 선택 list 의 PageUp·PageDown(10행)·Home·End. 트리 폴더 ⌥/Alt-클릭은 그 아래 폴더까지 함께 펴고
  접는다. 실행 중인 output 머리에 지난 초. `emu pages` 가 list 의 `tree`·`sort` 를 보여 준다.
- 대시보드 페이지 블록 접기(#57). 블록 이름 앞의 꺾쇠(▾)로 그 블록만 머리만 남기고 접으면 같은 영역의 나머지가
  자리를 나누고, 블록이 모두 접힌 main·bottom 은 머리 높이만 쓴다. output 은 접혀도 머리에 도는 명령과 걸린 시간을
  보인다. 페이지 바의 `unfold all` 은 그 페이지에서 접힌 영역과 블록을 한 번에 편다. 접힌 블록은 펼 때 불러오고
  (선택·체크를 가진 list 는 그대로), 접은 상태는 페이지별로 브라우저에 기억한다.
- 커스텀 화면 인터페이스 3단계 — 실행 중에 묻기 (#49). action 설정 `interactive: true`(툴바·행·form·html 블록
  액션): 명령이 stdout 에 한 줄 `::emu-ask {"id", "kind": "confirm|prompt|choose", title, message?, detail?,
  danger?, button?, fields?, options?, multiple?}` 를 찍으면 emu 가 그 줄을 출력(실시간·최종·로그)에서 빼고
  묻고, 답을 stdin 에 한 줄 `{"id", "value"}` 로 쓴다. 대시보드에서 시작한 실행은 그 탭에만(대시보드 창 규칙:
  텍스트로만, 출처 = 페이지·액션 이름, 한 번에 한 창, danger 면 포커스 Cancel), `emu run` 은 터미널에서 묻는다.
  답할 곳이 없거나(터미널 없음, 탭 닫힘) `askTimeout`(기본 120초) 안에 답이 없으면 `null`. `auto:` 와 함께 쓰면
  설정 오류(스스로 도는 실행엔 답할 사람이 없음).
  잘못된 JSON·모르는 kind·64 KB 넘는 줄은 `null` 로 답하고 출력에 경고. 답은 질문에 맞춰 거르고(bool, 그
  질문의 칸·항목), 질문 글자는 길이를 자른다. 명령에 `EMU_ASK=1`(물을 수 있을 때, 아니면 `0`). 질문이 답을
  기다리는 동안 실행 `timeout:` 은 멈추고, 기다린 시간은 실행 결과의 `waitedMs`. `interactive` 가 없으면 그런
  줄은 그냥 출력이고 stdin 은 지금처럼 닫힌다. API: 실행 요청의 `asker`, `/api/stream?asker=<id>[&only=ask]`,
  `POST /api/pages/<page>/asks/<askId>` `{value}`. 예제 `docs/examples/ask`.

### Changed
- 대시보드 페이지 output 의 실시간 출력 묶음은 최신 64KB 까지 — 0.1초에 그보다 많이 찍으면 끝부분을 온전한 줄부터
  보내고, 건너뛴 글자 수를 그 앞에 한 줄로 적는다(끝난 실행의 출력은 전과 같다). output 블록은 실행 중 새로 온 부분만 덧붙이고, 끝난 실행은
  다시 그리지 않는다.
- 대시보드 페이지 list 에서 행을 고르면(마우스·키) 표를 다시 그리지 않고 강조만 옮긴다(트리에서 옛 선택이 접힌
  폴더 안이면 다시 그림). 트리의 전체 체크는 접힌 폴더의 행까지 체크한다고 설명에 적고, Tab 으로 들어온 목록은
  테두리를 보인다.
- 서버가 `watch:` glob 을 한 번만 컴파일하고, 파일 변경 묶음마다 페이지 설정을 한 번만 읽는다.
- 접힌 영역·블록 안의 커스텀 화면(html 블록)이 보내는 요청은 화면에 없는 것으로 답한다(`emu:ready` 로 데이터는
  그대로 받는다).

### Fixed
- 대시보드 페이지 `auto:` 스위치를 끄면 기다리던 실행의 타이머만 취소되고 대기 상태가 남아, 다시 켠 뒤 다음
  자동 실행의 로그에 끄기 전에 바뀐 경로가 섞이던 문제 — 끌 때 대기 상태와 바뀐 경로를 함께 비운다.
- 실행 중 바뀐 파일로 한 번 더 도는 `auto:` 실행의 로그가 `(auto:  changed)` 로 비던 문제 — 실행 중 바뀐 경로도
  적는다.
- 합친 확인 창(`emu.run(id, {confirm})`)에서 emu.yaml 쪽 문구를 통째로 아래쪽 action 섹션에 둔다 — 화면 쪽
  `detail` 이 emu.yaml 쪽 내용을 덮어쓸 수 없다.
- `emu.refresh` 의 1초 반복 막기 기록을 페이지 전환·다시 그리기 때 정리한다(사라진 블록·다른 페이지 키가 남던 것).

## [0.15.0] - 2026-10-26

### Added
- 대시보드 페이지 블록 `panel` — 입력 칸 없는 form(버튼 패널). 툴바에 두기 싫은 버튼(배포 등)을 영역 안에 묶는다.
  `form` 도 `fields` 를 빼거나 `[]` 로 둘 수 있고, 그때 버튼의 `{{input.*}}` 는 설정 오류. form·panel 의 `note:` 는
  제목 아래 설명 한 줄. `emu pages` 는 입력 칸 없는 form 을 `panel` 로, note 를 함께 보여 준다 (#48).
- 대시보드 pages 의 `confirm:` 이 문자열·맵을 받는다(#46) — `title`·`message`(자리표시자, 텍스트로만)·`danger`
  (Run 강조, 포커스는 Cancel)·`button`·`preview`(확인 창 전에 돌리는 명령: diff·표·텍스트로 보이고, 실패하면
  Run 을 막음, `allowOnPreviewError` 로 해제). 실행할 명령은 늘 접힌 채 보인다. 서버 428 응답에 `confirm`·
  `preview` 가 붙고, `emu run` 은 터미널에서 같은 내용을 찍고 y/N 을 묻는다(`--yes` 는 그대로 건너뜀).
- 커스텀 화면(`html` 블록)용 대시보드 인터페이스 1단계 (#49). 대시보드가 frame 에 `window.emu` 도우미를 넣는다:
  `emu.onData`·`emu.run(id, {input})`(결과 `{ok, exitCode, error, output, data}` 를 돌려받음)·`emu.confirm`·
  `emu.prompt`·`emu.toast`. 확인·입력 창은 대시보드가 frame 바깥에 출처(블록 제목·`src`)와 함께 텍스트로만
  그리고, 한 번에 한 창·보이는 페이지의 frame 만 받으며, 연달아 취소하면 「이 화면의 요청 막기」를 제안한다.
  `confirm: true` 액션은 frame 이 실행해도 대시보드 자체 확인 창을 거친다. 기존 `emu:ready`·`emu:action` 은 그대로.
- `html` 블록 설정의 `inputs: [...]` 와 블록 자신의 액션(`actions:` 의 `- action: {…}`; 문자열은 지금처럼 툴바 id).
  `POST /api/pages/<page>/frames/<block>/<action>`, `emu run <page>.<block>.<action> --input k=v`. input 은
  `inputs:` 에 적은 이름만 받는다. 실행 응답에 stdout 이 JSON 이면 `data` 를 더한다. 예제 `docs/examples/html-block`.
- 커스텀 화면 인터페이스 2단계 (#49). `emu.choose({title, options, multiple})` — 대시보드가 그리는 선택 창(confirm·
  prompt 와 같은 규칙: 출처, 텍스트로만, 한 번에 한 창, 연속 취소 시 막기), 값 또는 `null`. `emu.select(key)` —
  페이지 선택 행을 바꿈(없는 행이면 `{ok: false}`). `emu.refresh(blockId?)` — 자기 블록이나 같은 페이지 블록의
  데이터를 다시 받음(받는 중·1초 안이면 거절).
- 확인 창 합치기 (#49). `emu.run(id, {input, confirm: {title, message, detail}})` 이면 화면의 설명과 `confirm:` 의
  문구·preview·실제 명령을 창 하나에 보여 주고 Run 한 번으로 실행. `emu.confirm` 직후(1초 안) 같은 화면이
  `confirm:` 액션을 실행하면 OK 를 누른 창이 그 자리에서 명령 확인으로 이어진다. 합칠 수 없으면 두 번 묻는다.
  frame 이 `confirmed` 를 보내는 길은 여전히 없다. 예제에 선택 list·Roll back·reload 를 더했다.
- 대시보드 페이지 list 의 여러 행 체크(#47) — `check: true` 로 체크박스 열·전체 선택·개수. 버튼 명령에서
  `{{checked.<col>...}}`(체크한 행마다 인자 하나), `{{checked.<col>}}`(쉼표로 이은 인자 하나),
  `{{checked.count}}`, list 가 여럿이면 `{{<list>.checked.…}}`. `confirm:` 의 title·message·preview 에도
  쓸 수 있다(텍스트에서는 펼치지 않음). `needs: checked` 는 0개일 때 버튼 비활성.
  `check: {column, toggle}` 로 도구가 체크 상태를 가질 수 있고, `rowActions[].bulk: true` 는 체크한 행마다
  차례로 돌리는 버튼을 목록 머리에 둔다. `emu run … --checked a,b,c`.
- `emu report <bug|feature|question> "<제목>"` — emu 에 대한 버그·기능 요청·질문을 GitHub 이슈로(#50). 보낼 이슈 전체(제목·
  라벨·본문·환경 정보)를 보여 주고 y 로 확인한 뒤에만 보낸다(`--yes`, `--dry-run` → `--send <id>`). 첨부는
  `--attach logs[:N]|errors|shot|<파일>` 로 고른 것만. 경로·프로젝트/앱 이름·토큰은 미리 보기 전에 가린다. `gh` 가
  로그인돼 있으면 `gh issue create`, 아니면 미리 채운 GitHub 작성 화면. 스크린샷은 이슈를 만든 뒤 코멘트에
  붙여 넣게(클립보드 복사). `emu report --mine` — 내가 보낸 리포트와 상태.
- 대시보드 **⚑ Report** 버튼·허브 서랍의 Report — 같은 기능의 모달(미리 본 그대로만 보냄, `My reports` 탭).
  `/api/report/*`.
- `emu:report` 스킬 — Claude Code 에서 대화로 리포트.
- 대시보드 페이지 list 의 긴 칸 말줄임과 행 버튼 열 고정(#59). text 칸은 너비(기본 32em, `name:text:40em`)를 넘으면
  `…` 로 줄이고 마우스를 올리면 전체를 보인다. `:start` 는 앞을 줄여 경로의 끝이 보이게 한다(`path:text:start`).
  행 버튼 열은 표가 가로로 넘쳐도 오른쪽에 붙어 있다.
- 대시보드 페이지 list 의 정렬과 키보드 이동(#62). 칸 머리를 누르면 오름차순 → 내림차순 → 명령이 낸 순서(숫자는
  숫자로, `1.2.10` 같은 버전은 자연 정렬). `sort: <col>[:asc|desc]` 로 처음 순서를 정하고, 누른 정렬은 브라우저별로
  기억한다. 선택을 만드는 list 에서 ↑·↓ 로 행을 고르면 따라오는 블록은 키를 멈춘 뒤 한 번만 불러오고, `/` 는 필터로 간다.
- 대시보드 페이지 list 의 트리 보기(#56). `tree: path` / `tree: [env, path]` / `tree: {columns, open}` — 열 값들을
  `/` 로 나눈 경로의 마지막 조각을 행, 앞을 폴더로 그린다. 폴더는 행 수를 보이고 누르면 접고 펴며(처음엔 `open`
  단계까지 펼침, 누른 상태는 브라우저별로 기억), 체크박스로 아래 행을 한 번에 체크한다. 필터 중에는 맞는 행과 그 위
  폴더를 펼친다. 트리 머리는 이름 정렬. `emu block` 은 경로 열을 앞에 둔 평평한 표.
- 대시보드 페이지 diff 블록의 세그먼트 맵(#58): `segments: {values, optional, hide}`. `optional: true` 면 처음엔 아무것도
  고르지 않고 고른 버튼을 다시 누르면 꺼진다(`{{seg}}` 빈 값, `emu block` 에서 `--seg` 를 빼면 같다). `hide:
  "{{selected.env}}"` 는 고른 행 값과 같은 세그먼트를 숨긴다. 출력에 hunk 가 없으면 「no differences」 대신 줄 번호
  붙은 텍스트로 보인다. 목록 형식 `segments: [a, b]` 는 그대로.
- 대시보드 패널 접기(#57). 기기 화면 패널은 머리의 ›(또는 `s` 키)로 오른쪽 끝의 좁은 띠로 접고, 띠를 눌러 편다 —
  접힌 동안 스크린샷을 받지 않고(auto 도 멈춤) 펼 때 새로 받는다. 페이지 영역(left·main·bottom)은 첫 블록 머리의
  꺾쇠로 블록 제목이 적힌 띠로 접고(left 는 세로, main·bottom 은 가로, 둘 다 접으면 오른쪽 열이 세로 띠), 띠를 누르면
  그 자리에서 펼친다. 접힌 영역의 블록은 펼 때 불러오고(선택·체크를 가진 list 는 그대로), 상태는 브라우저에 기억한다.
  마지막 남은 영역은 접을 수 없다.
- 대시보드 페이지 output 블록(#61): 실행 중 출력이 실시간으로 쌓인다 — 서버가 stdout·stderr 를 100ms 단위로 묶어
  `{type: 'ext', event: 'output', page, item, chunk}` 로 보내고, 끝나면 지금처럼 전체 결과로 바꾼다. output 과 Logs 의
  `http(s)://` 주소는 새 탭 링크. output 머리 메뉴로 최근 10개 실행(이 탭에만)을 다시 보고, 새 실행이 시작되면 그
  실행으로 돌아온다.
- 대시보드 페이지 툴바 액션의 `auto: {watch, debounce, on}`(#60) — 감시하는 프로젝트 파일이 바뀌면 debounce 뒤 서버가
  액션을 실행한다(`then:` 포함, 대시보드를 닫아도). 버튼 옆 ⚡ 로 켜고 끄며 스위치는 `.emu/pages_auto.json` 에 프로젝트별로
  기억(`POST /api/pages/<page>/auto/<item>`, `ext-auto` 알림). 실행 중 바뀐 파일은 끝난 뒤 한 번만 더 돌리고 그 한 번 더의
  변경은 세지 않는다(파일 수정 시각으로 판단) — 감시하는 파일을 쓰는 도구도 반복하지 않는다. 자리표시자·`confirm`·
  `needs`·`openUrl` 액션과 툴바 밖 액션에 주면 설정 오류. 실패하면 토스트, Logs 에 `(auto: … changed)`.

## [0.14.0] - 2026-10-23

### Added
- `emu ls [--json]` — 이 PC 에서 떠 있는 모든 emu 세션(프로젝트·포트·기기·앱 상태·가동 시간). 서버가
  `~/.emu/sessions/<id>.json` 에 자신을 기록하고(토큰 없음) 종료 시 지운다. 죽은 서버의 기록은 다음 조회 때 정리.
- `emu down --project <경로|이름|id>` / `--all` — 다른 프로젝트의 세션, 또는 모든 세션 종료.
- `emu hub [--no-open] [--stop]` — 이 PC 의 모든 세션을 한 페이지에서(`http://127.0.0.1:4576`). 왼쪽 서랍에 세션
  목록(상태·기기·가동 시간, ⋮ 메뉴: 새 창·경로 복사·Finder·reload/restart·종료), 최근 프로젝트 다시 시작, 기기
  점유, 하단 버전·새 릴리스 안내. 본문은 고른 세션의 대시보드(최근 3개는 띄워 둔 채). 허브는 세션 서버를 바꾸지
  않고, `emu up` 은 허브가 떠 있으면 링크만 안내한다.
- `emu app install|uninstall|open|status` — macOS 앱(`~/Applications/emu.app`, 이 PC 에서 swiftc 로 빌드). 허브 전용 창
  (⌥⌘E, 세션별 새 창), 메뉴바 세션 목록(수·실패 표시, 최근 프로젝트 시작, 모두 종료), 백그라운드 알림(실패·중단·
  기동 완료, 누르면 그 세션). 앱이 띄운 허브만 종료 시 끄고 세션은 건드리지 않는다. `emu update` 가 소스가 바뀌면
  다시 빌드.
- 세션 허브 설계 문서 `docs/HUB.md`.

### Changed
- 세션 대시보드의 `frame-ancestors` — 떠 있는 `emu hub` 의 origin 만 허용(허브가 없으면 지금처럼 `'none'`).
- `emu up` 의 기본 대시보드 포트 — 이 프로젝트가 지난번 쓴 포트(`~/.emu/projects.json`), 없으면 4577 부터 첫 빈
  포트. 같은 프로젝트는 같은 주소라 브라우저에 기억한 대시보드 배치가 유지된다. `mocks:` 가 있으면 목 서버
  포트(+13, +14)도 비어 있는 포트를 고른다(전에는 세션끼리 목 서버 포트가 겹칠 수 있었다).
- `emu devices` 의 점유 표시에 프로젝트 이름을 같이 보인다.

## [0.13.0] - 2026-10-23

### Added
- API 목업 — `emu.yaml` `mocks:` 로 앱의 API 요청에 미리 정한 응답(상태·헤더·본문·지연)을 돌려주고, 나머지는
  실서버로 그대로 보낸다. 앱 연결은 두 방식: `packages/emu_hook`(앱에 한 줄, `EMU_MOCK` dart-define 이 있을 때만
  켜지고 그 외 빌드에서는 빠짐 — 지정 호스트만 emu 로 평문 연결하므로 인증서 불필요) 또는 base URL dart-define
  (`upstream` + `define`, 앱 변경 없음). `emu up` 이 목 서버·dart-define·`adb reverse` 를 준비한다.
  `emu mock [use <scenario>|off|log]`, 서버 API `GET/POST /api/mock`, `GET /api/mock/log`,
  `GET /api/mock/hits/<id>`, `PUT/DELETE /api/mock/scenarios/<name>`.
- `emu mock set <METHOD|*> <path|url> [--status] [--body|--body-file] [--header] [--delay] [--save <scenario>]`,
  `emu mock unset`, `emu mock reset` — 요청 하나의 응답을 CLI 로 즉시 지정(시나리오보다 우선, 메모리에만).
  케이스별 자동 검증용. `emu mock log --bodies` 로 요청·응답 본문까지. 서버 API `POST/DELETE /api/mock/overrides`.
- 대시보드 **Mocks** 탭(Debug) — 시나리오 전환, 규칙 편집(match·status·delay·headers·body, `mocks/<name>.json`
  에 저장, emu.yaml 시나리오는 읽기 전용), 실시간 트래픽과 요청·응답 본문, 실제 응답을 규칙으로 만드는
  "mock this response".

## [0.12.0] - 2026-10-20

### Added
- 대시보드에서 `emu.yaml` 로 정의한 페이지 탭에 `yaml` 배지 — 어디서 온 탭인지 툴팁 없이 보인다.
- 대시보드 페이지 패널 크기 조정 — 왼쪽 영역의 오른쪽 경계, 아래 영역의 위쪽 경계를 끌어 크기를 바꾼다.
  크기는 페이지마다 브라우저에 기억되고(본문 대비 비율이라 창 크기가 바뀌어도 유지), 경계를 더블클릭하면
  기본 크기로 돌아간다.
- 대시보드 screen 패널 폭 조정 — 왼쪽 경계를 끌어 넓히고(모든 페이지 공통, 브라우저에 기억), 더블클릭하면
  기본 폭.
- 대시보드 페이지 — `emu.yaml` 의 `pages:` 로 프로젝트 도구(로컬 템플릿 전환, 검증, 배포 등)를 대시보드
  탭으로 붙인다. 페이지는 툴바(`action` 버튼·`toggle` 스위치)와 블록(`output`: 마지막 실행 결과)으로
  이뤄지고, emu 는 설정에 적힌 명령만 실행한다(요청은 항목 id만 보낸다). 명령은 argv 배열(직접 실행) 또는
  문자열(`sh -c`)이고, 프로젝트 루트에서 `EMU_PROJECT`·`EMU_PORT`·`EMU_DEVICE`·`EMU_PLATFORM`·`EMU_APP_ID`
  와 함께 실행되며 `timeout`(기본 60초)이 지나면 끊긴다. `then: reload|restart`, `confirm: true`(명령을
  보여 주고 묻기), 같은 항목 동시 실행 방지. 토글 상태는 `state` 명령이 출력한 `{"on": bool, "detail"?}`.
  앱 제어와 기기 화면은 모든 페이지에 그대로 있다. 실행은 열린 대시보드 모두와 Logs 탭(`[ext]`)에 남는다.
  `emu.yaml` 은 요청마다 다시 읽고, 파일이 바뀌면 대시보드가 새로 고친다. 서버 API `GET /api/pages`,
  `GET /api/pages/<page>/state/<item>`, `POST /api/pages/<page>/run/<item>` (#24).
- `emu pages`, `emu run <page>.<item> [on|off] [--yes]` — 같은 항목을 CLI로. 종료코드 0 = 명령과 `then:`
  이 성공, 명령이 실패하면 그 명령의 종료코드. on/off 없이 토글을 주면 현재 상태를 보여 준다.
  `emu pages` 는 세션이 없어도 `emu.yaml` 을 직접 읽어 보여 준다 (#24).
- 대시보드 페이지 블록 `list`·`diff` — `list` 는 명령이 출력한 JSON 배열을 표로(열 형식 `text`·`chip`·
  `count`, 필터, 행마다 `rowActions` 버튼), `diff` 는 명령이 출력한 unified diff를 Changes 탭처럼
  보여 준다(`segments` 로 비교 기준 전환). 페이지의 첫 list 에서 고른 행이 `{{selected.<col>}}`, 행 버튼의
  행이 `{{row.<col>}}`, 세그먼트가 `{{seg}}` 를 채운다. 치환은 argv 배열 명령에서만 되고 값은 인자 하나로만
  들어간다(셸 문자열 명령의 치환, 프로그램 자리(첫 요소)의 치환은 설정 오류). `watch:` 글롭에 맞는 파일이 바뀌면 블록을 다시 불러온다
  (git 이 무시하는 폴더 포함). 고른 행·세그먼트는 브라우저에 기억. 서버 API
  `GET /api/pages/<page>/blocks/<block>`, `POST /api/pages/<page>/rows/<list>/<action>` (#24).
- `emu block <page>.<block> [--select <col>=<value>]... [--seg <name>]` — list·diff 블록 내용을 CLI로.
  `emu run` 도 `--select` 로 툴바 항목의 `{{selected.<col>}}` 을 채운다 (#24).
- 대시보드 페이지 블록 `html` — 프로젝트 HTML 파일(`src:`)을 sandbox iframe(`allow-scripts` 만, opaque
  origin)에 `srcdoc` 으로 띄우고 `default-src 'none'` CSP 를 넣어 네트워크·대시보드·세션 토큰에 닿지 못하게
  한다. 데이터는 `run:` 출력(JSON 은 값, 아니면 텍스트)을 `postMessage`(`emu:data`)로 받고, `actions:` 에
  적은 툴바 액션만 `emu:action` 으로 요청할 수 있다(버튼과 같은 확인). 파일이 프로젝트 밖으로 이어지는
  링크면 거부, 파일을 저장하면 frame 을 다시 띄운다. 서버 API `GET /api/pages/<page>/frames/<block>`.
  list 의 chip 색은 흔한 상태 단어를 따르고 그 밖의 값은 중립색 (#24).
- 대시보드 페이지 블록 `form` — 입력 칸(`fields`)과 그 값을 `{{input.<field>}}` 로 읽는 버튼(`actions`).
  입력값은 브라우저에 기억하고, Enter 는 첫 버튼. 액션은 `run:` 대신 `openUrl:` 로 기기에 딥링크를 열 수
  있다 — 대시보드 딥링크 입력·`emu open-url` 과 같은 경로(argv, 기기 셸 인용, settle)를 쓰고 끝나면 화면을
  새로 고친다. 서버 API `POST /api/pages/<page>/forms/<form>/<action>` (#24).
- `emu run <page>.<block>.<action> [--row <col>=<value>]... [--input <field>=<value>]...` — list 행 버튼과
  form 버튼을 CLI로. `emu pages` 에 form 칸·버튼 표시 (#24).

### Changed
- 대시보드 레이아웃: Logs 툴바와 페이지 툴바가 screen 패널 위를 가로지르지 않고 왼쪽 본문 열에만 놓인다.
  screen 은 어느 페이지에도 속하지 않으므로 상단 바 바로 아래부터 바닥까지 이어진다.

### Fixed
- Changes 탭·`emu diff` 가 마지막 git 인덱스 갱신 직후에 한 같은 크기의 수정을 놓칠 수 있던 문제(Linux) —
  스냅샷용 임시 인덱스를 복사할 때 수정 시각이 새로 찍혀 git 의 racy-clean 재확인이 꺼졌다. 이제 원본 시각을 유지한다.
- 대시보드가 열린 채 `emu down` 하면 서버가 꺼지지 않던 문제 — 종료 중 대시보드 WebSocket을
  닫다가 예외가 나 `exit` 에 이르지 못했고, 서버(포트)와 `flutter run` 이 그대로 남았다. 이제
  소켓을 모두 닫고(응답 없는 소켓은 2초까지 기다림) 종료한다.
- 페이지 명령이 `timeout` 에 걸리면 직접 띄운 프로세스만 끊겨, `sh -c 'a | b'` 나 빌드를 띄우는
  스크립트의 자손 프로세스는 계속 돌던 문제 — 이제 자손까지 모두 끊는다.

### Security
- 서버 API를 이 세션의 대시보드와 CLI로 제한 — 지금까지는 API가 인증 없이
  `Access-Control-Allow-Origin: *` 로 열려 있어, 브라우저에 열린 아무 웹 페이지나 `127.0.0.1:4577` 로
  reload·tap·`shutdown` 등을 보내고 응답을 읽을 수 있었다. 이제 서버가 시작할 때마다 세션 토큰을 만들어
  `.emu/server.json`(CLI)과 대시보드 페이지에 넣고, `/api/` 요청은 토큰(`X-Emu-Token` 헤더,
  WebSocket·이미지는 `token` 쿼리)이 있어야 처리한다. 생존 확인용 `GET /api/status` 만 예외 — 토큰이 없으면 서버가 떠 있다는 것만 답하고, VM Service 주소
  (그 인증 코드로 앱 안에서 코드를 실행할 수 있다) 등 상태 전체는 토큰이 있어야 준다. `Host` 가
  `127.0.0.1`/`localhost` 가 아니거나(DNS rebinding) 브라우저 `Origin` 이 대시보드 자신이 아니면 거부하고,
  CORS 헤더를 없앴다. 대시보드 페이지는 캐시하지 않고 다른 사이트의 frame 안에 뜨지 않는다. 서버가 다시
  뜨면(새 토큰) 열려 있던 대시보드는 스스로 새로 고친다. 대시보드 페이지는 `Referrer-Policy: no-referrer`
  로 내려가 링크를 따라가도 토큰이 담긴 주소가 새지 않는다 (#24).

## [0.11.0] - 2026-10-19

### Added
- 대시보드 **Changes 탭**과 `emu diff` — 코드 변경을 네 범위로 본다: 커밋 안 한 변경(`head`),
  기준 브랜치 이후(`base`, 기본 develop/development/main/master, upstream 우선), 마지막 reload가
  반영한 변경(`reload`), 아직 reload 안 된 변경(`pending`). 서버가 기동·hot reload/restart 때마다
  임시 인덱스로 작업 트리(새 파일 포함)를 스냅샷해 두므로 reload 범위가 가능하고, 실제
  인덱스·파일·stash는 건드리지 않는다. 생성·vendor·lock 파일은 기본 숨김. reload 후 대시보드가
  저절로 갱신된다. 서버가 프로젝트를 감시해(build·.dart_tool·.git 등 제외, 0.4초 디바운스) 파일을
  저장만 해도 실시간으로 반영된다. 서버 API `GET /api/diff/files`, `GET /api/diff/file` (#22).

## [0.10.0] - 2026-10-16

### Added
- 대시보드 딥링크 입력 — screen 패널 하단에 URL을 넣고 `open`(또는 Enter)하면 `emu open-url` 과
  같은 방식(argv 배열, Android는 기기 셸용 인용)으로 기기에 보내고, settle 후 화면을 새로 고친다.
  최근 10개는 브라우저별로 기억해 자동완성으로 제공. 서버 API `POST /api/open-url?url=` (#20).
- 대시보드가 앱이 `running` 이 되면 첫 스크린샷을 자동으로 불러온다(↻ 를 누르지 않아도 됨) (#20).
- 대시보드 screen 패널 로딩 표시 — 앱 기동 중·첫 화면을 불러오는 동안 emu 아이콘이 눈을 깜빡이는
  Lottie 애니메이션(`web/loading.json`, 재생기 `web/vendor/lottie_light.min.js` 동봉)을 보여준다 (#20).

### Fixed
- 대시보드 첫 진입 시 screen 패널에 깨진 이미지 아이콘과 "device screen" 대체 텍스트가 보이던
  문제 — `#shot-img { display: block }` 이 `hidden` 속성을 덮어쓰고 있었다 (#20).

### Changed
- README 로고를 대시보드 로딩 애니메이션과 같은 눈 깜빡임 GIF(`docs/assets/emu_icon.gif`)로 교체 (#20).

## [0.9.0] - 2026-10-02

### Added
- 세션 재연결 — adb 서버 재시작 등으로 `flutter run` 이 `Lost connection to device` 로 끝나도
  앱이 기기에 살아 있으면 서버가 `flutter attach` 로 자동으로 다시 붙는다(1분에 한 번). 수동
  재시도 `emu attach`. 설계: `docs/ATTACH.md` (#13).
- `emu.yaml`(최상위·profile) `reversePorts`/`forwardPorts` 와 `emu up --reverse-port`/`--forward-port`
  — Android 기기가 정해지면 `flutter run` 전에 `adb reverse`/`forward` 를 건다. 15초마다 확인해
  adb 재시작·재부팅으로 풀린 연결을 다시 걸고, `emu status` 에 상태를 보여주며 `emu down` 이
  해제한다. iOS는 무시 (#13).
- `emu.yaml` `onDeviceReady`/`onAppStarted` hook — `sh -c` 로 실행, `EMU_DEVICE`/`EMU_PLATFORM`/
  `EMU_PROJECT`/`EMU_APP_ID`(빌드 산출물에서 읽은 applicationId·bundle id) 제공. 실패는 verdict의
  error로 보고 (#13).
- `tap --text`/`find --text` 가 정확히 일치하는 위젯이 없으면 공백을 정규화한 부분 일치로 다시
  찾고 결과를 partial 로 표시. `Text.rich` 도 매칭 (#13).
- `emu up --boot-avd <AVD>` — 그 AVD를 부팅(이미 실행 중이면 그대로)하고 한 번에 점유.
  손으로 부팅한 뒤 `up -d` 하는 사이에 다른 세션이 기기를 가져가던 문제의 해법 (#13).
- `emu down --keep-device` — `--temp-device` 기기를 지우지 않고 일반 AVD/시뮬레이터로 남김 (#13).

### Fixed
- 부팅 중인 에뮬레이터를 다른 세션의 `up --android` 가 먼저 잡던 경합 — 새 기기가 보이는
  즉시(부팅 완료 전) 점유하고, 그 전(serial이 생기기 전)에는 AVD 이름으로 예약해 둔다.
  `--temp-device` 기기도 해당 (#13).
- 수동 파싱하던 하위 명령(`shot`, `status`, `down`, `reload` 등)이 모르는 옵션을 무시해
  `emu shot --port 4591` 이 `4591` 파일로 저장되던 문제 — 이제 usage와 함께 종료 코드 2.
  `--help` 도 모두 지원 (#13).

## [0.8.0] - 2026-09-23

### Added
- `emu up --temp-device`(`--android`/`--ios` 와 함께) — 세션 전용 임시 AVD/시뮬레이터
  (`emu_tmp_<프로젝트>_<id>`)를 만들어 쓰고, `emu down`(또는 실패한 `up`)이 끄고 삭제한다.
  `~/.emu/temp-devices/` 에 기록해, `down` 없이 서버가 죽어 남은 기기는 다음
  `up --temp-device`/`down` 이 정리한다. 에이전트가 기기 부족 시 `avdmanager`/`simctl`
  로 직접 만들고 방치하던 기기(기기당 2–3GB)를 대체.

### Fixed
- Android 부팅이 PATH의 레거시 `<sdk>/tools/emulator` 를 쓰면 최신(arm64) 이미지를 못 띄우고
  타임아웃까지 대기하던 문제 — `<sdk>/emulator/emulator` 를 우선 사용.
- 다른 세션이 동시에 부팅한 에뮬레이터를 자기 것으로 잡을 수 있던 문제 — 새로 뜬 시리얼의
  AVD 이름까지 확인.

## [0.7.0] - 2026-09-22

### Added
- 디바이스 임대(device lease) — 한 기기는 한 시점에 한 emu 세션만 구동한다.
  프로젝트·worktree가 달라도 `~/.emu/devices/<device-id>.json` 으로 서로를
  본다. `up --android`/`--ios` 는 점유된 기기를 건너뛰고 다른 AVD/시뮬레이터를
  부팅, `up --device` 로 점유된 기기를 지정하면 점유자를 알려주며 즉시 실패.
  죽은 서버의 임대는 자동 회수. 설계: `docs/DEVICE_LEASE.md`.
- `emu up --share-device` — 점유 검사를 건너뛰고 의도적으로 기기를 공유.
- `emu devices` 가 점유 정보를 표시(`--json` 은 기기별 `lease`).

### Changed
- `emu down --kill-device` 가 모든 시뮬레이터/에뮬레이터(`simctl shutdown all`,
  `adb emu kill`) 대신 **이 세션의 기기만** 끈다. 다른 emu 세션이 점유 중이면
  끄지 않는다.

### Fixed
- 기동 전 기기 오류(기기 없음, 부팅 실패 등)에서 앱 상태가 `stopped` 에 머물러
  `up` 이 타임아웃(기본 240초)까지 기다리던 문제 — 이제 즉시 `failed` verdict.

## [0.6.0] - 2026-09-08

### Added
- `emu.yaml`/`emu.local.yaml`에 `profiles:` — 이름 붙은 설정 프리셋을
  `.vscode/launch.json` 없이도 정의(`emu up --profile <name>`,
  `emu config --profile <name>`으로 미리보기, `emu configs`에 목록 추가).
  같은 이름의 profile이 양쪽 파일에 있으면 `emu.local.yaml`이 필드 단위로
  이긴다. `--config`(launch.json)와는 상호 배타.

## [0.5.0] - 2026-09-08

### Added
- `emu find --text <label> | --key <key> | --type <Widget> [--index <n>] [--dump]`
  — `tap --text/--key`가 쓰는 온디바이스 위젯 조회를 탭 없이 노출. `--type`은
  위젯 런타임 타입명 매칭, `--dump`는 각 위젯의 `toString()`도 출력. 매칭
  0개는 에러가 아니라 `(no match)`.
- `emu eval '<dart-expr>'` — 브레이크포인트 없이 앱의 isolate root library
  스코프에서 표현식을 즉시 평가. 그 줄이 실행돼야 값을 주는 `probe`/`inspect`와
  달리 "지금 상태"를 바로 조회한다.
- `emu errors [--since <seq>]` — 로그에 이미 잡히는 Flutter 예외 콘솔 배너
  (`═══╡ ... ╞═══`)를 배너 단위로 묶어 라이브러리/예외 타입/seq 범위로
  구조화. Android는 로그가 logcat 태그를 달고 오므로 그걸 벗기고 매칭한다.
- `emu memory --diff-across "<shell command>" [--all]` — 주어진 커맨드
  실행 전후 힙 인스턴스 수 diff(VM Service `getAllocationProfile(gc:true)`).
  기본은 앱 자신의 패키지 클래스만, `--all`로 프레임워크 클래스까지 포함.

### Fixed
- `up`/`assert`/`probe`/`inspect`/`logs`/`swipe`/`settle`/`tap`이 `--help`나
  잘못된 플래그를 주면 `FormatException` 스택트레이스로 죽던 문제 수정.
  공유 헬퍼(`_parseOrUsage`)로 통일하고 모든 서브커맨드가 `-h`/`--help`를
  지원하도록 함(`find`/`eval`/`errors`/`memory` 포함).
- `emu open-url`이 Android에서 파라미터를 조용히 잃던 문제 수정: `adb shell`은
  argv 경계를 보존하지 않고 인자를 이어붙여 기기의 `/bin/sh`에 다시 넘기므로,
  URL에 `&`가 있으면 거기서 잘렸다. URL을 기기 셸용으로 인용해서 보낸다
  (이슈 리포터 [@Heewookji](https://github.com/Heewookji) 기여, #6).

## [0.4.0] - 2026-09-08

GitHub Issue #2(첫 실사용 후기)에서 나온 제안 중 문서 동기화 1건, 기능 2건,
버그 1건을 하위 워크트리 4개로 나눠 병렬 처리 후 병합.

### Added
- `emu open-url <url> [--no-settle]` — 연결된 기기로 딥링크 전송
  (Android는 `adb shell am start`, iOS는 `xcrun simctl openurl`). 인자를
  항상 argv 배열로 넘겨 쉘 이스케이프/인젝션 문제를 원천 차단. `tap`/`shot`과
  동일하게 기본적으로 전환 settle을 기다린다.
- `emu tap --text <label> | --key <key> [--index <n>]` — 픽셀 좌표 대신
  위젯의 Semantics/Text/Tooltip 라벨이나 `ValueKey`로 탭. VM Service로
  온디바이스 Element 트리를 직접 순회해 좌표를 구한다(적합한 inspector
  서비스 확장이 없어 채택한 접근). 여러 개 매칭 시 `--index`로 선택.

### Fixed
- `emu up`이 서버는 살아있지만 앱 상태가 `stopped`/`failed`인 "유령 세션"을
  만나면 자동으로 정리하고 재기동한다. 실제로 `running`/`starting`/
  `restarting`인 세션은 기존처럼 거부하되, 메시지에 현재 상태를 노출한다.

### Docs
- `skills/emu/SKILL.md`를 `emu` 실제 CLI 명령 전체와 동기화
  (`probe --capture`/`--count`, `shot`/`tap`/`open-url`의 `--no-settle`,
  `logs`의 `--clear`/`--follow`/`--lines`, `assert`의 `--expect`/`--deny`/
  `--since`, `settle`, `stop`, `--version`/`update`/`uninstall` 등 이전에
  누락되어 있던 항목 전부 반영).

## [0.3.0] - 2026-08-11

### Added
- `emu --version` / `-v` — 설치된 버전 + GitHub 최신 태그 대비 업데이트
  가능 여부 표시.
- `emu doctor`에 버전/업데이트 상태 확인 추가.
- `emu update [-y]` — git 체크아웃 기반 설치에서 최신 릴리스로 pull + 재빌드
  (dirty tree 가드, `--json` 지원).
- `emu uninstall [-y]` — 실행 중인 바이너리를 가리키는 PATH 심링크 제거.
- CI: GitHub Actions에 `dart analyze` + `dart test` + 웹 자산 번들 drift
  회귀 검사 추가.

### Fixed
- `tool/bundle_web.dart`가 파일을 정렬 없이 나열해 macOS/Linux 간 생성
  결과가 달라지던 문제 수정(결정적 출력).

## [0.2.0] - 2026-07-20

### Added
- `--dart-define-from-file <path>` 지원(`emu up`, `.vscode/launch.json`
  재현 양쪽 모두).
- `tap`/`shot` 이후 애니메이션/리빌드 settle 대기가 기본 동작으로 전환
  (이전엔 `--settle` 옵션으로 켜야 했음).

## [0.1.0] - 2026-07-20

최초 릴리스. 핵심 루프(기동 → 관찰 → 조작 → 검증 → 종료)와 그 위에 쌓인
초기 기능들을 포함한다.

### Added
- `emu up` / `down` / `stop` / `status` — 세션 생명주기. `up`은 기기 부팅 +
  앱 실행 + `running`/`failed`와 첫 프레임까지 대기.
- `emu reload` / `restart` / `cold` — hot reload/restart/cold restart,
  직후 로그의 에러를 같은 응답에 묶어 반환. reload 후 출력이 멎으면 restart
  힌트 제안.
- `emu logs` / `assert` — 검색 가능한 로그 스트림 + e2e/CI 오라클(로그 단언).
- `emu probe <file:line> --capture <expr>` / `emu inspect <file:line>` —
  VM Service 로그포인트로 변수값 캡처, 또는 그 줄에서 지역변수 전체 +
  콜스택을 덤프.
- `emu shot` / `emu tap` / `emu swipe` / `emu text` — 스크린샷 기반 앱 구동.
  입력 백엔드를 VM Service 합성 포인터로 통일해 Android/iOS 양쪽에서
  동작(유니코드 텍스트 입력 포함).
- `emu configs` / `emu up --config` — `.vscode/launch.json`의 실행 구성
  재현(debug 구성만 실행 가능).
- `emu.yaml`/`emu.local.yaml` 프로젝트별 계층 설정 + `.emu/memory.json`
  학습 메모리.
- `emu devices` — 연결된 기기 + Android AVD 목록.
- 웹 대시보드 — 인터랙티브 스크린샷, DevTools 링크.
- Claude Code 플러그인 패키징(`skills/emu/SKILL.md`, `commands/emu-setup.md`)
  — 셀프 마켓플레이스로 배포.

[Unreleased]: https://github.com/HuanSuh/emu/compare/v0.17.2...HEAD
[0.17.2]: https://github.com/HuanSuh/emu/compare/v0.17.1...v0.17.2
[0.17.1]: https://github.com/HuanSuh/emu/compare/v0.17.0...v0.17.1
[0.17.0]: https://github.com/HuanSuh/emu/compare/v0.16.0...v0.17.0
[0.16.0]: https://github.com/HuanSuh/emu/compare/v0.15.0...v0.16.0
[0.15.0]: https://github.com/HuanSuh/emu/compare/v0.14.0...v0.15.0
[0.14.0]: https://github.com/HuanSuh/emu/compare/v0.13.0...v0.14.0
[0.13.0]: https://github.com/HuanSuh/emu/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/HuanSuh/emu/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/HuanSuh/emu/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/HuanSuh/emu/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/HuanSuh/emu/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/HuanSuh/emu/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/HuanSuh/emu/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/HuanSuh/emu/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/HuanSuh/emu/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/HuanSuh/emu/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/HuanSuh/emu/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/HuanSuh/emu/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/HuanSuh/emu/releases/tag/v0.1.0
