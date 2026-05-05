#!/usr/bin/env Rscript

# routing_component_shares_rtr_groups_h600_by_parts_threads_grpc_total.R
#
# Ziel:
#   Wie routing_component_shares_rtr_groups_h600_by_parts_grpc_total.R, aber
#   zusätzlich nach routing_threads getrennt.
#
#   Außerdem werden gezielt zusätzliche Durchläufe in die RTR-Gruppen aufgenommen:
#
#   Pro Partition:
#     - fastest_10pct:
#         zusätzlich der schnellste Durchlauf mit routing_threads = 1
#
#     - middle_45_to_55pct:
#         zusätzlich der nächstlangsamere und nächstschnellere Durchlauf
#         um die Mitte mit routing_threads = 1
#
#     - slowest_10pct:
#         zusätzlich der langsamste Durchlauf mit routing_threads = 24
#
#   Die zusätzlichen Durchläufe werden nur ergänzt, wenn sie nicht ohnehin schon
#   in der jeweiligen Gruppe enthalten sind.
#
#   gRPC wird direkt zusammengefasst:
#
#     gRPCTotal = gRPCRequest + gRPCResponse
#
#   Dadurch werden gRPCRequest und gRPCResponse nicht getrennt dargestellt,
#   weil sie durch Clock-Offsets zwischen Rust- und Java-Prozess/Node einzeln
#   verfälscht sein können.
#
# Gruppierung:
#   Standardmäßig werden die RTR-Gruppen innerhalb jeder Kombination aus Partitionszahl und Routing-Threads gebildet:
#
#     GROUP_WITHIN_PARTS=1  # deprecated; Gruppierung erfolgt immer innerhalb parts × routing_threads
#
#   Referenz global:
#
#     GROUP_WITHIN_PARTS=0
#
# Komponenten:
#   RustRequest:
#     adapter_sent_request_grpc - route_call_start_realtime
#
#   gRPCTotal:
#     requestDeliveryRustToJavaLatency
#     +
#     (adapter_received_response_grpc - java_routing_service_sent_response_grpc)
#
#   javaTotal:
#     javaTotal aus Java
#
#   RustResponse:
#     (adapter_sent_response_agent - adapter_received_response_grpc)
#     +
#     (agent_replaced_route - agent_received_response_adapter)
#
#   Residual:
#     effective_routing_latency_ms - Summe der Komponenten
#
# Bereitliegezeit:
#   ready_wait_ms =
#     agent_received_response_adapter - adapter_sent_response_agent
#
# Nenner:
#   effective_routing_latency_ms =
#     (agent_replaced_route - route_call_start_realtime) - ready_wait_ms
#
# Aufruf:
#   Rscript R/routing_component_shares_rtr_groups_h600_by_parts_threads_grpc_total.R \
#     output/analysis/file_index_recursive.csv \
#     output/analysis/simulation_runtimes_from_logs.csv \
#     output/analysis/routing_component_shares_rtr_groups_h600_by_parts_threads_grpc_total
#
# Referenz:
#   GROUP_SHARE=0.10
#   GROUP_WITHIN_PARTS=1  # deprecated; Gruppierung erfolgt immer innerhalb parts × routing_threads
#   PARTS_KEEP=1,32,64,192
#   ROUTER_THREADS_KEEP=1,24,48,96
#   INCLUDE_RESIDUAL=1

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(tidyr)
  library(stringr)
  library(ggplot2)
})

args <- commandArgs(trailingOnly = TRUE)

file_index_path <- ifelse(length(args) >= 1, args[[1]], "output/analysis/file_index_recursive.csv")
runtime_file <- ifelse(length(args) >= 2, args[[2]], "output/analysis/simulation_runtimes_from_logs.csv")
out_dir <- ifelse(length(args) >= 3, args[[3]], "output/analysis/routing_component_shares_rtr_groups_h600_by_parts_threads_grpc_total")

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

if (!file.exists(file_index_path)) {
  stop("File index not found: ", file_index_path)
}
if (!file.exists(runtime_file)) {
  stop("Runtime file not found: ", runtime_file)
}

has_data_table <- requireNamespace("data.table", quietly = TRUE)

group_share <- suppressWarnings(as.numeric(Sys.getenv("GROUP_SHARE", "0.10")))
group_within_parts <- Sys.getenv("GROUP_WITHIN_PARTS", "1") == "1"
include_residual <- Sys.getenv("INCLUDE_RESIDUAL", "1") == "1"

if (!is.finite(group_share) || group_share <= 0 || group_share >= 0.5) {
  stop("GROUP_SHARE must be > 0 and < 0.5. Default is 0.10.")
}

parse_keep_int <- function(x) {
  if (is.na(x) || !nzchar(x)) return(NULL)
  as.integer(trimws(strsplit(x, ",", fixed = TRUE)[[1]]))
}

parts_keep <- parse_keep_int(Sys.getenv("PARTS_KEEP", ""))
router_threads_keep <- parse_keep_int(Sys.getenv("ROUTER_THREADS_KEEP", ""))

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

read_csv_fast <- function(path) {
  if (has_data_table) {
    dat <- as_tibble(data.table::fread(path, showProgress = FALSE))
  } else {
    dat <- readr::read_csv(path, show_col_types = FALSE, progress = FALSE)
  }

  if (requireNamespace("bit64", quietly = TRUE)) {
    int64_cols <- names(dat)[vapply(dat, function(z) inherits(z, "integer64"), logical(1))]
    if (length(int64_cols) > 0) {
      dat[int64_cols] <- lapply(dat[int64_cols], function(z) as.numeric(z))
    }
  }

  dat
}

pick_col <- function(df, candidates, required = TRUE) {
  hit <- candidates[candidates %in% names(df)]
  if (length(hit) > 0) return(hit[[1]])
  if (required) stop("Missing required column. Tried: ", paste(candidates, collapse = ", "))
  NA_character_
}

