#!/usr/bin/env Rscript

# analyze_blocking_wait_by_departure_minus_now.R
#
# Fragestellung:
#   Gibt es einen Zusammenhang zwischen
#     departure_time - now
#   und der blockierenden Wartezeit?
#
# Interpretation:
#   departure_time - now beschreibt den realen Preplanning-Horizon einer
#   Routinganfrage in Simulationssekunden. Kleine Werte bedeuten, dass die
#   Routinganfrage kurz vor der Abfahrt gestellt wurde. Dann ist es plausibler,
#   dass die Antwort noch nicht vorliegt und die Simulation blockieren muss.
#
# Das Skript verarbeitet rust-routing-requests-CSV-Dateien.
#
# Standardfilter:
#   HORIZON_KEEP=600
#
# Referenz:
#   HORIZON_KEEP=600
#   BATCH_KEEP=500,10000,25000,45000
#   ROUTER_THREADS_KEEP=1,24,48,96
#   PARTS_KEEP=1,32,192
#   BLOCKING_THRESHOLD_MS=0.001
#   MIN_EXACT_COUNT=30
#   SAMPLE_PER_FILE=2000
#   SAVE_SLIM=0
#
# Aufruf:
#   Rscript R/analyze_blocking_wait_by_departure_minus_now.R \
#     output/analysis/file_index_recursive.csv \
#     output/analysis/blocking_wait_by_departure_minus_now_h600
#
# Beispiel:
#   HORIZON_KEEP=600 BATCH_KEEP=10000,25000 ROUTER_THREADS_KEEP=24,96 PARTS_KEEP=1,32,192 \
#   Rscript R/analyze_blocking_wait_by_departure_minus_now.R \
#     output/analysis/file_index_recursive.csv \
#     output/analysis/blocking_wait_by_departure_minus_now_h600_subset

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(tidyr)
  library(stringr)
  library(ggplot2)
})

args <- commandArgs(trailingOnly = TRUE)

file_index_path <- ifelse(length(args) >= 1, args[[1]], "output/analysis/file_index_recursive.csv")
out_dir <- ifelse(length(args) >= 2, args[[2]], "output/analysis/blocking_wait_by_departure_minus_now")

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

if (!file.exists(file_index_path)) {
  stop("File index not found: ", file_index_path)
}

has_data_table <- requireNamespace("data.table", quietly = TRUE)

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

parse_keep <- function(x) {
  if (is.na(x) || !nzchar(x)) return(NULL)
  as.integer(trimws(strsplit(x, ",", fixed = TRUE)[[1]]))
}

horizon_keep <- parse_keep(Sys.getenv("HORIZON_KEEP", "600"))
batch_keep <- parse_keep(Sys.getenv("BATCH_KEEP", ""))
router_keep <- parse_keep(Sys.getenv("ROUTER_THREADS_KEEP", ""))
parts_keep <- parse_keep(Sys.getenv("PARTS_KEEP", ""))

blocking_threshold_ms <- suppressWarnings(as.numeric(Sys.getenv("BLOCKING_THRESHOLD_MS", "0.001")))
min_exact_count <- suppressWarnings(as.integer(Sys.getenv("MIN_EXACT_COUNT", "30")))
sample_per_file <- suppressWarnings(as.integer(Sys.getenv("SAMPLE_PER_FILE", "2000")))
save_slim <- Sys.getenv("SAVE_SLIM", "0") == "1"

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

safe_num <- function(df, col) {
  if (col %in% names(df)) {
    suppressWarnings(as.numeric(df[[col]]))
  } else {
    rep(NA_real_, nrow(df))
  }
}

safe_duration_ms <- function(df, ms_col, ns_col) {
  if (ms_col %in% names(df)) {
    return(suppressWarnings(as.numeric(df[[ms_col]])))
  }
  if (ns_col %in% names(df)) {
    return(suppressWarnings(as.numeric(df[[ns_col]])) / 1e6)
  }
  rep(NA_real_, nrow(df))
}

first_existing_col <- function(df, candidates) {
  hit <- candidates[candidates %in% names(df)]
  if (length(hit) == 0) return(NA_character_)
  hit[[1]]
}

