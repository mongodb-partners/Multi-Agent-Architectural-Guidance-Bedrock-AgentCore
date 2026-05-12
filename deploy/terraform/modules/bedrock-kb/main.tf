terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
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

  # IAM role name — caller can override via var.kb_iam_role_name; otherwise
  # we derive a project+env-scoped name. Account-global names are the worst
  # collision class, so the default is ALWAYS unique per (project, env).
  kb_role_name = (
    var.kb_iam_role_name != ""
    ? var.kb_iam_role_name
    : "${var.project_name}-bedrock-kb-${var.environment}-role"
  )

  embed_arn  = "arn:aws:bedrock:${var.aws_region}::foundation-model/${var.embed_model_id}"
  kb_id_file = "${path.module}/.kb-state.json"

  # S3 prefix under the shared bucket where KB docs are stored.
  # Bedrock data source is scoped to this prefix only.
  kb_docs_prefix = "kb-docs/docs"
}

# =============================================================================
# S3 — upload KB source documents to shared bucket under kb-docs/docs/ prefix
# Bucket is created and managed by deploy/terraform/bootstrap.
# =============================================================================

# Upload all .txt files from kb_docs_path → s3://<shared-bucket>/kb-docs/docs/<filename>
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

  secret_string = jsonencode({
    connectionString = "mongodb+srv://${var.atlas_srv_host}"
    username         = var.atlas_db_user
    password         = var.atlas_db_password
  })
}

# =============================================================================
# Atlas DB + collection bootstrap
# Search index requires the collection to exist; the collection itself isn't a
# Terraform resource (Atlas treats it as schema), so we ensure it via bun.
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
      path = "metadata"
    }
  ])

  depends_on = [null_resource.ensure_collection]
}

# =============================================================================
# Bedrock Knowledge Base — MongoDB Atlas vector store
#
# aws_bedrockagent_knowledge_base does not yet support MONGO_DB_ATLAS storage
# in the AWS Terraform provider. We use null_resource + AWS CLI for creation.
#
# Idempotency strategy:
#   1. If .kb-state.json has an ID and that KB is ACTIVE/CREATING → reuse it
#   2. Else search by name BUT ONLY ACTIVE ones (skips zombie CREATING orphans)
#   3. Else create new
# =============================================================================