safe_num <- function(df, col) {
  if (!is.na(col) && col %in% names(df)) {
    suppressWarnings(as.numeric(df[[col]]))
  } else {
    rep(NA_real_, nrow(df))
  }
}

duration_ms <- function(end_ns, start_ns, allow_negative = FALSE) {
  x <- (end_ns - start_ns) / 1e6
  if (allow_negative) return(ifelse(is.finite(x), x, NA_real_))
  ifelse(is.finite(x) & x >= 0, x, NA_real_)
}

clean_duration <- function(x, max_ms = 10 * 60 * 1000, allow_negative = FALSE) {
  if (allow_negative) return(ifelse(is.finite(x) & abs(x) <= max_ms, x, NA_real_))
  ifelse(is.finite(x) & x >= 0 & x <= max_ms, x, NA_real_)
}

ns_to_ms_col <- function(df, col) {
  if (!(col %in% names(df))) return(rep(NA_real_, nrow(df)))
  suppressWarnings(as.numeric(df[[col]])) / 1e6
}

write_markdown <- function(df, path) {
  lines <- c(
    paste0("| ", paste(names(df), collapse = " | "), " |"),
    paste0("| ", paste(rep("---", ncol(df)), collapse = " | "), " |")
  )
  for (i in seq_len(nrow(df))) {
    lines <- c(lines, paste0("| ", paste(as.character(df[i, ]), collapse = " | "), " |"))
  }
  writeLines(lines, path)
}

latex_escape <- function(x) {
  x <- as.character(x)
  x <- str_replace_all(x, fixed("_"), "\\\\_")
}

write_latex <- function(df, path, caption, label) {
  align <- paste(rep("r", ncol(df)), collapse = "")
  lines <- c(
    "\\begin{table}[htbp]",
    "\\centering",
    paste0("\\caption{", caption, "}"),
    paste0("\\label{", label, "}"),
    paste0("\\begin{tabular}{", align, "}"),
    "\\hline",
    paste0(paste(latex_escape(names(df)), collapse = " & "), " \\\\"),
    "\\hline"
  )
  for (i in seq_len(nrow(df))) {
    lines <- c(lines, paste0(paste(latex_escape(df[i, ]), collapse = " & "), " \\\\"))
  }
  lines <- c(lines, "\\hline", "\\end{tabular}", "\\end{table}")
  writeLines(lines, path)
}

# ------------------------------------------------------------
# Metric extraction
# ------------------------------------------------------------

compute_rust_metrics <- function(path) {
  rust <- read_csv_fast(path)

  required <- c(
    "id",
    "route_call_start_realtime",
    "adapter_sent_request_grpc",
    "java_routing_service_sent_response_grpc",
    "adapter_received_response_grpc",
    "adapter_sent_response_agent",
    "agent_received_response_adapter",
    "agent_replaced_route"
  )

  missing <- setdiff(required, names(rust))
  if (length(missing) > 0) {
    stop("Rust file missing columns: ", paste(missing, collapse = ", "))
  }

  route_call_start <- safe_num(rust, "route_call_start_realtime")
  adapter_sent_request <- safe_num(rust, "adapter_sent_request_grpc")
  java_sent_response <- safe_num(rust, "java_routing_service_sent_response_grpc")
  adapter_received_response <- safe_num(rust, "adapter_received_response_grpc")
  adapter_sent_response <- safe_num(rust, "adapter_sent_response_agent")
  agent_received_response <- safe_num(rust, "agent_received_response_adapter")
  agent_replaced_route <- safe_num(rust, "agent_replaced_route")

  ready_wait_ms <- duration_ms(agent_received_response, adapter_sent_response)

  effective_routing_latency_ms <-
    duration_ms(agent_replaced_route, route_call_start) - ready_wait_ms

  effective_routing_latency_ms_alt <-
    duration_ms(adapter_sent_response, route_call_start) +
    duration_ms(agent_replaced_route, agent_received_response)

  rust_request_ms <- duration_ms(adapter_sent_request, route_call_start)

  # Kann wegen verschiedener Clocks negativ sein; wird später mit gRPCRequest summiert.
  grpc_response_ms <- duration_ms(adapter_received_response, java_sent_response, allow_negative = TRUE)

  rust_response_ms <-
    duration_ms(adapter_sent_response, adapter_received_response) +
    duration_ms(agent_replaced_route, agent_received_response)

  tibble(
    request_id = as.character(rust$id),
    effective_routing_latency_ms = clean_duration(effective_routing_latency_ms),
    effective_routing_latency_ms_alt = clean_duration(effective_routing_latency_ms_alt),
    ready_wait_ms = clean_duration(ready_wait_ms),
    RustRequest_ms = clean_duration(rust_request_ms),
    gRPCResponse_ms = clean_duration(grpc_response_ms, allow_negative = TRUE),
    RustResponse_ms = clean_duration(rust_response_ms)
  )
}

compute_java_metrics <- function(path) {
  java <- read_csv_fast(path)

  required <- c("requestId", "requestDeliveryRustToJavaLatency", "javaTotal")
  missing <- setdiff(required, names(java))
  if (length(missing) > 0) {
    stop("Java file missing columns: ", paste(missing, collapse = ", "))
  }

  tibble(
    request_id = as.character(java$requestId),
    gRPCRequest_ms = clean_duration(ns_to_ms_col(java, "requestDeliveryRustToJavaLatency")),
    javaTotal_ms = clean_duration(ns_to_ms_col(java, "javaTotal"))
  )
}

# ------------------------------------------------------------
# 1) Build Horizon=600 runtime groups by RTR
# ------------------------------------------------------------

message("Reading runtime file: ", runtime_file)
rt_raw <- readr::read_csv(runtime_file, show_col_types = FALSE)

