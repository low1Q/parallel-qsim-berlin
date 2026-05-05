#!/usr/bin/env Rscript

# plot_blocking_recv_vs_routing_duration_reference_config_v3.R
#
# Ziel:
#   Darstellung analog zu Referenzplot, aber für deine Messdaten.
#
# Referenzplot-Konfiguration:
#   Berlin 1%, 64 partitions, 24 router threads
#
# Standard in diesem Skript:
#   REFERENCE_PARTS=64
#   REFERENCE_ROUTER_THREADS=24
#   REFERENCE_BATCH_SIZE=10000
#   HORIZONS_KEEP=0,200,600,1800
#
# Hinweis:
#   Referenzplot partitions=64 und router_threads=24.
#
# Aufruf:
#   Rscript R/plot_blocking_recv_vs_routing_duration_reference_config_v3.R \
#     output/analysis/file_index_recursive.csv \
#     output/analysis/simulation_runtimes_from_logs.csv \
#     output/analysis/Referenzplot_blocking_recv_reference_config
#
# Referenz:
#   REFERENCE_BATCH_SIZE=10000
#   REFERENCE_PARTS=64
#   REFERENCE_ROUTER_THREADS=24
#   HORIZONS_KEEP=0,200,600,1800
#   PLOT_SAMPLE_PER_HORIZON=50000
#   PLOT_MIN_MS=0.0003
#
# Falls du alle Punkte plotten willst:
#   PLOT_SAMPLE_PER_HORIZON=0
#
# Definitionen:
#
#   routing_duration_ms =
#     (adapter_sent_response_agent - route_call_start_realtime) / 1e6
#
#   blocking_recv_duration_ms =
#     route_blocking_wait_ns / 1e6
#
#   real_horizon_s =
#     departure_time - now
#
# Outputs:
#   selected_reference_configuration.csv
#   selected_reference_horizon_variants.csv
#   Referenzplot_reference_config_plot_data_summary.csv
#   Referenzplot_reference_config_plot_data_sample.csv
#   Referenzplot_reference_config_blocking_recv_vs_routing_duration.png
#   Referenzplot_reference_config_blocking_recv_vs_routing_duration.pdf
#   processing_errors.csv
#   README.txt

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
out_dir <- ifelse(length(args) >= 3, args[[3]], "output/analysis/Referenzplot_blocking_recv_reference_config")

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

if (!file.exists(file_index_path)) stop("File index not found: ", file_index_path)
if (!file.exists(runtime_file)) stop("Runtime file not found: ", runtime_file)

has_data_table <- requireNamespace("data.table", quietly = TRUE)

parse_keep_int <- function(x, default = NULL) {
  if (is.na(x) || !nzchar(x)) return(default)
  as.integer(trimws(strsplit(x, ",", fixed = TRUE)[[1]]))
}

horizons_keep <- parse_keep_int(Sys.getenv("HORIZONS_KEEP", "0,200,600,1800"), default = c(0L, 200L, 600L, 1800L))

reference_parts <- suppressWarnings(as.integer(Sys.getenv("REFERENCE_PARTS", "64")))
reference_router_threads <- suppressWarnings(as.integer(Sys.getenv("REFERENCE_ROUTER_THREADS", "24")))

reference_batch_size_env <- Sys.getenv("REFERENCE_BATCH_SIZE", "10000")
reference_batch_size <- if (nzchar(reference_batch_size_env)) suppressWarnings(as.integer(reference_batch_size_env)) else NA_integer_

if (!is.finite(reference_parts)) stop("REFERENCE_PARTS must be an integer.")
if (!is.finite(reference_router_threads)) stop("REFERENCE_ROUTER_THREADS must be an integer.")

plot_sample_per_horizon <- suppressWarnings(as.integer(Sys.getenv("PLOT_SAMPLE_PER_HORIZON", "50000")))
if (!is.finite(plot_sample_per_horizon) || plot_sample_per_horizon < 0) {
  plot_sample_per_horizon <- 50000L
}

plot_min_ms <- suppressWarnings(as.numeric(Sys.getenv("PLOT_MIN_MS", "0.0003")))
if (!is.finite(plot_min_ms) || plot_min_ms <= 0) {
  plot_min_ms <- 0.0003
}

max_duration_ms <- suppressWarnings(as.numeric(Sys.getenv("MAX_DURATION_MS", "600000")))
if (!is.finite(max_duration_ms) || max_duration_ms <= 0) {
  stop("MAX_DURATION_MS must be positive.")
}

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

