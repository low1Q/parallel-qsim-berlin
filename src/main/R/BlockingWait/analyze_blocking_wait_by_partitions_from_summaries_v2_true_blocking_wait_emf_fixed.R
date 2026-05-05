#!/usr/bin/env Rscript

# analyze_blocking_wait_by_partitions_from_summaries.R
#
# Ziel:
#   Beantwortet die Frage:
#     Haben hohe Partitionenzahlen mehr Blocking-Wait?
#
# Das Skript arbeitet bewusst auf den bereits erzeugten Summary-Dateien,
# damit nicht erneut alle großen Rust-Routing-CSV-Dateien gelesen werden müssen.
#
# Erwartete Inputs:
#   1) Ungefilterte Blocking-Wait-Zusammenfassung:
#      output/analysis/blocking_wait_by_departure_minus_now_h600/summary_by_config.csv
#
#   2) Referenz: Gefilterte Zusammenfassung mit departure_time - now >= 30:
#      output/analysis/blocking_wait_departure_ge30_h600/blocking_wait_filtered_by_config.csv
#
# Aufruf:
#   Rscript R/analyze_blocking_wait_by_partitions_from_summaries.R \
#     output/analysis/blocking_wait_by_departure_minus_now_h600/summary_by_config.csv \
#     output/analysis/blocking_wait_by_partitions
#
# Referenz mit gefilterter Datei:
#   Rscript R/analyze_blocking_wait_by_partitions_from_summaries.R \
#     output/analysis/blocking_wait_by_departure_minus_now_h600/summary_by_config.csv \
#     output/analysis/blocking_wait_by_partitions \
#     output/analysis/blocking_wait_departure_ge30_h600/blocking_wait_filtered_by_config.csv
#
# Outputs:
#   partition_overview_all_requests.csv
#   partition_overview_filtered_ge30.csv                falls Filterdatei vorhanden
#   partition_overview_all_vs_filtered.csv              falls Filterdatei vorhanden
#   blocking_wait_by_partition_config_values.csv
#   plot_1_blocking_wait_p95_by_partitions_all.png
#   plot_2_blocking_share_by_partitions_all.png
#   plot_3_partition_overview_all_vs_filtered.png       falls Filterdatei vorhanden
#
# Interpretation:
#   - wait_share_threshold beschreibt den Anteil relevanter Blocking-Waits.
#   - blocking_wait_p95_ms beschreibt das 95. Perzentil der Blocking-Wait-Zeit.
#   - median_config_* aggregiert über Konfigurationen, nicht über einzelne Requests.
#     Das ist sinnvoll, wenn Konfigurationen gleich gewichtet werden sollen.
#   - weighted_wait_share_threshold gewichtet nach Anzahl der Requests.

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(tidyr)
  library(stringr)
  library(ggplot2)
})

args <- commandArgs(trailingOnly = TRUE)

input_all <- ifelse(
  length(args) >= 1,
  args[[1]],
  "output/analysis/blocking_wait_by_departure_minus_now_h600/summary_by_config.csv"
)

out_dir <- ifelse(
  length(args) >= 2,
  args[[2]],
  "output/analysis/blocking_wait_by_partitions"
)

input_filtered <- ifelse(
  length(args) >= 3,
  args[[3]],
  "output/analysis/blocking_wait_departure_ge30_h600/blocking_wait_filtered_by_config.csv"
)

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

if (!file.exists(input_all)) {
  stop("Unfiltered summary file not found: ", input_all)
}

has_filtered <- file.exists(input_filtered)

message("Reading unfiltered summary: ", input_all)
all_df <- readr::read_csv(input_all, show_col_types = FALSE) %>%
  mutate(filter = "all_requests")

if (has_filtered) {
  message("Reading filtered summary: ", input_filtered)
  filtered_df <- readr::read_csv(input_filtered, show_col_types = FALSE) %>%
    mutate(filter = "departure_minus_now_ge_30s")
} else {
  warning("Filtered summary file not found: ", input_filtered)
  filtered_df <- tibble()
}

required <- c(
  "horizon", "batch_size", "parts", "router_threads",
  "n_requests", "wait_share_threshold",
  "blocking_wait_p50_ms", "blocking_wait_p95_ms", "blocking_wait_p99_ms", "blocking_wait_max_ms"
)

