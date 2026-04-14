#!/usr/bin/env bash
# Undelete soft-deleted GCP *project* custom IAM roles (same role_id cannot be
# recreated until undelete or retention expiry). Typical after Terraform errors:
# "role_id (...) which has been marked for deletion, failedPrecondition".
#
# Default (no project/role args): reads gcp_project_id and WIF role_prefix from
# Terraform in wif_config/ (same rules as osd-wif-config: coalesce(role_prefix,
# cluster_name with hyphens/underscores removed)), discovers soft-deleted roles
# by comparing gcloud iam roles list with vs without --show-deleted (gcloud JSON
# omits the API deleted flag, so .deleted-based filtering never matched).
#
# After success, align Terraform state (often terraform import per resource).
# See scripts/README.md and `make wif.undelete-soft-deleted-roles`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF' >&2
Usage:
  gcp-undelete-wif-custom-roles.sh [--dry-run] [--continue-on-error]
  gcp-undelete-wif-custom-roles.sh PROJECT_ID ROLE_ID [ROLE_ID ...] [--dry-run] [--continue-on-error]
  gcp-undelete-wif-custom-roles.sh --from-log PATH [--dry-run] [--continue-on-error]

Default (first form): uses Terraform in wif_config/ (override: --terraform-dir or
WIF_UNDELETE_TERRAFORM_DIR), then compares gcloud role lists (with vs without
--show-deleted) to find soft-deleted role_ids, filtered by WIF role prefix.
Optional --no-prefix-filter undeletes every soft-deleted custom role in the
project (use with care on shared projects).

Options:
  --from-log PATH       Parse projects/PROJECT/roles/ROLE_ID from Terraform log text.
  --terraform-dir PATH  Terraform root for var.gcp_project_id / role_prefix (default: REPO/wif_config).
  --no-prefix-filter    Undelete all soft-deleted project custom roles (ignore prefix).
  --dry-run             Print gcloud commands only.
  --continue-on-error   Try every role; exit 1 if any undelete failed (default: stop on first error).

Examples:
  ./scripts/gcp-undelete-wif-custom-roles.sh
  ./scripts/gcp-undelete-wif-custom-roles.sh --dry-run
  make wif.undelete-soft-deleted-roles
  make wif.undelete-soft-deleted-roles WIF_UNDELETE_ARGS='--dry-run'
  ./scripts/gcp-undelete-wif-custom-roles.sh mobb-demo czdemo_osd_deployer_v4.21
  ./scripts/gcp-undelete-wif-custom-roles.sh --from-log ./apply.log
EOF
  exit 1
}

command -v gcloud >/dev/null 2>&1 || {
  echo "Error: gcloud not found on PATH." >&2
  exit 1
}

dry_run=0
continue_on_error=0
from_log=""
no_prefix_filter=0
terraform_dir_cli=""
positional=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --continue-on-error)
      continue_on_error=1
      shift
      ;;
    --no-prefix-filter)
      no_prefix_filter=1
      shift
      ;;
    --from-log)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --from-log requires a file path." >&2
        exit 1
      fi
      from_log="$2"
      shift 2
      ;;
    --terraform-dir)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --terraform-dir requires a directory path." >&2
        exit 1
      fi
      terraform_dir_cli="$2"
      shift 2
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done

run_undelete() {
  local project_id="$1"
  local role_id="$2"
  echo "Undeleting projects/${project_id}/roles/${role_id} ..."
  if [[ "$dry_run" -eq 1 ]]; then
    echo "  (dry-run) gcloud iam roles undelete ${role_id} --project=${project_id}"
    return 0
  fi
  gcloud iam roles undelete "${role_id}" --project="${project_id}"
}

strip_tf_string() {
  # Terraform console prints strings as "value" (possibly with trailing newline).
  sed 's/^[[:space:]]*"\(.*\)"[[:space:]]*$/\1/' | tr -d '\r'
}

terraform_console() {
  local tf_dir="$1"
  local expr="$2"
  local out err ec
  err="$(mktemp)" || exit 1
  set +e
  out="$(printf '%s\n' "${expr}" | terraform -chdir="${tf_dir}" console 2>"${err}")"
  ec=$?
  set -e
  if [[ "${ec}" -ne 0 ]]; then
    echo "Error: terraform console failed in ${tf_dir} for expression:" >&2
    echo "  ${expr}" >&2
    cat "${err}" >&2
    rm -f "${err}"
    exit 1
  fi
  rm -f "${err}"
  echo "${out}" | strip_tf_string
}