resource "null_resource" "bedrock_kb" {
  triggers = {
    kb_name     = local.kb_name
    role_arn    = aws_iam_role.kb_role.arn
    secret_arn  = aws_secretsmanager_secret_version.atlas.arn
    atlas_db    = var.atlas_db_name
    atlas_coll  = var.atlas_collection
    atlas_index = var.atlas_vector_index
    embed_arn   = local.embed_arn
    # stored so destroy provisioner can reference via self.triggers
    aws_region = var.aws_region
    account_id = var.account_id
    kb_id_file = local.kb_id_file
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e

      REGION="${var.aws_region}"
      KB_NAME="${local.kb_name}"
      KB_STATE_FILE="${local.kb_id_file}"
      KB_ID=""

      # 1) State file is the source of truth — reuse if KB still ACTIVE/CREATING.
      if [ -f "$KB_STATE_FILE" ]; then
        SAVED_KB_ID=$(python3 -c "import json; print(json.load(open('$KB_STATE_FILE')).get('knowledge_base_id',''))" 2>/dev/null || echo "")
        if [ -n "$SAVED_KB_ID" ]; then
          STATUS=$(aws bedrock-agent get-knowledge-base --knowledge-base-id "$SAVED_KB_ID" --region "$REGION" --query 'knowledgeBase.status' --output text 2>/dev/null || echo "GONE")
          case "$STATUS" in
            ACTIVE|CREATING) KB_ID="$SAVED_KB_ID"; echo "Reusing KB from state file: $KB_ID ($STATUS)";;
            *) echo "KB $SAVED_KB_ID has status $STATUS — will create new.";;
          esac
        fi
      fi

      # 2) Fallback: search by name, ACTIVE only — skips zombie CREATING orphans.
      if [ -z "$KB_ID" ]; then
        EXISTING_KB_ID=$(aws bedrock-agent list-knowledge-bases \
          --region "$REGION" \
          --query "knowledgeBaseSummaries[?name=='$KB_NAME' && status=='ACTIVE'].knowledgeBaseId | [0]" \
          --output text 2>/dev/null || echo "None")
        if [ -n "$EXISTING_KB_ID" ] && [ "$EXISTING_KB_ID" != "None" ]; then
          KB_ID="$EXISTING_KB_ID"
          echo "Found existing ACTIVE KB by name: $KB_ID"
        fi
      fi

      # 3) Create new KB if no usable one found.
      if [ -z "$KB_ID" ]; then
        echo "Creating Bedrock Knowledge Base '$KB_NAME'..."
        KB_ID=$(aws bedrock-agent create-knowledge-base \
          --name "$KB_NAME" \
          --description "Troubleshooting product support articles (power, connectivity, hardware faults, warranty)" \
          --role-arn "${aws_iam_role.kb_role.arn}" \
          --region "$REGION" \
          --knowledge-base-configuration '{
            "type": "VECTOR",
            "vectorKnowledgeBaseConfiguration": {
              "embeddingModelArn": "${local.embed_arn}"
            }
          }' \
          --storage-configuration '{
            "type": "MONGO_DB_ATLAS",
            "mongoDbAtlasConfiguration": {
              "endpoint": "${var.atlas_srv_host}",
              "credentialsSecretArn": "${aws_secretsmanager_secret.atlas.arn}",
              "databaseName": "${var.atlas_db_name}",
              "collectionName": "${var.atlas_collection}",
              "vectorIndexName": "${var.atlas_vector_index}",
              "fieldMapping": {
                "vectorField": "embedding",
                "textField": "body",
                "metadataField": "metadata"
              }
            }
          }' \
          --query 'knowledgeBase.knowledgeBaseId' --output text)
        echo "Created KB: $KB_ID"
      fi

      # Wait for ACTIVE — fail loudly if KB ends up in a non-recoverable state.
      for i in $(seq 1 40); do
        STATE=$(aws bedrock-agent get-knowledge-base \
          --knowledge-base-id "$KB_ID" \
          --region "$REGION" \
          --query 'knowledgeBase.status' --output text 2>/dev/null || echo "UNKNOWN")
        echo "  KB state: $STATE ($i/40)"
        if [ "$STATE" = "ACTIVE" ]; then break; fi
        if [ "$STATE" = "FAILED" ] || [ "$STATE" = "DELETE_UNSUCCESSFUL" ]; then
          echo "ERROR: KB $KB_ID stuck in $STATE — destroy and redeploy required."
          exit 1
        fi
        sleep 15
      done

      # Persist KB ID for use by downstream resources and outputs
      echo "{\"knowledge_base_id\": \"$KB_ID\"}" > "${local.kb_id_file}"
      echo "KB ID saved to ${local.kb_id_file}"
    EOT
  }

  # Destroy provisioner — actually deletes the KB from AWS when terraform destroy runs.
  # null_resource has no implicit destroy behaviour; without this the KB survives destroy.
  # self.triggers.* is the only way to pass values into a destroy provisioner.
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -e
      REGION="${self.triggers.aws_region}"
      KB_STATE_FILE="${self.triggers.kb_id_file}"

      if [ ! -f "$KB_STATE_FILE" ]; then
        echo "No KB state file found — nothing to delete."
        exit 0
      fi

      KB_ID=$(python3 -c "import json; print(json.load(open('$KB_STATE_FILE')).get('knowledge_base_id',''))" 2>/dev/null || echo "")
      DS_ID=$(python3 -c "import json; print(json.load(open('$KB_STATE_FILE')).get('data_source_id',''))" 2>/dev/null || echo "")

      if [ -z "$KB_ID" ] || [ "$KB_ID" = "None" ]; then
        echo "No KB ID in state file — nothing to delete."
        exit 0
      fi

      # Delete data source first (if exists)
      if [ -n "$DS_ID" ] && [ "$DS_ID" != "None" ]; then
        echo "Deleting data source $DS_ID..."
        aws bedrock-agent delete-data-source \
          --knowledge-base-id "$KB_ID" \
          --data-source-id "$DS_ID" \
          --region "$REGION" 2>/dev/null || echo "Data source already gone."
      fi

      echo "Deleting Bedrock Knowledge Base $KB_ID..."
      aws bedrock-agent delete-knowledge-base \
        --knowledge-base-id "$KB_ID" \
        --region "$REGION" 2>/dev/null || echo "KB already gone."

      echo "Removing state file..."
      rm -f "$KB_STATE_FILE"
      echo "Bedrock KB $KB_ID deleted."
    EOT
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
# Bedrock KB Data Source — S3 (scoped to kb-docs/docs/ prefix in shared bucket)
# =============================================================================

