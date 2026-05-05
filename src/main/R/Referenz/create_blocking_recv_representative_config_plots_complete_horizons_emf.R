#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(stringr)
  library(ggplot2)
})

args <- commandArgs(trailingOnly = TRUE)

file_index_path <- if (length(args) >= 1) args[[1]] else "output/analysis/file_index_recursive.csv"
runtime_csv <- if (length(args) >= 2) args[[2]] else "output/analysis/simulation_runtimes_from_logs.csv"
out_dir <- if (length(args) >= 3) args[[3]] else "output/analysis/blocking_recv_representative_configs"

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

if (!file.exists(file_index_path)) stop("File index not found: ", file_index_path)
if (!file.exists(runtime_csv)) stop("Runtime CSV not found: ", runtime_csv)

parse_keep <- function(x, default = integer()) {
  if (is.null(x) || is.na(x) || !nzchar(trimws(x))) return(default)
  suppressWarnings(as.integer(trimws(strsplit(x, ",", fixed = TRUE)[[1]])))
}

first_existing_col <- function(df, candidates) {
  existing <- candidates[candidates %in% names(df)]
  if (length(existing) == 0) return(NA_character_)
  existing[[1]]
}

as_int_safe <- function(x) {
  suppressWarnings(as.integer(as.character(x)))
}

as_num_safe <- function(x) {
  suppressWarnings(as.numeric(as.character(x)))
}

extract_int_from_file <- function(x, pattern) {
  val <- stringr::str_match(basename(as.character(x)), pattern)[, 2]
  suppressWarnings(as.integer(val))
}

pick_col <- function(header, candidates, required = TRUE, label = "column") {
  existing <- candidates[candidates %in% header]
  if (length(existing) > 0) return(existing[[1]])
  if (required) {
    stop("Required ", label, " not found. Tried: ", paste(candidates, collapse = ", "),
         "\nAvailable columns: ", paste(header, collapse = ", "))
  }
  NA_character_
}

read_csv_header <- function(path) {
  names(readr::read_csv(path, n_max = 0, show_col_types = FALSE))
}

read_csv_selected <- function(path, cols) {
  cols <- unique(cols[!is.na(cols)])
  if (requireNamespace("data.table", quietly = TRUE)) {
    return(as_tibble(data.table::fread(path, select = cols, showProgress = FALSE)))
  }

  readr::read_csv(
    path,
    col_select = all_of(cols),
    show_col_types = FALSE,
    progress = FALSE
  )
}

q_exact <- function(x, p) {
  x <- x[is.finite(x)]
  if (length(x) == 0) return(NA_real_)
  as.numeric(stats::quantile(x, p, na.rm = TRUE, names = FALSE, type = 7))
}

max_exact <- function(x) {
  x <- x[is.finite(x)]
  if (length(x) == 0) return(NA_real_)
  max(x, na.rm = TRUE)
}

theme_eval <- function() {
  theme_minimal(base_size = 12) +
    theme(
      legend.position = "right",
      panel.grid.minor = element_blank(),
      strip.text = element_text(face = "bold"),
      axis.title = element_text(face = "bold"),
      plot.title = element_text(face = "bold"),
      plot.subtitle = element_text(size = 10)
    )
}

horizons_keep <- parse_keep(Sys.getenv("HORIZONS_KEEP", "0,200,600,1800"))
parts_keep <- parse_keep(Sys.getenv("PARTS_KEEP", ""))
router_threads_keep <- parse_keep(Sys.getenv("ROUTER_THREADS_KEEP", ""))
batch_keep <- parse_keep(Sys.getenv("BATCH_KEEP", ""))
plot_sample_per_horizon <- suppressWarnings(as.integer(Sys.getenv("PLOT_SAMPLE_PER_HORIZON", "10000")))
if (is.na(plot_sample_per_horizon)) plot_sample_per_horizon <- 10000
plot_min_ms <- suppressWarnings(as.numeric(Sys.getenv("PLOT_MIN_MS", "0.0004")))
if (is.na(plot_min_ms) || plot_min_ms <= 0) plot_min_ms <- 0.0004
max_duration_ms <- suppressWarnings(as.numeric(Sys.getenv("MAX_DURATION_MS", "Inf")))
if (is.na(max_duration_ms)) max_duration_ms <- Inf
random_seed <- suppressWarnings(as.integer(Sys.getenv("PLOT_RANDOM_SEED", "42")))
if (is.na(random_seed)) random_seed <- 42