missing <- setdiff(required, names(all_df))
if (length(missing) > 0) {
  stop("Missing required columns in unfiltered summary: ", paste(missing, collapse = ", "))
}

make_partition_overview <- function(df) {
  df %>%
    group_by(parts) %>%
    summarise(
      n_configs = n(),
      n_requests_total = sum(n_requests, na.rm = TRUE),

      # Konfigurationsgewichtete Sicht:
      median_config_wait_share_threshold = median(wait_share_threshold, na.rm = TRUE),
      median_config_blocking_p50_ms = median(blocking_wait_p50_ms, na.rm = TRUE),
      median_config_blocking_p95_ms = median(blocking_wait_p95_ms, na.rm = TRUE),
      median_config_blocking_p99_ms = median(blocking_wait_p99_ms, na.rm = TRUE),

      # Request-gewichteter Blocking-Anteil:
      weighted_wait_share_threshold = weighted.mean(wait_share_threshold, w = n_requests, na.rm = TRUE),

      # Extremwerte über Konfigurationen:
      max_config_blocking_p95_ms = max(blocking_wait_p95_ms, na.rm = TRUE),
      max_config_blocking_p99_ms = max(blocking_wait_p99_ms, na.rm = TRUE),
      max_observed_blocking_wait_ms = max(blocking_wait_max_ms, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    mutate(
      across(
        where(is.numeric),
        ~ round(.x, 6)
      )
    ) %>%
    arrange(parts)
}

overview_all <- make_partition_overview(all_df)
readr::write_csv(overview_all, file.path(out_dir, "partition_overview_all_requests.csv"))

combined_config_values <- all_df

if (has_filtered) {
  missing_filtered <- setdiff(required, names(filtered_df))
  if (length(missing_filtered) > 0) {
    stop("Missing required columns in filtered summary: ", paste(missing_filtered, collapse = ", "))
  }

  overview_filtered <- make_partition_overview(filtered_df)
  readr::write_csv(overview_filtered, file.path(out_dir, "partition_overview_filtered_ge30.csv"))

  combined_config_values <- bind_rows(all_df, filtered_df)

  overview_compare <- bind_rows(
    overview_all %>% mutate(filter = "all_requests", .before = 1),
    overview_filtered %>% mutate(filter = "departure_minus_now_ge_30s", .before = 1)
  )

  readr::write_csv(overview_compare, file.path(out_dir, "partition_overview_all_vs_filtered.csv"))
}

readr::write_csv(
  combined_config_values %>%
    arrange(filter, batch_size, parts, router_threads),
  file.path(out_dir, "blocking_wait_by_partition_config_values.csv")
)

# ------------------------------------------------------------
# Plots
# ------------------------------------------------------------

plot_all <- all_df %>%
  mutate(
    parts_f = factor(parts, levels = sort(unique(parts))),
    router_threads_f = factor(router_threads, levels = sort(unique(router_threads))),
    batch_size_f = factor(batch_size, levels = sort(unique(batch_size)))
  )




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

p1 <- ggplot(
  plot_all,
  aes(x = parts, y = blocking_wait_p95_ms, group = router_threads_f,
      linetype = router_threads_f, shape = router_threads_f)
) +
  geom_line(na.rm = TRUE) +
  geom_point(na.rm = TRUE, size = 2) +
  facet_wrap(~ batch_size_f, labeller = label_both) +
  scale_x_continuous(breaks = sort(unique(plot_all$parts))) +
  labs(
    title = "Blocking-Wait p95 nach Partitionen",
    subtitle = "Alle Requests; Linien nach Routing-Threads",
    x = "Partitionen",
    y = "blocking_wait_ms p95 [ms]",
    linetype = "Routing-Threads",
    shape = "Routing-Threads"
  ) +
  theme_bw() +
  theme(legend.position = "bottom")

save_plot_with_emf(p1, "plot_1_blocking_wait_p95_by_partitions_all", width = 11, height = 6, dpi = 200)

p2 <- ggplot(
  plot_all,
  aes(x = parts, y = wait_share_threshold, group = router_threads_f,
      linetype = router_threads_f, shape = router_threads_f)
) +
  geom_line(na.rm = TRUE) +
  geom_point(na.rm = TRUE, size = 2) +
  facet_wrap(~ batch_size_f, labeller = label_both) +
  scale_x_continuous(breaks = sort(unique(plot_all$parts))) +
  labs(
    title = "Anteil relevanter Blocking-Waits nach Partitionen",
    subtitle = "Alle Requests; Blocking definiert über wait_share_threshold",
    x = "Partitionen",
    y = "Anteil relevanter Blocking-Waits",
    linetype = "Routing-Threads",
    shape = "Routing-Threads"
  ) +
  theme_bw() +
  theme(legend.position = "bottom")

save_plot_with_emf(p2, "plot_2_blocking_share_by_partitions_all", width = 11, height = 6, dpi = 200)

if (has_filtered) {
  plot_compare <- bind_rows(
    overview_all %>% mutate(filter = "all_requests", .before = 1),
    overview_filtered %>% mutate(filter = "departure_minus_now_ge_30s", .before = 1)
  ) %>%
    mutate(
      parts_f = factor(parts, levels = sort(unique(parts))),
      filter = factor(filter, levels = c("all_requests", "departure_minus_now_ge_30s"))
    ) %>%
    select(
      filter, parts, parts_f,
      median_config_wait_share_threshold,
      weighted_wait_share_threshold,
      median_config_blocking_p95_ms,
      median_config_blocking_p99_ms
    ) %>%
    pivot_longer(
      cols = c(
        median_config_wait_share_threshold,
        weighted_wait_share_threshold,
        median_config_blocking_p95_ms,
        median_config_blocking_p99_ms
      ),
      names_to = "metric",
      values_to = "value"
    )

  p3 <- ggplot(plot_compare, aes(x = parts_f, y = value, fill = filter)) +
    geom_col(position = position_dodge(width = 0.8)) +
    facet_wrap(~ metric, scales = "free_y") +
    labs(
      title = "Blocking-Wait nach Partitionen: alle Requests vs. departure_time - now >= 30s",
      x = "Partitionen",
      y = "Wert",
      fill = "Filter"
    ) +
    theme_bw() +
    theme(legend.position = "bottom")

  save_plot_with_emf(p3, "plot_3_partition_overview_all_vs_filtered", width = 12, height = 7, dpi = 200)
}

# ------------------------------------------------------------
# Markdown helper
# ------------------------------------------------------------

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

write_markdown(overview_all, file.path(out_dir, "partition_overview_all_requests.md"))

if (has_filtered) {
  write_markdown(overview_filtered, file.path(out_dir, "partition_overview_filtered_ge30.md"))
  write_markdown(overview_compare, file.path(out_dir, "partition_overview_all_vs_filtered.md"))
}

readme <- c(
  "Blocking-Wait by partitions",
  "===========================",
  "",
  paste0("Input all requests: ", input_all),
  paste0("Input filtered ge30: ", ifelse(has_filtered, input_filtered, "not found")),
  "",
  "Main question:",
  "Do high partition counts have more blocking_wait?",
  "",
  "Important columns:",
  "- median_config_wait_share_threshold: median over configurations of the relevant blocking share.",
  "- weighted_wait_share_threshold: request-weighted blocking share.",
  "- median_config_blocking_p95_ms: median over configuration-level p95 values.",
  "- max_observed_blocking_wait_ms: largest observed max from any configuration.",
  "",
  "Recommended interpretation:",
  "Use the all_requests table first. Then compare with departure_minus_now_ge_30s.",
  "If high partition effects disappear or shrink strongly after filtering, the observed blocking waits are mostly related to low departure_time - now rather than partition count alone.",
  "",
  "Outputs:",
  "- partition_overview_all_requests.csv/.md",
  "- partition_overview_filtered_ge30.csv/.md, if available",
  "- partition_overview_all_vs_filtered.csv/.md, if available",
  "- blocking_wait_by_partition_config_values.csv",
  "- plot_1_blocking_wait_p95_by_partitions_all.png",
  "- plot_2_blocking_share_by_partitions_all.png",
  "- plot_3_partition_overview_all_vs_filtered.png, if available"
)

writeLines(readme, file.path(out_dir, "README.txt"))

message("Done. Outputs written to: ", out_dir)
message("Main table: ", file.path(out_dir, "partition_overview_all_requests.csv"))
if (has_filtered) {
  message("Filtered comparison: ", file.path(out_dir, "partition_overview_all_vs_filtered.csv"))
}
