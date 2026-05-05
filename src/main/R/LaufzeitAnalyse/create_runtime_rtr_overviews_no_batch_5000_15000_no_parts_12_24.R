#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(tidyr)
  library(stringr)
})

args <- commandArgs(trailingOnly = TRUE)

input_csv <- if (length(args) >= 1) args[[1]] else "output/analysis/simulation_runtimes_from_logs.csv"
out_dir <- if (length(args) >= 2) args[[2]] else "output/analysis/runtime_rtr_overviews"

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

if (!file.exists(input_csv)) {
  stop("Input file not found: ", input_csv)
}

parse_keep <- function(x) {
  if (is.null(x) || is.na(x) || !nzchar(trimws(x))) return(integer())
  suppressWarnings(as.integer(trimws(strsplit(x, ",", fixed = TRUE)[[1]])))
}

first_existing_col <- function(df, candidates) {
  existing <- candidates[candidates %in% names(df)]
  if (length(existing) == 0) return(NA_character_)
  existing[[1]]
}

extract_int_from_file <- function(x, pattern) {
  val <- stringr::str_match(basename(as.character(x)), pattern)[, 2]
  suppressWarnings(as.integer(val))
}

parts_keep <- parse_keep(Sys.getenv("PARTS_KEEP", ""))
parts_drop <- parse_keep(Sys.getenv("PARTS_DROP", "12,24"))
router_threads_keep <- parse_keep(Sys.getenv("ROUTER_THREADS_KEEP", ""))
batch_keep <- parse_keep(Sys.getenv("BATCH_KEEP", ""))
batch_drop <- parse_keep(Sys.getenv("BATCH_DROP", "5000,15000"))
horizons_keep <- parse_keep(Sys.getenv("HORIZONS_KEEP", ""))

raw <- readr::read_csv(input_csv, show_col_types = FALSE)

file_col <- first_existing_col(raw, c("file", "source_file", "log_file", "path"))
if (is.na(file_col)) {
  raw$file <- NA_character_
  file_col <- "file"
}

partitions_col <- first_existing_col(raw, c("partitions", "partition", "n_partitions", "num_partitions", "routing_partitions", "parts", "sim_cpus"))
horizon_col <- first_existing_col(raw, c("horizon", "preplanning_horizon", "real_horizon"))
routing_threads_col <- first_existing_col(raw, c("routing_threads", "router_threads", "r"))
batch_col <- first_existing_col(raw, c("batch_size", "batch"))
runtime_col <- first_existing_col(raw, c("runtime_s", "runtime_seconds", "wall_time_s", "duration_s"))
rtr_col <- first_existing_col(raw, c("rtr", "RTR", "real_time_ratio", "realtime_ratio", "realTimeRatio"))

if (is.na(rtr_col) && is.na(runtime_col)) {
  stop("Neither RTR nor runtime column found in input.")
}

runs <- raw %>%
  mutate(
    file_chr = as.character(.data[[file_col]]),
    partitions = coalesce(
      if (!is.na(partitions_col)) suppressWarnings(as.integer(.data[[partitions_col]])) else NA_integer_,
      extract_int_from_file(file_chr, "(?:^|[_/-])sim([0-9]+)(?:_|$)")
    ),
    horizon = coalesce(
      if (!is.na(horizon_col)) suppressWarnings(as.integer(.data[[horizon_col]])) else NA_integer_,
      extract_int_from_file(file_chr, "(?:^|[_/-])hor([0-9]+)(?:_|$)")
    ),
    routing_threads = coalesce(
      if (!is.na(routing_threads_col)) suppressWarnings(as.integer(.data[[routing_threads_col]])) else NA_integer_,
      extract_int_from_file(file_chr, "(?:^|[_/-])r([0-9]+)(?:_|$)")
    ),
    batch_size = coalesce(
      if (!is.na(batch_col)) suppressWarnings(as.integer(.data[[batch_col]])) else NA_integer_,
      extract_int_from_file(file_chr, "(?:^|[_/-])batch([0-9]+)(?:_|$)")
    ),
    runtime_s = if (!is.na(runtime_col)) suppressWarnings(as.numeric(.data[[runtime_col]])) else NA_real_,
    rtr = if (!is.na(rtr_col)) suppressWarnings(as.numeric(.data[[rtr_col]])) else 86400 / runtime_s
  ) %>%
  filter(!is.na(rtr), is.finite(rtr))

