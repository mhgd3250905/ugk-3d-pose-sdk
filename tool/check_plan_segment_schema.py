"""Validate the same segment fixtures used by Dart PlanCodec tests.

Run: python tool/check_plan_segment_schema.py (requires jsonschema).
"""

import json
from pathlib import Path

from jsonschema import Draft202012Validator

root = Path(__file__).resolve().parents[1]
schema = json.loads((root / 'schema/coach-reply.schema.json').read_text(encoding='utf-8'))
Draft202012Validator.check_schema(schema)
validator = Draft202012Validator({'$ref': '#/$defs/item', '$defs': schema['$defs']})
cases = json.loads((root / 'test/fixtures/plan-segments-schema.json').read_text(encoding='utf-8'))
for case in cases:
    item = {
        'exerciseId': 's-butterfly', 'mode': 'time', 'sets': 1,
        'perSide': False, 'restSeconds': 0, **case['patch'],
    }
    errors = list(validator.iter_errors(item))
    assert (not errors) == case['valid'], f"{case['name']}: {[e.message for e in errors]}"
print(f"JSON Schema: {len(cases)} shared PlanCodec fixtures passed")