to_num <- function(x) {
  if (inherits(x, "integer64")) return(as.numeric(as.character(x)))
  suppressWarnings(as.numeric(x))
}

read_header <- function(path) {
  if (has_data_table) {
    names(data.table::fread(path, nrows = 0, showProgress = FALSE))
  } else {
    names(readr::read_csv(path, n_max = 0, show_col_types = FALSE))
  }
}

read_csv_selected <- function(path, cols_needed) {
  cols_needed <- unique(cols_needed[!is.na(cols_needed) & nzchar(cols_needed)])

  if (has_data_table) {
    available <- names(data.table::fread(path, nrows = 0, showProgress = FALSE))
    cols_needed <- intersect(cols_needed, available)
    dat <- data.table::fread(path, select = cols_needed, showProgress = FALSE)
    as_tibble(dat)
  } else {
    readr::read_csv(
      path,
      col_select = any_of(cols_needed),
      show_col_types = FALSE,
      progress = FALSE
    )
  }
}

pick_col <- function(df_or_header, candidates, required = TRUE, label = "column") {
  header <- if (is.data.frame(df_or_header)) names(df_or_header) else df_or_header

  hit <- candidates[candidates %in% header]
  if (length(hit) > 0) return(hit[[1]])

  lower_header <- tolower(header)
  lower_candidates <- tolower(candidates)
  idx <- match(lower_candidates, lower_header)
  idx <- idx[!is.na(idx)]
  if (length(idx) > 0) return(header[[idx[[1]]]])

  if (required) {
    stop(
      "Missing required ", label, ". Tried: ",
      paste(candidates, collapse = ", "),
      ". Available columns include: ",
      paste(head(header, 80), collapse = ", ")
    )
  }

  NA_character_
}

q_exact <- function(x, p) {
  x <- to_num(x)
  x <- x[is.finite(x)]
  if (length(x) == 0) return(NA_real_)
  as.numeric(stats::quantile(x, probs = p, na.rm = TRUE, names = FALSE, type = 7))
}

mean_exact <- function(x) {
  x <- to_num(x)
  x <- x[is.finite(x)]
  if (length(x) == 0) return(NA_real_)
  mean(x)
}

max_exact <- function(x) {
  x <- to_num(x)
  x <- x[is.finite(x)]
  if (length(x) == 0) return(NA_real_)
  max(x)
}

safe_ggsave <- function(filename, plot, width, height, dpi = 200) {
  png_file <- filename
  pdf_file <- stringr::str_replace(filename, "\\.png$", ".pdf")
  emf_file <- stringr::str_replace(filename, "\\.png$", ".emf")

  ggplot2::ggsave(png_file, plot, width = width, height = height, dpi = dpi)
  ggplot2::ggsave(pdf_file, plot, width = width, height = height)

  if (requireNamespace("devEMF", quietly = TRUE)) {
    devEMF::emf(file = emf_file, width = width, height = height, bg = "white")
    print(plot)
    grDevices::dev.off()
  } else {
    message("Paket 'devEMF' nicht installiert; EMF wird übersprungen für: ", basename(emf_file),
            ". Installation: install.packages('devEMF')")
  }
}

# ------------------------------------------------------------
# 1) Runtime data for Reference config
# ------------------------------------------------------------

message("Reading runtime file: ", runtime_file)
rt_raw <- readr::read_csv(runtime_file, show_col_types = FALSE)

col_parts <- pick_col(rt_raw, c("parts", "sim_cpus", "SIM_CPUS", "partition_count", "partitionCount"), label = "parts")
col_horizon <- pick_col(rt_raw, c("horizon", "HORIZON", "preplanning_horizon", "PH", "pH"), label = "horizon")
col_router <- pick_col(rt_raw, c("router_threads", "ROUTER_THREADS", "routing_threads", "threads"), label = "router_threads")
col_batch <- pick_col(rt_raw, c("batch_size", "BATCH_SIZE", "batchSize", "batch"), label = "batch_size")
col_runtime <- pick_col(rt_raw, c("runtime_s", "runtime_sec", "walltime_s", "elapsed_s", "duration_s"), required = FALSE, label = "runtime")
col_rtr <- pick_col(rt_raw, c("rtr", "RTR", "real_time_ratio", "realTimeRatio"), required = FALSE, label = "RTR")
col_parse <- pick_col(rt_raw, c("parse_status"), required = FALSE, label = "parse_status")
col_completed <- pick_col(rt_raw, c("completed"), required = FALSE, label = "completed")

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
    parse_status == "ok",
    completed == TRUE,
    horizon %in% horizons_keep,
    parts == reference_parts,
    router_threads == reference_router_threads,
    !is.na(parts),
    !is.na(router_threads),
    !is.na(batch_size)
  )

