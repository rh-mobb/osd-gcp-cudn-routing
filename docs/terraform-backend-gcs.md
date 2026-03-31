# Terraform remote state on Google Cloud Storage

For production and shared environments, store Terraform state in a **GCS bucket** with **object versioning** and a **uniform bucket-level access** model so state is not tied to one laptop and concurrent applies are safer.

## 1. Bucket

Create a dedicated bucket (example naming: `PROJECT-terraform-state` or `ORG-osd-cudn-routing-tfstate`):

```bash
PROJECT_ID="your-gcp-project"
BUCKET="${PROJECT_ID}-osd-cudn-tfstate"
REGION="us-central1"

gcloud storage buckets create "gs://${BUCKET}" \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --uniform-bucket-level-access

gcloud storage buckets update "gs://${BUCKET}" --versioning
```

Enable **object versioning** on the bucket so you can recover from accidental overwrites.

Restrict who can read/write objects (e.g. dedicated service account for CI or operators, no public access).

## 2. Backend block

In the stack directory (for example `cluster_bgp_routing/`, or `archive/cluster_ilb_routing/` if you use the archived ILB stack), add a `terraform` block with a `backend "gcs"` configuration.

Do **not** commit real bucket names if they expose internal naming—use **`backend.tf`** in `.gitignore` or inject via CI. The repo ships **`backend.tf.example`** as a template you can copy to **`backend.tf`** and edit.

Minimal shape:

```hcl
terraform {
  backend "gcs" {
    bucket = "YOUR_PROJECT-osd-cudn-tfstate"
    prefix = "cluster-bgp/cluster-name-unique"

    # Optional: if not using ADC / gcloud application-default login:
    # credentials = "/path/to/sa-key.json"
  }
}
```

- **`prefix`**: unique per stack and environment (e.g. `prod/bgp/cluster-foo`). Avoid collisions between stacks (BGP vs archived ILB) and between dev/prod.
- **`credentials`**: rarely needed locally if you use `gcloud auth application-default login` with a user or WIF that can write the bucket.

After adding the backend, run **`terraform init -migrate-state`** once to move local state into the bucket (review the prompt before confirming).

## 3. Locking

Terraform’s **GCS backend** supports state locking when the bucket allows the principal to create/update the lock object. Ensure the apply identity has **`storage.objects.create`** / **`update`** / **`get`** on the state prefix (or bucket).

## 4. References

- [Terraform GCS backend](https://developer.hashicorp.com/terraform/language/settings/backends/gcs)
- [Google Cloud Storage buckets](https://cloud.google.com/storage/docs/creating-buckets)
