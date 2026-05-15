terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.27, < 7.0"
    }
    mongodbatlas = {
      source  = "mongodb/mongodbatlas"
      version = "~> 1.14"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

locals {
  # Project + env prefix on every account/region-global name so multiple
  # deployments (or multiple projects) in one AWS account do not collide.
  kb_name     = "${var.project_name}-troubleshooting-kb-${var.environment}"
  secret_name = "${var.project_name}-bedrock-kb-creds-${var.environment}"
  ds_name     = "${local.kb_name}-s3"
  # CloudWatch vended-log delivery names are capped at 60 chars. Keep the
  # human-readable project prefix while adding a hash to avoid collisions.
  kb_log_delivery_prefix = "${substr(local.kb_name, 0, 37)}-${substr(md5(local.kb_name), 0, 8)}"

  # IAM role name — caller can override via var.kb_iam_role_name; otherwise
  # we derive a project+env-scoped name. Account-global names are the worst
  # collision class, so the default is ALWAYS unique per (project, env).
  kb_role_name = (
    var.kb_iam_role_name != ""
    ? var.kb_iam_role_name
    : "${var.project_name}-bedrock-kb-${var.environment}-role"
  )

  embed_arn   = "arn:aws:bedrock:${var.aws_region}::foundation-model/${var.embed_model_id}"
  kb_endpoint = var.kb_endpoint_host != "" ? var.kb_endpoint_host : var.atlas_srv_host

  # S3 prefix under the shared bucket where KB docs are stored.
  # Bedrock data source is scoped to this prefix only.
  kb_docs_prefix = "kb-docs/docs"
}

# =============================================================================
# S3 — upload KB source documents to shared bucket under kb-docs/docs/ prefix
# Bucket is created and managed by deploy/terraform/bootstrap.
# =============================================================================

resource "aws_s3_object" "kb_doc" {
  for_each = fileset(var.kb_docs_path, "*.txt")

  bucket       = var.shared_bucket_name
  key          = "${local.kb_docs_prefix}/${each.value}"
  source       = "${var.kb_docs_path}/${each.value}"
  content_type = "text/plain"
  etag         = filemd5("${var.kb_docs_path}/${each.value}")
}

# =============================================================================
# IAM — create the Bedrock KB role (project+env-scoped, see local.kb_role_name)
# and attach required policies
# =============================================================================

resource "aws_iam_role" "kb_role" {
  name = local.kb_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  # Project tag inherited from provider default_tags
}

resource "aws_iam_role_policy" "kb_s3" {
  name = "BedrockKB-S3"
  role = aws_iam_role.kb_role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:GetObject", "s3:ListBucket"]
      Resource = [
        var.shared_bucket_arn,
        "${var.shared_bucket_arn}/kb-docs/*"
      ]
    }]
  })
}

resource "aws_iam_role_policy" "kb_embed" {
  name = "BedrockKB-EmbedModel"
  role = aws_iam_role.kb_role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "bedrock:InvokeModel"
      Resource = local.embed_arn
    }]
  })
}

resource "aws_iam_role_policy" "kb_secrets" {
  name = "BedrockKB-SecretsManager"
  role = aws_iam_role.kb_role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ]
      Resource = "arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:${local.secret_name}*"
    }]
  })
}

# =============================================================================
# Secrets Manager — Atlas credentials for Bedrock KB MongoDB connector
# =============================================================================

resource "aws_secretsmanager_secret" "atlas" {
  name                    = local.secret_name
  description             = "MongoDB Atlas credentials for Bedrock KB ${local.kb_name}"
  recovery_window_in_days = 0 # allow immediate deletion on terraform destroy
}

