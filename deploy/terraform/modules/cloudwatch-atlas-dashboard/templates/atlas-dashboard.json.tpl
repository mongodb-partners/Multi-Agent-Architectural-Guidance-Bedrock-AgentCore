{
  "widgets": [
    {
      "type": "metric", "x": 0, "y": 0, "width": 12, "height": 6,
      "properties": {
        "title": "Cluster CPU (process)",
        "region": "${aws_region}",
        "view": "timeSeries",
        "metrics": [
          [ "MongoDB/Atlas", "mongodbatlas_process_cpu_user", { "stat": "Average", "label": "User" } ],
          [ "...", { "stat": "Average", "label": "System" } ]
        ]
      }
    },
    {
      "type": "metric", "x": 12, "y": 0, "width": 12, "height": 6,
      "properties": {
        "title": "Connections (current vs available)",
        "region": "${aws_region}",
        "view": "timeSeries",
        "metrics": [
          [ "MongoDB/Atlas", "mongodbatlas_connections_current",   { "stat": "Average" } ],
          [ ".",             "mongodbatlas_connections_available", { "stat": "Average", "yAxis": "right" } ]
        ]
      }
    },
    {
      "type": "metric", "x": 0, "y": 6, "width": 12, "height": 6,
      "properties": {
        "title": "Opcounters",
        "region": "${aws_region}",
        "view": "timeSeries",
        "metrics": [
          [ "MongoDB/Atlas", "mongodbatlas_opcounters_query",   { "stat": "Sum" } ],
          [ ".",             "mongodbatlas_opcounters_insert",  { "stat": "Sum" } ],
          [ ".",             "mongodbatlas_opcounters_update",  { "stat": "Sum" } ],
          [ ".",             "mongodbatlas_opcounters_delete",  { "stat": "Sum" } ],
          [ ".",             "mongodbatlas_opcounters_command", { "stat": "Sum" } ]
        ]
      }
    },
    {
      "type": "metric", "x": 12, "y": 6, "width": 12, "height": 6,
      "properties": {
        "title": "Vector / Atlas Search latency (when published)",
        "region": "${aws_region}",
        "view": "timeSeries",
        "metrics": [
          [ "MongoDB/Atlas", "mongodbatlas_search_index_query_latency_ms", { "stat": "p95" } ],
          [ "...",                                                          { "stat": "p99" } ]
        ]
      }
    },
    {
      "type": "metric", "x": 0, "y": 12, "width": 12, "height": 6,
      "properties": {
        "title": "Replication lag (secondary -> primary)",
        "region": "${aws_region}",
        "view": "timeSeries",
        "metrics": [
          [ "MongoDB/Atlas", "mongodbatlas_replset_oplog_master_lag_ms", { "stat": "Maximum" } ]
        ]
      }
    }
  ]
}
