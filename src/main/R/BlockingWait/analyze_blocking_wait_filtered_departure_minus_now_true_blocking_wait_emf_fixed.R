#!/usr/bin/env Rscript

# analyze_blocking_wait_filtered_departure_minus_now.R
#
# Ziel:
#   Messdaten nach realem Preplanning-Horizon filtern:
#     departure_time - now >= 30
#
#   Danach werden nur noch diese Messdaten verwendet, um blocking_wait_ms
#   zusammenzufassen.
#
# Motivation:
#   Wenn die Blocking-Wartezeiten nach Entfernen der Fälle mit sehr kleinem
#   departure_time - now nahezu verschwinden, spricht das dafür, dass die
#   Blocking-Wartezeiten vor allem durch einen zu kleinen realen Preplanning-
#   Puffer entstehen und nicht primär durch die technische Router-Latenz.
#
# Input:
#   output/analysis/file_index_recursive.csv
#
# Aufruf:
#   Rscript R/analyze_blocking_wait_filtered_departure_minus_now.R \
#     output/analysis/file_index_recursive.csv \
#     output/analysis/blocking_wait_departure_ge30_h600
#
# Standardfilter:
#   HORIZON_KEEP=600
#   MIN_DEPARTURE_MINUS_NOW=30
#
# Referenz:
#   HORIZON_KEEP=600
#   BATCH_KEEP=500,10000,25000,45000
#   ROUTER_THREADS_KEEP=1,24,48,96
#   PARTS_KEEP=1,32,192
#   MIN_DEPARTURE_MINUS_NOW=30
#   BLOCKING_THRESHOLD_MS=0.001
#
# Beispiel:
#   HORIZON_KEEP=600 MIN_DEPARTURE_MINUS_NOW=30 \
#   Rscript R/analyze_blocking_wait_filtered_departure_minus_now.R \
#     output/analysis/file_index_recursive.csv \
#     output/analysis/blocking_wait_departure_ge30_h600

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(tidyr)
  library(stringr)
  library(ggplot2)
})

args <- commandArgs(trailingOnly = TRUE)

file_index_path <- ifelse(length(args) >= 1, args[[1]], "output/analysis/file_index_recursive.csv")
out_dir <- ifelse(length(args) >= 2, args[[2]], "output/analysis/blocking_wait_departure_ge30")

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

if (!file.exists(file_index_path)) {
  stop("File index not found: ", file_index_path)
}

has_data_table <- requireNamespace("data.table", quietly = TRUE)

# ------------------------------------------------------------
# Parameters
# ------------------------------------------------------------

parse_keep <- function(x) {
  if (is.na(x) || !nzchar(x)) return(NULL)
  as.integer(trimws(strsplit(x, ",", fixed = TRUE)[[1]]))
}

horizon_keep <- parse_keep(Sys.getenv("HORIZON_KEEP", "600"))
batch_keep <- parse_keep(Sys.getenv("BATCH_KEEP", ""))
router_keep <- parse_keep(Sys.getenv("ROUTER_THREADS_KEEP", ""))
parts_keep <- parse_keep(Sys.getenv("PARTS_KEEP", ""))