col_parts <- pick_col(rt_raw, c("parts", "sim_cpus", "SIM_CPUS", "partition_count", "partitionCount"))
col_horizon <- pick_col(rt_raw, c("horizon", "HORIZON", "preplanning_horizon", "PH", "pH"))
col_router <- pick_col(rt_raw, c("router_threads", "ROUTER_THREADS", "routing_threads", "threads"))
col_batch <- pick_col(rt_raw, c("batch_size", "BATCH_SIZE", "batchSize", "batch"))
col_runtime <- pick_col(rt_raw, c("runtime_s", "runtime_sec", "walltime_s", "elapsed_s", "duration_s"), required = FALSE)
col_rtr <- pick_col(rt_raw, c("rtr", "RTR", "real_time_ratio", "realTimeRatio"), required = FALSE)
col_parse <- pick_col(rt_raw, c("parse_status"), required = FALSE)
col_completed <- pick_col(rt_raw, c("completed"), required = FALSE)

runtime_data <- rt_raw %>%
  mutate(
    horizon = suppressWarnings(as.integer(.data[[col_horizon]])),
    batch_size = suppressWarnings(as.integer(.data[[col_batch]])),
    parts = suppressWarnings(as.integer(.data[[col_parts]])),
    router_threads = suppressWarnings(as.integer(.data[[col_router]])),
    runtime_s = if (!is.na(col_runtime)) suppressWarnings(as.numeric(.data[[col_runtime]])) else NA_real_,
    RTR = if (!is.na(col_rtr)) suppressWarnings(as.numeric(.data[[col_rtr]])) else NA_real_,
    parse_status = if (!is.na(col_parse)) as.character(.data[[col_parse]]) else "ok",
    completed = if (!is.na(col_completed)) as.logical(.data[[col_completed]]) else TRUE
  ) %>%
  mutate(
    RTR = ifelse(is.na(RTR) & !is.na(runtime_s) & runtime_s > 0, 86400 / runtime_s, RTR)
  ) %>%
  filter(
    horizon == 600,
    parse_status == "ok",
    completed == TRUE,
    !is.na(RTR),
    RTR > 0,
    !is.na(batch_size),
    !is.na(parts),
    !is.na(router_threads)
  )

if (!is.null(parts_keep)) {
  runtime_data <- runtime_data %>% filter(parts %in% parts_keep)
}
if (!is.null(router_threads_keep)) {
  runtime_data <- runtime_data %>% filter(router_threads %in% router_threads_keep)
}

if (nrow(runtime_data) == 0) {
  stop("No completed Horizon=600 runs with valid RTR found in runtime file.")
}

group_levels <- c("slowest_10pct", "middle_45_to_55pct", "fastest_10pct")

select_groups_one_block <- function(df) {
  df <- df %>%
    arrange(RTR) %>%
    mutate(
      run_rank_by_rtr_ascending = row_number(),
      n_group_base_runs = n(),
      rank_midpoint_pct = (run_rank_by_rtr_ascending - 0.5) / n_group_base_runs
    )

  n_group <- max(1L, ceiling(nrow(df) * group_share))

  slowest <- df %>%
    slice_head(n = n_group) %>%
    mutate(
      rtr_group = "slowest_10pct",
      selection_reason = "base_slowest_10pct"
    )

  fastest <- df %>%
    slice_tail(n = n_group) %>%
    mutate(
      rtr_group = "fastest_10pct",
      selection_reason = "base_fastest_10pct"
    )

  middle_by_interval <- df %>%
    filter(rank_midpoint_pct >= 0.45, rank_midpoint_pct <= 0.55) %>%
    mutate(
      rtr_group = "middle_45_to_55pct",
      selection_reason = "base_middle_45_to_55pct"
    )

  if (nrow(middle_by_interval) < n_group) {
    middle <- df %>%
      mutate(distance_to_middle = abs(rank_midpoint_pct - 0.5)) %>%
      arrange(distance_to_middle, run_rank_by_rtr_ascending) %>%
      slice_head(n = n_group) %>%
      arrange(run_rank_by_rtr_ascending) %>%
      mutate(
        rtr_group = "middle_45_to_55pct",
        selection_reason = "base_middle_closest"
      )
  } else {
    middle <- middle_by_interval
  }

  bind_rows(
    slowest,
    middle,
    fastest
  ) %>%
    distinct(
      rtr_group, horizon, batch_size, parts, router_threads, RTR, runtime_s,
      .keep_all = TRUE
    )
}

selected_runs <- runtime_data %>%
  group_by(parts, router_threads) %>%
  group_split() %>%
  lapply(select_groups_one_block) %>%
  bind_rows()

selected_runs <- selected_runs %>%
  arrange(
    parts,
    router_threads,
    factor(rtr_group, levels = group_levels),
    run_rank_by_rtr_ascending
  )

# Dokumentiere, welche Runs auf welcher Basis ausgewählt wurden.
selection_audit <- selected_runs %>%
  select(
    rtr_group, selection_reason,
    horizon, batch_size, parts, router_threads, RTR, runtime_s,
    run_rank_by_rtr_ascending, rank_midpoint_pct
  ) %>%
  arrange(parts, router_threads, rtr_group, run_rank_by_rtr_ascending)

group_thresholds <- selected_runs %>%
  group_by(parts, router_threads, rtr_group) %>%
  summarise(
    n_selected_runs = n(),
    rtr_min = min(RTR, na.rm = TRUE),
    rtr_median = median(RTR, na.rm = TRUE),
    rtr_max = max(RTR, na.rm = TRUE),
    rank_min = min(run_rank_by_rtr_ascending),
    rank_max = max(run_rank_by_rtr_ascending),
    pct_min = min(rank_midpoint_pct),
    pct_max = max(rank_midpoint_pct),
    .groups = "drop"
  ) %>%
  mutate(across(where(is.numeric), ~ round(.x, 6))) %>%
  arrange(parts, router_threads, factor(rtr_group, levels = group_levels))

