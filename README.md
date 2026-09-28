# puri.hermes — Hermes Bots for Omarchy

Omarchy(Hyprland/Quickshell) 바 위젯에서 원격 [Hermes Agent](https://github.com/NousResearch/hermes-agent) 봇을 만들고 관리하고 대화하는 플러그인.

- `Panel.qml` — 바 아이콘과 패널 UI (Quickshell, `qs.Ui` 컴포넌트)
- `hermes-remote.ts` — Bun 헬퍼. 패널과 NDJSON(stdin/stdout)으로 통신하고, `hermes serve`의 REST와 `/api/ws` JSON-RPC에 붙음
- `novnc/` — 봇 화면 보기용 noVNC 1.7.0 (MPL-2.0, `novnc/LICENSE.txt`)

## 기능

- 봇 목록·생성·삭제(2단계 확인)·모델 변경, 봇 설명/SOUL 편집·복제·고정·숨김
- 스트리밍 답변, 작업 상태줄(thinking/writing/도구·경과 시간), 봇의 할 일 목록, 토큰·컨텍스트 사용량
- 작업 중 추가 지시(Steer/Queue), 중지
- 질문(clarify)·승인 카드, 긴급 알림, 루틴(cron) 완료 알림
- 이미지·파일 보내기/받기(파일 칩), 대화 History
- Routines: 목록·생성·즉시 실행·일시정지·삭제·실행 기록
- Screen: 봇 데스크톱 실시간 보기, 넘겨받기/돌려주기
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

## IPC

`omarchy-shell puri.hermes <함수>` — `open close toggle show <bot> select <bot> send <text> steer <text> queue <text> stop newChat answer <text> create <name> <desc> deleteBot <name> setModel <id> attachFile <path> attachClipboard sessions listed openSession <id> routines screenUrl screenTake screenHandback screenState profileGet reconnect state`

## 로드맵

`ROADMAP.md` 참고.