summarise_blocking <- function(df) {
  df %>%
    summarise(
      n_requests = n(),
      n_blocked_gt0 = sum(blocking_wait_ms > 0, na.rm = TRUE),
      n_blocked_threshold = sum(blocking_wait_ms > blocking_threshold_ms, na.rm = TRUE),
      wait_share_gt0 = n_blocked_gt0 / n_requests,
      wait_share_threshold = n_blocked_threshold / n_requests,

      departure_minus_now_p50_s = median(departure_minus_now_s, na.rm = TRUE),
      departure_minus_now_p95_s = as.numeric(quantile(departure_minus_now_s, 0.95, na.rm = TRUE, names = FALSE)),

      blocking_wait_p50_ms = median(blocking_wait_ms, na.rm = TRUE),
      blocking_wait_p90_ms = as.numeric(quantile(blocking_wait_ms, 0.90, na.rm = TRUE, names = FALSE)),
      blocking_wait_p95_ms = as.numeric(quantile(blocking_wait_ms, 0.95, na.rm = TRUE, names = FALSE)),
      blocking_wait_p99_ms = as.numeric(quantile(blocking_wait_ms, 0.99, na.rm = TRUE, names = FALSE)),
      blocking_wait_max_ms = max(blocking_wait_ms, na.rm = TRUE),

      spearman_cor = suppressWarnings(cor(departure_minus_now_s, blocking_wait_ms, method = "spearman", use = "complete.obs")),
      pearson_cor = suppressWarnings(cor(departure_minus_now_s, blocking_wait_ms, method = "pearson", use = "complete.obs")),
      .groups = "drop"
    ) %>%
    mutate(
      across(
        c(wait_share_gt0, wait_share_threshold,
          departure_minus_now_p50_s, departure_minus_now_p95_s,
          blocking_wait_p50_ms, blocking_wait_p90_ms,
          blocking_wait_p95_ms, blocking_wait_p99_ms, blocking_wait_max_ms,
          spearman_cor, pearson_cor),
        ~ round(.x, 6)
      )
    )
}

save_plot <- function(p, filename, width, height) {
  png_path <- file.path(out_dir, filename)
  pdf_path <- stringr::str_replace(png_path, "\\.png$", ".pdf")
  emf_path <- stringr::str_replace(png_path, "\\.png$", ".emf")

  ggplot2::ggsave(png_path, p, width = width, height = height, dpi = 200)
  ggplot2::ggsave(pdf_path, p, width = width, height = height)

  if (requireNamespace("devEMF", quietly = TRUE)) {
    devEMF::emf(file = emf_path, width = width, height = height, bg = "white")
    print(p)
    grDevices::dev.off()
  } else {
    message("Paket 'devEMF' nicht installiert; EMF wird übersprungen für: ", basename(emf_path),
            ". Installation: install.packages('devEMF')")
  }
}

# ------------------------------------------------------------
# Select files
# ------------------------------------------------------------

message("Reading file index: ", file_index_path)
idx <- readr::read_csv(file_index_path, show_col_types = FALSE)

required_cols <- c("file", "file_type", "horizon", "parts", "router_threads", "batch_size")
missing_cols <- setdiff(required_cols, names(idx))
if (length(missing_cols) > 0) {
  stop("Missing required columns in file index: ", paste(missing_cols, collapse = ", "))
}

idx <- idx %>%
  filter(file_type == "rust_routing") %>%
  mutate(
    horizon = as.integer(horizon),
    batch_size = as.integer(batch_size),
    router_threads = as.integer(router_threads),
    parts = as.integer(parts)
  )

if (!is.null(horizon_keep)) idx <- idx %>% filter(horizon %in% horizon_keep)
if (!is.null(batch_keep)) idx <- idx %>% filter(batch_size %in% batch_keep)
if (!is.null(router_keep)) idx <- idx %>% filter(router_threads %in% router_keep)
if (!is.null(parts_keep)) idx <- idx %>% filter(parts %in% parts_keep)

idx <- idx %>% arrange(horizon, batch_size, parts, router_threads, file)

if (nrow(idx) == 0) {
  stop("No rust_routing files after filtering.")
}

readr::write_csv(idx, file.path(out_dir, "selected_rust_routing_files.csv"))

message("Selected rust_routing files: ", nrow(idx))
print(idx %>% count(horizon, batch_size, parts, router_threads, name = "n_files"))

# ------------------------------------------------------------
# Process files into slim data
# ------------------------------------------------------------

