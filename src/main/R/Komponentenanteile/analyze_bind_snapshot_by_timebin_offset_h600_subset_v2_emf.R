#!/usr/bin/env Rscript

# analyze_bind_snapshot_by_timebin_offset_h600_subset_v2.R
#
# Ziel:
#   Hypothese prüfen und visualisieren:
#
#   Durch die TimeBinFinalize-Logik warten Routinganfragen besonders dann lange
#   auf einen Snapshot, wenn sie sehr früh innerhalb eines TimeBins auftreten.
#
#   Konkret:
#     offset_in_timebin = Simulationssekunde %% TIME_BIN_SIZE
#
#   Besonders relevant:
#     offset_in_timebin <= 3
#
#   Zusätzlich soll sichtbar werden, dass im frühen Intervall
#     offset_in_timebin <= 20
#   bindSnapshot-Zeiten stark ansteigen und danach wieder abflachen.
#
# Einschränkung:
#   calcRoute wird vollständig ignoriert.
#   Es wird nur bindSnapshot = bindWaitNs ausgewertet.
#
# Standard-Subset:
#   Horizon = 600
#   parts = 1, 32, 64, 192
#   router_threads = 1, 48, 96
#
# Input:
#   output/analysis/file_index_recursive.csv
#
# Aufruf:
#   Rscript R/analyze_bind_snapshot_by_timebin_offset_h600_subset.R \
#     output/analysis/file_index_recursive.csv \
#     output/analysis/bind_snapshot_by_timebin_offset_h600_subset_v2
#
# Referenz:
#   TIME_BIN_SIZE=900
#   SIM_TIME_COL=now
#   EARLY_WINDOW_END=20
#   CRITICAL_WINDOW_END=3
#   SAMPLE_PER_FILE=1000
#
# Outputs:
#   bind_snapshot_by_offset_parts_threads.csv
#   bind_snapshot_by_offset_window_parts_threads.csv
#   bind_snapshot_early_vs_late_summary.csv
#   bind_snapshot_top_offsets_by_parts_threads.csv
#   bind_snapshot_raw_sample.csv
#
# Plots:
#   v2 uses facet_wrap over observed configurations to avoid empty panels/warnings.
#   plot_1_offset_0_20_p95_by_parts_threads.png
#   plot_2_offset_windows_by_parts_threads.png
#   plot_3_offset_0_20_heatmap.png
#   plot_4_full_timebin_offset_p95.png
#   plot_5_raw_sample_offset_scatter.png

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(tidyr)
  library(stringr)
  library(ggplot2)
})

args <- commandArgs(trailingOnly = TRUE)

file_index_path <- ifelse(length(args) >= 1, args[[1]], "output/analysis/file_index_recursive.csv")
out_dir <- ifelse(length(args) >= 2, args[[2]], "output/analysis/bind_snapshot_by_timebin_offset_h600_subset_v2")

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

if (!file.exists(file_index_path)) {
  stop("File index not found: ", file_index_path)
}

has_data_table <- requireNamespace("data.table", quietly = TRUE)

parts_keep <- c(1L, 32L, 64L, 192L)
router_threads_keep <- c(1L, 48L, 96L)

time_bin_size <- suppressWarnings(as.integer(Sys.getenv("TIME_BIN_SIZE", "900")))
if (!is.finite(time_bin_size) || time_bin_size <= 0) {
  stop("TIME_BIN_SIZE must be positive.")
}

sim_time_col <- Sys.getenv("SIM_TIME_COL", "now")

early_window_end <- suppressWarnings(as.integer(Sys.getenv("EARLY_WINDOW_END", "20")))
critical_window_end <- suppressWarnings(as.integer(Sys.getenv("CRITICAL_WINDOW_END", "3")))

if (!is.finite(early_window_end) || early_window_end < 0) {
  stop("EARLY_WINDOW_END must be >= 0.")
}
if (!is.finite(critical_window_end) || critical_window_end < 0) {
  stop("CRITICAL_WINDOW_END must be >= 0.")
}
if (critical_window_end > early_window_end) {
  stop("CRITICAL_WINDOW_END must be <= EARLY_WINDOW_END.")
}

