# Common issues — symptom → doc mapping

Use this table as a quick lookup before running `mongodb_vector_search`.
If the symptom matches closely, you can go directly to the docId.
For ambiguous symptoms, always run vector search to confirm.

| Symptom (customer words)                          | Doc id | Error codes         | Escalate if                                  |
|---------------------------------------------------|--------|---------------------|----------------------------------------------|
| "won't turn on", "dead", "no power"               | ts-1   | PWR-001, BOOT-010   | Persists after 2 cable swaps + 2 outlets     |
| "keeps disconnecting", "Wi-Fi drops", "offline"   | ts-2   | NET-204             | Returns within 24 h after factory reset      |
| "red light blinking", "hardware error"            | ts-3   | HW-900              | Immediately — do not attempt further steps   |
| "replacement", "swap my unit", "defective"        | ts-4   | RET-010             | Check order eligibility first                |
| "hot", "overheating", "shuts off when warm"       | ts-5   | THERM-101           | 3+ thermal shutdowns in one week             |
| "Bluetooth won't connect", "can't pair"           | ts-6   | BT-301              | Fails on multiple devices after reset        |
| "update stuck", "firmware failed", "update loop"  | ts-7   | FW-501              | Recovery tool also fails                     |
| "battery dying fast", "drains overnight"          | ts-8   | BAT-401             | Battery health < 80% — warranty replacement  |
| "screen blank", "display flickering", "no image"  | ts-9   | DISP-201            | External display works — internal panel swap |
| "want to wipe", "factory reset", "start fresh"    | ts-10  | (none)              | Recovery mode inaccessible                   |

When the user mentions an error code directly, load `references/error-codes.md`
for the full resolution path for that code.