process_file <- function(row) {
  path <- row$file[[1]]
  dat <- read_csv_fast(path)

  departure_time <- safe_num(dat, "departure_time")

  # now-Spalte suchen. Falls sie nicht existiert, ist route_end_to_end_sim_time
  # in deinen Daten sehr wahrscheinlich bereits departure_time - now.
  now_col <- first_existing_col(
    dat,
    c("now", "current_time", "route_call_start_sim_time", "request_time", "qsim_now", "sim_time", "time")
  )

  if (!is.na(now_col)) {
    now <- safe_num(dat, now_col)
    departure_minus_now_s <- departure_time - now
    horizon_source <- paste0("departure_time_minus_", now_col)
  } else if ("route_end_to_end_sim_time" %in% names(dat)) {
    departure_minus_now_s <- safe_num(dat, "route_end_to_end_sim_time")
    horizon_source <- "route_end_to_end_sim_time"
  } else {
    departure_minus_now_s <- rep(NA_real_, nrow(dat))
    horizon_source <- "missing"
  }

  blocking_wait_ms <- safe_duration_ms(dat, "route_blocking_wait_ms", "route_blocking_wait_ns")

  slim <- tibble(
    horizon = row$horizon[[1]],
    batch_size = row$batch_size[[1]],
    parts = row$parts[[1]],
    router_threads = row$router_threads[[1]],
    config_key = row$config_key[[1]],
    source_file = path,
    horizon_source = horizon_source,
    departure_minus_now_s = departure_minus_now_s,
    departure_minus_now_s_round = round(departure_minus_now_s),
    blocking_wait_ms = blocking_wait_ms
  ) %>%
    filter(
      is.finite(departure_minus_now_s),
      is.finite(blocking_wait_ms),
      departure_minus_now_s >= -1,
      departure_minus_now_s <= 86400,
      blocking_wait_ms >= 0,
      blocking_wait_ms <= 10 * 60 * 1000
    ) %>%
    mutate(
      blocked_gt0 = blocking_wait_ms > 0,
      blocked_threshold = blocking_wait_ms > blocking_threshold_ms,
      horizon_bin = cut(
        departure_minus_now_s,
        breaks = c(-Inf, 0, 1, 5, 10, 30, 60, 120, 300, 600, 1800, Inf),
        labels = c("<=0", "(0,1]", "(1,5]", "(5,10]", "(10,30]", "(30,60]",
                   "(60,120]", "(120,300]", "(300,600]", "(600,1800]", ">1800"),
        right = TRUE
      )
    )

  if (nrow(slim) == 0) {
    sample_rows <- slim
  } else {
    n_sample <- min(sample_per_file, nrow(slim))
    sample_rows <- slim %>% slice_sample(n = n_sample)
  }

  list(
    slim = slim,
    sample = sample_rows,
    method = tibble(
      source_file = path,
      config_key = row$config_key[[1]],
      horizon = row$horizon[[1]],
      batch_size = row$batch_size[[1]],
      parts = row$parts[[1]],
      router_threads = row$router_threads[[1]],
      horizon_source = horizon_source,
      rows_after_filter = nrow(slim)
    )
  )
}

slim_list <- vector("list", nrow(idx))
sample_list <- vector("list", nrow(idx))
method_list <- vector("list", nrow(idx))
errors <- list()

for (i in seq_len(nrow(idx))) {
  row <- idx[i, ]
  message(sprintf("[%d/%d] %s", i, nrow(idx), basename(row$file[[1]])))

  res <- tryCatch(
    process_file(row),
    error = function(e) {
      errors[[length(errors) + 1]] <<- tibble(
        source_file = row$file[[1]],
        config_key = row$config_key[[1]],
        horizon = row$horizon[[1]],
        batch_size = row$batch_size[[1]],
        parts = row$parts[[1]],
        router_threads = row$router_threads[[1]],
        error = conditionMessage(e)
      )
      NULL
    }
  )

  if (!is.null(res)) {
    slim_list[[i]] <- res$slim
    sample_list[[i]] <- res$sample
    method_list[[i]] <- res$method
  }

  rm(res)
  gc(verbose = FALSE)
}

slim_data <- bind_rows(slim_list)
sample_data <- bind_rows(sample_list)
method_data <- bind_rows(method_list)

errors_df <- if (length(errors) > 0) bind_rows(errors) else tibble(
  source_file = character(),
  config_key = character(),
  horizon = integer(),
  batch_size = integer(),
  parts = integer(),
  router_threads = integer(),
  error = character()
)

readr::write_csv(method_data, file.path(out_dir, "departure_minus_now_source_by_file.csv"))
readr::write_csv(errors_df, file.path(out_dir, "processing_errors.csv"))