sample_per_file <- suppressWarnings(as.integer(Sys.getenv("SAMPLE_PER_FILE", "1000")))
if (!is.finite(sample_per_file) || sample_per_file < 0) sample_per_file <- 0L

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

sum_exact <- function(x) {
  x <- to_num(x)
  x <- x[is.finite(x)]
  if (length(x) == 0) return(0)
  sum(x)
}

summarise_bind <- function(df, group_cols) {
  df %>%
    group_by(across(all_of(group_cols))) %>%
    summarise(
      n_requests = n(),
      bindSnapshot_sum_ms = sum_exact(bindSnapshot_ms),
      bindSnapshot_mean_ms = mean_exact(bindSnapshot_ms),
      bindSnapshot_p50_ms = q_exact(bindSnapshot_ms, 0.50),
      bindSnapshot_p90_ms = q_exact(bindSnapshot_ms, 0.90),
      bindSnapshot_p95_ms = q_exact(bindSnapshot_ms, 0.95),
      bindSnapshot_p99_ms = q_exact(bindSnapshot_ms, 0.99),
      bindSnapshot_max_ms = max_exact(bindSnapshot_ms),
      .groups = "drop"
    ) %>%
    mutate(across(where(is.numeric), ~ round(.x, 6)))
}

safe_ggsave <- function(filename, plot, width, height, dpi = 200) {
  png_file <- filename
  pdf_file <- stringr::str_replace(filename, "\\.png$", ".pdf")
  emf_file <- stringr::str_replace(filename, "\\.png$", ".emf")

  tryCatch({
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
  }, error = function(e) {
    message("Plot skipped: ", basename(filename), " | ", conditionMessage(e))
  })
}