runtime_raw <- readr::read_csv(runtime_csv, show_col_types = FALSE)

runtime_file_col <- first_existing_col(runtime_raw, c("file", "source_file", "log_file", "path"))
if (is.na(runtime_file_col)) {
  runtime_raw$file <- NA_character_
  runtime_file_col <- "file"
}

runtime_parts_col <- first_existing_col(runtime_raw, c("partitions", "parts", "sim_cpus", "partition", "n_partitions"))
runtime_horizon_col <- first_existing_col(runtime_raw, c("horizon", "preplanning_horizon"))
runtime_router_col <- first_existing_col(runtime_raw, c("routing_threads", "router_threads", "r"))
runtime_batch_col <- first_existing_col(runtime_raw, c("batch_size", "batch"))
runtime_rtr_col <- first_existing_col(runtime_raw, c("rtr", "RTR", "rtr_median", "aggregated_rtr", "real_time_ratio"))
runtime_runtime_col <- first_existing_col(runtime_raw, c("runtime_s", "runtime_seconds", "wall_time_s", "duration_s"))

if (is.na(runtime_rtr_col) && is.na(runtime_runtime_col)) {
  stop("Runtime CSV contains neither RTR nor runtime_s-like column.")
}

runtime_norm <- runtime_raw %>%
  mutate(
    file_chr = as.character(.data[[runtime_file_col]]),
    parts = coalesce(
      if (!is.na(runtime_parts_col)) as_int_safe(.data[[runtime_parts_col]]) else NA_integer_,
      extract_int_from_file(file_chr, "(?:^|[_/-])sim([0-9]+)(?:_|$)")
    ),
    horizon = coalesce(
      if (!is.na(runtime_horizon_col)) as_int_safe(.data[[runtime_horizon_col]]) else NA_integer_,
      extract_int_from_file(file_chr, "(?:^|[_/-])hor([0-9]+)(?:_|$)")
    ),
    routing_threads = coalesce(
      if (!is.na(runtime_router_col)) as_int_safe(.data[[runtime_router_col]]) else NA_integer_,
      extract_int_from_file(file_chr, "(?:^|[_/-])r([0-9]+)(?:_|$)")
    ),
    batch_size = coalesce(
      if (!is.na(runtime_batch_col)) as_int_safe(.data[[runtime_batch_col]]) else NA_integer_,
      extract_int_from_file(file_chr, "(?:^|[_/-])batch([0-9]+)(?:_|$)")
    ),
    runtime_s = if (!is.na(runtime_runtime_col)) as_num_safe(.data[[runtime_runtime_col]]) else NA_real_,
    rtr = if (!is.na(runtime_rtr_col)) as_num_safe(.data[[runtime_rtr_col]]) else 86400 / runtime_s
  ) %>%
  filter(!is.na(parts), !is.na(horizon), !is.na(routing_threads), !is.na(batch_size), !is.na(rtr), is.finite(rtr))

if (length(horizons_keep) > 0) runtime_norm <- runtime_norm %>% filter(horizon %in% horizons_keep)
if (length(parts_keep) > 0) runtime_norm <- runtime_norm %>% filter(parts %in% parts_keep)
if (length(router_threads_keep) > 0) runtime_norm <- runtime_norm %>% filter(routing_threads %in% router_threads_keep)
if (length(batch_keep) > 0) runtime_norm <- runtime_norm %>% filter(batch_size %in% batch_keep)

