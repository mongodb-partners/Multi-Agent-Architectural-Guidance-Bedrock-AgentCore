{
  "widgets": [
    {
      "type": "metric", "x": 0, "y": 0, "width": 12, "height": 6,
      "properties": {
        "title": "Mongo query volume + duration (all collections)",
        "region": "${aws_region}",
        "view": "timeSeries",
        "metrics": [
          [ { "expression": "SUM(SEARCH('{Multiagent/Mongo,collection,kind} QueryCount', 'Sum', 300))", "label": "Query count", "id": "e1", "color": "#1f77b4" } ],
          [ { "expression": "SUM(SEARCH('{Multiagent/Mongo,collection,kind} QueryLatencyMs', 'p95', 300))", "label": "p95 latency (ms)", "id": "e2", "color": "#ff7f0e", "yAxis": "right" } ]
        ]
      }
    },
    {
      "type": "metric", "x": 12, "y": 0, "width": 12, "height": 6,
      "properties": {
        "title": "Vector-search latency (p50 / p95 / p99)",
        "region": "${aws_region}",
        "view": "timeSeries",
        "metrics": [
          [ "Multiagent/Mongo", "VectorSearchLatencyMs", "kind", "vector_search", "collection", "agent_memory_facts", { "stat": "p50", "label": "facts p50", "color": "#1f77b4" } ],
          [ "Multiagent/Mongo", "VectorSearchLatencyMs", "kind", "vector_search", "collection", "agent_memory_facts", { "stat": "p95", "label": "facts p95", "color": "#ff7f0e" } ],
          [ "Multiagent/Mongo", "VectorSearchLatencyMs", "kind", "vector_search", "collection", "chat_messages", { "stat": "p95", "label": "chat_msgs p95", "color": "#2ca02c" } ]
        ]
      }
    },
    {
      "type": "metric", "x": 0, "y": 6, "width": 12, "height": 6,
      "properties": {
        "title": "Long-term memory write throughput",
        "region": "${aws_region}",
        "view": "timeSeries",
        "metrics": [
          [ { "expression": "SUM(SEARCH('{Multiagent/Memory,agentId} FactsExtracted', 'Sum', 300))", "label": "Facts extracted", "id": "e1", "color": "#2ca02c" } ],
          [ { "expression": "SUM(SEARCH('{Multiagent/Memory,agentId} FactsWritten', 'Sum', 300))", "label": "Facts written", "id": "e2", "color": "#1f77b4" } ],
          [ { "expression": "SUM(SEARCH('{Multiagent/Memory,agentId} EmbeddingFailures', 'Sum', 300))", "label": "Embedding failures", "id": "e3", "color": "#d62728", "yAxis": "right" } ]
        ]
      }
    },
    {
      "type": "log", "x": 12, "y": 6, "width": 12, "height": 6,
      "properties": {
        "title": "Recent Mongo errors",
        "region": "${aws_region}",
        "view": "table",
        "query": "SOURCE '${api_log_group}'\n| fields @timestamp, msg, error_class, error_message, collection, trace_id\n| filter msg like /mongo/ and level = 'error'\n| sort @timestamp desc\n| limit 50"
      }
    }
  ]
}