selected_run_counts <- selected_runs %>%
  count(parts, router_threads, rtr_group, name = "n_selected_runs") %>%
  arrange(parts, router_threads, factor(rtr_group, levels = group_levels))

runtime_ranked <- runtime_data %>%
  group_by(parts, router_threads) %>%
  arrange(RTR, .by_group = TRUE) %>%
  mutate(
    run_rank_by_rtr_ascending_within_parts_threads = row_number(),
    n_runs_within_parts_threads = n(),
    rank_midpoint_pct_within_parts_threads = (run_rank_by_rtr_ascending_within_parts_threads - 0.5) / n_runs_within_parts_threads
  ) %>%
  ungroup()

readr::write_csv(runtime_ranked, file.path(out_dir, "h600_runtime_runs_ranked_by_rtr_by_parts_threads.csv"))
readr::write_csv(selected_runs, file.path(out_dir, "selected_rtr_group_runs_h600_by_parts_threads.csv"))
readr::write_csv(selection_audit, file.path(out_dir, "selected_rtr_group_runs_audit_h600_by_parts_threads.csv"))
readr::write_csv(group_thresholds, file.path(out_dir, "rtr_group_thresholds_h600_by_parts_threads.csv"))
readr::write_csv(selected_run_counts, file.path(out_dir, "selected_run_counts_by_parts_threads_group.csv"))

message("Horizon=600 runs with RTR: ", nrow(runtime_data))
message("Grouping within parts × routing_threads: TRUE")
print(selected_run_counts)

# ------------------------------------------------------------
# 2) Pair selected runs with Rust/Java routing files
# ------------------------------------------------------------

message("Reading file index: ", file_index_path)
idx <- readr::read_csv(file_index_path, show_col_types = FALSE)

required_index <- c("file", "file_type", "horizon", "parts", "router_threads", "batch_size", "config_key")
missing_index <- setdiff(required_index, names(idx))
if (length(missing_index) > 0) {
  stop("Missing required columns in file index: ", paste(missing_index, collapse = ", "))
}

idx <- idx %>%
  filter(file_type %in% c("rust_routing", "java_routing")) %>%
  mutate(
    horizon = as.integer(horizon),
    batch_size = as.integer(batch_size),
    router_threads = as.integer(router_threads),
    parts = as.integer(parts)
  ) %>%
  filter(horizon == 600)

if (!is.null(parts_keep)) {
  idx <- idx %>% filter(parts %in% parts_keep)
}
if (!is.null(router_threads_keep)) {
  idx <- idx %>% filter(router_threads %in% router_threads_keep)
}

selected_keys <- selected_runs %>%
  distinct(
    rtr_group, selection_reason,
    horizon, batch_size, parts, router_threads, RTR, runtime_s,
    run_rank_by_rtr_ascending
  )

rust_pairs <- idx %>%
  filter(file_type == "rust_routing") %>%
  arrange(horizon, batch_size, parts, router_threads, file) %>%
  group_by(horizon, batch_size, parts, router_threads) %>%
  summarise(
    rust_file = first(file),
    rust_config_key = first(config_key),
    n_rust_files = n(),
    .groups = "drop"
  )

java_pairs <- idx %>%
  filter(file_type == "java_routing") %>%
  arrange(horizon, batch_size, parts, router_threads, file) %>%
  group_by(horizon, batch_size, parts, router_threads) %>%
  summarise(
    java_file = first(file),
    java_config_key = first(config_key),
    n_java_files = n(),
    .groups = "drop"
  )

pairs <- selected_keys %>%
  left_join(rust_pairs, by = c("horizon", "batch_size", "parts", "router_threads")) %>%
  left_join(java_pairs, by = c("horizon", "batch_size", "parts", "router_threads")) %>%
  arrange(
    parts,
    router_threads,
    factor(rtr_group, levels = group_levels),
    run_rank_by_rtr_ascending
  )

readr::write_csv(pairs, file.path(out_dir, "selected_rtr_group_file_pairs_h600_by_parts_threads.csv"))

if (any(is.na(pairs$rust_file))) {
  warning("Some selected runs have no rust_routing file. See selected_rtr_group_file_pairs_h600_by_parts_threads.csv")
}
if (any(is.na(pairs$java_file))) {
  warning("Some selected runs have no java_routing file. Java components will be missing for those runs.")
}

# ------------------------------------------------------------
# 3) Per-run summaries, then aggregate by parts, routing_threads, RTR group
# ------------------------------------------------------------

run_summaries <- list()
diagnostics <- list()
errors <- list()

