"""pytest 플러그인: mafest/llm 아래 함수가 실제로 실행됐는지 기록한다(호출 경로 증명용 관찰 도구)."""

import json, os, sys, threading
import pytest

SINK_FILES = ("/mafest/llm/client.py", "/mafest/llm/expanded.py")
SINK_FUNCS = {
    "generate",
    "_answer_from_evidence_outcome",
    "answer_from_evidence_outcome",
    "complete_text",
    "feature_caller",
}
executed_llm = {}
sinks_hit = {}


def profiler(frame, event, arg):
    if event != "call":
        return
    code = frame.f_code
    path = code.co_filename
    if "/mafest/llm/" not in path:
        return
    key = f"{path.split('/mafest/')[-1]}::{code.co_name}"
    executed_llm[key] = executed_llm.get(key, 0) + 1
    if path.endswith(SINK_FILES) or code.co_name in SINK_FUNCS:
        sinks_hit[key] = sinks_hit.get(key, 0) + 1


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_call(item):
    sys.setprofile(profiler)
    threading.setprofile(profiler)
    try:
        yield
    finally:
        sys.setprofile(None)
        threading.setprofile(None)


def pytest_sessionfinish(session, exitstatus):
    out = os.environ["LLM_SPY_OUT"]
    json.dump(
        {"llm_functions_executed": executed_llm, "sink_functions_executed": sinks_hit},
        open(out, "w"),
        ensure_ascii=False,
        indent=1,
        sort_keys=True,
    )
