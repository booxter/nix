import importlib.util
import os
import pathlib
import sys
import tempfile


TOKEN_FILE = tempfile.NamedTemporaryFile(mode="w", delete=False)
TOKEN_FILE.write("test-token")
TOKEN_FILE.close()

os.environ.update(
    {
        "PAPERLESS_API_TOKEN_FILE": TOKEN_FILE.name,
        "PAPERLESS_BASE_URL": "http://paperless.test",
        "PAPERLESS_GPT_AUTO_TAG": "paperless-gpt-auto",
        "PAPERLESS_GPT_AUTO_OCR_TAG": "paperless-gpt-ocr-auto",
        "PAPERLESS_GPT_OCR_COMPLETE_TAG": "paperless-gpt-ocr-complete",
        "PAPERLESS_GPT_AUTO_OCR_WORKFLOW_NAME": "Auto OCR with paperless-gpt",
        "PAPERLESS_GPT_POST_OCR_WORKFLOW_NAME": "Auto classify after paperless-gpt OCR",
    }
)

MODULE_PATH = pathlib.Path(
    os.environ.get(
        "PAPERLESS_GPT_CONFIGURE_MAIN", pathlib.Path(__file__).with_name("main.py")
    )
)
SPEC = importlib.util.spec_from_file_location("paperless_gpt_configure", MODULE_PATH)
paperless_gpt_configure = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = paperless_gpt_configure
SPEC.loader.exec_module(paperless_gpt_configure)
pathlib.Path(TOKEN_FILE.name).unlink()


def test_desired_workflows_sequence_ocr_before_metadata():
    tags = {
        "paperless-gpt-auto": {"id": 1},
        "paperless-gpt-ocr-auto": {"id": 3},
        "paperless-gpt-ocr-complete": {"id": 4},
    }

    workflows = paperless_gpt_configure.desired_workflows(tags)

    assert workflows == [
        (
            "Auto OCR with paperless-gpt",
            [{"type": 2}],
            [{"type": 1, "assign_tags": [3]}],
        ),
        (
            "Auto classify after paperless-gpt OCR",
            [
                {
                    "type": 3,
                    "filter_has_tags": [4],
                    "filter_has_not_tags": [1],
                }
            ],
            [
                {"type": 1, "assign_tags": [1]},
                {"type": 2, "remove_tags": [4]},
            ],
        ),
    ]


def test_workflow_payload_preserves_nested_object_ids():
    payload = paperless_gpt_configure.workflow_payload(
        "Existing workflow",
        [{"type": 3, "filter_has_tags": [4]}],
        [
            {"type": 1, "assign_tags": [1]},
            {"type": 2, "remove_tags": [4]},
        ],
        {
            "triggers": [{"id": 20, "type": 2}],
            "actions": [{"id": 30, "type": 1}],
        },
    )

    assert payload == {
        "name": "Existing workflow",
        "order": 0,
        "enabled": True,
        "triggers": [{"id": 20, "type": 3, "filter_has_tags": [4]}],
        "actions": [
            {"id": 30, "type": 1, "assign_tags": [1]},
            {"type": 2, "remove_tags": [4]},
        ],
    }
