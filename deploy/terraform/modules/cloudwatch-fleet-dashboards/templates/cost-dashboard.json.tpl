{
  "widgets": [
    {
      "type": "log", "x": 0, "y": 0, "width": 24, "height": 8,
      "properties": {
        "title": "Per-user token + cost attribution (last 24h) — requires Bedrock invocation logging + Phase 3 metadata wiring",
        "region": "${aws_region}",
        "view": "table",
        "query": "SOURCE '${invocation_log_group}'\n| fields @timestamp, modelId, requestMetadata.userId as userId, requestMetadata.agentId as agentId, input.inputTokenCount as inTok, output.outputTokenCount as outTok\n| stats sum(inTok) as inputTokens, sum(outTok) as outputTokens by userId, agentId, modelId\n| sort inputTokens desc\n| limit 100"
      }
    },
    {
      "type": "metric", "x": 0, "y": 8, "width": 12, "height": 6,
      "properties": {
        "title": "Bedrock token volume by model",
        "region": "${aws_region}",
        "view": "timeSeries",
        "metrics": [
          [ "AWS/Bedrock", "InputTokenCount", { "stat": "Sum" } ],
          [ ".", "OutputTokenCount", { "stat": "Sum", "yAxis": "right" } ]
        ]
      }
    },
    {
      "type": "log", "x": 12, "y": 8, "width": 12, "height": 6,
      "properties": {
        "title": "Top users by turn count (last 24h)",
        "region": "${aws_region}",
        "view": "table",
        "query": "SOURCE '${api_log_group}'\n| fields @timestamp, user_id\n| filter msg = 'chat.turn.end'\n| stats count() as turns by user_id\n| sort turns desc\n| limit 25"
      }
    }
  ]
}