if (nrow(runtime_norm) == 0) {
  stop("No runtime rows after filtering.")
}

config_scores <- runtime_norm %>%
  group_by(parts, routing_threads, batch_size) %>%
  summarise(
    n_runtime_rows = n(),
    n_horizons = n_distinct(horizon),
    horizons = paste(sort(unique(horizon)), collapse = ","),
    covers_all_horizons = all(horizons_keep %in% unique(horizon)),
    rtr_median_across_horizons = median(rtr, na.rm = TRUE),
    rtr_mean_across_horizons = mean(rtr, na.rm = TRUE),
    rtr_min = min(rtr, na.rm = TRUE),
    rtr_max = max(rtr, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  filter(covers_all_horizons) %>%
  arrange(rtr_median_across_horizons)

if (nrow(config_scores) == 0) {
  stop(
    "No configurations cover all requested horizons: ",
    paste(horizons_keep, collapse = ", "),
    ". Check HORIZONS_KEEP or available runtime data."
  )
}

global_median <- median(config_scores$rtr_median_across_horizons, na.rm = TRUE)

selected_configs <- bind_rows(
  config_scores %>%
    slice_max(rtr_median_across_horizons, n = 1, with_ties = FALSE) %>%
    mutate(selection = "fastest"),
  config_scores %>%
    mutate(distance_to_global_median = abs(rtr_median_across_horizons - global_median)) %>%
    slice_min(distance_to_global_median, n = 1, with_ties = FALSE) %>%
    select(-distance_to_global_median) %>%
    mutate(selection = "median_like"),
  config_scores %>%
    slice_min(rtr_median_across_horizons, n = 1, with_ties = FALSE) %>%
    mutate(selection = "slowest")
) %>%
  distinct(selection, parts, routing_threads, batch_size, .keep_all = TRUE) %>%
  mutate(
    selection = factor(selection, levels = c("fastest", "median_like", "slowest"))
  ) %>%
  arrange(selection)

readr::write_csv(config_scores, file.path(out_dir, "configuration_scores_by_median_rtr.csv"))
readr::write_csv(selected_configs, file.path(out_dir, "selected_representative_configurations.csv"))

file_index_raw <- readr::read_csv(file_index_path, show_col_types = FALSE)

idx_file_col <- first_existing_col(file_index_raw, c("file", "source_file", "path"))
idx_type_col <- first_existing_col(file_index_raw, c("file_type", "type"))
idx_parts_col <- first_existing_col(file_index_raw, c("parts", "partitions", "sim_cpus", "partition"))
idx_horizon_col <- first_existing_col(file_index_raw, c("horizon", "preplanning_horizon"))
idx_router_col <- first_existing_col(file_index_raw, c("router_threads", "routing_threads", "r"))
idx_batch_col <- first_existing_col(file_index_raw, c("batch_size", "batch"))

if (is.na(idx_file_col)) stop("file_index must contain a file column.")

file_index <- file_index_raw %>%
  mutate(
    file = as.character(.data[[idx_file_col]]),
    file_name = basename(file),
    file_type_norm = if (!is.na(idx_type_col)) as.character(.data[[idx_type_col]]) else NA_character_,
    parts = coalesce(
      if (!is.na(idx_parts_col)) as_int_safe(.data[[idx_parts_col]]) else NA_integer_,
      extract_int_from_file(file, "(?:^|[_/-])sim([0-9]+)(?:_|$)")
    ),
    horizon = coalesce(
      if (!is.na(idx_horizon_col)) as_int_safe(.data[[idx_horizon_col]]) else NA_integer_,
      extract_int_from_file(file, "(?:^|[_/-])hor([0-9]+)(?:_|$)")
    ),
    routing_threads = coalesce(
      if (!is.na(idx_router_col)) as_int_safe(.data[[idx_router_col]]) else NA_integer_,
      extract_int_from_file(file, "(?:^|[_/-])r([0-9]+)(?:_|$)")
    ),
    batch_size = coalesce(
      if (!is.na(idx_batch_col)) as_int_safe(.data[[idx_batch_col]]) else NA_integer_,
      extract_int_from_file(file, "(?:^|[_/-])batch([0-9]+)(?:_|$)")
    ),
    is_rust_routing = case_when(
      !is.na(file_type_norm) & file_type_norm == "rust_routing" ~ TRUE,
      str_detect(file_name, regex("rust.*routing.*requests|rust-routing-requests|routing.*requests", ignore_case = TRUE)) ~ TRUE,
      TRUE ~ FALSE
    )
  ) %>%
  filter(is_rust_routing, file.exists(file))

if (nrow(file_index) == 0) {
  stop("No rust_routing files found in file_index.")
}

classify_real_horizon <- function(real_horizon) {
  case_when(
    is.na(real_horizon) ~ NA_character_,
    real_horizon <= 0 ~ "0",
    real_horizon <= 300 ~ "(0,300]",
    real_horizon <= 600 ~ "(300,600]",
    real_horizon <= 1800 ~ "(600,1800]",
    TRUE ~ ">1800"
  )
}

load_plot_data_for_config <- function(cfg_row) {
  cfg_files <- file_index %>%
    filter(
      parts == cfg_row$parts,
      routing_threads == cfg_row$routing_threads,
      batch_size == cfg_row$batch_size,
      horizon %in% horizons_keep
    ) %>%
    arrange(horizon, file)

  if (nrow(cfg_files) == 0) {
    warning("No rust_routing files for selection ", as.character(cfg_row$selection),
            " parts=", cfg_row$parts,
            " routing_threads=", cfg_row$routing_threads,
            " batch_size=", cfg_row$batch_size)
    return(tibble())
  }

  all_rows <- vector("list", nrow(cfg_files))

  for (i in seq_len(nrow(cfg_files))) {
    f <- cfg_files$file[[i]]
    h <- cfg_files$horizon[[i]]

    message("[", as.character(cfg_row$selection), "] reading ", i, "/", nrow(cfg_files), ": ", basename(f))

    header <- read_csv_header(f)

    route_start_col <- pick_col(
      header,
      c("route_call_start_realtime", "routing_start_realtime", "routeCallStartRealtime"),
      required = TRUE,
      label = "routing start timestamp"
    )

    adapter_sent_col <- pick_col(
      header,
      c("adapter_sent_response_agent", "route_response_ready_realtime", "adapterSentResponseAgent"),
      required = TRUE,
      label = "adapter sent response timestamp"
    )

    blocking_wait_col <- pick_col(
      header,
      c("route_blocking_wait_ns", "last_route_blocking_wait_ns", "routeBlockingWaitNs"),
      required = TRUE,
      label = "route blocking wait ns"
    )

    now_col <- pick_col(header, c("now", "sim_time", "simulation_time"), required = FALSE, label = "now/sim_time")
    departure_col <- pick_col(header, c("departure_time", "departureTime"), required = FALSE, label = "departure_time")

    cols <- c(route_start_col, adapter_sent_col, blocking_wait_col, now_col, departure_col)
    dat <- read_csv_selected(f, cols)

    route_start <- as_num_safe(dat[[route_start_col]])
    adapter_sent <- as_num_safe(dat[[adapter_sent_col]])
    blocking_wait_ns <- as_num_safe(dat[[blocking_wait_col]])

    routing_duration_ms <- (adapter_sent - route_start) / 1e6
    blocking_recv_duration_ms <- pmax(0, blocking_wait_ns / 1e6)

    real_horizon <- rep(NA_real_, length(routing_duration_ms))
    if (!is.na(now_col) && !is.na(departure_col)) {
      real_horizon <- pmax(0, as_num_safe(dat[[departure_col]]) - as_num_safe(dat[[now_col]]))
    } else if (!is.na(now_col)) {
      now_vals <- as_num_safe(dat[[now_col]])
      real_horizon <- pmin(pmax(0, h), pmax(0, h))
      real_horizon <- rep(real_horizon, length(now_vals))
    }

    one <- tibble(
      selection = as.character(cfg_row$selection),
      parts = cfg_row$parts,
      routing_threads = cfg_row$routing_threads,
      batch_size = cfg_row$batch_size,
      horizon = h,
      source_file = f,
      routing_duration_ms = routing_duration_ms,
      blocking_recv_duration_ms = blocking_recv_duration_ms,
      plot_routing_duration_ms = pmax(routing_duration_ms, plot_min_ms),
      plot_blocking_recv_duration_ms = pmax(blocking_recv_duration_ms, plot_min_ms),
      real_horizon = real_horizon,
      real_horizon_group = classify_real_horizon(real_horizon)
    ) %>%
      filter(
        is.finite(routing_duration_ms),
        is.finite(blocking_recv_duration_ms),
        routing_duration_ms >= 0,
        blocking_recv_duration_ms >= 0,
        routing_duration_ms <= max_duration_ms,
        blocking_recv_duration_ms <= max_duration_ms
      )

    all_rows[[i]] <- one
    rm(dat, one)
    gc(verbose = FALSE)
  }

  bind_rows(all_rows)
}

plot_one_config <- function(plot_data, cfg_row) {
  if (nrow(plot_data) == 0) return(invisible(NULL))

  set.seed(random_seed)

  plot_data_sampled <- if (plot_sample_per_horizon > 0) {
    plot_data %>%
      group_by(horizon) %>%
      slice_sample(n = min(n(), plot_sample_per_horizon)) %>%
      ungroup()
  } else {
    plot_data
  }

  plot_data_sampled <- plot_data_sampled %>%
    mutate(
      horizon_label = factor(
        paste0("Preplanning horizon: ", horizon),
        levels = paste0("Preplanning horizon: ", horizons_keep)
      ),
      real_horizon_group = factor(
        real_horizon_group,
        levels = c("0", "(0,300]", "(300,600]", "(600,1800]", ">1800")
      )
    )

  max_axis <- max(c(
    plot_data_sampled$plot_routing_duration_ms,
    plot_data_sampled$plot_blocking_recv_duration_ms
  ), na.rm = TRUE)

  if (!is.finite(max_axis) || max_axis <= 0) max_axis <- 1

  subtitle <- paste0(
    cfg_row$selection,
    ": parts=", cfg_row$parts,
    ", routing_threads=", cfg_row$routing_threads,
    ", batch_size=", cfg_row$batch_size,
    "; Punkte je Horizon: ",
    ifelse(plot_sample_per_horizon > 0, as.character(plot_sample_per_horizon), "alle")
  )

  p <- ggplot(
    plot_data_sampled,
    aes(
      x = plot_routing_duration_ms,
      y = plot_blocking_recv_duration_ms,
      color = real_horizon_group
    )
  ) +
    geom_point(alpha = 0.45, size = 0.8, na.rm = TRUE) +
    geom_abline(slope = 1, intercept = 0, linetype = "dashed", linewidth = 0.45) +
    facet_wrap(~ horizon_label, ncol = 2) +
    scale_x_log10() +
    scale_y_log10() +
    coord_equal(xlim = c(plot_min_ms, max_axis), ylim = c(plot_min_ms, max_axis)) +
    labs(
      title = "Blocking receive duration by routing duration",
      subtitle = subtitle,
      x = "Routing duration [ms]",
      y = "Blocking recv duration [ms]",
      color = "Real horizon"
    ) +
    theme_eval()

  safe_selection <- str_replace_all(as.character(cfg_row$selection), "[^A-Za-z0-9_]+", "_")
  base_name <- paste0(
    "blocking_recv_vs_routing_duration_",
    safe_selection,
    "_parts", cfg_row$parts,
    "_rt", cfg_row$routing_threads,
    "_batch", cfg_row$batch_size
  )

  png_file <- file.path(out_dir, paste0(base_name, ".png"))
  pdf_file <- file.path(out_dir, paste0(base_name, ".pdf"))
  emf_file <- file.path(out_dir, paste0(base_name, ".emf"))
  data_file <- file.path(out_dir, paste0(base_name, "_plot_data.csv"))
  summary_file <- file.path(out_dir, paste0(base_name, "_summary.csv"))

  readr::write_csv(plot_data, data_file)

  summary <- plot_data %>%
    group_by(selection, parts, routing_threads, batch_size, horizon) %>%
    summarise(
      n = n(),
      routing_p50_ms = q_exact(routing_duration_ms, 0.50),
      routing_p95_ms = q_exact(routing_duration_ms, 0.95),
      routing_p99_ms = q_exact(routing_duration_ms, 0.99),
      routing_max_ms = max_exact(routing_duration_ms),
      blocking_p50_ms = q_exact(blocking_recv_duration_ms, 0.50),
      blocking_p95_ms = q_exact(blocking_recv_duration_ms, 0.95),
      blocking_p99_ms = q_exact(blocking_recv_duration_ms, 0.99),
      blocking_max_ms = max_exact(blocking_recv_duration_ms),
      blocking_share_gt_1ms = mean(blocking_recv_duration_ms > 1, na.rm = TRUE),
      blocking_share_gt_10ms = mean(blocking_recv_duration_ms > 10, na.rm = TRUE),
      .groups = "drop"
    )

  readr::write_csv(summary, summary_file)

  ggsave(png_file, p, width = 11.5, height = 8.0, dpi = 300)
  ggsave(pdf_file, p, width = 11.5, height = 8.0)

  if (requireNamespace("devEMF", quietly = TRUE)) {
    devEMF::emf(file = emf_file, width = 11.5, height = 8.0, bg = "white")
    print(p)
    grDevices::dev.off()
  } else {
    message("Package devEMF not installed; EMF skipped for ", base_name,
            ". Install with install.packages('devEMF').")
  }

  tibble(
    selection = as.character(cfg_row$selection),
    parts = cfg_row$parts,
    routing_threads = cfg_row$routing_threads,
    batch_size = cfg_row$batch_size,
    png = png_file,
    pdf = pdf_file,
    emf = if (file.exists(emf_file)) emf_file else NA_character_,
    data = data_file,
    summary = summary_file
  )
}

manifest_rows <- list()

for (i in seq_len(nrow(selected_configs))) {
  cfg <- selected_configs[i, ]
  dat <- load_plot_data_for_config(cfg)
  manifest_rows[[i]] <- plot_one_config(dat, cfg)
}

manifest <- bind_rows(manifest_rows)
readr::write_csv(manifest, file.path(out_dir, "representative_blocking_plots_manifest.csv"))

method_note <- c(
  "Representative blocking-vs-routing-duration plots",
  "",
  "Configuration selection:",
  "  1. Aggregate runtime CSV by parts, routing_threads and batch_size.",
  "  2. Keep only configurations that cover all selected horizons.",
  "  3. Score each remaining configuration by median RTR across selected horizons.",
  "  4. Select fastest = highest score, median_like = score closest to global median, slowest = lowest score.",
  "",
  "Blocking duration definition:",
  "  blocking_recv_duration_ms = route_blocking_wait_ns / 1e6",
  "",
  "Routing duration definition:",
  "  routing_duration_ms = (adapter_sent_response_agent - route_call_start_realtime) / 1e6",
  "",
  paste0("HORIZONS_KEEP = ", paste(horizons_keep, collapse = ",")),
  paste0("PLOT_SAMPLE_PER_HORIZON = ", plot_sample_per_horizon),
  paste0("PLOT_MIN_MS = ", plot_min_ms)
)

writeLines(method_note, file.path(out_dir, "README_representative_blocking_plots.txt"))

cat("Wrote outputs to:\n")
cat(out_dir, "\n\n")
cat("Selected configurations:\n")
print(selected_configs)
cat("\nManifest:\n")
print(manifest)
