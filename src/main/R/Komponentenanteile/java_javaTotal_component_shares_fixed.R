#!/usr/bin/env Rscript

# java_javaTotal_component_shares.R
#
# Ziel:
#   Wie java_component_shares_rtr_groups_h600_by_parts.R, aber zusätzlich nach
#   routing_threads getrennt und mit den gleichen erzwungenen Zusatzläufen wie
#   bei der Routing-Komponentenanalyse.
#
# Für Horizon = 600 werden Simulationsdurchläufe nach RTR gruppiert:
#
#   slowest_10pct:
#     niedrigste RTR, also langsamste Durchläufe
#
#   middle_45_to_55pct:
#     mediane Durchläufe um den RTR-Median
#
#   fastest_10pct:
#     höchste RTR, also schnellste Durchläufe
#
# Standardmäßig werden die Basisgruppen INNERHALB jeder Partitionszahl gebildet:
#
#   GROUP_WITHIN_PARTS=1
#
# Zusätzlich werden pro Partition erzwungen:
#
#   fastest_10pct:
#     schnellster Durchlauf mit routing_threads = 1
#
#   middle_45_to_55pct:
#     nächstlangsamere und nächstschnellere Durchläufe um die Mitte
#     mit routing_threads = 1
#
#   slowest_10pct:
#     langsamster Durchlauf mit routing_threads = 24
#
# Java-Zerlegung:
#   bindSnapshot  = bindWaitNs
#   buildRequest  = createCarRouteRequest
#   calcRoute     = calcRoute
#   buildResponse = createCarResponse
#   Residual      = javaTotal - Summe der obigen Komponenten
#
# Die relativen Anteile beziehen sich auf javaTotal.
#
# Aufruf:
#   Rscript R/java_javaTotal_component_shares.R \
#     output/analysis/file_index_recursive.csv \
#     output/analysis/simulation_runtimes_from_logs.csv \
#     output/analysis/java_component_shares_rtr_groups_h600_by_parts_threads
#
# Referenz:
#   GROUP_SHARE=0.10
#   GROUP_WITHIN_PARTS=1
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
out_dir <- ifelse(length(args) >= 3, args[[3]], "output/analysis/Komponenten_JavaTotal")

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

if (!file.exists(file_index_path)) {
  stop("File index not found: ", file_index_path)
}
if (!file.exists(runtime_file)) {
  stop("Runtime file not found: ", runtime_file)
}

has_data_table <- requireNamespace("data.table", quietly = TRUE)

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

group_share <- suppressWarnings(as.numeric(Sys.getenv("GROUP_SHARE", "0.10")))
group_within_parts <- TRUE
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

ns_to_ms <- function(x) {
  suppressWarnings(as.numeric(x)) / 1e6
}