min_departure_minus_now <- suppressWarnings(as.numeric(Sys.getenv("MIN_DEPARTURE_MINUS_NOW", "30")))
blocking_threshold_ms <- suppressWarnings(as.numeric(Sys.getenv("BLOCKING_THRESHOLD_MS", "0.001")))

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
      blocking_wait_mean_ms = mean(blocking_wait_ms, na.rm = TRUE),
      blocking_wait_p50_ms = median(blocking_wait_ms, na.rm = TRUE),
      blocking_wait_p90_ms = as.numeric(quantile(blocking_wait_ms, 0.90, na.rm = TRUE, names = FALSE)),
      blocking_wait_p95_ms = as.numeric(quantile(blocking_wait_ms, 0.95, na.rm = TRUE, names = FALSE)),
      blocking_wait_p99_ms = as.numeric(quantile(blocking_wait_ms, 0.99, na.rm = TRUE, names = FALSE)),
      blocking_wait_max_ms = max(blocking_wait_ms, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    mutate(
      across(
        c(wait_share_gt0, wait_share_threshold,
          departure_minus_now_p50_s, departure_minus_now_p95_s,
          blocking_wait_mean_ms, blocking_wait_p50_ms, blocking_wait_p90_ms,
          blocking_wait_p95_ms, blocking_wait_p99_ms, blocking_wait_max_ms),
        ~ round(.x, 6)
      )
    )
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
  x
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
# Process files
# ------------------------------------------------------------

process_file <- function(row) {
  path <- row$file[[1]]
  dat <- read_csv_fast(path)

  departure_time <- safe_num(dat, "departure_time")

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

  tibble(
    horizon = row$horizon[[1]],
    batch_size = row$batch_size[[1]],
    parts = row$parts[[1]],
    router_threads = row$router_threads[[1]],
    config_key = row$config_key[[1]],
    source_file = path,
    horizon_source = horizon_source,
    departure_minus_now_s = departure_minus_now_s,
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
      filtered_ge_threshold = departure_minus_now_s >= min_departure_minus_now,
      blocked_threshold = blocking_wait_ms > blocking_threshold_ms
    )
}

data_list <- vector("list", nrow(idx))
errors <- list()

for (i in seq_len(nrow(idx))) {
  row <- idx[i, ]
  message(sprintf("[%d/%d] %s", i, nrow(idx), basename(row$file[[1]])))

  data_list[[i]] <- tryCatch(
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
      tibble()
    }
  )

  gc(verbose = FALSE)
}

all_data <- bind_rows(data_list)

errors_df <- if (length(errors) > 0) {
  bind_rows(errors)
} else {
  tibble(
    source_file = character(),
    config_key = character(),
    horizon = integer(),
    batch_size = integer(),
    parts = integer(),
    router_threads = integer(),
    error = character()
  )
}

readr::write_csv(errors_df, file.path(out_dir, "processing_errors.csv"))

if (nrow(all_data) == 0) {
  stop("No usable rows after processing.")
}

filtered_data <- all_data %>%
  filter(departure_minus_now_s >= min_departure_minus_now)

if (nrow(filtered_data) == 0) {
  stop("No rows after departure_time - now filter.")
}

# ------------------------------------------------------------
# Summaries
# ------------------------------------------------------------

overall_all <- all_data %>%
  summarise_blocking() %>%
  mutate(filter = "all_requests", .before = 1)

overall_filtered <- filtered_data %>%
  summarise_blocking() %>%
  mutate(filter = paste0("departure_minus_now_ge_", min_departure_minus_now, "s"), .before = 1)

overall_compare <- bind_rows(overall_all, overall_filtered)

readr::write_csv(overall_compare, file.path(out_dir, "blocking_wait_overall_all_vs_filtered.csv"))
write_markdown(overall_compare, file.path(out_dir, "blocking_wait_overall_all_vs_filtered.md"))
write_latex(
  overall_compare,
  file.path(out_dir, "blocking_wait_overall_all_vs_filtered.tex"),
  paste0("Blocking-Wartezeiten vor und nach Filterung auf departure_time - now >= ", min_departure_minus_now, " Sekunden."),
  "tab:blocking-wait-filtered-overall"
)

summary_filtered_by_config <- filtered_data %>%
  group_by(horizon, batch_size, parts, router_threads) %>%
  summarise_blocking() %>%
  arrange(batch_size, parts, router_threads)

readr::write_csv(summary_filtered_by_config, file.path(out_dir, "blocking_wait_filtered_by_config.csv"))
write_markdown(summary_filtered_by_config, file.path(out_dir, "blocking_wait_filtered_by_config.md"))
write_latex(
  summary_filtered_by_config,
  file.path(out_dir, "blocking_wait_filtered_by_config.tex"),
  paste0("Blocking-Wartezeiten für Routinganfragen mit departure_time - now >= ", min_departure_minus_now, " Sekunden."),
  "tab:blocking-wait-filtered-by-config"
)

# Vergleich pro Konfiguration: alle vs. gefiltert
summary_all_by_config <- all_data %>%
  group_by(horizon, batch_size, parts, router_threads) %>%
  summarise_blocking() %>%
  mutate(filter = "all_requests", .before = 1)

