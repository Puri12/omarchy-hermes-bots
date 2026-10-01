# puri.hermes — Hermes Bots for Omarchy

Omarchy(Hyprland/Quickshell) 바 위젯에서 원격 [Hermes Agent](https://github.com/NousResearch/hermes-agent) 봇을 만들고 관리하고 대화하는 플러그인.

- `Panel.qml` — 바 아이콘과 패널 UI (Quickshell, `qs.Ui` 컴포넌트)
- `hermes-remote.ts` — Bun 헬퍼. 패널과 NDJSON(stdin/stdout)으로 통신하고, `hermes serve`의 REST와 `/api/ws` JSON-RPC에 붙음 (아래 "헬퍼 데몬")
- `novnc/` — 봇 화면 보기용 noVNC 1.7.0 (MPL-2.0, `novnc/LICENSE.txt`)

## 기능

- 봇 목록·생성·삭제(2단계 확인)·모델 변경, 봇 설명/SOUL 편집·복제·고정·숨김
- 봇 목록 상태 표시: `?` 답을 기다림 · `…` 작업 중 · `⏱` 예약 작업 실행 중 · `•` 보지 않는 동안 새 답장·알림 (선택하면 지워짐, IPC `unread`)
- 대화 검색: History 옆 **Search**로 현재 대화에서 글자가 들어간 줄만 표시(일치 수 표시, Esc로 닫기, IPC `search <text>`)
- 답장 인용: 말풍선을 오른쪽 클릭하면 입력창 위에 `↩ replying to`가 뜨고, 보낼 때 `> ` 인용으로 앞에 붙음(× 로 취소, IPC `quote <index>`)
- 단축키(패널에 포커스가 있을 때): `Ctrl+N` 새 대화 · `Ctrl+K` History · `Ctrl+F` 검색 · `Ctrl+↑` 마지막으로 보낸 메시지 불러오기(입력창이 비어 있을 때) · `Alt+1`…`Alt+9` 봇 목록의 N번째 봇 선택 · `Shift+Enter` 줄바꿈
- 서버 공지 배너: 크레딧 경고·소진·복구, 에이전트 시작 지연, 속도 제한·모델 대체 경고를 헤더 아래 색 배너로 표시(× 로 닫기, 시간제 공지는 자동으로 사라짐, IPC `notices`)
- 위임 진행 표시: 봇이 하위 작업(delegate_task)을 맡기면 대화에 `🔀 delegated / completed` 줄, 상태줄에 진행 중인 위임 수와 마지막 도구를 표시(부모 답이 끝난 뒤에도 유지, IPC `subagents`)
- 음성: 봇 말풍선의 🔊 로 서버 TTS(`/api/audio/speak`) 음성을 `pw-play`로 재생(다시 누르면 중지). 입력줄 **Mic**로 노트북 마이크를 `pw-record`로 녹음해 서버 STT(`/api/audio/transcribe`)로 받아쓴 글을 입력창에 넣음 — 서버에 STT 엔진(예: faster-whisper)이 있어야 하며, 없으면 서버 오류를 그대로 표시
- 봇 템플릿: Edit 섹션의 **Export**로 역할(설명·SOUL)·모델·직접 만든 스킬·루틴을 `~/Downloads/hermes-bot-<봇>.json`에 저장, **Import**(파일 경로 + 새 봇 이름)로 그대로 새 봇 생성. 대화·기억·자격 증명은 포함하지 않음
- 시연으로 스킬 만들기: Screen 줄의 **● Record demo**를 누르면 봇 화면을 넘겨받고 화면 페이지가 열림. 화면에서 직접 한 번 해 보인 뒤 **■ Stop & teach**를 누르면 그동안의 입력(클릭·더블클릭·드래그·스크롤·입력한 글자·단축키)이 단계 목록으로 봇에게 전달되고, 봇이 SKILL.md 초안을 답함. 초안 카드의 **Save skill**로 그 봇의 스킬로 저장(서버가 거절하면 이유를 카드에 표시). 입력은 헬퍼가 화면으로 중계하는 RFB 메시지에서 읽으므로 화면 페이지에서 한 조작만 기록됨 (IPC `demoStart demoStop demoState saveSkillDraft`)
- 발송 초안 카드: 봇이 `send_message`로 메시지를 보내려 하면 수신자와 본문을 카드로 보여 주고 **Send**를 눌러야만 발송됨. **Discard**는 폐기, **Edit…**는 폐기한 뒤 고쳐 보낼 지시문을 입력창에 채워 줌(봇이 다시 보내려 하면 새 초안 카드). 이번 한 번만 승인하는 버튼만 두어 이후 발송이 검토 없이 나가지 않음. 서버 쪽에 아래 `outbound-review` Hermes 플러그인이 켜져 있어야 동작함
- 그룹 채팅: **Groups**에서 봇 2~6개를 골라 이름을 넣고 **Create group**. 방을 열면 모두에게, 또는 `@봇`으로 한 봇에게 말을 걸 수 있고 봇들이 Hermes Desktop 그룹 채팅과 같은 서버 방(hosted room)에서 차례로 답함. 패널이 열려 있고 방을 보고 있는 동안만 방 기록을 2.5초마다 받아 옴. 답하는 중이면 **Stop**, **Delete group**(두 번 클릭)으로 방 삭제. 방 안의 명령 승인 요청은 개수만 표시하고 답은 Hermes Desktop에서 함 (IPC `groupsView groups groupCreate <name> <bot,bot> groupOpen <id> groupSend <text> groupDisband <id> room`)
- 스트리밍 답변, 작업 상태줄(thinking/writing/도구·경과 시간), 봇의 할 일 목록, 토큰·컨텍스트 사용량
- 작업 중 추가 지시(Steer/Queue), 중지
- 질문(clarify)·승인 카드, 긴급 알림, 루틴(cron) 완료 알림
- 이미지·파일 보내기/받기(파일 칩), 대화 History(대화마다 이름 바꾸기·보관·삭제, 삭제는 두 번 클릭), 다시 불러온 대화의 cron 지시문·첨부 확장문은 접어서 표시(클릭하면 전체)
- Routines: 목록·생성·즉시 실행·일시정지·삭제·실행 기록
- Screen: 봇 데스크톱 실시간 보기, 넘겨받기/돌려주기
- 스킬 `/`: 입력창이 `/`로 시작하면 봇의 스킬 제안 목록(최대 6개, ↑/↓ 이동, Tab·클릭 완성, Esc 닫기). `/스킬이름 …`은 `command.dispatch`로 실행되고 대화에는 게이트웨이의 표시 문구가 남음. 모르는 `/x`는 그냥 텍스트로 보냄. Edit의 "Save as skill"은 마지막으로 보낸 질문을 SKILL.md로 저장(삭제 API는 없음)
- 연결 끊김 시 Reconnect

## 설치

1. 이 저장소를 `~/.config/omarchy/plugins/puri.hermes`에 둡니다.
2. [Bun](https://bun.sh)을 설치합니다.
3. `~/.config/hermes-remote/credentials.env` (권한 600)를 만듭니다. 값은 저장소에 넣지 마세요.

   ```
   HERMES_REMOTE_URL=http://<hermes-serve-host>:9119
   HERMES_REMOTE_USER=<basic auth user>
   HERMES_REMOTE_PASSWORD=<basic auth password>
   ```

4. 바에 "Hermes Bots" 위젯을 추가하고 `omarchy restart shell`.

## 발송 검토 Hermes 플러그인 (`hermes-plugin/outbound-review`)

Hermes 자체에는 발송 전 검토 단계가 없어서, 초안 카드는 이 서버 플러그인이 `send_message`의 send 호출을 Hermes 승인 절차로 넘길 때만 나타납니다. 플러그인은 수신자와 본문을 승인 요청에 담고, 거절·시간 초과·오류면 발송을 막습니다(fail closed). 검토할 봇마다 Hermes가 도는 서버에서 설치합니다:

1. 플러그인 폴더를 그 봇의 홈에 복사: 기본 봇은 `~/.hermes/plugins/outbound-review`, 다른 봇은 `~/.hermes/profiles/<봇>/plugins/outbound-review`
2. 그 봇의 `config.yaml`(기본 봇은 `~/.hermes/config.yaml`, 다른 봇은 `~/.hermes/profiles/<봇>/config.yaml`)에 추가:

   ```yaml
   plugins:
     enabled: [outbound-review]
   ```

3. `hermes serve`(와 메시지 게이트웨이를 쓰면 그것도)를 재시작

## 헬퍼 데몬

바는 패널을 두 개 띄우지만 백엔드 연결은 하나입니다. 패널마다 `hermes-remote.ts stdio` 클라이언트가 돌고, 이 클라이언트가 백그라운드 데몬 `hermes-remote.ts daemon` 하나에 붙습니다. 데몬이 로그인·WebSocket·루틴(cron) 확인·봇 화면 서버를 모두 맡고, 이벤트는 모든 패널에 똑같이 보냅니다(데스크톱 알림은 한 패널만 띄움).

- 소켓: `$XDG_RUNTIME_DIR/puri-hermes.sock` (없으면 `/tmp/puri-hermes-$UID.sock`, 권한 600)
- PID: `~/.cache/puri.hermes/daemon.pid`, 로그: `~/.cache/puri.hermes/daemon.log`
- 데몬이 없으면 클라이언트가 띄우고, `omarchy restart shell`을 해도 데몬은 그대로 살아 있습니다.
- `hermes-remote.ts`가 바뀌면 다음 클라이언트가 옛 데몬을 끄고 새 데몬을 띄웁니다.
- 패널의 Reconnect(또는 IPC `reconnect`)는 데몬의 로그인과 WebSocket을 새로 맺습니다.
- 멈추기: `kill "$(cat ~/.cache/puri.hermes/daemon.pid)"` (패널이 열려 있으면 몇 초 뒤 다시 뜹니다. 완전히 멈추려면 위젯을 뺀 뒤 실행)

## IPC

`omarchy-shell puri.hermes <함수>` — `open close toggle show <bot> select <bot> send <text> steer <text> queue <text> stop newChat answer <text> create <name> <desc> deleteBot <name> setModel <id> attachFile <path> attachClipboard sessions listed openSession <id> sessionRename <id> <title> sessionArchive <id> sessionDelete <id> routines screenUrl screenTake screenHandback screenState profileGet skills skillSave <name> <SKILL.md> setComposer <text> reconnect state`

- `skills`: 선택된 봇의 스킬 목록(캐시)을 JSON으로 돌려주고 새로 받아옴. 서버가 스캔을 약 30초 캐시하므로 방금 저장한 스킬은 잠시 늦게 보일 수 있음
- `setComposer <text>`: 테스트용. 입력창 텍스트를 바꾸고 지금 보이는 스킬 제안 이름 목록을 JSON으로 돌려줌

## 로드맵

`ROADMAP.md` 참고.