if (is.finite(reference_batch_size)) {
  runtime_data <- runtime_data %>% filter(batch_size == reference_batch_size)
}

if (nrow(runtime_data) == 0) {
  stop(
    "No runtime rows found for Reference configuration. Tried parts=", reference_parts,
    ", router_threads=", reference_router_threads,
    ifelse(is.finite(reference_batch_size), paste0(", batch_size=", reference_batch_size), ", batch_size=<any>"),
    ", horizons=", paste(horizons_keep, collapse = ", ")
  )
}

# Falls REFERENCE_BATCH_SIZE leer ist, nimm den batch_size mit den meisten Horizon-Varianten.
if (!is.finite(reference_batch_size)) {
  selected_batch <- runtime_data %>%
    count(batch_size, name = "n_horizon_rows") %>%
    arrange(desc(n_horizon_rows), batch_size) %>%
    slice_head(n = 1) %>%
    pull(batch_size)

  runtime_data <- runtime_data %>% filter(batch_size == selected_batch)
  reference_batch_size <- selected_batch
}

selected_config <- tibble(
  selection = "reference_Referenzplot_configuration",
  parts = reference_parts,
  router_threads = reference_router_threads,
  batch_size = reference_batch_size,
  horizons = paste(horizons_keep, collapse = ","),
  n_runtime_rows = nrow(runtime_data),
  note = "Referenzplot uses Berlin 1%, 64 partitions and 24 router threads; batch_size is specific to this measurement setup."
)

readr::write_csv(selected_config, file.path(out_dir, "selected_reference_configuration.csv"))

message(
  "Using Reference config: parts=", reference_parts,
  ", router_threads=", reference_router_threads,
  ", batch_size=", reference_batch_size,
  ", horizons=", paste(horizons_keep, collapse = ", ")
)

# ------------------------------------------------------------
# 2) Select matching rust_routing files
# ------------------------------------------------------------

message("Reading file index: ", file_index_path)
idx <- readr::read_csv(file_index_path, show_col_types = FALSE)

required_index <- c("file", "file_type", "horizon", "parts", "router_threads", "batch_size", "config_key")
missing_index <- setdiff(required_index, names(idx))
if (length(missing_index) > 0) {
  stop("Missing required columns in file index: ", paste(missing_index, collapse = ", "))
}

selected_files <- idx %>%
  mutate(
    horizon = as.integer(horizon),
    batch_size = as.integer(batch_size),
    parts = as.integer(parts),
    router_threads = as.integer(router_threads)
  ) %>%
  filter(
    file_type == "rust_routing",
    horizon %in% horizons_keep,
    parts == reference_parts,
    router_threads == reference_router_threads,
    batch_size == reference_batch_size
  ) %>%
  arrange(horizon, file) %>%
  group_by(horizon, parts, router_threads, batch_size) %>%
  summarise(
    rust_routing_file = first(file),
    config_key = first(config_key),
    n_matching_files = n(),
    .groups = "drop"
  ) %>%
  left_join(
    runtime_data %>%
      select(horizon, parts, router_threads, batch_size, runtime_s, RTR),
    by = c("horizon", "parts", "router_threads", "batch_size")
  ) %>%
  arrange(horizon)

readr::write_csv(selected_files, file.path(out_dir, "selected_reference_horizon_variants.csv"))

missing_horizons <- setdiff(horizons_keep, selected_files$horizon)
if (length(missing_horizons) > 0) {
  warning("Missing rust_routing files for horizons: ", paste(missing_horizons, collapse = ", "))
}

if (nrow(selected_files) == 0) {
  stop("No rust_routing files found for Reference configuration.")
}

# ------------------------------------------------------------
# 3) Extract plot data
# ------------------------------------------------------------

plot_rows <- list()
summary_rows <- list()
errors <- list()