if (length(parts_keep) > 0) runs <- runs %>% filter(.data$partitions %in% parts_keep)
if (length(parts_drop) > 0) runs <- runs %>% filter(!.data$partitions %in% parts_drop)
if (length(router_threads_keep) > 0) runs <- runs %>% filter(.data$routing_threads %in% router_threads_keep)
if (length(batch_keep) > 0) runs <- runs %>% filter(.data$batch_size %in% batch_keep)
if (length(batch_drop) > 0) runs <- runs %>% filter(!.data$batch_size %in% batch_drop)
if (length(horizons_keep) > 0) runs <- runs %>% filter(.data$horizon %in% horizons_keep)

readr::write_csv(runs, file.path(out_dir, "runtime_rtr_clean_filtered_runs.csv"))

summarise_rtr <- function(df, group_cols) {
  df %>%
    filter(if_all(all_of(group_cols), ~ !is.na(.x))) %>%
    group_by(across(all_of(group_cols))) %>%
    summarise(
      n_runs = n(),
      runtime_s_median = median(runtime_s, na.rm = TRUE),
      rtr_min = min(rtr, na.rm = TRUE),
      rtr_p25 = quantile(rtr, 0.25, na.rm = TRUE, names = FALSE),
      rtr_median = median(rtr, na.rm = TRUE),
      rtr_mean = mean(rtr, na.rm = TRUE),
      rtr_p75 = quantile(rtr, 0.75, na.rm = TRUE, names = FALSE),
      rtr_max = max(rtr, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    arrange(across(all_of(group_cols)))
}

write_table_set <- function(x, name) {
  readr::write_csv(x, file.path(out_dir, paste0(name, ".csv")))

  md <- c(
    paste0("# ", name),
    "",
    paste(c("|", paste(names(x), collapse = " | "), "|"), collapse = ""),
    paste(c("|", paste(rep("---", ncol(x)), collapse = " | "), "|"), collapse = "")
  )

  if (nrow(x) > 0) {
    md <- c(md, apply(x, 1, function(row) {
      paste(c("|", paste(as.character(row), collapse = " | "), "|"), collapse = "")
    }))
  }

  writeLines(md, file.path(out_dir, paste0(name, ".md")))

  tex <- paste(capture.output(print(knitr::kable(x, format = "latex", booktabs = TRUE))), collapse = "\n")
  writeLines(tex, file.path(out_dir, paste0(name, ".tex")))
}

by_horizon <- summarise_rtr(runs, c("horizon"))
by_partitions <- summarise_rtr(runs, c("partitions"))
by_batch_size <- summarise_rtr(runs, c("batch_size"))
by_routing_threads <- summarise_rtr(runs, c("routing_threads"))

all_long <- bind_rows(
  by_horizon %>% rename(parameter_value = horizon) %>% mutate(parameter = "horizon", .before = 1),
  by_partitions %>% rename(parameter_value = partitions) %>% mutate(parameter = "partitions", .before = 1),
  by_batch_size %>% rename(parameter_value = batch_size) %>% mutate(parameter = "batch_size", .before = 1),
  by_routing_threads %>% rename(parameter_value = routing_threads) %>% mutate(parameter = "routing_threads", .before = 1)
)

write_table_set(by_horizon, "runtime_rtr_overview_by_horizon")
write_table_set(by_partitions, "runtime_rtr_overview_by_partitions")
write_table_set(by_batch_size, "runtime_rtr_overview_by_batch_size")
write_table_set(by_routing_threads, "runtime_rtr_overview_by_routing_threads")
write_table_set(all_long, "runtime_rtr_overview_all_parameters_long")

readme <- c(
  "Runtime/RTR overview tables",
  "",
  paste0("Input: ", input_csv),
  paste0("Dropped batch sizes: ", paste(batch_drop, collapse = ", ")),
  paste0("Dropped partitions: ", paste(parts_drop, collapse = ", ")),
  "Aggregated with median and descriptive RTR statistics."
)
writeLines(readme, file.path(out_dir, "README.txt"))

cat("Wrote overview tables to: ", out_dir, "\n", sep = "")