resource "null_resource" "bedrock_data_source" {
  triggers = {
    kb_null_resource = null_resource.bedrock_kb.id
    bucket_arn       = var.shared_bucket_arn
    doc_etags        = join(",", [for o in aws_s3_object.kb_doc : o.etag])
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      REGION="${var.aws_region}"
      KB_STATE_FILE="${local.kb_id_file}"

      if [ ! -f "$KB_STATE_FILE" ]; then
        echo "ERROR: $KB_STATE_FILE not found — bedrock_kb resource must apply first"; exit 1
      fi

      KB_ID=$(python3 -c "import json,sys; print(json.load(open('$KB_STATE_FILE'))['knowledge_base_id'])")
      DS_NAME="${local.ds_name}"

      EXISTING_DS_ID=$(aws bedrock-agent list-data-sources \
        --knowledge-base-id "$KB_ID" \
        --region "$REGION" \
        --query "dataSourceSummaries[?name=='$DS_NAME'].dataSourceId | [0]" \
        --output text 2>/dev/null || echo "None")

      if [ -z "$EXISTING_DS_ID" ] || [ "$EXISTING_DS_ID" = "None" ]; then
        echo "Creating S3 data source '$DS_NAME'..."
        DS_ID=$(aws bedrock-agent create-data-source \
          --knowledge-base-id "$KB_ID" \
          --name "$DS_NAME" \
          --description "Troubleshooting guides from S3" \
          --region "$REGION" \
          --data-source-configuration '{
            "type": "S3",
            "s3Configuration": {
              "bucketArn": "${var.shared_bucket_arn}",
              "inclusionPrefixes": ["kb-docs/docs/"]
            }
          }' \
          --vector-ingestion-configuration '{
            "chunkingConfiguration": {
              "chunkingStrategy": "FIXED_SIZE",
              "fixedSizeChunkingConfiguration": {"maxTokens": 300, "overlapPercentage": 20}
            }
          }' \
          --query 'dataSource.dataSourceId' --output text)
        echo "Data source created: $DS_ID"
      else
        DS_ID="$EXISTING_DS_ID"
        echo "Data source already exists: $DS_ID"
      fi

      # Update state file with DS ID
      python3 -c "
import json
with open('$KB_STATE_FILE') as f: state = json.load(f)
state['data_source_id'] = '$DS_ID'
with open('$KB_STATE_FILE','w') as f: json.dump(state, f)
"
      echo "Data source ID saved."
    EOT
  }

  depends_on = [
    null_resource.bedrock_kb,
    aws_s3_object.kb_doc,
  ]
}

# =============================================================================
# Ingestion — trigger sync when docs change
# =============================================================================

resource "null_resource" "ingestion" {
  triggers = {
    data_source_null = null_resource.bedrock_data_source.id
    doc_etags        = join(",", [for o in aws_s3_object.kb_doc : o.etag])
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      REGION="${var.aws_region}"
      KB_STATE_FILE="${local.kb_id_file}"

      KB_ID=$(python3 -c "import json; d=json.load(open('$KB_STATE_FILE')); print(d['knowledge_base_id'])")
      DS_ID=$(python3 -c "import json; d=json.load(open('$KB_STATE_FILE')); print(d['data_source_id'])")

      echo "Waiting for KB to be ACTIVE before starting ingestion..."
      for i in $(seq 1 40); do
        KB_STATUS=$(aws bedrock-agent get-knowledge-base \
          --knowledge-base-id "$KB_ID" \
          --region "$REGION" \
          --query 'knowledgeBase.status' --output text 2>/dev/null || echo "UNKNOWN")
        echo "  KB status: $KB_STATUS ($i/40)"
        if [ "$KB_STATUS" = "ACTIVE" ]; then break; fi
        if [ "$KB_STATUS" = "FAILED" ]; then echo "ERROR: KB failed to become ACTIVE."; exit 1; fi
        sleep 15
      done

      echo "Starting ingestion job..."
      JOB_ID=$(aws bedrock-agent start-ingestion-job \
        --knowledge-base-id "$KB_ID" \
        --data-source-id "$DS_ID" \
        --region "$REGION" \
        --query 'ingestionJob.ingestionJobId' --output text 2>/tmp/_ingest_err.txt) || {
        _ERR=$(cat /tmp/_ingest_err.txt 2>/dev/null || echo "unknown error")
        if echo "$_ERR" | grep -qE "not able to call specified bedrock embedding model|Operation not allowed"; then
          echo "WARNING: Bedrock model access not enabled for the embedding model."
          echo "  → Enable 'Titan Embed Text v2' in the Bedrock console (Model access page)"
          echo "    then re-run: terraform apply (or deploy-local.sh) to retry ingestion."
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
        if [ "$STATUS" = "COMPLETE" ]; then echo "Ingestion complete."; break; fi
        if [ "$STATUS" = "FAILED" ]; then echo "WARNING: Ingestion failed — check console."; break; fi
        sleep 10
      done
    EOT
  }

  depends_on = [null_resource.bedrock_data_source]
}