if (save_slim) {
  readr::write_csv(slim_data, file.path(out_dir, "blocking_wait_departure_minus_now_slim.csv"))
}

if (nrow(slim_data) == 0) {
  stop("No usable rows after processing.")
}

# ------------------------------------------------------------
# Summaries
# ------------------------------------------------------------

overall_summary <- slim_data %>%
  summarise_blocking()

readr::write_csv(overall_summary, file.path(out_dir, "overall_summary.csv"))

summary_by_bin <- slim_data %>%
  group_by(horizon_bin) %>%
  summarise_blocking() %>%
  arrange(horizon_bin)

readr::write_csv(summary_by_bin, file.path(out_dir, "summary_by_departure_minus_now_bin.csv"))

summary_by_config_and_bin <- slim_data %>%
  group_by(horizon, batch_size, parts, router_threads, horizon_bin) %>%
  summarise_blocking() %>%
  arrange(batch_size, parts, router_threads, horizon_bin)

readr::write_csv(summary_by_config_and_bin, file.path(out_dir, "summary_by_config_and_departure_minus_now_bin.csv"))

summary_by_exact <- slim_data %>%
  group_by(departure_minus_now_s_round) %>%
  summarise_blocking() %>%
  filter(n_requests >= min_exact_count) %>%
  arrange(departure_minus_now_s_round)

readr::write_csv(summary_by_exact, file.path(out_dir, "summary_by_exact_departure_minus_now_second.csv"))

summary_by_config <- slim_data %>%
  group_by(horizon, batch_size, parts, router_threads) %>%
  summarise_blocking() %>%
  arrange(batch_size, parts, router_threads)

readr::write_csv(summary_by_config, file.path(out_dir, "summary_by_config.csv"))

# ------------------------------------------------------------
# Plots
# ------------------------------------------------------------

plot_bin <- summary_by_bin %>%
  mutate(horizon_bin = factor(horizon_bin, levels = levels(slim_data$horizon_bin)))