# ------------------------------------------------------------
# File selection and pairing
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
    parts = as.integer(parts),
    router_threads = as.integer(router_threads)
  ) %>%
  filter(
    horizon == 600,
    parts %in% parts_keep,
    router_threads %in% router_threads_keep
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

pairs <- rust_pairs %>%
  inner_join(java_pairs, by = c("horizon", "batch_size", "parts", "router_threads")) %>%
  arrange(parts, router_threads, batch_size)

if (nrow(pairs) == 0) {
  stop("No paired rust_routing/java_routing files for Horizon=600 subset.")
}

readr::write_csv(pairs, file.path(out_dir, "selected_h600_file_pairs_subset.csv"))
message("Selected file pairs: ", nrow(pairs))

# ------------------------------------------------------------
# Process compact request rows
# ------------------------------------------------------------

compact_rows <- list()
raw_sample_list <- list()
file_diag_list <- list()
errors <- list()

for (i in seq_len(nrow(pairs))) {
  p <- pairs[i, ]

  message(sprintf(
    "[%d/%d] parts=%s rt=%s batch=%s | %s",
    i, nrow(pairs), p$parts[[1]], p$router_threads[[1]], p$batch_size[[1]],
    basename(p$java_file[[1]])
  ))

  tryCatch({
    rust_header <- read_header(p$rust_file[[1]])
    java_header <- read_header(p$java_file[[1]])

    rust_required <- c("id", sim_time_col)
    rust_missing <- setdiff(rust_required, rust_header)
    if (length(rust_missing) > 0) {
      stop(
        "Rust file missing columns for SIM_TIME_COL='", sim_time_col, "': ",
        paste(rust_missing, collapse = ", ")
      )
    }

    java_required <- c("requestId", "bindWaitNs")
    java_missing <- setdiff(java_required, java_header)
    if (length(java_missing) > 0) {
      stop("Java file missing columns: ", paste(java_missing, collapse = ", "))
    }

    rust <- read_csv_selected(p$rust_file[[1]], c("id", sim_time_col)) %>%
      transmute(
        request_id = as.character(.data$id),
        sim_second = to_num(.data[[sim_time_col]])
      ) %>%
      filter(is.finite(sim_second))

    java <- read_csv_selected(p$java_file[[1]], c("requestId", "bindWaitNs")) %>%
      transmute(
        request_id = as.character(.data$requestId),
        bindSnapshot_ms = to_num(.data$bindWaitNs) / 1e6
      ) %>%
      filter(
        is.finite(bindSnapshot_ms),
        bindSnapshot_ms >= 0,
        bindSnapshot_ms <= 10 * 60 * 1000
      )

    joined <- java %>%
      inner_join(rust, by = "request_id") %>%
      mutate(
        horizon = p$horizon[[1]],
        batch_size = p$batch_size[[1]],
        parts = p$parts[[1]],
        router_threads = p$router_threads[[1]],
        config_key = paste0(
          "parts", p$parts[[1]],
          "_rt", p$router_threads[[1]],
          "_batch", p$batch_size[[1]]
        ),
        timebin_offset = sim_second %% time_bin_size,
        timebin_index = floor(sim_second / time_bin_size),
        offset_window = case_when(
          timebin_offset <= critical_window_end ~ paste0("offset_0_", critical_window_end),
          timebin_offset <= early_window_end ~ paste0("offset_", critical_window_end + 1, "_", early_window_end),
          TRUE ~ paste0("offset_gt_", early_window_end)
        )
      ) %>%
      select(
        horizon, batch_size, parts, router_threads, config_key,
        sim_second, timebin_index, timebin_offset, offset_window,
        bindSnapshot_ms
      )

    if (nrow(joined) == 0) {
      stop("No joined Java/Rust rows after filtering.")
    }

    compact_rows[[length(compact_rows) + 1]] <- joined

    if (sample_per_file > 0) {
      set.seed(1000 + i)
      raw_sample_list[[length(raw_sample_list) + 1]] <- joined %>%
        slice_sample(n = min(sample_per_file, nrow(joined)))
    }

    file_diag_list[[length(file_diag_list) + 1]] <- tibble(
      horizon = p$horizon[[1]],
      batch_size = p$batch_size[[1]],
      parts = p$parts[[1]],
      router_threads = p$router_threads[[1]],
      rust_file = p$rust_file[[1]],
      java_file = p$java_file[[1]],
      n_rust_rows = nrow(rust),
      n_java_rows = nrow(java),
      n_joined_rows = nrow(joined),
      joined_share_of_java = nrow(joined) / nrow(java),
      sim_second_min = min(joined$sim_second, na.rm = TRUE),
      sim_second_max = max(joined$sim_second, na.rm = TRUE),
      bindSnapshot_mean_ms = mean_exact(joined$bindSnapshot_ms),
      bindSnapshot_p95_ms = q_exact(joined$bindSnapshot_ms, 0.95),
      bindSnapshot_p99_ms = q_exact(joined$bindSnapshot_ms, 0.99),
      bindSnapshot_max_ms = max_exact(joined$bindSnapshot_ms)
    )
  }, error = function(e) {
    errors[[length(errors) + 1]] <<- tibble(
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

processing_errors <- if (length(errors) > 0) {
  bind_rows(errors)
} else {
  tibble(
    horizon = integer(),
    batch_size = integer(),
    parts = integer(),
    router_threads = integer(),
    rust_file = character(),
    java_file = character(),
    error = character()
  )
}
readr::write_csv(processing_errors, file.path(out_dir, "processing_errors.csv"))

if (length(compact_rows) == 0) {
  stop("No compact rows produced. See processing_errors.csv.")
}

all_rows <- bind_rows(compact_rows)

raw_sample <- if (length(raw_sample_list) > 0) bind_rows(raw_sample_list) else tibble()
if (nrow(raw_sample) > 0) {
  readr::write_csv(raw_sample, file.path(out_dir, "bind_snapshot_raw_sample.csv"))
}

file_diag <- bind_rows(file_diag_list) %>%
  mutate(across(where(is.numeric), ~ round(.x, 6)))
readr::write_csv(file_diag, file.path(out_dir, "file_diagnostics.csv"))

# ------------------------------------------------------------
# Summaries
# ------------------------------------------------------------

by_offset_parts_threads <- summarise_bind(
  all_rows,
  c("horizon", "parts", "router_threads", "timebin_offset")
)

by_window_parts_threads <- summarise_bind(
  all_rows,
  c("horizon", "parts", "router_threads", "offset_window")
) %>%
  mutate(
    offset_window = factor(
      offset_window,
      levels = c(
        paste0("offset_0_", critical_window_end),
        paste0("offset_", critical_window_end + 1, "_", early_window_end),
        paste0("offset_gt_", early_window_end)
      )
    )
  ) %>%
  arrange(parts, router_threads, offset_window)

overall_by_window <- summarise_bind(
  all_rows,
  c("horizon", "offset_window")
) %>%
  mutate(
    offset_window = factor(
      offset_window,
      levels = c(
        paste0("offset_0_", critical_window_end),
        paste0("offset_", critical_window_end + 1, "_", early_window_end),
        paste0("offset_gt_", early_window_end)
      )
    )
  ) %>%
  arrange(offset_window)

early_vs_late <- by_window_parts_threads %>%
  select(parts, router_threads, offset_window, n_requests, bindSnapshot_mean_ms, bindSnapshot_p95_ms, bindSnapshot_p99_ms) %>%
  pivot_wider(
    names_from = offset_window,
    values_from = c(n_requests, bindSnapshot_mean_ms, bindSnapshot_p95_ms, bindSnapshot_p99_ms)
  )

critical_name <- paste0("offset_0_", critical_window_end)
early_name <- paste0("offset_", critical_window_end + 1, "_", early_window_end)
late_name <- paste0("offset_gt_", early_window_end)

# Add ratios only if names exist.
critical_p95_col <- paste0("bindSnapshot_p95_ms_", critical_name)
early_p95_col <- paste0("bindSnapshot_p95_ms_", early_name)
late_p95_col <- paste0("bindSnapshot_p95_ms_", late_name)

critical_mean_col <- paste0("bindSnapshot_mean_ms_", critical_name)
late_mean_col <- paste0("bindSnapshot_mean_ms_", late_name)

if (all(c(critical_p95_col, late_p95_col, critical_mean_col, late_mean_col) %in% names(early_vs_late))) {
  early_vs_late <- early_vs_late %>%
    mutate(
      p95_ratio_critical_vs_late =
        .data[[critical_p95_col]] / .data[[late_p95_col]],
      mean_ratio_critical_vs_late =
        .data[[critical_mean_col]] / .data[[late_mean_col]]
    ) %>%
    mutate(across(c(p95_ratio_critical_vs_late, mean_ratio_critical_vs_late), ~ round(.x, 6)))
}

top_offsets <- by_offset_parts_threads %>%
  group_by(parts, router_threads) %>%
  arrange(desc(bindSnapshot_p95_ms), .by_group = TRUE) %>%
  slice_head(n = 20) %>%
  ungroup() %>%
  arrange(parts, router_threads, desc(bindSnapshot_p95_ms))

readr::write_csv(by_offset_parts_threads, file.path(out_dir, "bind_snapshot_by_offset_parts_threads.csv"))
readr::write_csv(by_window_parts_threads, file.path(out_dir, "bind_snapshot_by_offset_window_parts_threads.csv"))
readr::write_csv(overall_by_window, file.path(out_dir, "bind_snapshot_by_offset_window_overall.csv"))
readr::write_csv(early_vs_late, file.path(out_dir, "bind_snapshot_early_vs_late_summary.csv"))
readr::write_csv(top_offsets, file.path(out_dir, "bind_snapshot_top_offsets_by_parts_threads.csv"))

# ------------------------------------------------------------
# Plots
# ------------------------------------------------------------

offset_0_20 <- by_offset_parts_threads %>%
  filter(timebin_offset <= early_window_end) %>%
  filter(is.finite(bindSnapshot_p95_ms)) %>%
  mutate(
    parts_f = factor(parts, levels = parts_keep),
    router_threads_f = factor(router_threads, levels = router_threads_keep),
    config_f = factor(
      paste0("parts=", parts, ", rt=", router_threads),
      levels = unique(paste0("parts=", parts, ", rt=", router_threads))
    )
  )

p1 <- ggplot(offset_0_20, aes(x = timebin_offset, y = bindSnapshot_p95_ms)) +
  geom_line(linewidth = 0.7) +
  geom_point(size = 1.0, alpha = 0.75) +
  geom_vline(xintercept = critical_window_end + 0.5, linetype = "dashed") +
  facet_wrap(~ config_f, scales = "free_y") +
  labs(
    title = "bindSnapshot-Peak am Anfang des TimeBins",
    subtitle = paste0(
      "Horizon=600; offset = Simulationssekunde %% ", time_bin_size,
      "; gezeigt: offset <= ", early_window_end,
      "; gestrichelte Linie trennt offset <= ", critical_window_end
    ),
    x = "Offset innerhalb des TimeBins [Simulationssekunden]",
    y = "bindSnapshot p95 [ms]"
  ) +
  theme_bw()

safe_ggsave(
  file.path(out_dir, "plot_1_offset_0_20_p95_by_parts_threads.png"),
  p1,
  width = 14,
  height = 10
)

window_plot <- by_window_parts_threads %>%
  filter(is.finite(bindSnapshot_p95_ms)) %>%
  mutate(
    parts_f = factor(parts, levels = parts_keep),
    router_threads_f = factor(router_threads, levels = router_threads_keep),
    config_f = factor(
      paste0("parts=", parts, ", rt=", router_threads),
      levels = unique(paste0("parts=", parts, ", rt=", router_threads))
    ),
    offset_window = factor(offset_window, levels = c(critical_name, early_name, late_name))
  )

p2 <- ggplot(window_plot, aes(x = offset_window, y = bindSnapshot_p95_ms)) +
  geom_col() +
  facet_wrap(~ config_f, scales = "free_y") +
  labs(
    title = "bindSnapshot nach Offset-Intervall im TimeBin",
    subtitle = paste0(
      "Vergleich: offset <= ", critical_window_end,
      ", offset ", critical_window_end + 1, "-", early_window_end,
      ", offset > ", early_window_end
    ),
    x = "Offset-Intervall",
    y = "bindSnapshot p95 [ms]"
  ) +
  theme_bw() +
  theme(axis.text.x = element_text(angle = 25, hjust = 1))

safe_ggsave(
  file.path(out_dir, "plot_2_offset_windows_by_parts_threads.png"),
  p2,
  width = 14,
  height = 10
)

p3 <- ggplot(offset_0_20, aes(x = timebin_offset, y = config_f, fill = bindSnapshot_p95_ms)) +
  geom_tile() +
  labs(
    title = "Heatmap: bindSnapshot p95 für offset <= 20",
    subtitle = paste0("offset = Simulationssekunde %% ", time_bin_size),
    x = "Offset innerhalb des TimeBins",
    y = "Konfiguration",
    fill = "p95 [ms]"
  ) +
  theme_bw()

safe_ggsave(
  file.path(out_dir, "plot_3_offset_0_20_heatmap.png"),
  p3,
  width = 13,
  height = 7
)

full_offset <- by_offset_parts_threads %>%
  filter(is.finite(bindSnapshot_p95_ms)) %>%
  mutate(
    parts_f = factor(parts, levels = parts_keep),
    router_threads_f = factor(router_threads, levels = router_threads_keep),
    config_f = factor(
      paste0("parts=", parts, ", rt=", router_threads),
      levels = unique(paste0("parts=", parts, ", rt=", router_threads))
    )
  )

p4 <- ggplot(full_offset, aes(x = timebin_offset, y = bindSnapshot_p95_ms)) +
  geom_line(linewidth = 0.5) +
  geom_vline(xintercept = early_window_end + 0.5, linetype = "dashed") +
  facet_wrap(~ config_f, scales = "free_y") +
  labs(
    title = "bindSnapshot p95 über den gesamten TimeBin",
    subtitle = paste0(
      "Gestrichelte Linie markiert offset <= ", early_window_end,
      "; TimeBin-Größe = ", time_bin_size
    ),
    x = "Offset innerhalb des TimeBins",
    y = "bindSnapshot p95 [ms]"
  ) +
  theme_bw()

safe_ggsave(
  file.path(out_dir, "plot_4_full_timebin_offset_p95.png"),
  p4,
  width = 14,
  height = 10
)

if (nrow(raw_sample) > 0) {
  sample_plot <- raw_sample %>%
    filter(timebin_offset <= early_window_end) %>%
    mutate(
      parts_f = factor(parts, levels = parts_keep),
      router_threads_f = factor(router_threads, levels = router_threads_keep),
      config_f = factor(
        paste0("parts=", parts, ", rt=", router_threads),
        levels = unique(paste0("parts=", parts, ", rt=", router_threads))
      )
    )

  p5 <- ggplot(sample_plot, aes(x = timebin_offset, y = bindSnapshot_ms)) +
    geom_point(alpha = 0.12, size = 0.35) +
    facet_wrap(~ config_f, scales = "free_y") +
    labs(
      title = "bindSnapshot-Einzelwerte am Anfang des TimeBins",
      subtitle = paste0("Stichprobe; gezeigt: offset <= ", early_window_end),
      x = "Offset innerhalb des TimeBins",
      y = "bindSnapshot [ms]"
    ) +
    theme_bw()

  safe_ggsave(
    file.path(out_dir, "plot_5_raw_sample_offset_scatter.png"),
    p5,
    width = 14,
    height = 10
  )
}

readme <- c(
  "bindSnapshot by TimeBin offset, Horizon=600 subset",
  "================================================",
  "",
  paste0("Input file index: ", file_index_path),
  paste0("Output directory: ", out_dir),
  paste0("Horizon filter: 600"),
  paste0("parts: ", paste(parts_keep, collapse = ", ")),
  paste0("router_threads: ", paste(router_threads_keep, collapse = ", ")),
  paste0("SIM_TIME_COL: ", sim_time_col),
  paste0("TIME_BIN_SIZE: ", time_bin_size),
  paste0("CRITICAL_WINDOW_END: ", critical_window_end),
  paste0("EARLY_WINDOW_END: ", early_window_end),
  paste0("Selected paired files: ", nrow(pairs)),
  "",
  "Definition:",
  "bindSnapshot_ms = bindWaitNs / 1e6",
  paste0("timebin_offset = ", sim_time_col, " %% ", time_bin_size),
  "",
  "Hypothesis:",
  paste0("Routing requests with timebin_offset <= ", critical_window_end, " wait longer for snapshots."),
  paste0("The broader early interval timebin_offset <= ", early_window_end, " should show elevated bindSnapshot times that flatten afterwards."),
  "",
  "calcRoute is intentionally ignored in this script.",
  "v2 uses only observed parts/routing_threads combinations in plots, avoiding empty facet panels.",
  "",
  "Important outputs:",
  "- bind_snapshot_by_offset_parts_threads.csv",
  "- bind_snapshot_by_offset_window_parts_threads.csv",
  "- bind_snapshot_by_offset_window_overall.csv",
  "- bind_snapshot_early_vs_late_summary.csv",
  "- bind_snapshot_top_offsets_by_parts_threads.csv",
  "- plot_1_offset_0_20_p95_by_parts_threads.png/.pdf/.emf",
  "- plot_2_offset_windows_by_parts_threads.png/.pdf/.emf",
  "- plot_3_offset_0_20_heatmap.png/.pdf/.emf",
  "- plot_4_full_timebin_offset_p95.png/.pdf/.emf",
  "- plot_5_raw_sample_offset_scatter.png/.pdf/.emf"
)

writeLines(readme, file.path(out_dir, "README.txt"))

message("Done. Outputs written to: ", out_dir)
message("Main plot: ", file.path(out_dir, "plot_1_offset_0_20_p95_by_parts_threads.png"))
message("Window summary: ", file.path(out_dir, "bind_snapshot_by_offset_window_parts_threads.csv"))
