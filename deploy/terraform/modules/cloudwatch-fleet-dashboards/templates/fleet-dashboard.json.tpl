{
  "widgets": [
    {
      "type": "metric", "x": 0, "y": 0, "width": 12, "height": 6,
      "properties": {
        "title": "Turn latency (p50 / p95 / p99)",
        "region": "${aws_region}",
        "stacked": false,
        "view": "timeSeries",
        "metrics": [
          [ { "expression": "SUM(SEARCH('{Multiagent/Chat,agentId} TurnLatencyMs', 'p50', 300))", "label": "p50", "id": "e1", "color": "#1f77b4" } ],
          [ { "expression": "SUM(SEARCH('{Multiagent/Chat,agentId} TurnLatencyMs', 'p95', 300))", "label": "p95", "id": "e2", "color": "#ff7f0e" } ],
          [ { "expression": "SUM(SEARCH('{Multiagent/Chat,agentId} TurnLatencyMs', 'p99', 300))", "label": "p99", "id": "e3", "color": "#d62728" } ]
        ],
        "annotations": {
          "horizontal": [ { "value": ${p99_latency_threshold_ms}, "label": "p99 SLO", "color": "#d62728" } ]
        }
      }
    },
    {
      "type": "metric", "x": 12, "y": 0, "width": 12, "height": 6,
      "properties": {
        "title": "Turn volume + errors",
        "region": "${aws_region}",
        "stacked": false,
        "view": "timeSeries",
        "metrics": [
          [ { "expression": "SUM(SEARCH('{Multiagent/Chat,agentId} TurnsTotal', 'Sum', 300))", "label": "Turns", "id": "e1", "color": "#2ca02c" } ],
          [ { "expression": "SUM(SEARCH('{Multiagent/Chat,agentId} TurnErrors', 'Sum', 300))", "label": "Errors", "id": "e2", "color": "#d62728", "yAxis": "right" } ]
        ]
      }
    },
    {
      "type": "metric", "x": 0, "y": 6, "width": 12, "height": 6,
      "properties": {
        "title": "Bedrock model invocations + throttles",
        "region": "${aws_region}",
        "view": "timeSeries",
        "metrics": [
          [ "AWS/Bedrock", "Invocations", { "stat": "Sum", "color": "#1f77b4" } ],
          [ ".", "InvocationThrottles", { "stat": "Sum", "yAxis": "right", "color": "#ff7f0e" } ],
          [ ".", "InvocationClientErrors", { "stat": "Sum", "yAxis": "right", "color": "#d62728" } ]
        ],
        "annotations": {
          "horizontal": [ { "value": ${throttle_burst_threshold}, "label": "Throttle threshold" } ]
        }
      }
    },
    {
      "type": "metric", "x": 12, "y": 6, "width": 12, "height": 6,
      "properties": {
        "title": "AgentCore runtime invocations",
        "region": "${aws_region}",
        "view": "timeSeries",
        "metrics": [
          [ { "expression": "SUM(SEARCH('{Multiagent/Chat,agentId,mode} AgentCoreInvokes', 'Sum', 300))", "label": "Invocations", "id": "e1", "color": "#2ca02c" } ],
          [ { "expression": "SUM(SEARCH('{Multiagent/Chat,agentId,mode} AgentCoreInvokeErrors', 'Sum', 300))", "label": "Errors", "id": "e2", "color": "#d62728", "yAxis": "right" } ]
        ]
      }
    },
    {
      "type": "log", "x": 0, "y": 12, "width": 24, "height": 6,
      "properties": {
        "title": "Top errors (live)",
        "region": "${aws_region}",
        "view": "table",
        "query": "SOURCE '${api_log_group}'\n| fields @timestamp, level, msg, error_class, error_message, trace_id\n| filter level = 'error'\n| sort @timestamp desc\n| limit 50"
      }
    }
  ]
}
