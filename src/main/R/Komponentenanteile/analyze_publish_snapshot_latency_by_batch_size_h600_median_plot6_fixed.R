#!/usr/bin/env Rscript

# analyze_publish_snapshot_latency_by_batch_size_h600.R
#
# Ziel:
#   Die Zeit analysieren, die ein finalisierter Batch ungefähr vom Abschluss/
#   Schließen des Batches bis zur veröffentlichten Snapshot-Aktualisierung benötigt.
#
# Näherung:
#   Da kein `finalizedBatchAtRealtime` vorliegt, wird die messbare Pipeline-Zeit
#   ab Übergabe Richtung UpdatingService verwendet:
#
#     finalized_batch_publication_latency_ns =
#       batch_delivery_rust_to_java_latency_ns + total_update_ns
#
#   In ms:
#
#     finalized_batch_publication_latency_ms =
#       (batch_delivery_rust_to_java_latency_ns + total_update_ns) / 1e6
#
# Interpretation:
#   Diese Größe ist KEINE vollständige Zeit ab physischem Batch-Close-Timestamp,
#   sondern die gemessene Zeit von Rust->Java-Delivery plus Java-Update bis zur
#   Snapshot-Veröffentlichung im UpdatingService. Wenn diese Zeit im Bereich von
#   bindSnapshot-Peaks liegt, stützt sie die Erklärung, dass frühe Routinganfragen
#   im TimeBin auf noch nicht verfügbare Snapshots warten.
#
# Standard-Subset:
#   Horizon = 600
#   parts = 1, 32, 64, 192
#   router_threads = 1, 48, 96
#
# Aufruf:
#   Rscript R/analyze_publish_snapshot_latency_by_batch_size_h600.R \
#     output/analysis/file_index_recursive.csv \
#     output/analysis/finalized_batch_publication_latency_h600_subset
#
# Referenz mit Vergleich zu bindSnapshot-Offset-Auswertung:
#   Rscript R/analyze_publish_snapshot_latency_by_batch_size_h600.R \
#     output/analysis/file_index_recursive.csv \
#     output/analysis/finalized_batch_publication_latency_h600_subset \
#     output/analysis/bind_snapshot_by_timebin_offset_h600_subset_v2/bind_snapshot_by_offset_window_parts_threads.csv
#
# Referenz:
#   PARTS_KEEP=1,32,64,192
#   ROUTER_THREADS_KEEP=1,48,96
#   HORIZON_KEEP=600
#   MAX_LATENCY_MS=600000
#
# Outputs:
#   selected_java_updating_files.csv
#   finalized_batch_publication_latency_per_file.csv
#   finalized_batch_publication_latency_by_parts_threads.csv
#   finalized_batch_publication_latency_by_batch_time.csv, falls Batch-Zeitspalten vorhanden
#   finalized_batch_publication_latency_top_configs.csv
#   comparison_bind_snapshot_vs_batch_publication_latency.csv, falls bindSnapshot-Datei übergeben
#   processing_errors.csv
#
# Plots:
#   plot_1_mean_latency_components_by_parts_threads.png
#   plot_2_p95_publication_latency_by_parts_threads.png
#   plot_3_publication_latency_over_batch_time.png, falls Batch-Zeitspalten vorhanden
#   plot_4_component_share_delivery_vs_update.png
#   plot_5_bind_snapshot_vs_publication_latency.png
#   "plot_6_publication_latency_by_batch_size_median_lines.png"
#   plot_7_p95_publication_latency_by_batch_size_bars.png
#   plot_8_publication_latency_components_by_batch_size.png
#   plot_9_publication_latency_component_share_by_batch_size.png, falls bindSnapshot-Datei übergeben

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(tidyr)
  library(stringr)
  library(ggplot2)
})

args <- commandArgs(trailingOnly = TRUE)

file_index_path <- ifelse(length(args) >= 1, args[[1]], "output/analysis/file_index_recursive.csv")
out_dir <- ifelse(length(args) >= 2, args[[2]], "output/analysis/publish_snapshot_latency_by_batch_size_h600")
bind_snapshot_offset_window_path <- ifelse(length(args) >= 3, args[[3]], "")

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

if (!file.exists(file_index_path)) {
  stop("File index not found: ", file_index_path)
}

has_data_table <- requireNamespace("data.table", quietly = TRUE)

