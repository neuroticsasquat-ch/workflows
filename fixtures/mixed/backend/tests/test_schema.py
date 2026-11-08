import json

from schema import SCHEMA, render


def test_render_round_trips() -> None:
    assert json.loads(render()) == SCHEMA