summary_filtered_by_config_compare <- filtered_data %>%
  group_by(horizon, batch_size, parts, router_threads) %>%
  summarise_blocking() %>%
  mutate(filter = paste0("departure_minus_now_ge_", min_departure_minus_now, "s"), .before = 1)

summary_compare_by_config <- bind_rows(summary_all_by_config, summary_filtered_by_config_compare) %>%
  arrange(batch_size, parts, router_threads, filter)

readr::write_csv(summary_compare_by_config, file.path(out_dir, "blocking_wait_by_config_all_vs_filtered.csv"))

# Kompakte Tabelle nur mit den wichtigsten Kenngrößen nach Filterung.
compact_filtered <- summary_filtered_by_config %>%
  select(
    horizon, batch_size, parts, router_threads,
    n_requests,
    wait_share_threshold,
    blocking_wait_p50_ms,
    blocking_wait_p95_ms,
    blocking_wait_p99_ms,
    blocking_wait_max_ms
  )

readr::write_csv(compact_filtered, file.path(out_dir, "blocking_wait_filtered_compact.csv"))
write_markdown(compact_filtered, file.path(out_dir, "blocking_wait_filtered_compact.md"))
write_latex(
  compact_filtered,
  file.path(out_dir, "blocking_wait_filtered_compact.tex"),
  paste0("Kompakte Zusammenfassung der Blocking-Wartezeiten nach Filterung auf departure_time - now >= ", min_departure_minus_now, " Sekunden."),
  "tab:blocking-wait-filtered-compact"
)

# Reduktionsübersicht pro Konfiguration
reduction_by_config <- summary_all_by_config %>%
  select(horizon, batch_size, parts, router_threads,
         n_requests_all = n_requests,
         wait_share_threshold_all = wait_share_threshold,
         p95_all_ms = blocking_wait_p95_ms,
         p99_all_ms = blocking_wait_p99_ms,
         max_all_ms = blocking_wait_max_ms) %>%
  left_join(
    summary_filtered_by_config %>%
      select(horizon, batch_size, parts, router_threads,
             n_requests_filtered = n_requests,
             wait_share_threshold_filtered = wait_share_threshold,
             p95_filtered_ms = blocking_wait_p95_ms,
             p99_filtered_ms = blocking_wait_p99_ms,
             max_filtered_ms = blocking_wait_max_ms),
    by = c("horizon", "batch_size", "parts", "router_threads")
  ) %>%
  mutate(
    removed_requests = n_requests_all - n_requests_filtered,
    removed_share = round(removed_requests / n_requests_all, 6),
    p95_reduction_ms = round(p95_all_ms - p95_filtered_ms, 6),
    p99_reduction_ms = round(p99_all_ms - p99_filtered_ms, 6),
    wait_share_threshold_reduction = round(wait_share_threshold_all - wait_share_threshold_filtered, 6)
  ) %>%
  arrange(batch_size, parts, router_threads)

readr::write_csv(reduction_by_config, file.path(out_dir, "blocking_wait_reduction_by_config.csv"))

# ------------------------------------------------------------
# Plots
# ------------------------------------------------------------

plot_overall <- overall_compare %>%
  select(filter, wait_share_threshold, blocking_wait_p95_ms, blocking_wait_p99_ms, blocking_wait_max_ms) %>%
  pivot_longer(cols = c(wait_share_threshold, blocking_wait_p95_ms, blocking_wait_p99_ms, blocking_wait_max_ms),
               names_to = "metric", values_to = "value")


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

p1 <- ggplot(plot_overall, aes(x = filter, y = value, fill = filter)) +
  geom_col() +
  facet_wrap(~ metric, scales = "free_y") +
  labs(
    title = "Blocking Wait vor und nach Filterung nach departure_time - now",
    subtitle = paste0("Filter: departure_time - now >= ", min_departure_minus_now, " s"),
    x = "",
    y = "Wert"
  ) +
  theme_bw() +
  theme(
    legend.position = "none",
    axis.text.x = element_text(angle = 20, hjust = 1)
  )

