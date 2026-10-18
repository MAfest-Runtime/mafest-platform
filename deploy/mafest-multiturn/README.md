# mafest 멀티턴 배포 초안

`drafts/` 는 `.draft`·`.tmpl` 확장자라 어떤 kustomize 렌더에도 들어가지 않는 비활성 선언 초안이다(마이그레이션 Job, NetworkPolicy,
세션 정리 CronJob 등). 실제로 적용되는 선언은 `kustomize/` 아래에 있다.

배포 준비 런북, 검증기, 장애 시험·측정 도구는 persona-ops-lab 의 `repos/persona-platform/` 에 있다.