resolve_terraform_dir() {
  if [[ -n "${terraform_dir_cli}" ]]; then
    echo "${terraform_dir_cli}"
  elif [[ -n "${WIF_UNDELETE_TERRAFORM_DIR:-}" ]]; then
    echo "${WIF_UNDELETE_TERRAFORM_DIR}"
  else
    echo "${ROOT}/wif_config"
  fi
}

list_soft_deleted_full_names_to_file() {
  # Names returned with --show-deleted but not without = soft-deleted custom roles
  # (gcloud table/json output does not expose the API "deleted" boolean reliably).
  local project_id="$1"
  local out_file="$2"
  local active all
  active="$(mktemp)" || exit 1
  all="$(mktemp)" || exit 1
  if ! gcloud iam roles list --project="${project_id}" --format='value(name)' | sort -u >"${active}"; then
    rm -f "${active}" "${all}"
    return 1
  fi
  if ! gcloud iam roles list --project="${project_id}" --show-deleted --format='value(name)' | sort -u >"${all}"; then
    rm -f "${active}" "${all}"
    return 1
  fi
  comm -23 "${all}" "${active}" >"${out_file}"
  rm -f "${active}" "${all}"
}

auto_discover_from_terraform() {
  command -v terraform >/dev/null 2>&1 || {
    echo "Error: terraform not found on PATH (required for auto mode)." >&2
    exit 1
  }

  local tf_dir
  tf_dir="$(resolve_terraform_dir)"
  if [[ ! -d "${tf_dir}" ]]; then
    echo "Error: Terraform directory not found: ${tf_dir}" >&2
    exit 1
  fi

  echo "=== Auto mode: Terraform in ${tf_dir} ==="
  if ! terraform -chdir="${tf_dir}" init -backend=false -input=false -upgrade >/dev/null; then
    echo "Error: terraform init failed in ${tf_dir}" >&2
    exit 1
  fi

  local project_id prefix
  project_id="$(terraform_console "${tf_dir}" "var.gcp_project_id")"
  if [[ -z "${project_id}" ]]; then
    echo "Error: var.gcp_project_id is empty after reading Terraform in ${tf_dir}." >&2
    exit 1
  fi

  prefix="$(terraform_console "${tf_dir}" 'coalesce(var.role_prefix, replace(replace(var.cluster_name, "-", ""), "_", ""))')"
  if [[ -z "${prefix}" ]]; then
    echo "Error: could not compute WIF role prefix from Terraform in ${tf_dir}." >&2
    exit 1
  fi

  echo "GCP project: ${project_id}"
  if [[ "${no_prefix_filter}" -eq 1 ]]; then
    echo "Filter: all soft-deleted custom roles in project (--no-prefix-filter)"
  else
    echo "Role id prefix (from Terraform): ${prefix}"
  fi

  local names_tmp roles_tmp
  names_tmp="$(mktemp)" || exit 1
  roles_tmp="$(mktemp)" || exit 1
  if ! list_soft_deleted_full_names_to_file "${project_id}" "${names_tmp}"; then
    echo "Error: gcloud iam roles list failed for project ${project_id}" >&2
    rm -f "${names_tmp}" "${roles_tmp}"
    exit 1
  fi
  : >"${roles_tmp}"
  while IFS= read -r full_name || [[ -n "${full_name}" ]]; do
    [[ -z "${full_name}" ]] && continue
    rid="${full_name##*/roles/}"
    [[ -z "${rid}" || "${rid}" == "${full_name}" ]] && continue
    if [[ "${no_prefix_filter}" -eq 1 ]]; then
      echo "${rid}" >>"${roles_tmp}"
    elif [[ "${rid}" == "${prefix}"* ]]; then
      echo "${rid}" >>"${roles_tmp}"
    fi
  done <"${names_tmp}"
  sort -u -o "${roles_tmp}" "${roles_tmp}"
  names_nonempty=0
  [[ -s "${names_tmp}" ]] && names_nonempty=1
  rm -f "${names_tmp}"

  if [[ ! -s "${roles_tmp}" ]]; then
    if [[ "${names_nonempty}" -eq 1 ]]; then
      echo "Soft-deleted role(s) were found via list diff, but none matched role_id prefix '${prefix}'."
      echo "Check wif_config cluster_name / role_prefix vs the role_id strings in the Terraform error."
    elif [[ "${no_prefix_filter}" -eq 1 ]]; then
      echo "No soft-deleted custom roles found in ${project_id} (list with --show-deleted minus list without is empty). Nothing to do."
    else
      echo "No soft-deleted custom roles found in ${project_id} with role_id prefix '${prefix}' (list diff is empty)."
      c0="$(gcloud iam roles list --project="${project_id}" --format='value(name)' 2>/dev/null | wc -l | tr -d ' ')"
      c1="$(gcloud iam roles list --project="${project_id}" --show-deleted --format='value(name)' 2>/dev/null | wc -l | tr -d ' ')"
      echo "Diagnostic: custom role count lines without --show-deleted=${c0}, with --show-deleted=${c1}."
      echo "If Terraform still fails with \"marked for deletion\" for those role_ids but"
      echo "  gcloud iam roles describe ROLE_ID --project=${project_id}  → NOT_FOUND, and"
      echo "  gcloud iam roles undelete ROLE_ID --project=${project_id} → NOT_FOUND,"
      echo "then GCP has left the role_id reserved (tombstone) after soft-delete; it no longer appears in"
      echo "iam roles list. Undelete is not possible. Wait until GCP allows reusing the id (often weeks),"
      echo "or use new role_ids if your platform supports changing them. See scripts/README.md (WIF roles section)."
    fi
    rm -f "${roles_tmp}"
    exit 0
  fi

  echo "Roles to undelete:"
  sed 's/^/  /' "${roles_tmp}"

  while IFS= read -r role_id || [[ -n "${role_id}" ]]; do
    [[ -z "${role_id}" ]] && continue
    if run_undelete "${project_id}" "${role_id}"; then
      :
    else
      failures+=("projects/${project_id}/roles/${role_id}")
      if [[ "${continue_on_error}" -ne 1 ]]; then
        rm -f "${roles_tmp}"
        exit 1
      fi
    fi
  done <"${roles_tmp}"
  rm -f "${roles_tmp}"
}

