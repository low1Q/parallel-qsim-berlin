#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(stringr)
  library(tidyr)
  library(purrr)
})

args <- commandArgs(trailingOnly = TRUE)

data_root <- ifelse(length(args) >= 1, args[[1]], "/home/lowiq/Schreibtisch/HNR-Ergebnisse/FullRun")
analysis_dir <- ifelse(length(args) >= 2, args[[2]], "output/analysis")
type_filter_arg <- ifelse(length(args) >= 3, args[[3]], "")

file_index_path <- file.path(analysis_dir, "file_index_recursive.csv")
file_index_counts_path <- file.path(analysis_dir, "file_index_counts.csv")
summary_dir <- file.path(analysis_dir, "streaming_summary")

dir.create(analysis_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(summary_dir, recursive = TRUE, showWarnings = FALSE)

if (!dir.exists(data_root)) {
  stop("Data root not found: ", data_root)
}

safe_int <- function(x) {
  suppressWarnings(as.integer(x))
}

first_match <- function(x, pattern, group = 1) {
  m <- stringr::str_match(x, pattern)
  out <- m[, group + 1]
  out[is.na(out)] <- NA_character_
  out
}

extract_metadata_from_path <- function(files) {
  base <- basename(files)
  parent <- basename(dirname(files))
  path_lower <- stringr::str_to_lower(files)

  bin_from_file     <- first_match(base, "-bin(\\d+)")
  threads_from_file <- first_match(base, "-threads(\\d+)")
  ph_from_file      <- first_match(base, "-PH(\\d+)")
  batch_from_file   <- first_match(base, "-batch(\\d+)")
  parts_from_file   <- first_match(base, "-parts(\\d+)")

  sim_from_base      <- first_match(base, "sim(\\d+)_hor\\d+_w\\d+(?:_r\\d+)?_bin\\d+_batch\\d+")
  hor_from_base      <- first_match(base, "sim\\d+_hor(\\d+)_w\\d+(?:_r\\d+)?_bin\\d+_batch\\d+")
  worker_from_base   <- first_match(base, "sim\\d+_hor\\d+_w(\\d+)(?:_r\\d+)?_bin\\d+_batch\\d+")
  router_from_base   <- first_match(base, "sim\\d+_hor\\d+_w\\d+_r(\\d+)_bin\\d+_batch\\d+")
  bin_from_base      <- first_match(base, "sim\\d+_hor\\d+_w\\d+(?:_r\\d+)?_bin(\\d+)_batch\\d+")
  batch_from_base2   <- first_match(base, "sim\\d+_hor\\d+_w\\d+(?:_r\\d+)?_bin\\d+_batch(\\d+)")

  sim_from_parent      <- first_match(parent, "sim(\\d+)_hor\\d+_w\\d+(?:_r\\d+)?_bin\\d+_batch\\d+")
  hor_from_parent      <- first_match(parent, "sim\\d+_hor(\\d+)_w\\d+(?:_r\\d+)?_bin\\d+_batch\\d+")
  worker_from_parent   <- first_match(parent, "sim\\d+_hor\\d+_w(\\d+)(?:_r\\d+)?_bin\\d+_batch\\d+")
  router_from_parent   <- first_match(parent, "sim\\d+_hor\\d+_w\\d+_r(\\d+)_bin\\d+_batch\\d+")
  bin_from_parent      <- first_match(parent, "sim\\d+_hor\\d+_w\\d+(?:_r\\d+)?_bin(\\d+)_batch\\d+")
  batch_from_parent    <- first_match(parent, "sim\\d+_hor\\d+_w\\d+(?:_r\\d+)?_bin\\d+_batch(\\d+)")

  server_idx <- first_match(parent, "_server(\\d+)$")

  variant <- dplyr::case_when(
    str_detect(path_lower, "freespeed") ~ "Freespeed",
    str_detect(path_lower, "minpop|min_act|minact|min-act|min_act_pop") ~ "MinPop",
    str_detect(path_lower, "planedbasedruns|plannedbasedruns|planbased|plan-based") ~ "PlanBased",
    str_detect(path_lower, "withoutlogging|no_logging|nologging|no-logging|keinlogging") ~ "WithoutLogging",
    str_detect(path_lower, "withoutupdater|withoutupdating|without_update|without-update|disabledupdating|disable-updating|noupdating") ~ "WithoutUpdater",
    str_detect(path_lower, "fullrun") ~ "FullRun",
    TRUE ~ "normal_or_unknown"
  )

  parts <- safe_int(coalesce(parts_from_file, sim_from_base, sim_from_parent))
  horizon <- safe_int(coalesce(ph_from_file, hor_from_base, hor_from_parent))
  worker_threads <- safe_int(coalesce(worker_from_base, worker_from_parent))
  router_threads <- safe_int(coalesce(threads_from_file, router_from_base, router_from_parent))
  bin_size <- safe_int(coalesce(bin_from_file, bin_from_base, bin_from_parent))
  batch_size <- safe_int(coalesce(batch_from_file, batch_from_base2, batch_from_parent))

  tibble(
    file = normalizePath(files, mustWork = FALSE),
    file_name = base,
    parent_dir = parent,
    bin_size = bin_size,
    router_threads = router_threads,
    horizon = horizon,
    batch_size = batch_size,
    parts = parts,
    worker_threads = worker_threads,
    server_idx = safe_int(server_idx),
    run_variant = variant,
    config_key = paste0(
      "sim", parts,
      "_hor", horizon,
      "_w", worker_threads,
      "_r", router_threads,
      "_bin", bin_size,
      "_batch", batch_size
    )
  )
}

classify_file_type <- function(files) {
  base <- basename(files)

  case_when(
    str_detect(base, "^rust-routing-requests-") ~ "rust_routing",
    str_detect(base, "^rust-event-sharing-summary-") ~ "rust_event_summary",
    str_detect(base, "^java-routing-time-profiling-") ~ "java_routing",
    str_detect(base, "^java-updating-profiling-") ~ "java_updating",
    TRUE ~ "other_csv"
  )
}

build_file_index <- function(data_root) {
  data_root_norm <- normalizePath(data_root, mustWork = FALSE)

  files <- list.files(
    path = data_root_norm,
    pattern = "\\.csv$",
    recursive = TRUE,
    full.names = TRUE
  )

  if (length(files) == 0) {
    warning("No CSV files found below: ", data_root_norm)
    return(tibble())
  }

  meta <- extract_metadata_from_path(files)

  meta %>%
    mutate(
      file_type = classify_file_type(file),
      rel_path = stringr::str_remove(
        normalizePath(file, mustWork = FALSE),
        paste0("^", stringr::fixed(data_root_norm), "/?")
      ),
      file_size_bytes = file.info(file)$size
    ) %>%
    arrange(file_type, horizon, parts, router_threads, batch_size, file)
}

has_data_table <- requireNamespace("data.table", quietly = TRUE)

exclude_exact <- c(
  "person_id", "person", "link_id", "link", "vehicle_id", "vehicle",
  "from_link", "to_link", "route_id", "request_id"
)

interesting_patterns <- paste(
  c(
    "duration", "latency", "wait", "time", "elapsed", "queue",
    "_ns$", "_ms$", "_s$", "count", "num", "total", "publish",
    "batch", "route", "grpc", "snapshot", "processing"
  ),
  collapse = "|"
)

empty_summary <- function() {
  tibble(
    metric = character(),
    n_rows = integer(),
    n_non_na = integer(),
    min = numeric(),
    p50 = numeric(),
    mean = numeric(),
    p95 = numeric(),
    p99 = numeric(),
    max = numeric()
  )
}

summarise_numeric_file <- function(path) {
  dat <- if (has_data_table) {
    as_tibble(data.table::fread(path, showProgress = FALSE))
  } else {
    readr::read_csv(path, show_col_types = FALSE, progress = FALSE)
  }

  n_rows <- nrow(dat)

  if (requireNamespace("bit64", quietly = TRUE)) {
    int64_cols <- names(dat)[vapply(dat, function(z) inherits(z, "integer64"), logical(1))]
    if (length(int64_cols) > 0) {
      dat[int64_cols] <- lapply(dat[int64_cols], function(z) as.numeric(z))
    }
  }

  numeric_cols <- names(dat)[vapply(dat, function(z) is.numeric(z) || is.integer(z), logical(1))]
  numeric_cols <- setdiff(numeric_cols, exclude_exact)

  interesting <- numeric_cols[str_detect(numeric_cols, regex(interesting_patterns, ignore_case = TRUE))]
  if (length(interesting) > 0) {
    numeric_cols <- interesting
  }

  if (length(numeric_cols) == 0) {
    return(empty_summary())
  }

  bind_rows(lapply(numeric_cols, function(col) {
    x <- dat[[col]]
    x <- x[is.finite(x)]

    if (length(x) == 0) {
      return(tibble(
        metric = col,
        n_rows = n_rows,
        n_non_na = 0L,
        min = NA_real_,
        p50 = NA_real_,
        mean = NA_real_,
        p95 = NA_real_,
        p99 = NA_real_,
        max = NA_real_
      ))
    }

    qs <- stats::quantile(
      x,
      probs = c(0.5, 0.95, 0.99),
      na.rm = TRUE,
      names = FALSE,
      type = 7
    )

    tibble(
      metric = col,
      n_rows = n_rows,
      n_non_na = length(x),
      min = min(x, na.rm = TRUE),
      p50 = qs[[1]],
      mean = mean(x, na.rm = TRUE),
      p95 = qs[[2]],
      p99 = qs[[3]],
      max = max(x, na.rm = TRUE)
    )
  }))
}

write_streaming_summaries <- function(file_index_path, out_dir, type_filter_arg = "") {
  if (!file.exists(file_index_path)) {
    stop("File index not found: ", file_index_path)
  }

  idx <- readr::read_csv(file_index_path, show_col_types = FALSE)

  relevant_types <- c("rust_routing", "rust_event_summary", "java_routing", "java_updating")

  wanted_types <- if (nzchar(type_filter_arg)) {
    trimws(strsplit(type_filter_arg, ",", fixed = TRUE)[[1]])
  } else {
    relevant_types
  }

  idx <- idx %>%
    filter(.data$file_type %in% wanted_types) %>%
    arrange(.data$file_type, .data$horizon, .data$parts, .data$router_threads, .data$batch_size, .data$file)

  message("Files to process: ", nrow(idx))
  message("File types:")
  print(idx %>% count(.data$file_type, name = "n_files"))

  all_summaries <- vector("list", nrow(idx))
  errors <- list()

  if (nrow(idx) > 0) {
    for (i in seq_len(nrow(idx))) {
      idx_row <- idx[i, ]
      current_file <- idx_row$file[[1]]

      message(sprintf("[%d/%d] %s", i, nrow(idx), basename(current_file)))

      res <- tryCatch(
        {
          s <- summarise_numeric_file(current_file)

          if (nrow(s) == 0) {
            tibble()
          } else {
            s %>%
              mutate(
                source_file = current_file,
                source_file_name = basename(current_file),
                source_file_type = idx_row$file_type[[1]],
                config_key = idx_row$config_key[[1]],
                run_variant = idx_row$run_variant[[1]],
                horizon = idx_row$horizon[[1]],
                parts = idx_row$parts[[1]],
                worker_threads = idx_row$worker_threads[[1]],
                router_threads = idx_row$router_threads[[1]],
                bin_size = idx_row$bin_size[[1]],
                batch_size = idx_row$batch_size[[1]],
                server_idx = idx_row$server_idx[[1]],
                .before = 1
              )
          }
        },
        error = function(e) {
          errors[[length(errors) + 1]] <<- tibble(
            source_file = current_file,
            source_file_type = idx_row$file_type[[1]],
            config_key = idx_row$config_key[[1]],
            error = conditionMessage(e)
          )
          tibble()
        }
      )

      all_summaries[[i]] <- res
      rm(res)
      gc(verbose = FALSE)
    }
  }

  summary_long <- bind_rows(all_summaries)

  errors_df <- if (length(errors) > 0) {
    bind_rows(errors)
  } else {
    tibble(
      source_file = character(),
      source_file_type = character(),
      config_key = character(),
      error = character()
    )
  }

  long_path <- file.path(out_dir, "per_file_numeric_summary_long.csv")
  err_path <- file.path(out_dir, "processing_errors.csv")

  readr::write_csv(summary_long, long_path)
  readr::write_csv(errors_df, err_path)

  message("Wrote: ", long_path)
  message("Wrote: ", err_path)

  if (nrow(summary_long) == 0) {
    message("No numeric metrics found. Skipping wide and per-config summaries.")
    return(invisible(list(summary_long = summary_long, errors = errors_df)))
  }

  id_cols <- c(
    "source_file", "source_file_name", "source_file_type", "config_key", "run_variant",
    "horizon", "parts", "worker_threads", "router_threads", "bin_size", "batch_size", "server_idx"
  )

  stat_cols <- c("n_rows", "n_non_na", "min", "p50", "mean", "p95", "p99", "max")

  summary_wide <- summary_long %>%
    select(any_of(c(id_cols, "metric", stat_cols))) %>%
    pivot_longer(
      cols = any_of(stat_cols),
      names_to = "stat",
      values_to = "value"
    ) %>%
    mutate(metric_stat = paste(.data$metric, .data$stat, sep = "__")) %>%
    select(-.data$metric, -.data$stat) %>%
    pivot_wider(names_from = .data$metric_stat, values_from = .data$value)

  wide_path <- file.path(out_dir, "per_file_numeric_summary_wide.csv")
  readr::write_csv(summary_wide, wide_path)
  message("Wrote: ", wide_path)

  per_config <- summary_long %>%
    group_by(
      .data$config_key, .data$run_variant,
      .data$horizon, .data$parts, .data$worker_threads, .data$router_threads, .data$bin_size, .data$batch_size,
      .data$source_file_type, .data$metric
    ) %>%
    summarise(
      n_files = n(),
      rows_total = sum(.data$n_rows, na.rm = TRUE),
      p50_median = median(.data$p50, na.rm = TRUE),
      p95_median = median(.data$p95, na.rm = TRUE),
      p99_median = median(.data$p99, na.rm = TRUE),
      max_max = max(.data$max, na.rm = TRUE),
      mean_median = median(.data$mean, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    mutate(
      p50_median = ifelse(is.infinite(.data$p50_median), NA_real_, .data$p50_median),
      p95_median = ifelse(is.infinite(.data$p95_median), NA_real_, .data$p95_median),
      p99_median = ifelse(is.infinite(.data$p99_median), NA_real_, .data$p99_median),
      max_max = ifelse(is.infinite(.data$max_max), NA_real_, .data$max_max),
      mean_median = ifelse(is.infinite(.data$mean_median), NA_real_, .data$mean_median)
    )

  config_path <- file.path(out_dir, "per_config_numeric_summary.csv")
  readr::write_csv(per_config, config_path)
  message("Wrote: ", config_path)

  invisible(list(
    summary_long = summary_long,
    errors = errors_df,
    summary_wide = summary_wide,
    per_config = per_config
  ))
}

drop_constant_columns_from_summaries <- function(root_dir) {
  cols_to_drop <- c("run_variant", "worker_threads", "bin_size")

  summary_files <- list.files(
    path = root_dir,
    pattern = "^(per_file_numeric_summary_long|per_file_numeric_summary_wide|per_config_numeric_summary)\\.csv$",
    recursive = TRUE,
    full.names = TRUE
  )

  if (length(summary_files) == 0) {
    warning("No summary CSV files found below: ", root_dir)
    return(invisible(tibble()))
  }

  out_rows <- list()

  for (f in summary_files) {
    message("Reducing: ", f)

    x <- readr::read_csv(f, show_col_types = FALSE)
    present <- intersect(cols_to_drop, names(x))

    x_reduced <- x %>%
      select(-any_of(cols_to_drop))

    out <- stringr::str_replace(f, "\\.csv$", "_reduced.csv")
    readr::write_csv(x_reduced, out)

    out_rows[[length(out_rows) + 1]] <- tibble(
      input_file = f,
      output_file = out,
      dropped_columns = paste(present, collapse = ",")
    )

    if (length(present) > 0) {
      message("  Dropped columns: ", paste(present, collapse = ", "))
    } else {
      message("  None of the requested columns were present.")
    }

    message("  Wrote: ", out)
  }

  bind_rows(out_rows)
}

message("Building recursive file index from: ", data_root)

file_index <- build_file_index(data_root)

if (nrow(file_index) == 0) {
  stop("No CSV files found below: ", data_root)
}

file_index_counts <- file_index %>%
  count(file_type, run_variant, name = "n_files") %>%
  arrange(file_type, run_variant)

readr::write_csv(file_index, file_index_path)
readr::write_csv(file_index_counts, file_index_counts_path)

message("Wrote: ", file_index_path)
message("Wrote: ", file_index_counts_path)
message("Found CSV files:")
print(file_index_counts)

message("Starting streaming summary...")

write_streaming_summaries(
  file_index_path = file_index_path,
  out_dir = summary_dir,
  type_filter_arg = type_filter_arg
)

message("Creating reduced summary CSVs...")

reduced_outputs <- drop_constant_columns_from_summaries(summary_dir)

reduced_manifest_path <- file.path(summary_dir, "reduced_outputs_manifest.csv")
readr::write_csv(reduced_outputs, reduced_manifest_path)

message("Wrote: ", reduced_manifest_path)

message("Done.")
message("Main outputs:")
message("  ", file_index_path)
message("  ", file_index_counts_path)
message("  ", file.path(summary_dir, "per_file_numeric_summary_long.csv"))
message("  ", file.path(summary_dir, "per_file_numeric_summary_wide.csv"))
message("  ", file.path(summary_dir, "per_config_numeric_summary.csv"))
message("  ", file.path(summary_dir, "per_file_numeric_summary_long_reduced.csv"))
message("  ", file.path(summary_dir, "per_file_numeric_summary_wide_reduced.csv"))
message("  ", file.path(summary_dir, "per_config_numeric_summary_reduced.csv"))
