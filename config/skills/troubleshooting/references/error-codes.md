# Error codes — full reference

## How to use this file

Load with `read_skill_resource` when the customer mentions a specific code.
Each entry shows: meaning, linked doc playbook, resolution path, and when to escalate.

---

| Code      | Meaning                          | Doc id | Resolution path                                                        | Escalate if                                         |
|-----------|----------------------------------|--------|------------------------------------------------------------------------|-----------------------------------------------------|
| PWR-001   | Power path fault                 | ts-1   | Cable swap → outlet swap → 10-sec hard reset                           | Still dead after 2 cables + 2 outlets               |
| BOOT-010  | Random restarts / boot loop      | ts-1b  | Firmware update (companion app) → disable background sync → battery calibrate (full discharge then 100% charge) → factory reset | Restarts continue after clean firmware install |
| NET-204   | Intermittent connectivity loss   | ts-2   | Move to router → disable VPN → firmware update → network reset         | Returns within 24 h after factory reset             |
| HW-900    | Hardware self-test failure       | ts-3   | **Do not retry.** Capture serial number + proof of purchase. Escalate. | Always escalate immediately                         |
| RET-010   | Post-delivery replacement flag   | ts-4   | Confirm return eligibility via order-management tools                  | Notes mention HW-900 or repeated failures           |
| THERM-101 | Thermal shutdown                 | ts-5   | Remove case → cool surface → clear vents → avoid charging + using      | 3+ shutdowns in one week                            |
| BT-301    | Bluetooth handshake failure      | ts-6   | Delete pairing → re-pair → Bluetooth stack reset → firmware check      | Fails on 2+ devices after stack reset               |
| FW-501    | Firmware update timeout/failure  | ts-7   | Wait 20 min → recovery tool flash                                      | Recovery tool fails — factory reflash needed        |
| BAT-401   | Battery cell degradation         | ts-8   | Check battery health in Settings → Battery → Health                    | Health < 80% — warranty battery replacement         |
| DISP-201  | Display driver / panel fault     | ts-9   | Double power press → brightness check → test external display          | External display works → internal panel replacement |

---

## Priority mapping for `buildSupportTicket`

| Priority | Codes                              |
|----------|------------------------------------|
| high     | HW-900, BAT-401, DISP-201, THERM-101 |
| medium   | BT-301, FW-501, BOOT-010           |
| low      | PWR-001, NET-204, RET-010          |

---

## Knowledge Base note

`bedrock_kb_retrieve` returns supplementary context. Always prefer
`troubleshooting_docs` playbooks when both return content on the same issue.
