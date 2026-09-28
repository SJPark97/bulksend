# CLAUDE.md — bulksend

LocalSend 유사 로컬 네트워크 파일 전송 앱 (파일 개수 제한 없음). 안드↔안드, 안드↔아이폰, 아이폰↔아이폰.

## 작업 규칙
- 단계별로 작업하고, 각 단계가 끝날 때마다 커밋한다. (커밋 컨벤션은 전역 CLAUDE.md 따름)
- 설계·태스크 보드는 Notion blog 하위 페이지 "파일 개수 제한 없는 LocalSend 직접 만들기 — BulkSend 설계와 태스크" (id: 3e9dee7cb4ee814987d8c7fe7743f104)에서 관리한다.
- 태스크(BS-N)를 하나씩 순서대로 구현하고, 완료 시 커밋 + Notion 체크박스 체크.
- 이 저장소의 커밋은 **개인 GitHub 계정**(`박승재 <tjwlsdud33@naver.com>`)으로 한다. 저장소 로컬 git 설정(`git config --local`)에 지정돼 있으니 전역 설정(회사 계정)으로 바꾸지 않는다.