declare -a failures=()

if [[ -n "${from_log}" ]]; then
  if [[ ${#positional[@]} -gt 0 ]]; then
    echo "Error: extra arguments with --from-log are not allowed (got: ${positional[*]})." >&2
    exit 1
  fi
  if [[ ! -f "${from_log}" ]]; then
    echo "Error: log file not found: ${from_log}" >&2
    exit 1
  fi
  lines_tmp="$(mktemp)" || exit 1
  trap 'rm -f "${lines_tmp}"' EXIT
  grep -hoE 'projects/[^/[:space:]]+/roles/[^[:space:]:]+' "${from_log}" | sort -u >"${lines_tmp}" || true
  if [[ ! -s "${lines_tmp}" ]]; then
    echo "Error: no matches for projects/PROJECT/roles/ROLE_ID in ${from_log}" >&2
    exit 1
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" ]] && continue
    project_id="${line#projects/}"
    project_id="${project_id%%/roles/*}"
    role_id="${line##*/roles/}"
    if [[ -z "${project_id}" || -z "${role_id}" || "${project_id}" == "${line}" ]]; then
      echo "Warning: could not parse project/role from: ${line}" >&2
      failures+=("${line}")
      [[ "${continue_on_error}" -eq 1 ]] || exit 1
      continue
    fi
    if run_undelete "${project_id}" "${role_id}"; then
      :
    else
      failures+=("projects/${project_id}/roles/${role_id}")
      if [[ "${continue_on_error}" -ne 1 ]]; then
        exit 1
      fi
    fi
  done <"${lines_tmp}"
  rm -f "${lines_tmp}"
  trap - EXIT
elif [[ ${#positional[@]} -ge 2 ]]; then
  project_id="${positional[0]}"
  for ((i = 1; i < ${#positional[@]}; i++)); do
    role_id="${positional[$i]}"
    if run_undelete "${project_id}" "${role_id}"; then
      :
    else
      failures+=("projects/${project_id}/roles/${role_id}")
      if [[ "${continue_on_error}" -ne 1 ]]; then
        exit 1
      fi
    fi
  done
elif [[ ${#positional[@]} -eq 1 ]]; then
  echo "Error: with manual mode, pass at least PROJECT_ID and one ROLE_ID (got only: ${positional[0]})." >&2
  exit 1
else
  auto_discover_from_terraform
fi

if [[ ${#failures[@]} -gt 0 ]]; then
  echo "The following undelete operations failed:" >&2
  printf '  %s\n' "${failures[@]}" >&2
  exit 1
fi

echo
echo "Done. If Terraform still tries to create these roles, import them or refresh state,"
echo "e.g. terraform import 'module.cluster.module.wif_gcp.google_project_iam_custom_role.wif[\"ROLE_ID\"]' \"projects/PROJECT_ID/roles/ROLE_ID\""
