# LLM 호출 도달 가능성 증명 재현

`llm-call-basis.json` 의 라우트 증명(진입점 → 호출 경로 → 분기)을 사람이 다시 확인하는 방법이다. 이미지 digest가 바뀌면 이 절차로 새 이미지의 소스를 다시 검토하고 표를 갱신해야 한다. 그때까지 `mafest_fault.py` 는 시작하지 않는다.

1. digest에 대응하는 앱 커밋의 소스를 읽기 전용으로 꺼낸다(작업 폴더를 바꾸지 않는다).
   `git -C <mafest 저장소> archive <커밋> pyproject.toml Ontology src sql scripts tests data | tar -x -C <빈 폴더>`
   (데이터 포함 추출본이 필요한 이유: 검색 테스트의 라우터가 데이터 없이는 outcome=error 로 끝난다. 상세 조회 테스트는 데이터 없이도 돈다.)
2. `llm_spy.py` 는 pytest 플러그인이다. 테스트 중 `mafest/llm/` 아래 함수가 실행되는 것을 기록하고, 그중 LLM 호출 지점
   (`llm/client.py` 전체, `llm/expanded.py` 전체, `generate`, `_answer_from_evidence_outcome`, `answer_from_evidence_outcome`,
   `complete_text`, `feature_caller`)이 실행되면 별도로 표시한다.
3. 실행 예(추출 폴더 `$T` 에서):
   ```
   LLM_SPY_OUT=/tmp/spy.json MAFEST_REPO_ROOT=$T PYTHONPATH=$T/src:$T/scripts/dev:<llm_spy.py 폴더> \
     python3 -m pytest -q -p no:cacheprovider -p llm_spy tests/unit/serving/test_v1_detail.py \
     --deselect tests/unit/serving/test_v1_detail.py::test_first_search_row_id_opens_the_detail
   ```
   `sink_functions_executed` 가 비어 있어야 한다(상세 조회). 양성 대조로 같은 방법을
   `tests/unit/serving/test_v1_search.py::test_log_line_has_only_fixed_fields_and_no_question` 에 돌리면 `expand_answer`·`complete_text` 가 잡혀야 한다.
4. 동적 관찰은 실행된 분기만 보여 주므로, 표의 `call_chain`·`branches` 와 같은 소스를 직접 읽은 결과를 함께 검토한다.

한계: 이 도구는 테스트가 실행한 분기만 관찰한다. 증명은 소스 읽기(호출 경로)와 이 관찰을 합친 것이며 이미지 digest ↔ 커밋 대응은 별도로 확인해야 한다(`provenance_verified`).