for (i in seq_len(nrow(selected_files))) {
  f <- selected_files$rust_routing_file[[i]]
  h <- selected_files$horizon[[i]]

  message(sprintf("[%d/%d] horizon=%s | %s", i, nrow(selected_files), h, basename(f)))

  tryCatch({
    header <- read_header(f)

    route_start_col <- pick_col(
      header,
      c("route_call_start_realtime", "routeCallStartRealtime"),
      required = TRUE,
      label = "route call start timestamp"
    )

    adapter_sent_col <- pick_col(
      header,
      c(
        "adapter_sent_response_agent",
        "adapter_response_sent_realtime",
        "adapter_sent_response_realtime",
        "adapter_sent_response_to_agent",
        "adapterSentResponseAgent"
      ),
      required = TRUE,
      label = "adapter sent response timestamp"
    )

    blocking_wait_col <- pick_col(
      header,
      c(
        "route_blocking_wait_ns",
        "last_route_blocking_wait_ns",
        "routeBlockingWaitNs"
      ),
      required = TRUE,
      label = "true route blocking wait"
    )

    now_col <- pick_col(header, c("now", "sim_time", "simulation_time"), required = FALSE, label = "now/sim_time")
    departure_col <- pick_col(header, c("departure_time", "departureTime"), required = FALSE, label = "departure_time")

    cols <- c(route_start_col, adapter_sent_col, blocking_wait_col, now_col, departure_col)
    dat <- read_csv_selected(f, cols)

    route_start <- to_num(dat[[route_start_col]])
    adapter_sent <- to_num(dat[[adapter_sent_col]])
    blocking_wait_ns <- to_num(dat[[blocking_wait_col]])

    routing_duration_ms <- (adapter_sent - route_start) / 1e6

    # Korrigierte Logik: echte blockierende Wartezeit aus route_blocking_wait_ns.
    # Die alte Timestamp-Differenz adapter_sent_response_agent - agent_received_response_adapter
    # ist keine echte Blocking-Wartezeit.
    blocking_recv_duration_ms <- pmax(0, blocking_wait_ns / 1e6)

    now <- if (!is.na(now_col) && now_col %in% names(dat)) to_num(dat[[now_col]]) else rep(NA_real_, nrow(dat))
    departure <- if (!is.na(departure_col) && departure_col %in% names(dat)) to_num(dat[[departure_col]]) else rep(NA_real_, nrow(dat))

    real_horizon_s <- departure - now

    tmp <- tibble(
      horizon = h,
      horizon_f = factor(paste0("Preplanning horizon: ", h), levels = paste0("Preplanning horizon: ", horizons_keep)),
      parts = selected_files$parts[[i]],
      router_threads = selected_files$router_threads[[i]],
      batch_size = selected_files$batch_size[[i]],
      runtime_s = selected_files$runtime_s[[i]],
      RTR = selected_files$RTR[[i]],
      routing_duration_ms = routing_duration_ms,
      blocking_recv_duration_ms = blocking_recv_duration_ms,
      plot_routing_duration_ms = pmax(routing_duration_ms, plot_min_ms),
      plot_blocking_recv_duration_ms = pmax(blocking_recv_duration_ms, plot_min_ms),
      real_horizon_s = real_horizon_s,
      real_horizon_bin = case_when(
        !is.finite(real_horizon_s) & h == 0 ~ "0",
        !is.finite(real_horizon_s) ~ NA_character_,
        real_horizon_s <= 0 ~ "0",
        real_horizon_s <= 300 ~ "(0,300]",
        real_horizon_s <= 600 ~ "(300,600]",
        real_horizon_s <= 1800 ~ "(600,1800]",
        TRUE ~ ">1800"
      )
    ) %>%
      filter(
        is.finite(routing_duration_ms),
        is.finite(blocking_recv_duration_ms),
        routing_duration_ms >= 0,
        blocking_recv_duration_ms >= 0,
        routing_duration_ms <= max_duration_ms,
        blocking_recv_duration_ms <= max_duration_ms
      ) %>%
      mutate(
        real_horizon_bin = factor(real_horizon_bin, levels = c("0", "(0,300]", "(300,600]", "(600,1800]", ">1800"))
      )

    if (nrow(tmp) == 0) {
      stop("No valid plot rows after filtering.")
    }

    plot_rows[[length(plot_rows) + 1]] <- tmp

    summary_rows[[length(summary_rows) + 1]] <- tmp %>%
      summarise(
        horizon = first(horizon),
        parts = first(parts),
        router_threads = first(router_threads),
        batch_size = first(batch_size),
        runtime_s = first(runtime_s),
        RTR = first(RTR),
        n_requests = n(),
        routing_duration_p50_ms = q_exact(routing_duration_ms, 0.50),
        routing_duration_p95_ms = q_exact(routing_duration_ms, 0.95),
        routing_duration_p99_ms = q_exact(routing_duration_ms, 0.99),
        blocking_recv_p50_ms = q_exact(blocking_recv_duration_ms, 0.50),
        blocking_recv_p95_ms = q_exact(blocking_recv_duration_ms, 0.95),
        blocking_recv_p99_ms = q_exact(blocking_recv_duration_ms, 0.99),
        blocking_recv_max_ms = max_exact(blocking_recv_duration_ms),
        blocking_share_gt_1ms = mean(blocking_recv_duration_ms > 1, na.rm = TRUE),
        blocking_share_gt_10ms = mean(blocking_recv_duration_ms > 10, na.rm = TRUE),
        real_horizon_p50_s = q_exact(real_horizon_s, 0.50),
        real_horizon_p95_s = q_exact(real_horizon_s, 0.95),
        source_file = f,
        .groups = "drop"
      ) %>%
      mutate(across(where(is.numeric), ~ round(.x, 6)))
  }, error = function(e) {
    errors[[length(errors) + 1]] <<- tibble(
      horizon = h,
      source_file = f,
      error = conditionMessage(e)
    )
  })

  gc(verbose = FALSE)
}