for (i in seq_len(nrow(pairs))) {
  p <- pairs[i, ]
  group_name <- p$rtr_group[[1]]

  if (is.na(p$rust_file[[1]])) {
    errors[[length(errors) + 1]] <- tibble(
      phase = "pairing",
      rtr_group = group_name,
      selection_reason = p$selection_reason[[1]],
      horizon = p$horizon[[1]],
      batch_size = p$batch_size[[1]],
      parts = p$parts[[1]],
      router_threads = p$router_threads[[1]],
      rust_file = NA_character_,
      java_file = p$java_file[[1]],
      error = "No rust_routing file for selected run"
    )
    next
  }

  message(sprintf(
    "[%d/%d] parts=%s | routing_threads=%s | %s | RTR %.4f | %s",
    i, nrow(pairs), p$parts[[1]], p$router_threads[[1]],
    group_name, p$RTR[[1]], basename(p$rust_file[[1]])
  ))

  tryCatch({
    rust_metrics <- compute_rust_metrics(p$rust_file[[1]])

    if (!is.na(p$java_file[[1]]) && file.exists(p$java_file[[1]])) {
      java_metrics <- compute_java_metrics(p$java_file[[1]])

      joined <- rust_metrics %>%
        left_join(java_metrics, by = "request_id")

      join_method <- "rust_id_to_java_requestId"
      n_java_rows <- nrow(java_metrics)
    } else {
      joined <- rust_metrics %>%
        mutate(gRPCRequest_ms = NA_real_, javaTotal_ms = NA_real_)

      join_method <- "no_java_file"
      n_java_rows <- NA_integer_
    }

    joined <- joined %>%
      mutate(
        gRPCTotal_ms = gRPCRequest_ms + gRPCResponse_ms,
        component_sum_ms =
          RustRequest_ms +
          gRPCTotal_ms +
          javaTotal_ms +
          RustResponse_ms,
        residual_ms = effective_routing_latency_ms - component_sum_ms,
        complete_components =
          is.finite(effective_routing_latency_ms) &
            is.finite(ready_wait_ms) &
            is.finite(RustRequest_ms) &
            is.finite(gRPCRequest_ms) &
            is.finite(gRPCResponse_ms) &
            is.finite(gRPCTotal_ms) &
            is.finite(javaTotal_ms) &
            is.finite(RustResponse_ms) &
            is.finite(component_sum_ms) &
            is.finite(residual_ms)
      )

    sub <- joined %>% filter(complete_components)

    run_summaries[[length(run_summaries) + 1]] <- tibble(
      rtr_group = group_name,
      selection_reason = p$selection_reason[[1]],
      horizon = p$horizon[[1]],
      batch_size = p$batch_size[[1]],
      parts = p$parts[[1]],
      router_threads = p$router_threads[[1]],
      RTR = p$RTR[[1]],
      runtime_s = p$runtime_s[[1]],
      rust_file = p$rust_file[[1]],
      java_file = p$java_file[[1]],

      n_requests = nrow(joined),
      n_complete_component_rows = nrow(sub),

      denominator_sum_ms = sum(sub$effective_routing_latency_ms, na.rm = TRUE),
      ready_wait_sum_ms = sum(sub$ready_wait_ms, na.rm = TRUE),

      RustRequest_sum_ms = sum(sub$RustRequest_ms, na.rm = TRUE),
      gRPCRequest_sum_ms = sum(sub$gRPCRequest_ms, na.rm = TRUE),
      gRPCResponse_sum_ms = sum(sub$gRPCResponse_ms, na.rm = TRUE),
      gRPCTotal_sum_ms = sum(sub$gRPCTotal_ms, na.rm = TRUE),
      javaTotal_sum_ms = sum(sub$javaTotal_ms, na.rm = TRUE),
      RustResponse_sum_ms = sum(sub$RustResponse_ms, na.rm = TRUE),

      component_sum_ms = sum(sub$component_sum_ms, na.rm = TRUE),
      residual_sum_ms = sum(sub$residual_ms, na.rm = TRUE),

      denominator_median_ms = median(sub$effective_routing_latency_ms, na.rm = TRUE),
      RustRequest_median_ms = median(sub$RustRequest_ms, na.rm = TRUE),
      gRPCTotal_median_ms = median(sub$gRPCTotal_ms, na.rm = TRUE),
      javaTotal_median_ms = median(sub$javaTotal_ms, na.rm = TRUE),
      RustResponse_median_ms = median(sub$RustResponse_ms, na.rm = TRUE),
      residual_median_ms = median(sub$residual_ms, na.rm = TRUE),

      RustRequest_share_pct = 100 * sum(sub$RustRequest_ms, na.rm = TRUE) / sum(sub$effective_routing_latency_ms, na.rm = TRUE),
      gRPCTotal_share_pct = 100 * sum(sub$gRPCTotal_ms, na.rm = TRUE) / sum(sub$effective_routing_latency_ms, na.rm = TRUE),
      javaTotal_share_pct = 100 * sum(sub$javaTotal_ms, na.rm = TRUE) / sum(sub$effective_routing_latency_ms, na.rm = TRUE),
      RustResponse_share_pct = 100 * sum(sub$RustResponse_ms, na.rm = TRUE) / sum(sub$effective_routing_latency_ms, na.rm = TRUE),
      Residual_share_pct = 100 * sum(sub$residual_ms, na.rm = TRUE) / sum(sub$effective_routing_latency_ms, na.rm = TRUE)
    )

    diagnostics[[length(diagnostics) + 1]] <- tibble(
      rtr_group = group_name,
      selection_reason = p$selection_reason[[1]],
      horizon = p$horizon[[1]],
      batch_size = p$batch_size[[1]],
      parts = p$parts[[1]],
      router_threads = p$router_threads[[1]],
      RTR = p$RTR[[1]],
      runtime_s = p$runtime_s[[1]],
      run_rank_by_rtr_ascending = p$run_rank_by_rtr_ascending[[1]],
      rust_file = p$rust_file[[1]],
      java_file = p$java_file[[1]],
      join_method = join_method,
      n_rust_rows = nrow(rust_metrics),
      n_java_rows = n_java_rows,
      n_joined_java = sum(is.finite(joined$javaTotal_ms)),
      n_complete_components = nrow(sub),
      complete_component_row_share = nrow(sub) / nrow(joined),
      component_sum_share_pct =
        100 * sum(sub$component_sum_ms, na.rm = TRUE) / sum(sub$effective_routing_latency_ms, na.rm = TRUE),
      residual_share_pct =
        100 * sum(sub$residual_ms, na.rm = TRUE) / sum(sub$effective_routing_latency_ms, na.rm = TRUE),
      denominator_alt_abs_diff_max_ms = suppressWarnings(max(abs(
        joined$effective_routing_latency_ms - joined$effective_routing_latency_ms_alt
      ), na.rm = TRUE)),
      gRPCRequest_median_ms = median(sub$gRPCRequest_ms, na.rm = TRUE),
      gRPCResponse_median_ms = median(sub$gRPCResponse_ms, na.rm = TRUE),
      gRPCTotal_median_ms = median(sub$gRPCTotal_ms, na.rm = TRUE)
    )
  }, error = function(e) {
    errors[[length(errors) + 1]] <<- tibble(
      phase = "aggregate",
      rtr_group = group_name,
      selection_reason = p$selection_reason[[1]],
      horizon = p$horizon[[1]],
      batch_size = p$batch_size[[1]],
      parts = p$parts[[1]],
      router_threads = p$router_threads[[1]],
      rust_file = p$rust_file[[1]],
      java_file = p$java_file[[1]],
      error = conditionMessage(e)
    )
  })

  gc(verbose = FALSE)
}