save_plot_with_emf <- function(plot, filename_base, width, height, dpi = 200) {
  png_file <- file.path(out_dir, paste0(filename_base, ".png"))
  pdf_file <- file.path(out_dir, paste0(filename_base, ".pdf"))
  emf_file <- file.path(out_dir, paste0(filename_base, ".emf"))

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

p1 <- ggplot(plot_bin, aes(x = horizon_bin, y = wait_share_threshold)) +
  geom_col() +
  labs(
    title = "Anteil blockierender Routinganfragen nach departure_time - now",
    subtitle = paste0("Blocking definiert als blocking_wait_ms > ", blocking_threshold_ms, " ms"),
    x = "departure_time - now [s]",
    y = "Anteil blockierender Anfragen"
  ) +
  theme_bw() +
  theme(axis.text.x = element_text(angle = 35, hjust = 1))

save_plot(p1, "plot_1_blocking_share_by_departure_minus_now_bin.png", width = 10, height = 6)

p2 <- ggplot(plot_bin, aes(x = horizon_bin, y = blocking_wait_p95_ms)) +
  geom_col() +
  labs(
    title = "p95 der Blocking-Wait-Zeit nach departure_time - now",
    x = "departure_time - now [s]",
    y = "blocking_wait_ms p95 [ms]"
  ) +
  theme_bw() +
  theme(axis.text.x = element_text(angle = 35, hjust = 1))

save_plot(p2, "plot_2_blocking_wait_p95_by_departure_minus_now_bin.png", width = 10, height = 6)

sample_plot <- sample_data %>%
  mutate(
    blocking_wait_ms_for_log = pmax(blocking_wait_ms, 1e-6),
    batch_size_f = factor(batch_size, levels = sort(unique(batch_size)))
  )

p3 <- ggplot(sample_plot, aes(x = departure_minus_now_s, y = blocking_wait_ms_for_log)) +
  geom_point(alpha = 0.25, size = 0.6) +
  scale_y_log10() +
  facet_wrap(~ batch_size_f, labeller = label_both) +
  labs(
    title = "Zusammenhang zwischen departure_time - now und Blocking Wait",
    subtitle = "Stichprobe aus den Routinganfragen; y-Achse logarithmisch, Nullwerte bei 1e-6 ms",
    x = "departure_time - now [s]",
    y = "blocking_wait_ms [log10]"
  ) +
  theme_bw()

save_plot(p3, "plot_3_scatter_departure_minus_now_vs_blocking_wait_sample.png", width = 11, height = 7)

plot_config_bin <- summary_by_config_and_bin %>%
  mutate(
    horizon_bin = factor(horizon_bin, levels = levels(slim_data$horizon_bin)),
    batch_size_f = factor(batch_size, levels = sort(unique(batch_size))),
    parts_f = factor(parts, levels = sort(unique(parts))),
    router_threads_f = factor(router_threads, levels = sort(unique(router_threads)))
  )

p4 <- ggplot(plot_config_bin, aes(x = horizon_bin, y = wait_share_threshold, group = router_threads_f, linetype = router_threads_f)) +
  geom_line(na.rm = TRUE) +
  geom_point(na.rm = TRUE, size = 1.5) +
  facet_grid(parts_f ~ batch_size_f, labeller = label_both) +
  labs(
    title = "Blocking-Anteil nach departure_time - now je Konfiguration",
    subtitle = paste0("Blocking definiert als blocking_wait_ms > ", blocking_threshold_ms, " ms"),
    x = "departure_time - now [s]",
    y = "Anteil blockierender Anfragen",
    linetype = "Routing-Threads"
  ) +
  theme_bw() +
  theme(
    axis.text.x = element_text(angle = 35, hjust = 1),
    legend.position = "bottom"
  )

save_plot(p4, "plot_4_blocking_share_by_bin_and_config.png", width = 13, height = 8)

# Referenz exact-second plot for values with enough observations.
if (nrow(summary_by_exact) > 0) {
  p5 <- ggplot(summary_by_exact, aes(x = departure_minus_now_s_round, y = wait_share_threshold)) +
    geom_line() +
    geom_point(size = 1) +
    labs(
      title = "Blocking-Anteil nach exaktem gerundetem departure_time - now",
      subtitle = paste0("Nur Werte mit mindestens ", min_exact_count, " Anfragen"),
      x = "departure_time - now [s], gerundet",
      y = "Anteil blockierender Anfragen"
    ) +
    theme_bw()

  save_plot(p5, "plot_5_blocking_share_by_exact_departure_minus_now_second.png", width = 11, height = 6)
}

# ------------------------------------------------------------
# README
# ------------------------------------------------------------

readme <- c(
  "Blocking wait by departure_time - now",
  "=====================================",
  "",
  paste0("Input file index: ", file_index_path),
  paste0("Selected files: ", nrow(idx)),
  paste0("Usable rows: ", nrow(slim_data)),
  "",
  "Interpretation:",
  "- departure_time - now is the real preplanning horizon in simulation seconds.",
  "- Smaller values mean the request was issued shortly before departure.",
  "- If blocking_wait_ms increases for small values, the preplanning buffer was insufficient.",
  "",
  "Blocking definition:",
  paste0("- gt0: blocking_wait_ms > 0"),
  paste0("- threshold: blocking_wait_ms > ", blocking_threshold_ms, " ms"),
  "",
  "Outputs:",
  "- overall_summary.csv",
  "- summary_by_departure_minus_now_bin.csv",
  "- summary_by_exact_departure_minus_now_second.csv",
  "- summary_by_config.csv",
  "- summary_by_config_and_departure_minus_now_bin.csv",
  "- departure_minus_now_source_by_file.csv",
  "- processing_errors.csv",
  "",
  "Plots:",
  "- plot_1_blocking_share_by_departure_minus_now_bin.png",
  "- plot_2_blocking_wait_p95_by_departure_minus_now_bin.png",
  "- plot_3_scatter_departure_minus_now_vs_blocking_wait_sample.png",
  "- plot_4_blocking_share_by_bin_and_config.png",
  "- plot_5_blocking_share_by_exact_departure_minus_now_second.png",
  "",
  "Applied filters:",
  paste0("- HORIZON_KEEP: ", ifelse(is.null(horizon_keep), "none", paste(horizon_keep, collapse = ", "))),
  paste0("- BATCH_KEEP: ", ifelse(is.null(batch_keep), "none", paste(batch_keep, collapse = ", "))),
  paste0("- ROUTER_THREADS_KEEP: ", ifelse(is.null(router_keep), "none", paste(router_keep, collapse = ", "))),
  paste0("- PARTS_KEEP: ", ifelse(is.null(parts_keep), "none", paste(parts_keep, collapse = ", ")))
)

writeLines(readme, file.path(out_dir, "README.txt"))

message("Done. Outputs written to: ", out_dir)