processing_errors <- if (length(errors) > 0) {
  bind_rows(errors)
} else {
  tibble(horizon = integer(), source_file = character(), error = character())
}
readr::write_csv(processing_errors, file.path(out_dir, "processing_errors.csv"))

if (length(plot_rows) == 0) {
  stop("No plot data produced. See processing_errors.csv.")
}

plot_data_all <- bind_rows(plot_rows)
summary_data <- bind_rows(summary_rows) %>% arrange(horizon)

readr::write_csv(summary_data, file.path(out_dir, "Referenzplot_reference_config_plot_data_summary.csv"))

# Robust horizon-wise sampling.
if (plot_sample_per_horizon > 0) {
  set.seed(20260501)
  plot_data <- plot_data_all %>%
    group_by(horizon) %>%
    mutate(.sample_order = runif(n())) %>%
    arrange(.sample_order, .by_group = TRUE) %>%
    mutate(.sample_rank = row_number()) %>%
    filter(.sample_rank <= pmin(plot_sample_per_horizon, n())) %>%
    ungroup() %>%
    select(-.sample_order, -.sample_rank)
} else {
  plot_data <- plot_data_all
}

readr::write_csv(
  plot_data %>%
    select(
      horizon, parts, router_threads, batch_size, RTR,
      routing_duration_ms, blocking_recv_duration_ms,
      plot_routing_duration_ms, plot_blocking_recv_duration_ms,
      real_horizon_s, real_horizon_bin
    ),
  file.path(out_dir, "Referenzplot_reference_config_plot_data_sample.csv")
)

# ------------------------------------------------------------
# 4) Referenzplot style plot
# ------------------------------------------------------------

plot_data <- plot_data %>%
  mutate(
    horizon_f = factor(paste0("Preplanning horizon: ", horizon), levels = paste0("Preplanning horizon: ", horizons_keep)),
    real_horizon_bin = factor(real_horizon_bin, levels = c("0", "(0,300]", "(300,600]", "(600,1800]", ">1800"))
  )

p <- ggplot(plot_data, aes(x = plot_routing_duration_ms, y = plot_blocking_recv_duration_ms)) +
  geom_point(aes(color = real_horizon_bin), alpha = 0.35, size = 0.45, na.rm = TRUE) +
  geom_abline(slope = 1, intercept = 0, linetype = "dashed", linewidth = 0.35) +
  facet_wrap(~ horizon_f, ncol = 2) +
  scale_x_log10() +
  scale_y_log10() +
  labs(
    title = "Blocking receive duration by routing duration",
    subtitle = paste0(
      "Referenzkonfiguration: parts=", reference_parts,
      ", routing_threads=", reference_router_threads,
      ", batch_size=", reference_batch_size,
      "; Punkte ggf. je Horizon auf ", plot_sample_per_horizon, " gesampelt"
    ),
    x = "Routing duration [ms]",
    y = "Blocking recv duration [ms]",
    color = "Real horizon"
  ) +
  theme_bw() +
  theme(
    legend.position = "right",
    panel.grid.minor = element_blank()
  )

safe_width <- 9
safe_height <- 7