run_summary_df <- bind_rows(run_summaries)

if (nrow(run_summary_df) == 0) {
  stop("No usable routing component summaries were produced.")
}

readr::write_csv(run_summary_df, file.path(out_dir, "per_run_routing_component_summaries_h600_by_parts_threads_grpc_total.csv"))

run_level_component_long <- run_summary_df %>%
  select(
    parts, router_threads, rtr_group, selection_reason, RTR, runtime_s,
    n_requests, n_complete_component_rows,
    denominator_median_ms,
    RustRequest_median_ms,
    gRPCTotal_median_ms,
    javaTotal_median_ms,
    RustResponse_median_ms,
    residual_median_ms,
    RustRequest_share_pct,
    gRPCTotal_share_pct,
    javaTotal_share_pct,
    RustResponse_share_pct,
    Residual_share_pct
  ) %>%
  pivot_longer(
    cols = c(
      RustRequest_share_pct,
      gRPCTotal_share_pct,
      javaTotal_share_pct,
      RustResponse_share_pct,
      Residual_share_pct
    ),
    names_to = "component",
    values_to = "relative_share_pct"
  ) %>%
  mutate(
    component = str_replace(component, "_share_pct$", "")
  ) %>%
  left_join(
    run_summary_df %>%
      select(
        parts, router_threads, rtr_group, selection_reason, RTR,
        RustRequest_median_ms,
        gRPCTotal_median_ms,
        javaTotal_median_ms,
        RustResponse_median_ms,
        residual_median_ms
      ) %>%
      pivot_longer(
        cols = c(
          RustRequest_median_ms,
          gRPCTotal_median_ms,
          javaTotal_median_ms,
          RustResponse_median_ms,
          residual_median_ms
        ),
        names_to = "component",
        values_to = "component_median_ms"
      ) %>%
      mutate(
        component = str_replace(component, "_median_ms$", ""),
        component = recode(component, residual = "Residual")
      ),
    by = c("parts", "router_threads", "rtr_group", "selection_reason", "RTR", "component")
  )

if (!include_residual) {
  run_level_component_long <- run_level_component_long %>% filter(component != "Residual")
}

component_order <- c("RustRequest", "gRPCTotal", "javaTotal", "RustResponse", "Residual")

