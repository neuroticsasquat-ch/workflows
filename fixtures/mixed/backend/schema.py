"""The API schema the frontend copies to src/schema.json.

Stdlib only, so the drift check runs it with the runner's python3.
"""

import json

SCHEMA: dict[str, object] = {
    "title": "Greeting",
    "type": "object",
    "properties": {"name": {"type": "string"}, "message": {"type": "string"}},
    "required": ["name", "message"],
}


def render() -> str:
    return json.dumps(SCHEMA, indent=2) + "\n"


if __name__ == "__main__":
    print(render(), end="")