clean_duration <- function(x, max_ms = 10 * 60 * 1000, allow_negative = FALSE) {
  if (allow_negative) return(ifelse(is.finite(x) & abs(x) <= max_ms, x, NA_real_))
  ifelse(is.finite(x) & x >= 0 & x <= max_ms, x, NA_real_)
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
# Java component extraction
# ------------------------------------------------------------

compute_java_components <- function(path) {
  java <- read_csv_fast(path)

  required <- c(
    "requestId",
    "bindWaitNs",
    "createCarRouteRequest",
    "calcRoute",
    "createCarResponse",
    "javaTotal"
  )

  missing <- setdiff(required, names(java))
  if (length(missing) > 0) {
    stop("Java file missing columns: ", paste(missing, collapse = ", "))
  }

  bind_snapshot_ms <- clean_duration(ns_to_ms(java$bindWaitNs))
  build_request_ms <- clean_duration(ns_to_ms(java$createCarRouteRequest))
  calc_route_ms <- clean_duration(ns_to_ms(java$calcRoute))
  build_response_ms <- clean_duration(ns_to_ms(java$createCarResponse))
  java_total_ms <- clean_duration(ns_to_ms(java$javaTotal))

  component_sum_ms <-
    bind_snapshot_ms +
    build_request_ms +
    calc_route_ms +
    build_response_ms

  residual_ms <- java_total_ms - component_sum_ms

  tibble(
    request_id = as.character(java$requestId),
    javaTotal_ms = java_total_ms,
    bindSnapshot_ms = bind_snapshot_ms,
    buildRequest_ms = build_request_ms,
    calcRoute_ms = calc_route_ms,
    buildResponse_ms = build_response_ms,
    component_sum_ms = component_sum_ms,
    residual_ms = residual_ms,
    complete_components =
      is.finite(javaTotal_ms) &
        is.finite(bindSnapshot_ms) &
        is.finite(buildRequest_ms) &
        is.finite(calcRoute_ms) &
        is.finite(buildResponse_ms) &
        is.finite(component_sum_ms) &
        is.finite(residual_ms)
  )
}

# ------------------------------------------------------------
# 1) Build Horizon=600 RTR groups with forced selections
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

  bind_rows(slowest, middle, fastest) %>%
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
    run_rank_by_rtr_ascending_within_parts = row_number(),
    n_runs_within_parts = n(),
    rank_midpoint_pct_within_parts = (run_rank_by_rtr_ascending_within_parts - 0.5) / n_runs_within_parts
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
# 2) Pair selected runs with java_routing files
# ------------------------------------------------------------

message("Reading file index: ", file_index_path)
idx <- readr::read_csv(file_index_path, show_col_types = FALSE)

required_index <- c("file", "file_type", "horizon", "parts", "router_threads", "batch_size", "config_key")
missing_index <- setdiff(required_index, names(idx))
if (length(missing_index) > 0) {
  stop("Missing required columns in file index: ", paste(missing_index, collapse = ", "))
}

idx <- idx %>%
  filter(file_type == "java_routing") %>%
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

java_pairs <- idx %>%
  arrange(horizon, batch_size, parts, router_threads, file) %>%
  group_by(horizon, batch_size, parts, router_threads) %>%
  summarise(
    java_file = first(file),
    java_config_key = first(config_key),
    n_java_files = n(),
    .groups = "drop"
  )

pairs <- selected_keys %>%
  left_join(java_pairs, by = c("horizon", "batch_size", "parts", "router_threads")) %>%
  arrange(
    parts,
    router_threads,
    factor(rtr_group, levels = group_levels),
    run_rank_by_rtr_ascending
  )

readr::write_csv(pairs, file.path(out_dir, "selected_rtr_group_java_files_h600_by_parts_threads.csv"))

if (any(is.na(pairs$java_file))) {
  warning("Some selected runs have no java_routing file. See selected_rtr_group_java_files_h600_by_parts_threads.csv")
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

  if (is.na(p$java_file[[1]])) {
    errors[[length(errors) + 1]] <- tibble(
      phase = "pairing",
      rtr_group = group_name,
      selection_reason = p$selection_reason[[1]],
      horizon = p$horizon[[1]],
      batch_size = p$batch_size[[1]],
      parts = p$parts[[1]],
      router_threads = p$router_threads[[1]],
      java_file = NA_character_,
      error = "No java_routing file for selected run"
    )
    next
  }

  message(sprintf(
    "[%d/%d] parts=%s | routing_threads=%s | %s | RTR %.4f | %s",
    i, nrow(pairs), p$parts[[1]], p$router_threads[[1]],
    group_name, p$RTR[[1]], basename(p$java_file[[1]])
  ))

  tryCatch({
    java_components <- compute_java_components(p$java_file[[1]])
    sub <- java_components %>% filter(complete_components)

    run_summaries[[length(run_summaries) + 1]] <- tibble(
      rtr_group = group_name,
      selection_reason = p$selection_reason[[1]],
      horizon = p$horizon[[1]],
      batch_size = p$batch_size[[1]],
      parts = p$parts[[1]],
      router_threads = p$router_threads[[1]],
      RTR = p$RTR[[1]],
      runtime_s = p$runtime_s[[1]],
      java_file = p$java_file[[1]],

      n_requests = nrow(java_components),
      n_complete_component_rows = nrow(sub),

      javaTotal_sum_ms = sum(sub$javaTotal_ms, na.rm = TRUE),
      bindSnapshot_sum_ms = sum(sub$bindSnapshot_ms, na.rm = TRUE),
      buildRequest_sum_ms = sum(sub$buildRequest_ms, na.rm = TRUE),
      calcRoute_sum_ms = sum(sub$calcRoute_ms, na.rm = TRUE),
      buildResponse_sum_ms = sum(sub$buildResponse_ms, na.rm = TRUE),

      component_sum_ms = sum(sub$component_sum_ms, na.rm = TRUE),
      residual_sum_ms = sum(sub$residual_ms, na.rm = TRUE)
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
      java_file = p$java_file[[1]],
      n_java_rows = nrow(java_components),
      n_complete_components = nrow(sub),
      complete_component_row_share = nrow(sub) / nrow(java_components),
      java_component_sum_share_pct =
        100 * sum(sub$component_sum_ms, na.rm = TRUE) / sum(sub$javaTotal_ms, na.rm = TRUE),
      residual_share_pct =
        100 * sum(sub$residual_ms, na.rm = TRUE) / sum(sub$javaTotal_ms, na.rm = TRUE),
      javaTotal_p50_ms = median(sub$javaTotal_ms, na.rm = TRUE),
      javaTotal_p95_ms = as.numeric(quantile(sub$javaTotal_ms, 0.90, na.rm = TRUE, names = FALSE))
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
      java_file = p$java_file[[1]],
      error = conditionMessage(e)
    )
  })

  gc(verbose = FALSE)
}

run_summary_df <- bind_rows(run_summaries)

if (nrow(run_summary_df) == 0) {
  stop("No usable Java component summaries were produced.")
}

readr::write_csv(run_summary_df, file.path(out_dir, "per_run_java_component_summaries_h600_by_parts_threads.csv"))

acc_df <- run_summary_df %>%
  group_by(parts, router_threads, rtr_group) %>%
  summarise(
    n_selected_runs = n(),
    n_requests = sum(n_requests, na.rm = TRUE),
    n_complete_component_rows = sum(n_complete_component_rows, na.rm = TRUE),

    javaTotal_sum_ms = sum(javaTotal_sum_ms, na.rm = TRUE),
    bindSnapshot_sum_ms = sum(bindSnapshot_sum_ms, na.rm = TRUE),
    buildRequest_sum_ms = sum(buildRequest_sum_ms, na.rm = TRUE),
    calcRoute_sum_ms = sum(calcRoute_sum_ms, na.rm = TRUE),
    buildResponse_sum_ms = sum(buildResponse_sum_ms, na.rm = TRUE),

    component_sum_ms = sum(component_sum_ms, na.rm = TRUE),
    residual_sum_ms = sum(residual_sum_ms, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(
    rtr_group = factor(rtr_group, levels = group_levels),
    parts = as.integer(parts),
    router_threads = as.integer(router_threads)
  )

component_long <- acc_df %>%
  select(
    parts, router_threads, rtr_group,
    n_selected_runs, n_requests, n_complete_component_rows, javaTotal_sum_ms,
    bindSnapshot_sum_ms,
    buildRequest_sum_ms,
    calcRoute_sum_ms,
    buildResponse_sum_ms,
    residual_sum_ms
  ) %>%
  pivot_longer(
    cols = c(
      bindSnapshot_sum_ms,
      buildRequest_sum_ms,
      calcRoute_sum_ms,
      buildResponse_sum_ms,
      residual_sum_ms
    ),
    names_to = "component",
    values_to = "component_sum_ms"
  ) %>%
  mutate(
    component = str_replace(component, "_sum_ms$", ""),
    component = recode(
      component,
      bindSnapshot = "bindSnapshot",
      buildRequest = "buildRequest",
      calcRoute = "calcRoute",
      buildResponse = "buildResponse",
      residual = "Residual"
    )
  )

if (!include_residual) {
  component_long <- component_long %>% filter(component != "Residual")
}

component_order <- c("bindSnapshot", "buildRequest", "calcRoute", "buildResponse", "Residual")

component_share_table <- component_long %>%
  mutate(
    median_javaTotal_ms = javaTotal_sum_ms / n_complete_component_rows,
    median_component_ms = component_sum_ms / n_complete_component_rows,
    relative_share_pct = 100 * component_sum_ms / javaTotal_sum_ms
  ) %>%
  select(
    parts, router_threads, rtr_group, component,
    n_selected_runs, n_requests, n_complete_component_rows,
    median_javaTotal_ms, median_component_ms, relative_share_pct
  ) %>%
  mutate(
    across(c(median_javaTotal_ms, median_component_ms, relative_share_pct), ~ round(.x, 6))
  ) %>%
  arrange(parts, router_threads, rtr_group, factor(component, levels = component_order))

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
    median_javaTotal_ms = javaTotal_sum_ms / n_complete_component_rows,
    java_component_sum_share_pct = 100 * component_sum_ms / javaTotal_sum_ms,
    residual_share_pct = 100 * residual_sum_ms / javaTotal_sum_ms,
    total_share_including_residual_pct =
      100 * (component_sum_ms + residual_sum_ms) / javaTotal_sum_ms,
    complete_component_row_share = n_complete_component_rows / n_requests
  ) %>%
  mutate(
    across(
      c(median_javaTotal_ms, java_component_sum_share_pct,
        residual_share_pct, total_share_including_residual_pct,
        complete_component_row_share,
        rtr_min_selected, rtr_median_selected, rtr_max_selected),
      ~ round(.x, 6)
    )
  ) %>%
  arrange(parts, router_threads, rtr_group)

file_diagnostics <- bind_rows(diagnostics) %>%
  mutate(
    across(
      c(complete_component_row_share, java_component_sum_share_pct,
        residual_share_pct, javaTotal_p50_ms, javaTotal_p95_ms),
      ~ round(.x, 6)
    )
  ) %>%
  arrange(parts, router_threads, factor(rtr_group, levels = group_levels), RTR)

processing_errors <- if (length(errors) > 0) {
  bind_rows(errors)
} else {
  tibble(
    phase = character(),
    rtr_group = character(),
    selection_reason = character(),
    horizon = integer(),
    batch_size = integer(),
    parts = integer(),
    router_threads = integer(),
    java_file = character(),
    error = character()
  )
}

readr::write_csv(component_share_table, file.path(out_dir, "java_component_share_table_rtr_groups_h600_by_parts_threads.csv"))
readr::write_csv(group_diagnostics, file.path(out_dir, "group_diagnostics_by_parts_threads.csv"))
readr::write_csv(file_diagnostics, file.path(out_dir, "file_diagnostics_by_parts_threads.csv"))
if (!exists("processing_errors", inherits = FALSE)) {
  processing_errors <- tibble::tibble(
    parts = integer(),
    router_threads = integer(),
    rtr_group = character(),
    file = character(),
    error = character()
  )
}

readr::write_csv(processing_errors, file.path(out_dir, "processing_errors.csv"))

write_markdown(component_share_table, file.path(out_dir, "java_component_share_table_rtr_groups_h600_by_parts_threads.md"))
write_latex(
  component_share_table,
  file.path(out_dir, "java_component_share_table_rtr_groups_h600_by_parts_threads.tex"),
  "Relative Zeitanteile der Java-Routing-Komponenten für RTR-Gruppen, Partitionen und Routing-Threads bei Horizon 600.",
  "tab:java-routing-component-shares-rtr-groups-h600-by-parts-threads"
)

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
    title = "Relative Zeitanteile der Java-Routing-Komponenten",
    subtitle = paste0(
      "Horizon = 600; nach Partitionen und Routing-Threads; RTR-Gruppen ",
      ifelse(group_within_parts, "innerhalb jeder Partitionszahl", "global über alle Partitionen"),
      "; Medianaggregation"
    ),
    x = "Java-Komponente",
    y = "Anteil an javaTotal [%]",
    fill = "RTR-Gruppe"
  ) +
  theme_bw() +
  theme(
    legend.position = "bottom",
    axis.text.x = element_text(angle = 35, hjust = 1)
  )

save_plot_with_emf(p_share, "java_component_share_grouped_bar_rtr_groups_h600_by_parts_threads", width = 16, height = 12, dpi = 200)

p_ms <- ggplot(plot_data, aes(x = component, y = median_component_ms, fill = rtr_group)) +
  geom_col(position = position_dodge(width = 0.8)) +
  facet_grid(parts_f ~ router_threads_f, scales = "free_y", labeller = labeller(
    parts_f = function(x) paste0("parts=", x),
    router_threads_f = function(x) paste0("rt=", x)
  )) +
  labs(
    title = "Mediane Dauer der Java-Routing-Komponenten",
    subtitle = paste0(
      "Horizon = 600; nach Partitionen und Routing-Threads; RTR-Gruppen ",
      ifelse(group_within_parts, "innerhalb jeder Partitionszahl", "global über alle Partitionen"),
      "; Medianaggregation"
    ),
    x = "Java-Komponente",
    y = "Mediane Dauer [ms]",
    fill = "RTR-Gruppe"
  ) +
  theme_bw() +
  theme(
    legend.position = "bottom",
    axis.text.x = element_text(angle = 35, hjust = 1)
  )

save_plot_with_emf(p_ms, "java_component_median_ms_grouped_bar_rtr_groups_h600_by_parts_threads", width = 16, height = 12, dpi = 200)

java_total_plot <- group_diagnostics %>%
  mutate(
    rtr_group = factor(rtr_group, levels = group_levels),
    parts_f = factor(parts, levels = sort(unique(parts))),
    router_threads_f = factor(router_threads, levels = sort(unique(router_threads)))
  )

p_java_total <- ggplot(java_total_plot, aes(x = router_threads_f, y = median_javaTotal_ms, fill = rtr_group)) +
  geom_col(position = position_dodge(width = 0.8)) +
  facet_wrap(~ parts_f, scales = "free_y", labeller = labeller(parts_f = function(x) paste0("parts=", x))) +
  labs(
    title = "Medianes javaTotal nach Partitionen und Routing-Threads",
    subtitle = "Horizon = 600",
    x = "Routing-Threads",
    y = "median javaTotal [ms]",
    fill = "RTR-Gruppe"
  ) +
  theme_bw() +
  theme(legend.position = "bottom")

save_plot_with_emf(p_java_total, "java_total_median_ms_by_parts_threads_and_rtr_group", width = 12, height = 8, dpi = 200)

readme <- c(
  "Java routing component shares by RTR groups, parts and routing_threads, Horizon=600",
  "================================================================================",
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
  "Java denominator:",
  "javaTotal",
  "",
  "Java components:",
  "- bindSnapshot  = bindWaitNs",
  "- buildRequest  = createCarRouteRequest",
  "- calcRoute     = calcRoute",
  "- buildResponse = createCarResponse",
  "- Residual      = javaTotal - sum(components)",
  "",
  "Outputs:",
  "- selected_rtr_group_runs_h600_by_parts_threads.csv",
  "- selected_rtr_group_runs_audit_h600_by_parts_threads.csv",
  "- selected_run_counts_by_parts_threads_group.csv",
  "- selected_rtr_group_java_files_h600_by_parts_threads.csv",
  "- per_run_java_component_summaries_h600_by_parts_threads.csv",
  "- java_component_share_table_rtr_groups_h600_by_parts_threads.csv/.md/.tex",
  "- java_component_share_grouped_bar_rtr_groups_h600_by_parts_threads.png",
  "- java_component_median_ms_grouped_bar_rtr_groups_h600_by_parts_threads.png",
  "- java_total_median_ms_by_parts_threads_and_rtr_group.png",
  "- group_diagnostics_by_parts_threads.csv",
  "- file_diagnostics_by_parts_threads.csv",
  "- processing_errors.csv",
  "",
  "Diagnostics:",
  "- processing_errors.csv should contain only the header.",
  "- complete_component_row_share should be high.",
  "- java_component_sum_share_pct + residual_share_pct should be 100.",
  "- selected_rtr_group_runs_audit_h600_by_parts_threads.csv shows which runs were selected by the base 10% logic and which were forced."
)

writeLines(readme, file.path(out_dir, "README.txt"))

message("Done. Outputs written to: ", out_dir)
message("Main table: ", file.path(out_dir, "java_component_share_table_rtr_groups_h600_by_parts_threads.csv"))
message("Audit table: ", file.path(out_dir, "selected_rtr_group_runs_audit_h600_by_parts_threads.csv"))
message("Main plot: ", file.path(out_dir, "java_component_share_grouped_bar_rtr_groups_h600_by_parts_threads.png"))