resource "aws_secretsmanager_secret_version" "atlas" {
  secret_id = aws_secretsmanager_secret.atlas.id

  # The connection string MUST use the same hostname Bedrock dials for the
  # storage endpoint. Per MongoDB Atlas docs, when PrivateLink is enabled
  # for the Bedrock KB integration the hostname carries a "-pl" suffix that
  # resolves to the AWS-side VPCE rather than the public SRV record. If the
  # secret's connectionString points at the public SRV while the KB endpoint
  # is set to the -pl host, ingestion fails with "Write failure with error
  # code -3" because Bedrock cannot complete the Atlas handshake.
  secret_string = jsonencode({
    connectionString = "mongodb+srv://${local.kb_endpoint}"
    username         = var.atlas_db_user
    password         = var.atlas_db_password
  })
}

# =============================================================================
# Atlas DB + collection bootstrap
# Search index requires the collection to exist; the collection itself isn't a
# Terraform resource (Atlas treats collections as schema, not infra — there is
# no `mongodbatlas_collection` in the provider as of 1.14, and `db.createCollection`
# is a one-shot mongo API call). We therefore ensure it via a small bun script;
# kept as `null_resource` because it is an action, not state. Re-runs only when
# cluster/db/collection identity changes.
# =============================================================================

resource "null_resource" "ensure_collection" {
  triggers = {
    cluster_name = var.atlas_cluster_name
    db_name      = var.atlas_db_name
    collection   = var.atlas_collection
  }

  provisioner "local-exec" {
    command = "bun ${var.ensure_collection_script}"

    environment = {
      MONGODB_URI  = "mongodb+srv://${var.atlas_db_user}:${var.atlas_db_password}@${var.atlas_srv_host}/?retryWrites=true&w=majority"
      MONGODB_DB   = var.atlas_db_name
      MONGODB_COLL = var.atlas_collection
    }
  }
}

# =============================================================================
# Atlas Vector Search Index — native Terraform resource
# Replaces the previous Atlas Admin API call. Provider 1.8+ supports vectorSearch.
# =============================================================================

resource "mongodbatlas_search_index" "vector" {
  project_id      = var.atlas_project_id
  cluster_name    = var.atlas_cluster_name
  database        = var.atlas_db_name
  collection_name = var.atlas_collection
  name            = var.atlas_vector_index
  type            = "vectorSearch"

  fields = jsonencode([
    {
      type          = "vector"
      path          = "embedding"
      numDimensions = var.embedding_dimensions
      similarity    = "cosine"
    },
    {
      type = "filter"
      path = "bedrock_metadata"
    },
    {
      type = "filter"
      path = "bedrock_text_chunk"
    },
    {
      type = "filter"
      path = "x-amz-bedrock-kb-document-page-number"
    }
  ])

  depends_on = [null_resource.ensure_collection]
}

# =============================================================================
# Bedrock Knowledge Base — native resource (provider 6.x supports MONGO_DB_ATLAS).
# Replaces the previous null_resource + AWS CLI shim. Deletion + re-creation are
# handled by Terraform; on `terraform destroy` the KB and its IAM grants are
# torn down cleanly.
# =============================================================================

resource "aws_bedrockagent_knowledge_base" "this" {
  name        = local.kb_name
  description = "Troubleshooting product support articles (power, connectivity, hardware faults, warranty)"
  role_arn    = aws_iam_role.kb_role.arn

  lifecycle {
    # Imported KBs created by older deploy scripts used `body` / `metadata`.
    # Bedrock treats field_mapping as ForceNew, so adopting an active KB should
    # not destroy/recreate it just to normalize equivalent field names.
    ignore_changes = [
      storage_configuration[0].mongo_db_atlas_configuration[0].field_mapping[0].metadata_field,
      storage_configuration[0].mongo_db_atlas_configuration[0].field_mapping[0].text_field,
    ]
  }

  knowledge_base_configuration {
    type = "VECTOR"
    vector_knowledge_base_configuration {
      embedding_model_arn = local.embed_arn
    }
  }

  storage_configuration {
    type = "MONGO_DB_ATLAS"
    mongo_db_atlas_configuration {
      endpoint               = local.kb_endpoint
      credentials_secret_arn = aws_secretsmanager_secret.atlas.arn
      database_name          = var.atlas_db_name
      collection_name        = var.atlas_collection
      vector_index_name      = var.atlas_vector_index

      # Empty → omitted at apply time → Bedrock falls back to public SRV
      # (documented Option B). Set to an NLB-fronting VPC Endpoint Service
      # name to satisfy CLIENT_REVIEW P1-6 Option A end-to-end. Wiring is
      # done from envs/ec2 via var.enable_kb_privatelink → module
      # bedrock-kb-privatelink → module bedrock_kb.endpoint_service_name.
      endpoint_service_name = var.endpoint_service_name != "" ? var.endpoint_service_name : null

      field_mapping {
        vector_field   = "embedding"
        text_field     = "bedrock_text_chunk"
        metadata_field = "bedrock_metadata"
      }
    }
  }

  depends_on = [
    aws_iam_role_policy.kb_s3,
    aws_iam_role_policy.kb_embed,
    aws_iam_role_policy.kb_secrets,
    aws_secretsmanager_secret_version.atlas,
    mongodbatlas_search_index.vector,
  ]
}