component_share_table <- run_level_component_long %>%
  group_by(parts, router_threads, rtr_group, component) %>%
  summarise(
    n_selected_runs = n_distinct(paste(selection_reason, RTR, runtime_s, sep = "|")),
    n_requests = sum(n_requests, na.rm = TRUE),
    n_complete_component_rows = sum(n_complete_component_rows, na.rm = TRUE),
    median_denominator_ms = median(denominator_median_ms, na.rm = TRUE),
    median_component_ms = median(component_median_ms, na.rm = TRUE),
    relative_share_pct = median(relative_share_pct, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(
    rtr_group = factor(rtr_group, levels = group_levels),
    parts = as.integer(parts),
    router_threads = as.integer(router_threads),
    across(c(median_denominator_ms, median_component_ms, relative_share_pct), ~ round(.x, 6))
  ) %>%
  arrange(parts, router_threads, rtr_group, factor(component, levels = component_order))

acc_df <- component_share_table %>%
  group_by(parts, router_threads, rtr_group) %>%
  summarise(
    n_selected_runs = max(n_selected_runs, na.rm = TRUE),
    n_requests = max(n_requests, na.rm = TRUE),
    n_complete_component_rows = max(n_complete_component_rows, na.rm = TRUE),
    median_denominator_ms = median(median_denominator_ms, na.rm = TRUE),
    median_gRPCTotal_ms = median(median_component_ms[component == "gRPCTotal"], na.rm = TRUE),
    .groups = "drop"
  )

# Für Diagnostics werden zusätzlich RTR-Bereiche pro parts/router_threads/rtr_group berechnet.
run_group_ranges <- selected_runs %>%
  group_by(parts, router_threads, rtr_group) %>%
  summarise(
    rtr_min_selected = min(RTR, na.rm = TRUE),
    rtr_median_selected = median(RTR, na.rm = TRUE),
    rtr_max_selected = max(RTR, na.rm = TRUE),
    n_selected_runs_from_selection = n(),
    .groups = "drop"
  )

group_diagnostics <- acc_df %>%
  left_join(run_group_ranges, by = c("parts", "router_threads", "rtr_group")) %>%
  mutate(
    complete_component_row_share = n_complete_component_rows / n_requests
  ) %>%
  arrange(parts, router_threads, factor(rtr_group, levels = group_levels))

file_diagnostics_base_cols <- c(
  "parts",
  "router_threads",
  "rtr_group",
  "selection_reason",
  "RTR",
  "runtime_s",
  "horizon",
  "batch_size",
  "source_file",
  "rust_routing_file",
  "java_routing_file",
  "config_key",
  "run_id",
  "n_requests",
  "n_complete_component_rows",
  "denominator_median_ms",
  "RustRequest_median_ms",
  "gRPCTotal_median_ms",
  "javaTotal_median_ms",
  "RustResponse_median_ms",
  "residual_median_ms",
  "RustRequest_share_pct",
  "gRPCTotal_share_pct",
  "javaTotal_share_pct",
  "RustResponse_share_pct",
  "Residual_share_pct"
)

file_diagnostics <- run_summary_df %>%
  select(any_of(file_diagnostics_base_cols)) %>%
  mutate(
    complete_component_row_share = if (
      all(c("n_complete_component_rows", "n_requests") %in% names(.))
    ) {
      n_complete_component_rows / n_requests
    } else {
      NA_real_
    }
  ) %>%
  arrange(
    parts,
    router_threads,
    factor(rtr_group, levels = group_levels),
    RTR
  )

if (!exists("processing_errors", inherits = FALSE)) {
  processing_errors <- tibble::tibble(
    parts = integer(),
    router_threads = integer(),
    rtr_group = character(),
    file = character(),
    error = character()
  )
}

readr::write_csv(group_diagnostics, file.path(out_dir, "group_diagnostics_by_parts_threads_grpc_total.csv"))
readr::write_csv(file_diagnostics, file.path(out_dir, "file_diagnostics_by_parts_threads_grpc_total.csv"))
readr::write_csv(processing_errors, file.path(out_dir, "processing_errors.csv"))

write_markdown(component_share_table, file.path(out_dir, "routing_component_share_table_rtr_groups_h600_by_parts_threads_grpc_total.md"))
write_latex(
  component_share_table,
  file.path(out_dir, "routing_component_share_table_rtr_groups_h600_by_parts_threads_grpc_total.tex"),
  "Relative Zeitanteile der Routing-Komponenten für RTR-Gruppen, Partitionen und Routing-Threads bei Horizon 600 mit zusammengefasster gRPC-Komponente.",
  "tab:routing-component-shares-rtr-groups-h600-by-parts-threads-grpc-total"
)


save_plot_with_emf <- function(plot, filename_base, width, height, dpi = 200) {
  png_file <- file.path(out_dir, paste0(filename_base, ".png"))
  pdf_file <- file.path(out_dir, paste0(filename_base, ".pdf"))
  emf_file <- file.path(out_dir, paste0(filename_base, ".emf"))

  ggsave(png_file, plot, width = width, height = height, dpi = dpi)
  ggsave(pdf_file, plot, width = width, height = height)

  if (requireNamespace("devEMF", quietly = TRUE)) {
    devEMF::emf(file = emf_file, width = width, height = height, bg = "white")
    print(plot)
    grDevices::dev.off()
  } else {
    message("Paket 'devEMF' nicht installiert; EMF wird übersprungen für: ", filename_base,
            ". Installation: install.packages('devEMF')")
  }
}

plot_data <- component_share_table %>%
  filter(component != "Residual") %>%
  mutate(
    rtr_group = factor(rtr_group, levels = group_levels),
    component = factor(component, levels = component_order),
    parts_f = factor(parts, levels = sort(unique(parts))),
    router_threads_f = factor(router_threads, levels = sort(unique(router_threads)))
  )

p_share <- ggplot(plot_data, aes(x = component, y = relative_share_pct, fill = rtr_group)) +
  geom_col(position = position_dodge(width = 0.8)) +
  facet_grid(parts_f ~ router_threads_f, labeller = labeller(
    parts_f = function(x) paste0("parts=", x),
    router_threads_f = function(x) paste0("rt=", x)
  )) +
  labs(
    title = "Relative Zeitanteile der Routing-Komponenten nach Partitionen und Routing-Threads",
    subtitle = paste0(
      "Horizon = 600; gRPC als gRPCTotal; RTR-Gruppen ",
      "innerhalb jeder Kombination aus Partitionszahl und Routing-Threads",
      "; Medianaggregation"
    ),
    x = "Komponente",
    y = "Anteil an effektiver Routing-End-to-End-Zeit [%]",
    fill = "RTR-Gruppe"
  ) +
  theme_bw() +
  theme(
    legend.position = "bottom",
    axis.text.x = element_text(angle = 35, hjust = 1)
  )

save_plot_with_emf(p_share, "routing_component_share_grouped_bar_rtr_groups_h600_by_parts_threads_grpc_total", width = 16, height = 12, dpi = 200)

p_ms <- ggplot(plot_data, aes(x = component, y = median_component_ms, fill = rtr_group)) +
  geom_col(position = position_dodge(width = 0.8)) +
  facet_grid(parts_f ~ router_threads_f, scales = "free_y", labeller = labeller(
    parts_f = function(x) paste0("parts=", x),
    router_threads_f = function(x) paste0("rt=", x)
  )) +
  labs(
    title = "Mittlere Dauer der Routing-Komponenten nach Partitionen und Routing-Threads",
    subtitle = paste0(
      "Horizon = 600; gRPC als gRPCTotal; RTR-Gruppen ",
      "innerhalb jeder Kombination aus Partitionszahl und Routing-Threads",
      "; Medianaggregation"
    ),
    x = "Komponente",
    y = "Mittlere Dauer [ms]",
    fill = "RTR-Gruppe"
  ) +
  theme_bw() +
  theme(
    legend.position = "bottom",
    axis.text.x = element_text(angle = 35, hjust = 1)
  )

save_plot_with_emf(p_ms, "routing_component_median_ms_grouped_bar_rtr_groups_h600_by_parts_threads_grpc_total", width = 16, height = 12, dpi = 200)

# Zusatzplot: effektive Routinglatenz nach Partitionen und Routing-Threads
denom_plot <- group_diagnostics %>%
  mutate(
    rtr_group = factor(rtr_group, levels = group_levels),
    parts_f = factor(parts, levels = sort(unique(parts))),
    router_threads_f = factor(router_threads, levels = sort(unique(router_threads)))
  )

p_denom <- ggplot(denom_plot, aes(x = router_threads_f, y = median_denominator_ms, fill = rtr_group)) +
  geom_col(position = position_dodge(width = 0.8)) +
  facet_wrap(~ parts_f, labeller = labeller(parts_f = function(x) paste0("parts=", x))) +
  labs(
    title = "Effektive Routing-End-to-End-Zeit nach Partitionen und Routing-Threads",
    subtitle = "Horizon = 600; ohne Bereitliegezeit",
    x = "Routing-Threads",
    y = "median effective routing latency [ms]",
    fill = "RTR-Gruppe"
  ) +
  theme_bw() +
  theme(legend.position = "bottom")

save_plot_with_emf(p_denom, "routing_effective_latency_median_ms_by_parts_threads_and_rtr_group", width = 12, height = 8, dpi = 200)

# Zusatzplot: gRPCTotal nach Partitionen und Routing-Threads
p_grpc <- ggplot(denom_plot, aes(x = router_threads_f, y = median_gRPCTotal_ms, fill = rtr_group)) +
  geom_col(position = position_dodge(width = 0.8)) +
  facet_wrap(~ parts_f, scales = "free_y", labeller = labeller(parts_f = function(x) paste0("parts=", x))) +
  labs(
    title = "gRPCTotal nach Partitionen und Routing-Threads",
    subtitle = "Horizon = 600; gRPCRequest + gRPCResponse",
    x = "Routing-Threads",
    y = "median gRPCTotal [ms]",
    fill = "RTR-Gruppe"
  ) +
  theme_bw() +
  theme(legend.position = "bottom")

save_plot_with_emf(p_grpc, "grpc_total_median_ms_by_parts_threads_and_rtr_group", width = 12, height = 8, dpi = 200)

readme <- c(
  "Routing component shares by RTR groups, parts and routing_threads, Horizon=600, gRPC collapsed",
  "============================================================================================",
  "",
  paste0("File index: ", file_index_path),
  paste0("Runtime file: ", runtime_file),
  paste0("Group share: ", group_share),
  paste0("Group within parts: ", group_within_parts),
  paste0("Horizon filter: 600"),
  paste0("Horizon=600 runs with RTR after optional filters: ", nrow(runtime_data)),
  "",
  "Groups:",
  "- slowest_10pct: lowest RTR values.",
  "- middle_45_to_55pct: center around the RTR median.",
  "- fastest_10pct: highest RTR values.",
  "",
  "Forced additional selections per partition:",
  "- fastest_10pct additionally includes the fastest run with routing_threads = 1.",
  "- middle_45_to_55pct additionally includes the next slower and next faster run around the median with routing_threads = 1.",
  "- slowest_10pct additionally includes the slowest run with routing_threads = 24.",
  "",
  "If GROUP_WITHIN_PARTS=1  # deprecated; Gruppierung erfolgt immer innerhalb parts × routing_threads, base groups are selected separately for each partition count.",
  "If GROUP_WITHIN_PARTS=0, base groups are selected globally and then reported by partition/routing_threads.",
  "",
  "Bereitliegezeit:",
  "ready_wait_ms = agent_received_response_adapter - adapter_sent_response_agent",
  "",
  "Denominator:",
  "effective_routing_latency_ms = (agent_replaced_route - route_call_start_realtime) - ready_wait_ms",
  "",
  "Components:",
  "- RustRequest: route_call_start_realtime -> adapter_sent_request_grpc",
  "- gRPCTotal: requestDeliveryRustToJavaLatency + (adapter_received_response_grpc - java_routing_service_sent_response_grpc)",
  "- javaTotal: Java-side total duration",
  "- RustResponse: adapter_received_response_grpc -> adapter_sent_response_agent plus agent_received_response_adapter -> agent_replaced_route",
  "- Residual: denominator - sum(components)",
  "",
  "Clock-skew note:",
  "gRPCRequest and gRPCResponse are not shown separately because they use timestamps from different processes/nodes.",
  "The script still writes median_gRPCRequest_ms and median_gRPCResponse_ms to diagnostics for checking.",
  "",
  "Outputs:",
  "- selected_rtr_group_runs_h600_by_parts_threads.csv",
  "- selected_rtr_group_runs_audit_h600_by_parts_threads.csv",
  "- selected_run_counts_by_parts_threads_group.csv",
  "- selected_rtr_group_file_pairs_h600_by_parts_threads.csv",
  "- per_run_routing_component_summaries_h600_by_parts_threads_grpc_total.csv",
  "- routing_component_share_table_rtr_groups_h600_by_parts_threads_grpc_total.csv/.md/.tex",
  "- routing_component_share_grouped_bar_rtr_groups_h600_by_parts_threads_grpc_total.png",
  "- routing_component_median_ms_grouped_bar_rtr_groups_h600_by_parts_threads_grpc_total.png",
  "- routing_effective_latency_median_ms_by_parts_threads_and_rtr_group.png",
  "- grpc_total_median_ms_by_parts_threads_and_rtr_group.png",
  "- group_diagnostics_by_parts_threads_grpc_total.csv",
  "- file_diagnostics_by_parts_threads_grpc_total.csv",
  "- processing_errors.csv",
  "",
  "Diagnostics:",
  "- processing_errors.csv should contain only the header.",
  "- complete_component_row_share should be high.",
  "- component_sum_share_pct + residual_share_pct should be 100.",
  "- selected_rtr_group_runs_audit_h600_by_parts_threads.csv shows which runs were selected by the base 5% logic and which were forced."
)

writeLines(readme, file.path(out_dir, "README.txt"))

message("Done. Outputs written to: ", out_dir)
message("Main table: ", file.path(out_dir, "routing_component_share_table_rtr_groups_h600_by_parts_threads_grpc_total.csv"))
message("Audit table: ", file.path(out_dir, "selected_rtr_group_runs_audit_h600_by_parts_threads.csv"))
message("Main plot: ", file.path(out_dir, "routing_component_share_grouped_bar_rtr_groups_h600_by_parts_threads_grpc_total.png"))
