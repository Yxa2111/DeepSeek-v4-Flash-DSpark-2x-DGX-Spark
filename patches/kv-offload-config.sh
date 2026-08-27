#!/usr/bin/env bash
# Build the experimental runtime argument arrays. Source this file; do not exec it.

dspark_require_uint() {
  local name="$1" value="$2" minimum="$3" maximum="$4"
  if ! [[ "$value" =~ ^[0-9]+$ ]] \
    || (( 10#$value < minimum || 10#$value > maximum )); then
    echo "$name must be an integer between $minimum and $maximum (got: $value)" >&2
    return 2
  fi
}

dspark_require_bool01() {
  local name="$1" value="$2"
  case "$value" in
    0|1) ;;
    *)
      echo "$name must be 0 or 1 (got: $value)" >&2
      return 2
      ;;
  esac
}

dspark_build_experimental_args() {
  KV_TRANSFER_ARGS=()
  SPECULATIVE_ARGS=()
  KV_OFFLOAD_CONFIG=""
  SPECULATIVE_CONFIG=""

  case "${DSPARK_KV_OFFLOAD_DIAG:-0}" in
    0|1) ;;
    *)
      echo "DSPARK_KV_OFFLOAD_DIAG must be 0 or 1 (got: ${DSPARK_KV_OFFLOAD_DIAG})" >&2
      return 2
      ;;
  esac

  case "${KV_OFFLOAD_MODE:-off}" in
    off) ;;
    nvme-local)
      dspark_require_uint KV_OFFLOAD_DISK_BYTES \
        "${KV_OFFLOAD_DISK_BYTES:-68719476736}" 1073741824 171798691840 \
        || return $?
      dspark_require_uint KV_OFFLOAD_DISK_BUFFER_SLOTS \
        "${KV_OFFLOAD_DISK_BUFFER_SLOTS:-2}" 1 8 || return $?
      dspark_require_bool01 KV_OFFLOAD_USE_PAGE_CACHE \
        "${KV_OFFLOAD_USE_PAGE_CACHE:-0}" || return $?
      dspark_require_bool01 KV_OFFLOAD_PREALLOCATE_DISK \
        "${KV_OFFLOAD_PREALLOCATE_DISK:-1}" || return $?

      # The connector keeps only two bounded pinned transfer slots in UMA.
      # expandable_segments may remap registered addresses, so it is unsafe
      # for both local NVMe and the older filesystem tier.
      unset PYTORCH_CUDA_ALLOC_CONF
      KV_OFFLOAD_CONFIG="{\"kv_connector\":\"SimpleCPUOffloadConnector\",\"kv_role\":\"kv_both\",\"kv_connector_extra_config\":{\"kv_offload_backend\":\"disk\",\"disk_path\":\"/kv-offload/vllm-kv.slots\",\"disk_capacity_bytes\":${KV_OFFLOAD_DISK_BYTES:-68719476736},\"disk_buffer_slots\":${KV_OFFLOAD_DISK_BUFFER_SLOTS:-2},\"use_page_cache\":$([ "${KV_OFFLOAD_USE_PAGE_CACHE:-0}" = 1 ] && echo true || echo false),\"preallocate_disk\":$([ "${KV_OFFLOAD_PREALLOCATE_DISK:-1}" = 1 ] && echo true || echo false),\"lazy_offload\":false}}"
      KV_TRANSFER_ARGS=(--kv-transfer-config "$KV_OFFLOAD_CONFIG")
      ;;
    fs-poc|fs-rank0)
      dspark_require_uint KV_OFFLOAD_CPU_BYTES \
        "${KV_OFFLOAD_CPU_BYTES:-536870912}" 67108864 68719476736 || return $?
      dspark_require_uint KV_OFFLOAD_READ_THREADS \
        "${KV_OFFLOAD_READ_THREADS:-8}" 1 128 || return $?
      dspark_require_uint KV_OFFLOAD_WRITE_THREADS \
        "${KV_OFFLOAD_WRITE_THREADS:-4}" 1 128 || return $?
      dspark_require_uint KV_OFFLOAD_PYTHONHASHSEED \
        "${KV_OFFLOAD_PYTHONHASHSEED:-0}" 0 4294967295 || return $?
      dspark_require_uint KV_OFFLOAD_MAX_TRANSFER_CHUNK_BYTES \
        "${KV_OFFLOAD_MAX_TRANSFER_CHUNK_BYTES:-67108864}" 1048576 268435456 || return $?

      # vLLM rejects OffloadingConnector with PyTorch expandable segments:
      # the VMM allocator may remap virtual KV addresses after the connector
      # has pinned/registered them.  This helper runs inside the container
      # immediately before exec'ing vLLM, so mode-local unsetting is enough.
      unset PYTORCH_CUDA_ALLOC_CONF
      export PYTHONHASHSEED="${KV_OFFLOAD_PYTHONHASHSEED:-0}"
      KV_OFFLOAD_CONFIG="{\"kv_connector\":\"OffloadingConnector\",\"kv_role\":\"kv_both\",\"kv_load_failure_policy\":\"recompute\",\"kv_connector_extra_config\":{\"spec_name\":\"TieringOffloadingSpec\",\"cpu_bytes_to_use\":${KV_OFFLOAD_CPU_BYTES:-536870912},\"eviction_policy\":\"lru\",\"distributed_staging\":\"rank0\",\"max_transfer_chunk_bytes\":${KV_OFFLOAD_MAX_TRANSFER_CHUNK_BYTES:-67108864},\"offload_prompt_only\":true,\"secondary_tiers\":[{\"type\":\"fs\",\"root_dir\":\"/kv-offload\",\"n_read_threads\":${KV_OFFLOAD_READ_THREADS:-8},\"n_write_threads\":${KV_OFFLOAD_WRITE_THREADS:-4}}]}}"
      KV_TRANSFER_ARGS=(--kv-transfer-config "$KV_OFFLOAD_CONFIG")
      ;;
    *)
      echo "KV_OFFLOAD_MODE must be one of: off, nvme-local, fs-poc, fs-rank0 (got: ${KV_OFFLOAD_MODE})" >&2
      return 2
      ;;
  esac

  case "${DSPARK_SPECULATION:-dspark}" in
    dspark)
      case "${DRAFT_SAMPLE_METHOD:-probabilistic}" in
        probabilistic|greedy)
          DRAFT_SAMPLE_METHOD="${DRAFT_SAMPLE_METHOD:-probabilistic}"
          ;;
        *)
          echo "DRAFT_SAMPLE_METHOD must be one of: probabilistic, greedy (got: ${DRAFT_SAMPLE_METHOD})" >&2
          return 2
          ;;
      esac
      SPECULATIVE_CONFIG="{\"method\":\"dspark\",\"num_speculative_tokens\":${MTP_NUM_TOKENS:-5},\"draft_sample_method\":\"${DRAFT_SAMPLE_METHOD}\"}"
      SPECULATIVE_ARGS=(--speculative-config "$SPECULATIVE_CONFIG")
      MAX_CUDAGRAPH_CAPTURE_SIZE=$(( ${MAX_NUM_SEQS:-6} * (${MTP_NUM_TOKENS:-5} + 1) ))
      ;;
    off)
      MAX_CUDAGRAPH_CAPTURE_SIZE="${MAX_NUM_SEQS:-6}"
      ;;
    *)
      echo "DSPARK_SPECULATION must be one of: dspark, off (got: ${DSPARK_SPECULATION})" >&2
      return 2
      ;;
  esac
}