# =============================================================================
# Bedrock KB Data Source — native resource for the S3 source under
# kb-docs/docs/ in the shared bucket. FIXED_SIZE chunking with 300 tokens /
# 20% overlap (matches the previous CLI behaviour exactly).
# =============================================================================

resource "aws_bedrockagent_data_source" "s3" {
  knowledge_base_id    = aws_bedrockagent_knowledge_base.this.id
  name                 = local.ds_name
  description          = "Troubleshooting guides from S3"
  data_deletion_policy = "DELETE"

  data_source_configuration {
    type = "S3"
    s3_configuration {
      bucket_arn         = var.shared_bucket_arn
      inclusion_prefixes = ["${local.kb_docs_prefix}/"]
    }
  }

  vector_ingestion_configuration {
    chunking_configuration {
      chunking_strategy = "FIXED_SIZE"
      fixed_size_chunking_configuration {
        max_tokens         = 300
        overlap_percentage = 20
      }
    }
  }

  depends_on = [aws_s3_object.kb_doc]
}

# =============================================================================
# CloudWatch APPLICATION_LOGS for the KB.
#
# Without these, ingestion failures only surface as the cryptic top-level
# "Write failure with error code -3" — which masked an `E11000` duplicate-key
# error on the seed `docId_1` index for hours during P1-6 Option A bring-up.
# With APPLICATION_LOGS wired up, every per-chunk INDEXING_FAILED event carries
# the actual driver `status_reasons`, making the next regression diagnosable
# from a single `aws logs tail` instead of an EC2-side mongosh probe.
# Implementation uses the CloudWatch Logs Vended Logs delivery API
# (PutDeliverySource → PutDeliveryDestination → CreateDelivery) which is the
# only way Bedrock-managed services can ship logs into our account.
# =============================================================================

resource "aws_cloudwatch_log_group" "kb_application" {
  name              = "/aws/bedrock/knowledgebase/${aws_bedrockagent_knowledge_base.this.id}"
  retention_in_days = 7
  tags              = var.common_tags
}

resource "aws_cloudwatch_log_delivery_source" "kb_application" {
  name         = "${local.kb_log_delivery_prefix}-app-logs-src"
  resource_arn = aws_bedrockagent_knowledge_base.this.arn
  log_type     = "APPLICATION_LOGS"
}

resource "aws_cloudwatch_log_delivery_destination" "kb_application_cwl" {
  name = "${local.kb_log_delivery_prefix}-app-logs-cwl"

  delivery_destination_configuration {
    destination_resource_arn = "${aws_cloudwatch_log_group.kb_application.arn}:*"
  }
}

resource "aws_cloudwatch_log_delivery" "kb_application" {
  delivery_source_name     = aws_cloudwatch_log_delivery_source.kb_application.name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.kb_application_cwl.arn
}