ggsave(file.path(out_dir, "Referenzplot_reference_config_blocking_recv_vs_routing_duration.png"), p, width = safe_width, height = safe_height, dpi = 300)
ggsave(file.path(out_dir, "Referenzplot_reference_config_blocking_recv_vs_routing_duration.pdf"), p, width = safe_width, height = safe_height)

if (plot_sample_per_horizon == 0 || nrow(plot_data_all) <= 200000) {
  plot_data_all_for_plot <- plot_data_all %>%
    mutate(
      horizon_f = factor(paste0("Preplanning horizon: ", horizon), levels = paste0("Preplanning horizon: ", horizons_keep)),
      real_horizon_bin = factor(real_horizon_bin, levels = c("0", "(0,300]", "(300,600]", "(600,1800]", ">1800"))
    )

  p_all <- ggplot(plot_data_all_for_plot, aes(x = plot_routing_duration_ms, y = plot_blocking_recv_duration_ms)) +
    geom_point(aes(color = real_horizon_bin), alpha = 0.35, size = 0.45, na.rm = TRUE) +
    geom_abline(slope = 1, intercept = 0, linetype = "dashed", linewidth = 0.35) +
    facet_wrap(~ horizon_f, ncol = 2) +
    scale_x_log10() +
    scale_y_log10() +
    labs(
      title = "Blocking receive duration by routing duration",
      subtitle = paste0(
        "Referenzkonfiguration: parts=", reference_parts,
        ", routing_threads=", reference_router_threads,
        ", batch_size=", reference_batch_size,
        "; alle Punkte"
      ),
      x = "Routing duration [ms]",
      y = "Blocking recv duration [ms]",
      color = "Real horizon"
    ) +
    theme_bw() +
    theme(
      legend.position = "right",
      panel.grid.minor = element_blank()
    )

  ggsave(file.path(out_dir, "Referenzplot_reference_config_blocking_recv_vs_routing_duration_no_sample.png"), p_all, width = safe_width, height = safe_height, dpi = 300)
}

readme <- c(
  "Referenzplot-style plot for Reference configuration",
  "=============================================",
  "",
  paste0("File index: ", file_index_path),
  paste0("Runtime file: ", runtime_file),
  paste0("Output directory: ", out_dir),
  "",
  "Reference Referenzplot configuration:",
  "Berlin 1%, 64 partitions and 24 router threads.",
  "This script uses REFERENCE_PARTS=64 and REFERENCE_ROUTER_THREADS=24 by default.",
  "Because batch_size is specific to this measurement setup and not part of Reference caption, REFERENCE_BATCH_SIZE is configurable.",
  "",
  paste0("REFERENCE_PARTS: ", reference_parts),
  paste0("REFERENCE_ROUTER_THREADS: ", reference_router_threads),
  paste0("REFERENCE_BATCH_SIZE: ", reference_batch_size),
  paste0("HORIZONS_KEEP: ", paste(horizons_keep, collapse = ", ")),
  "",
  "Definitions:",
  "routing_duration_ms = (adapter_sent_response_agent - route_call_start_realtime) / 1e6",
  "blocking_recv_duration_ms = route_blocking_wait_ns / 1e6",
  "real_horizon_s = departure_time - now",
  "",
  "Log-scale plotting:",
  paste0("Values equal to zero are plotted at PLOT_MIN_MS=", plot_min_ms, " ms."),
  "The original unclipped values are preserved in Referenzplot_reference_config_plot_data_sample.csv.",
  "",
  "If data.table::fread reports 'Discarded single-line footer', this usually means a CSV ended with one truncated/incomplete line.",
  "The affected footer line is ignored by fread; the rest of the file is still processed.",
  "",
  "Main outputs:",
  "- selected_reference_configuration.csv",
  "- selected_reference_horizon_variants.csv",
  "- Referenzplot_reference_config_plot_data_summary.csv",
  "- Referenzplot_reference_config_plot_data_sample.csv",
  "- Referenzplot_reference_config_blocking_recv_vs_routing_duration.png",
  "- Referenzplot_reference_config_blocking_recv_vs_routing_duration.pdf",
  "- processing_errors.csv"
)

writeLines(readme, file.path(out_dir, "README.txt"))

message("Done. Outputs written to: ", out_dir)
message("Main plot: ", file.path(out_dir, "Referenzplot_reference_config_blocking_recv_vs_routing_duration.png"))
message("Summary: ", file.path(out_dir, "Referenzplot_reference_config_plot_data_summary.csv"))