save_plot(p1, "plot_1_overall_all_vs_filtered.png", width = 11, height = 6)

plot_config <- compact_filtered %>%
  mutate(
    batch_size_f = factor(batch_size, levels = sort(unique(batch_size))),
    parts_f = factor(parts, levels = sort(unique(parts))),
    router_threads_f = factor(router_threads, levels = sort(unique(router_threads)))
  )

p2 <- ggplot(plot_config, aes(x = router_threads_f, y = blocking_wait_p95_ms, group = parts_f, linetype = parts_f, shape = parts_f)) +
  geom_line(na.rm = TRUE) +
  geom_point(na.rm = TRUE, size = 2) +
  facet_wrap(~ batch_size_f, labeller = label_both) +
  labs(
    title = "Blocking-Wartezeit nach Filterung",
    subtitle = paste0("Nur Anfragen mit departure_time - now >= ", min_departure_minus_now, " s; p95"),
    x = "Routing-Threads",
    y = "blocking_wait_ms p95 [ms]",
    linetype = "Partitionen",
    shape = "Partitionen"
  ) +
  theme_bw() +
  theme(legend.position = "bottom")

save_plot(p2, "plot_2_filtered_blocking_wait_p95_by_config.png", width = 11, height = 6)

p3 <- ggplot(plot_config, aes(x = router_threads_f, y = wait_share_threshold, group = parts_f, linetype = parts_f, shape = parts_f)) +
  geom_line(na.rm = TRUE) +
  geom_point(na.rm = TRUE, size = 2) +
  facet_wrap(~ batch_size_f, labeller = label_both) +
  labs(
    title = "Anteil relevanter Blocking-Wartezeiten nach Filterung",
    subtitle = paste0("Blocking definiert als blocking_wait_ms > ", blocking_threshold_ms, " ms"),
    x = "Routing-Threads",
    y = "Anteil relevanter Blocking-Wartezeiten",
    linetype = "Partitionen",
    shape = "Partitionen"
  ) +
  theme_bw() +
  theme(legend.position = "bottom")

save_plot(p3, "plot_3_filtered_blocking_share_by_config.png", width = 11, height = 6)

# ------------------------------------------------------------
# README
# ------------------------------------------------------------

readme <- c(
  "Blocking wait after filtering by departure_time - now",
  "====================================================",
  "",
  paste0("Input file index: ", file_index_path),
  paste0("Selected files: ", nrow(idx)),
  paste0("All usable rows: ", nrow(all_data)),
  paste0("Filtered rows: ", nrow(filtered_data)),
  paste0("Filter: departure_time - now >= ", min_departure_minus_now, " s"),
  paste0("Blocking threshold: blocking_wait_ms > ", blocking_threshold_ms, " ms"),
  "",
  "Main interpretation:",
  "If blocking_wait p95/p99 and wait_share_threshold become very small after this filter,",
  "then most relevant blocking waits were caused by requests with too little real preplanning buffer.",
  "",
  "Main outputs:",
  "- blocking_wait_overall_all_vs_filtered.csv/.md/.tex",
  "- blocking_wait_filtered_by_config.csv/.md/.tex",
  "- blocking_wait_filtered_compact.csv/.md/.tex",
  "- blocking_wait_by_config_all_vs_filtered.csv",
  "- blocking_wait_reduction_by_config.csv",
  "",
  "Plots:",
  "- plot_1_overall_all_vs_filtered.png",
  "- plot_2_filtered_blocking_wait_p95_by_config.png",
  "- plot_3_filtered_blocking_share_by_config.png",
  "",
  "Caution:",
  "This supports the interpretation that low departure_time - now is an important cause of blocking waits.",
  "It does not prove that the router has no influence at all, because router latency can still matter when the preplanning buffer is too small."
)

writeLines(readme, file.path(out_dir, "README.txt"))

message("Done. Outputs written to: ", out_dir)
message("All usable rows: ", nrow(all_data))
message("Filtered rows: ", nrow(filtered_data))
message("Main table: ", file.path(out_dir, "blocking_wait_filtered_compact.csv"))