parse_keep_int <- function(x, default = NULL) {
  if (is.na(x) || !nzchar(x)) return(default)
  as.integer(trimws(strsplit(x, ",", fixed = TRUE)[[1]]))
}

horizon_keep <- parse_keep_int(Sys.getenv("HORIZON_KEEP", "600"), default = 600L)
parts_keep <- parse_keep_int(Sys.getenv("PARTS_KEEP", "1,32,64,192"), default = c(1L, 32L, 64L, 192L))
router_threads_keep <- parse_keep_int(Sys.getenv("ROUTER_THREADS_KEEP", "1,48,96"), default = c(1L, 48L, 96L))

max_latency_ms <- suppressWarnings(as.numeric(Sys.getenv("MAX_LATENCY_MS", "600000")))
if (!is.finite(max_latency_ms) || max_latency_ms <= 0) {
  stop("MAX_LATENCY_MS must be positive.")
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

pick_col <- function(header, candidates, required = TRUE, label = "column") {
  hit <- candidates[candidates %in% header]
  if (length(hit) > 0) return(hit[[1]])

  # Zweiter Versuch: case-insensitive
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
      paste(head(header, 50), collapse = ", ")
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

sum_exact <- function(x) {
  x <- to_num(x)
  x <- x[is.finite(x)]
  if (length(x) == 0) return(0)
  sum(x)
}

summarise_latency <- function(df, group_cols) {
  df %>%
    group_by(across(all_of(group_cols))) %>%
    summarise(
      n_batches = n(),

      delivery_sum_ms = sum_exact(batch_delivery_rust_to_java_latency_ms),
      update_sum_ms = sum_exact(total_update_ms),
      publication_latency_sum_ms = sum_exact(finalized_batch_publication_latency_ms),

      delivery_mean_ms = mean_exact(batch_delivery_rust_to_java_latency_ms),
      delivery_p50_ms = q_exact(batch_delivery_rust_to_java_latency_ms, 0.50),
      delivery_p95_ms = q_exact(batch_delivery_rust_to_java_latency_ms, 0.95),
      delivery_p99_ms = q_exact(batch_delivery_rust_to_java_latency_ms, 0.99),
      delivery_max_ms = max_exact(batch_delivery_rust_to_java_latency_ms),

      update_mean_ms = mean_exact(total_update_ms),
      update_p50_ms = q_exact(total_update_ms, 0.50),
      update_p95_ms = q_exact(total_update_ms, 0.95),
      update_p99_ms = q_exact(total_update_ms, 0.99),
      update_max_ms = max_exact(total_update_ms),

      publication_latency_mean_ms = mean_exact(finalized_batch_publication_latency_ms),
      publication_latency_p50_ms = q_exact(finalized_batch_publication_latency_ms, 0.50),
      publication_latency_p90_ms = q_exact(finalized_batch_publication_latency_ms, 0.90),
      publication_latency_p95_ms = q_exact(finalized_batch_publication_latency_ms, 0.95),
      publication_latency_p99_ms = q_exact(finalized_batch_publication_latency_ms, 0.99),
      publication_latency_max_ms = max_exact(finalized_batch_publication_latency_ms),

      delivery_share_pct =
        ifelse(publication_latency_sum_ms > 0, 100 * delivery_sum_ms / publication_latency_sum_ms, NA_real_),
      update_share_pct =
        ifelse(publication_latency_sum_ms > 0, 100 * update_sum_ms / publication_latency_sum_ms, NA_real_),

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
# File selection
# ------------------------------------------------------------

message("Reading file index: ", file_index_path)
idx <- readr::read_csv(file_index_path, show_col_types = FALSE)

required_index <- c("file", "file_type", "horizon", "parts", "router_threads", "batch_size", "config_key")
missing_index <- setdiff(required_index, names(idx))
if (length(missing_index) > 0) {
  stop("Missing required columns in file index: ", paste(missing_index, collapse = ", "))
}

selected <- idx %>%
  mutate(
    horizon = as.integer(horizon),
    batch_size = as.integer(batch_size),
    parts = as.integer(parts),
    router_threads = as.integer(router_threads)
  ) %>%
  filter(
    file_type == "java_updating",
    horizon %in% horizon_keep,
    parts %in% parts_keep,
    router_threads %in% router_threads_keep
  ) %>%
  arrange(parts, router_threads, batch_size, file)

if (nrow(selected) == 0) {
  stop("No java_updating files found for requested filters.")
}

readr::write_csv(selected, file.path(out_dir, "selected_java_updating_files.csv"))

message("Selected java_updating files: ", nrow(selected))

# ------------------------------------------------------------
# Process java_updating files
# ------------------------------------------------------------

rows <- list()
file_diag <- list()
errors <- list()

for (i in seq_len(nrow(selected))) {
  f <- selected$file[[i]]

  message(sprintf(
    "[%d/%d] parts=%s rt=%s batch=%s | %s",
    i, nrow(selected),
    selected$parts[[i]],
    selected$router_threads[[i]],
    selected$batch_size[[i]],
    basename(f)
  ))

  tryCatch({
    header <- read_header(f)

    delivery_col <- pick_col(
      header,
      c(
        "batch_delivery_rust_to_java_latency_ns",
        "batchDeliveryRustToJavaLatencyNs",
        "batchDeliveryRustToJavaLatency",
        "batch_delivery_rust_to_java_latency",
        "batchDeliveryLatencyNs",
        "deliveryRustToJavaLatencyNs"
      ),
      required = TRUE,
      label = "batch delivery latency column"
    )

    update_col <- pick_col(
      header,
      c(
        "total_update_ns",
        "totalUpdateNs",
        "totalUpdate",
        "updateTotalNs",
        "updateTotal",
        "total_update",
        "totalUpdateNanos"
      ),
      required = TRUE,
      label = "total update column"
    )

    batch_id_col <- pick_col(
      header,
      c("batch_id", "batchId", "id", "updateBatchId"),
      required = FALSE,
      label = "batch id column"
    )

    bin_start_col <- pick_col(
      header,
      c(
        "completed_bin_start",
        "completedBinStart",
        "bin_start",
        "binStart",
        "time_bin_start",
        "timeBinStart",
        "snapshot_bin_start",
        "snapshotBinStart"
      ),
      required = FALSE,
      label = "batch bin start column"
    )

    bin_end_col <- pick_col(
      header,
      c(
        "completed_bin_end",
        "completedBinEnd",
        "bin_end",
        "binEnd",
        "time_bin_end",
        "timeBinEnd",
        "snapshot_bin_end",
        "snapshotBinEnd"
      ),
      required = FALSE,
      label = "batch bin end column"
    )

    cols <- c(delivery_col, update_col, batch_id_col, bin_start_col, bin_end_col)
    dat <- read_csv_selected(f, cols)

    tmp <- tibble(
      horizon = selected$horizon[[i]],
      batch_size = selected$batch_size[[i]],
      parts = selected$parts[[i]],
      router_threads = selected$router_threads[[i]],
      config_key = selected$config_key[[i]],
      source_file = f,

      batch_id =
        if (!is.na(batch_id_col) && batch_id_col %in% names(dat)) as.character(dat[[batch_id_col]]) else NA_character_,
      batch_bin_start =
        if (!is.na(bin_start_col) && bin_start_col %in% names(dat)) to_num(dat[[bin_start_col]]) else NA_real_,
      batch_bin_end =
        if (!is.na(bin_end_col) && bin_end_col %in% names(dat)) to_num(dat[[bin_end_col]]) else NA_real_,

      batch_delivery_rust_to_java_latency_ms = to_num(dat[[delivery_col]]) / 1e6,
      total_update_ms = to_num(dat[[update_col]]) / 1e6
    ) %>%
      mutate(
        finalized_batch_publication_latency_ms =
          batch_delivery_rust_to_java_latency_ms + total_update_ms,
        batch_time =
          dplyr::case_when(
            is.finite(batch_bin_end) ~ batch_bin_end,
            is.finite(batch_bin_start) ~ batch_bin_start,
            TRUE ~ NA_real_
          )
      ) %>%
      filter(
        is.finite(batch_delivery_rust_to_java_latency_ms),
        is.finite(total_update_ms),
        is.finite(finalized_batch_publication_latency_ms),
        batch_delivery_rust_to_java_latency_ms >= 0,
        total_update_ms >= 0,
        finalized_batch_publication_latency_ms >= 0,
        finalized_batch_publication_latency_ms <= max_latency_ms
      )

    if (nrow(tmp) == 0) {
      stop("No valid finalized batch rows after filtering.")
    }

    rows[[length(rows) + 1]] <- tmp

    file_diag[[length(file_diag) + 1]] <- tibble(
      horizon = selected$horizon[[i]],
      batch_size = selected$batch_size[[i]],
      parts = selected$parts[[i]],
      router_threads = selected$router_threads[[i]],
      source_file = f,
      delivery_col = delivery_col,
      update_col = update_col,
      batch_id_col = ifelse(is.na(batch_id_col), "", batch_id_col),
      bin_start_col = ifelse(is.na(bin_start_col), "", bin_start_col),
      bin_end_col = ifelse(is.na(bin_end_col), "", bin_end_col),
      n_valid_batches = nrow(tmp),
      has_batch_time = any(is.finite(tmp$batch_time)),
      publication_latency_mean_ms = mean_exact(tmp$finalized_batch_publication_latency_ms),
      publication_latency_p95_ms = q_exact(tmp$finalized_batch_publication_latency_ms, 0.95),
      publication_latency_p99_ms = q_exact(tmp$finalized_batch_publication_latency_ms, 0.99),
      publication_latency_max_ms = max_exact(tmp$finalized_batch_publication_latency_ms),
      delivery_share_pct =
        100 * sum_exact(tmp$batch_delivery_rust_to_java_latency_ms) /
        sum_exact(tmp$finalized_batch_publication_latency_ms),
      update_share_pct =
        100 * sum_exact(tmp$total_update_ms) /
        sum_exact(tmp$finalized_batch_publication_latency_ms)
    )
  }, error = function(e) {
    errors[[length(errors) + 1]] <<- tibble(
      horizon = selected$horizon[[i]],
      batch_size = selected$batch_size[[i]],
      parts = selected$parts[[i]],
      router_threads = selected$router_threads[[i]],
      source_file = f,
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
    source_file = character(),
    error = character()
  )
}
readr::write_csv(processing_errors, file.path(out_dir, "processing_errors.csv"))

if (length(rows) == 0) {
  stop("No valid java_updating rows produced. See processing_errors.csv.")
}

all_batches <- bind_rows(rows)

diag <- bind_rows(file_diag) %>%
  mutate(across(where(is.numeric), ~ round(.x, 6)))
readr::write_csv(diag, file.path(out_dir, "file_diagnostics.csv"))

# ------------------------------------------------------------
# Summaries
# ------------------------------------------------------------

per_file <- summarise_latency(
  all_batches,
  c("horizon", "batch_size", "parts", "router_threads", "config_key", "source_file")
)

by_parts_threads <- summarise_latency(
  all_batches,
  c("horizon", "parts", "router_threads")
)

by_parts_threads_batch <- summarise_latency(
  all_batches,
  c("horizon", "parts", "router_threads", "batch_size")
)

top_configs <- by_parts_threads_batch %>%
  arrange(desc(publication_latency_p95_ms))

readr::write_csv(per_file, file.path(out_dir, "finalized_batch_publication_latency_per_file.csv"))
readr::write_csv(by_parts_threads, file.path(out_dir, "finalized_batch_publication_latency_by_parts_threads.csv"))
readr::write_csv(by_parts_threads_batch, file.path(out_dir, "finalized_batch_publication_latency_by_parts_threads_batch.csv"))
readr::write_csv(top_configs, file.path(out_dir, "finalized_batch_publication_latency_top_configs.csv"))
by_batch_size <- summarise_latency(
  all_batches,
  c("horizon", "batch_size")
)

by_batch_size_parts <- summarise_latency(
  all_batches,
  c("horizon", "batch_size", "parts")
)

by_batch_size_threads <- summarise_latency(
  all_batches,
  c("horizon", "batch_size", "router_threads")
)

readr::write_csv(by_batch_size, file.path(out_dir, "publish_snapshot_latency_by_batch_size.csv"))
readr::write_csv(by_batch_size_parts, file.path(out_dir, "publish_snapshot_latency_by_batch_size_parts.csv"))
readr::write_csv(by_batch_size_threads, file.path(out_dir, "publish_snapshot_latency_by_batch_size_threads.csv"))


has_batch_time <- any(is.finite(all_batches$batch_time))

if (has_batch_time) {
  by_batch_time <- summarise_latency(
    all_batches %>% filter(is.finite(batch_time)),
    c("horizon", "parts", "router_threads", "batch_time")
  )

  readr::write_csv(by_batch_time, file.path(out_dir, "finalized_batch_publication_latency_by_batch_time.csv"))
}

# ------------------------------------------------------------
# Referenz comparison with bindSnapshot offset windows
# ------------------------------------------------------------

comparison <- tibble()

if (nzchar(bind_snapshot_offset_window_path) && file.exists(bind_snapshot_offset_window_path)) {
  bind_window <- readr::read_csv(bind_snapshot_offset_window_path, show_col_types = FALSE)

  needed <- c("parts", "router_threads", "offset_window", "bindSnapshot_mean_ms", "bindSnapshot_p95_ms", "bindSnapshot_p99_ms")
  missing <- setdiff(needed, names(bind_window))

  if (length(missing) == 0) {
    # Nimm kritisches Offset-Fenster, wenn vorhanden; sonst alle Fenster.
    critical_rows <- bind_window %>%
      filter(str_detect(as.character(offset_window), "^offset_0_"))

    if (nrow(critical_rows) == 0) critical_rows <- bind_window

    comparison <- critical_rows %>%
      select(
        parts, router_threads, offset_window,
        bindSnapshot_mean_ms,
        bindSnapshot_p95_ms,
        bindSnapshot_p99_ms
      ) %>%
      left_join(
        by_parts_threads %>%
          select(
            parts, router_threads,
            n_batches,
            delivery_mean_ms,
            update_mean_ms,
            publication_latency_mean_ms,
            publication_latency_p95_ms,
            publication_latency_p99_ms
          ),
        by = c("parts", "router_threads")
      ) %>%
      mutate(
        bind_p95_minus_publication_mean_ms =
          bindSnapshot_p95_ms - publication_latency_mean_ms,
        bind_p95_div_publication_mean =
          bindSnapshot_p95_ms / publication_latency_mean_ms
      ) %>%
      mutate(across(where(is.numeric), ~ round(.x, 6)))

    readr::write_csv(comparison, file.path(out_dir, "comparison_bind_snapshot_vs_batch_publication_latency.csv"))
  } else {
    warning("Optional bindSnapshot comparison file missing columns: ", paste(missing, collapse = ", "))
  }
}

# ------------------------------------------------------------
# Plots
# ------------------------------------------------------------

plot_components <- by_parts_threads %>%
  select(parts, router_threads, delivery_mean_ms, update_mean_ms) %>%
  pivot_longer(
    cols = c(delivery_mean_ms, update_mean_ms),
    names_to = "component",
    values_to = "mean_ms"
  ) %>%
  mutate(
    component = recode(
      component,
      delivery_mean_ms = "Rust→Java delivery",
      update_mean_ms = "Java update"
    ),
    parts_f = factor(parts, levels = sort(unique(parts))),
    router_threads_f = factor(router_threads, levels = sort(unique(router_threads)))
  )

p1 <- ggplot(plot_components, aes(x = router_threads_f, y = mean_ms, fill = component)) +
  geom_col() +
  facet_wrap(~ parts_f, scales = "free_y", labeller = labeller(parts_f = function(x) paste0("parts=", x))) +
  labs(
    title = "Mittlere Pipeline-Zeit finalisierter Batches bis zur Snapshot-Veröffentlichung",
    subtitle = "batch_delivery_rust_to_java_latency_ns + total_update_ns",
    x = "routing_threads",
    y = "mittlere Zeit [ms]",
    fill = "Komponente"
  ) +
  theme_bw() +
  theme(legend.position = "bottom")

safe_ggsave(file.path(out_dir, "plot_1_mean_latency_components_by_parts_threads.png"), p1, width = 12, height = 8)

plot_p95 <- by_parts_threads %>%
  mutate(
    parts_f = factor(parts, levels = sort(unique(parts))),
    router_threads_f = factor(router_threads, levels = sort(unique(router_threads)))
  )

p2 <- ggplot(plot_p95, aes(x = router_threads_f, y = publication_latency_p95_ms)) +
  geom_col() +
  facet_wrap(~ parts_f, scales = "free_y", labeller = labeller(parts_f = function(x) paste0("parts=", x))) +
  labs(
    title = "p95 der Pipeline-Zeit finalisierter Batches",
    subtitle = "delivery + total_update; je parts/routing_threads",
    x = "routing_threads",
    y = "p95 [ms]"
  ) +
  theme_bw()

safe_ggsave(file.path(out_dir, "plot_2_p95_publication_latency_by_parts_threads.png"), p2, width = 12, height = 8)

if (has_batch_time) {
  p3_data <- readr::read_csv(file.path(out_dir, "finalized_batch_publication_latency_by_batch_time.csv"), show_col_types = FALSE) %>%
    mutate(
      parts_f = factor(parts, levels = sort(unique(parts))),
      router_threads_f = factor(router_threads, levels = sort(unique(router_threads)))
    )

  p3 <- ggplot(p3_data, aes(x = batch_time, y = publication_latency_mean_ms, group = router_threads_f)) +
    geom_line(aes(linetype = router_threads_f)) +
    geom_point(size = 0.8, alpha = 0.6) +
    facet_wrap(~ parts_f, scales = "free_y", labeller = labeller(parts_f = function(x) paste0("parts=", x))) +
    labs(
      title = "Pipeline-Zeit finalisierter Batches über Batch-Simulationszeit",
      subtitle = "Mittelwert von delivery + total_update",
      x = "Batch-Zeit / TimeBin",
      y = "mittlere Zeit [ms]",
      linetype = "routing_threads"
    ) +
    theme_bw() +
    theme(legend.position = "bottom")

  safe_ggsave(file.path(out_dir, "plot_3_publication_latency_over_batch_time.png"), p3, width = 12, height = 8)
}

plot_share <- by_parts_threads %>%
  select(parts, router_threads, delivery_share_pct, update_share_pct) %>%
  pivot_longer(
    cols = c(delivery_share_pct, update_share_pct),
    names_to = "component",
    values_to = "share_pct"
  ) %>%
  mutate(
    component = recode(
      component,
      delivery_share_pct = "Rust→Java delivery",
      update_share_pct = "Java update"
    ),
    parts_f = factor(parts, levels = sort(unique(parts))),
    router_threads_f = factor(router_threads, levels = sort(unique(router_threads)))
  )

p4 <- ggplot(plot_share, aes(x = router_threads_f, y = share_pct, fill = component)) +
  geom_col() +
  facet_wrap(~ parts_f, labeller = labeller(parts_f = function(x) paste0("parts=", x))) +
  labs(
    title = "Anteile an der Pipeline-Zeit finalisierter Batches",
    subtitle = "delivery vs. total_update",
    x = "routing_threads",
    y = "Anteil [%]",
    fill = "Komponente"
  ) +
  theme_bw() +
  theme(legend.position = "bottom")

safe_ggsave(file.path(out_dir, "plot_4_component_share_delivery_vs_update.png"), p4, width = 12, height = 8)

if (nrow(comparison) > 0) {
  comp_plot <- comparison %>%
    mutate(
      parts_f = factor(parts, levels = sort(unique(parts))),
      router_threads_f = factor(router_threads, levels = sort(unique(router_threads)))
    ) %>%
    select(
      parts, router_threads, parts_f, router_threads_f,
      bindSnapshot_p95_ms,
      publication_latency_mean_ms,
      publication_latency_p95_ms
    ) %>%
    pivot_longer(
      cols = c(bindSnapshot_p95_ms, publication_latency_mean_ms, publication_latency_p95_ms),
      names_to = "metric",
      values_to = "ms"
    ) %>%
    mutate(
      metric = recode(
        metric,
        bindSnapshot_p95_ms = "bindSnapshot p95, offset_0_*",
        publication_latency_mean_ms = "batch publication mean",
        publication_latency_p95_ms = "batch publication p95"
      )
    )

  p5 <- ggplot(comp_plot, aes(x = router_threads_f, y = ms, fill = metric)) +
    geom_col(position = position_dodge(width = 0.8)) +
    facet_wrap(~ parts_f, scales = "free_y", labeller = labeller(parts_f = function(x) paste0("parts=", x))) +
    labs(
      title = "bindSnapshot-Peaks im Vergleich zur Batch-Pipeline-Zeit",
      subtitle = "Dient als Plausibilitätscheck für waitForSnapshot-Erklärung",
      x = "routing_threads",
      y = "Zeit [ms]",
      fill = "Metrik"
    ) +
    theme_bw() +
    theme(legend.position = "bottom")

  safe_ggsave(file.path(out_dir, "plot_5_bind_snapshot_vs_publication_latency.png
  "plot_6_publication_latency_by_batch_size_median_lines.png"
  plot_7_p95_publication_latency_by_batch_size_bars.png
  plot_8_publication_latency_components_by_batch_size.png
  plot_9_publication_latency_component_share_by_batch_size.png"), p5, width = 12, height = 8)
}

readme <- c(
  "Finalized batch publication latency, Horizon subset",
  "===================================================",
  "",
  paste0("Input file index: ", file_index_path),
  paste0("Output directory: ", out_dir),
  paste0("HORIZON_KEEP: ", paste(horizon_keep, collapse = ", ")),
  paste0("PARTS_KEEP: ", paste(parts_keep, collapse = ", ")),
  paste0("ROUTER_THREADS_KEEP: ", paste(router_threads_keep, collapse = ", ")),
  paste0("Selected java_updating files: ", nrow(selected)),
  "",
  "Definition:",
  "finalized_batch_publication_latency_ms =",
  "  batch_delivery_rust_to_java_latency_ns / 1e6 + total_update_ns / 1e6",
  "",
  "Interpretation:",
  "Because finalizedBatchAtRealtime is not available, this is an approximation.",
  "It covers Rust-to-Java batch delivery and Java UpdatingService processing until the snapshot publication.",
  "It does not include any unmeasured time before the batch enters the measured delivery/update path.",
  "",
  "Main outputs:",
  "- finalized_batch_publication_latency_by_parts_threads.csv",
  "- finalized_batch_publication_latency_by_parts_threads_batch.csv",
  "- finalized_batch_publication_latency_per_file.csv",
  "- finalized_batch_publication_latency_top_configs.csv",
  "- file_diagnostics.csv",
  "- processing_errors.csv",
  "- comparison_bind_snapshot_vs_batch_publication_latency.csv, if a bindSnapshot window file was provided",
  "",
  "Main plots:",
  "- plot_1_mean_latency_components_by_parts_threads.png",
  "- plot_2_p95_publication_latency_by_parts_threads.png",
  "- plot_3_publication_latency_over_batch_time.png, if batch time columns exist",
  "- plot_4_component_share_delivery_vs_update.png",
  "- plot_5_bind_snapshot_vs_publication_latency.png
  "plot_6_publication_latency_by_batch_size_median_lines.png"
  plot_7_p95_publication_latency_by_batch_size_bars.png
  plot_8_publication_latency_components_by_batch_size.png
  plot_9_publication_latency_component_share_by_batch_size.png, if comparison data exists",
  "",
  "Use in thesis:",
  "Compare the mean/p95 finalized-batch publication latency to the observed bindSnapshot peaks",
  "for early TimeBin offsets. If they are of similar magnitude, this supports the explanation",
  "that early routing requests wait for snapshots that are still being delivered/updated."
)

writeLines(readme, file.path(out_dir, "README.txt"))

message("Done. Outputs written to: ", out_dir)
message("Main table: ", file.path(out_dir, "finalized_batch_publication_latency_by_parts_threads.csv"))
message("Main plot: ", file.path(out_dir, "plot_1_mean_latency_components_by_parts_threads.png"))


# ------------------------------------------------------------
# Batch-size focused plots
# ------------------------------------------------------------

plot_batch_median <- by_parts_threads_batch %>%
  mutate(
    parts_f = factor(parts, levels = sort(unique(parts))),
    router_threads_f = factor(router_threads, levels = sort(unique(router_threads))),
    batch_size_f = factor(batch_size, levels = sort(unique(batch_size)))
  ) %>%
  select(
    horizon, parts, router_threads, batch_size,
    parts_f, router_threads_f, batch_size_f,
    publication_latency_p50_ms
  )

p_batch_lines <- ggplot(
  plot_batch_median,
  aes(
    x = batch_size,
    y = publication_latency_p50_ms,
    color = router_threads_f,
    group = router_threads_f
  )
) +
  geom_line(linewidth = 0.75, na.rm = TRUE) +
  geom_point(size = 2.1, na.rm = TRUE) +
  facet_wrap(~ parts_f, scales = "free_y", labeller = labeller(parts_f = function(x) paste0("parts=", x))) +
  scale_x_continuous(breaks = sort(unique(plot_batch_median$batch_size))) +
  labs(
    title = "Median der publishSnapshot-Latenz nach Batchgröße",
    subtitle = "Näherung: batch_delivery_rust_to_java_latency_ns + total_update_ns; Horizon = 600",
    x = "batch_size",
    y = "Median-Latenz [ms]",
    color = "routing_threads"
  ) +
  theme_bw() +
  theme(
    legend.position = "bottom",
    axis.text.x = element_text(angle = 35, hjust = 1)
  )

safe_ggsave(file.path(out_dir, "plot_6_publication_latency_by_batch_size_median_lines.png"), p_batch_lines, width = 12, height = 8)

p_batch_p95 <- by_parts_threads_batch %>%
  mutate(
    parts_f = factor(parts, levels = sort(unique(parts))),
    router_threads_f = factor(router_threads, levels = sort(unique(router_threads))),
    batch_size_f = factor(batch_size, levels = sort(unique(batch_size)))
  ) %>%
  ggplot(aes(x = batch_size_f, y = publication_latency_p95_ms, fill = router_threads_f)) +
  geom_col(position = position_dodge(width = 0.8), na.rm = TRUE) +
  facet_wrap(~ parts_f, scales = "free_y", labeller = labeller(parts_f = function(x) paste0("parts=", x))) +
  labs(
    title = "p95 der publishSnapshot-Latenz nach Batchgröße",
    subtitle = "Näherung: delivery + total_update; gruppiert nach parts und routing_threads",
    x = "batch_size",
    y = "p95 [ms]",
    fill = "routing_threads"
  ) +
  theme_bw() +
  theme(
    legend.position = "bottom",
    axis.text.x = element_text(angle = 35, hjust = 1)
  )

safe_ggsave(file.path(out_dir, "plot_7_p95_publication_latency_by_batch_size_bars.png"), p_batch_p95, width = 12, height = 8)

plot_batch_components <- by_parts_threads_batch %>%
  select(parts, router_threads, batch_size, delivery_mean_ms, update_mean_ms) %>%
  tidyr::pivot_longer(
    cols = c(delivery_mean_ms, update_mean_ms),
    names_to = "component",
    values_to = "mean_ms"
  ) %>%
  mutate(
    component = dplyr::recode(
      component,
      delivery_mean_ms = "Rust→Java delivery",
      update_mean_ms = "Java update"
    ),
    parts_f = factor(parts, levels = sort(unique(parts))),
    router_threads_f = factor(router_threads, levels = sort(unique(router_threads))),
    batch_size_f = factor(batch_size, levels = sort(unique(batch_size)))
  )

p_batch_components <- ggplot(plot_batch_components, aes(x = batch_size_f, y = mean_ms, fill = component)) +
  geom_col(na.rm = TRUE) +
  facet_grid(parts_f ~ router_threads_f, scales = "free_y", labeller = labeller(
    parts_f = function(x) paste0("parts=", x),
    router_threads_f = function(x) paste0("rt=", x)
  )) +
  labs(
    title = "Komponenten der publishSnapshot-Latenz nach Batchgröße",
    subtitle = "Anteile von Rust→Java delivery und Java update; Horizon = 600",
    x = "batch_size",
    y = "mittlere Zeit [ms]",
    fill = "Komponente"
  ) +
  theme_bw() +
  theme(
    legend.position = "bottom",
    axis.text.x = element_text(angle = 35, hjust = 1)
  )

safe_ggsave(file.path(out_dir, "plot_8_publication_latency_components_by_batch_size.png"), p_batch_components, width = 14, height = 10)

plot_batch_share <- by_parts_threads_batch %>%
  select(parts, router_threads, batch_size, delivery_share_pct, update_share_pct) %>%
  tidyr::pivot_longer(
    cols = c(delivery_share_pct, update_share_pct),
    names_to = "component",
    values_to = "share_pct"
  ) %>%
  mutate(
    component = dplyr::recode(
      component,
      delivery_share_pct = "Rust→Java delivery",
      update_share_pct = "Java update"
    ),
    parts_f = factor(parts, levels = sort(unique(parts))),
    router_threads_f = factor(router_threads, levels = sort(unique(router_threads))),
    batch_size_f = factor(batch_size, levels = sort(unique(batch_size)))
  )

p_batch_share <- ggplot(plot_batch_share, aes(x = batch_size_f, y = share_pct, fill = component)) +
  geom_col(na.rm = TRUE) +
  facet_grid(parts_f ~ router_threads_f, labeller = labeller(
    parts_f = function(x) paste0("parts=", x),
    router_threads_f = function(x) paste0("rt=", x)
  )) +
  labs(
    title = "Relative Komponentenanteile der publishSnapshot-Latenz nach Batchgröße",
    subtitle = "delivery vs. total_update; Horizon = 600",
    x = "batch_size",
    y = "Anteil [%]",
    fill = "Komponente"
  ) +
  theme_bw() +
  theme(
    legend.position = "bottom",
    axis.text.x = element_text(angle = 35, hjust = 1)
  )

safe_ggsave(file.path(out_dir, "plot_9_publication_latency_component_share_by_batch_size.png"), p_batch_share, width = 14, height = 10)