# =============================================================================
# Ingestion — fire start-ingestion-job whenever the underlying docs change.
#
# Terraform has no native resource for "trigger an ingestion job" because it is
# an action, not infrastructure (neither `hashicorp/aws` nor `hashicorp/awscc`
# expose `aws_bedrockagent_ingestion_job` as of 6.45 / 1.51 — the `start-ingestion-job`
# API is a one-shot trigger, not a managed resource). Kept as `null_resource`
# for this reason; `terraform_data`-style triggers re-fire the job whenever the
# doc etags change so the corpus stays in sync with S3. Bedrock-model-access
# errors are demoted to a warning so the apply doesn't fail on a fresh deploy
# where the operator hasn't enabled Titan v2 yet.
# =============================================================================

resource "null_resource" "ingestion" {
  triggers = {
    knowledge_base_id = aws_bedrockagent_knowledge_base.this.id
    data_source_id    = aws_bedrockagent_data_source.s3.data_source_id
    doc_etags         = join(",", [for o in aws_s3_object.kb_doc : o.etag])
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      REGION="${var.aws_region}"
      KB_ID="${aws_bedrockagent_knowledge_base.this.id}"
      DS_ID="${aws_bedrockagent_data_source.s3.data_source_id}"

      echo "Starting Bedrock KB ingestion job (kb=$KB_ID, ds=$DS_ID)..."
      JOB_ID=$(aws bedrock-agent start-ingestion-job \
        --knowledge-base-id "$KB_ID" \
        --data-source-id "$DS_ID" \
        --region "$REGION" \
        --query 'ingestionJob.ingestionJobId' --output text 2>/tmp/_ingest_err.txt) || {
        _ERR=$(cat /tmp/_ingest_err.txt 2>/dev/null || echo "unknown error")
        if echo "$_ERR" | grep -qE "not able to call specified bedrock embedding model|Operation not allowed"; then
          echo "WARNING: Bedrock model access not enabled for the embedding model."
          echo "  → Enable 'Titan Embed Text v2' in the Bedrock console (Model access page)"
          echo "    then re-run: terraform apply (or deploy.sh) to retry ingestion."
          exit 0
        fi
        echo "ERROR starting ingestion job: $_ERR"
        exit 1
      }
      echo "Job started: $JOB_ID"

      for i in $(seq 1 30); do
        STATUS=$(aws bedrock-agent get-ingestion-job \
          --knowledge-base-id "$KB_ID" \
          --data-source-id "$DS_ID" \
          --ingestion-job-id "$JOB_ID" \
          --region "$REGION" \
          --query 'ingestionJob.status' --output text 2>/dev/null || echo "IN_PROGRESS")
        echo "  Ingestion: $STATUS ($i/30)"
        if [ "$STATUS" = "COMPLETE" ]; then echo "Ingestion complete."; exit 0; fi
        if [ "$STATUS" = "FAILED" ]; then
          # Hard-fail the deploy. Silent FAILED was how we previously shipped
          # P1-6 Option A as "done" while every ingestion job was failing
          # with E11000 on the seed `docId_1` unique index — see memory.md
          # ("Bedrock KB ingestion — `troubleshooting_docs.docId` must be a
          # **partial** unique index"). Surfacing the failure reasons here
          # makes that class of regression impossible to miss in CI.
          echo "ERROR: Bedrock KB ingestion FAILED. Failure reasons:"
          aws bedrock-agent get-ingestion-job \
            --knowledge-base-id "$KB_ID" \
            --data-source-id "$DS_ID" \
            --ingestion-job-id "$JOB_ID" \
            --region "$REGION" \
            --query 'ingestionJob.{Stats:statistics,Errors:failureReasons}' --output json || true
          echo "→ enable APPLICATION_LOGS on the KB and grep status_reasons for the real driver error before assuming it's a network/PrivateLink issue."
          exit 1
        fi
        sleep 10
      done
      echo "ERROR: Bedrock KB ingestion did not reach COMPLETE in 5 minutes."
      exit 1
    EOT
  }
}
