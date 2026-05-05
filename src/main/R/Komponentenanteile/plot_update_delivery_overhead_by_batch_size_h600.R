#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(stringr)
  library(tidyr)
  library(ggplot2)
})

args <- commandArgs(trailingOnly = TRUE)

file_index_path <- if (length(args) >= 1) args[[1]] else "output/analysis/file_index_recursive.csv"
out_dir <- if (length(args) >= 2) args[[2]] else "output/analysis/update_delivery_overhead_by_batch_size_h600"
plot_name <- if (length(args) >= 3) args[[3]] else "update_delivery_overhead_by_batch_size_h600"

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

if (!file.exists(file_index_path)) {
  stop("File index not found: ", file_index_path)
}

parse_keep_int <- function(x, default = NULL) {
  if (is.null(x) || is.na(x) || !nzchar(trimws(x))) return(default)
  suppressWarnings(as.integer(trimws(strsplit(x, ",", fixed = TRUE)[[1]])))
}

first_existing_col <- function(df, candidates) {
  existing <- candidates[candidates %in% names(df)]
  if (length(existing) == 0) return(NA_character_)
  existing[[1]]
}

pick_col <- function(header, candidates, required = TRUE, label = "column") {
  existing <- candidates[candidates %in% header]
  if (length(existing) > 0) return(existing[[1]])
  if (required) {
    stop(
      "Required ", label, " not found. Tried: ", paste(candidates, collapse = ", "),
      "\nAvailable columns: ", paste(header, collapse = ", ")
    )
  }
  NA_character_
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

q_exact <- function(x, p) {
  x <- x[is.finite(x)]
  if (length(x) == 0) return(NA_real_)
  as.numeric(stats::quantile(x, p, na.rm = TRUE, names = FALSE, type = 7))
}

safe_ggsave <- function(filename, plot, width, height, dpi = 220) {
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
    message(
      "Paket 'devEMF' nicht installiert; EMF wird übersprungen für: ", basename(emf_file),
      ". Installation: install.packages('devEMF')"
    )
  }
}

read_csv_header <- function(path) {
  names(readr::read_csv(path, n_max = 0, show_col_types = FALSE, progress = FALSE))
}

read_csv_selected <- function(path, cols) {
  cols <- unique(cols[!is.na(cols)])
  if (requireNamespace("data.table", quietly = TRUE)) {
    return(tibble::as_tibble(data.table::fread(path, select = cols, showProgress = FALSE)))
  }

  readr::read_csv(
    path,
    col_select = all_of(cols),
    show_col_types = FALSE,
    progress = FALSE
  )
}

horizon_keep <- as.integer(Sys.getenv("HORIZON_KEEP", "600"))
parts_keep <- parse_keep_int(Sys.getenv("PARTS_KEEP", "1,32,64,192"))
router_threads_keep <- parse_keep_int(Sys.getenv("ROUTER_THREADS_KEEP", "1,24,48,96,192"))
batch_keep <- parse_keep_int(Sys.getenv("BATCH_KEEP", "500,10000,25000,45000"))

idx_raw <- readr::read_csv(file_index_path, show_col_types = FALSE)

file_col <- first_existing_col(idx_raw, c("file", "path", "source_file"))
file_type_col <- first_existing_col(idx_raw, c("file_type", "type"))
parts_col <- first_existing_col(idx_raw, c("parts", "partitions", "sim_cpus", "partition"))
horizon_col <- first_existing_col(idx_raw, c("horizon", "preplanning_horizon"))
router_col <- first_existing_col(idx_raw, c("router_threads", "routing_threads", "r"))
batch_col <- first_existing_col(idx_raw, c("batch_size", "batch"))

if (is.na(file_col)) stop("File index must contain a file/path column.")

file_index <- idx_raw %>%
  mutate(
    file = as.character(.data[[file_col]]),
    file_name = basename(file),
    file_type_norm = if (!is.na(file_type_col)) as.character(.data[[file_type_col]]) else NA_character_,
    parts = coalesce(
      if (!is.na(parts_col)) as_int_safe(.data[[parts_col]]) else NA_integer_,
      extract_int_from_file(file, "(?:^|[_/-])parts([0-9]+)(?:--|_|$)"),
      extract_int_from_file(file, "(?:^|[_/-])sim([0-9]+)(?:_|$)")
    ),
    horizon = coalesce(
      if (!is.na(horizon_col)) as_int_safe(.data[[horizon_col]]) else NA_integer_,
      extract_int_from_file(file, "(?:^|[_/-])PH([0-9]+)(?:-|_|$)"),
      extract_int_from_file(file, "(?:^|[_/-])hor([0-9]+)(?:_|$)")
    ),
    router_threads = coalesce(
      if (!is.na(router_col)) as_int_safe(.data[[router_col]]) else NA_integer_,
      extract_int_from_file(file, "(?:^|[_/-])threads([0-9]+)(?:-|_|$)"),
      extract_int_from_file(file, "(?:^|[_/-])r([0-9]+)(?:_|$)")
    ),
    batch_size = coalesce(
      if (!is.na(batch_col)) as_int_safe(.data[[batch_col]]) else NA_integer_,
      extract_int_from_file(file, "(?:^|[_/-])batch([0-9]+)(?:-|_|$)")
    ),
    is_java_updating = case_when(
      !is.na(file_type_norm) & str_detect(file_type_norm, regex("java.*updat|java_updating|updating", ignore_case = TRUE)) ~ TRUE,
      str_detect(file_name, regex("java-updating-profiling|java.*updat|updating", ignore_case = TRUE)) ~ TRUE,
      TRUE ~ FALSE
    )
  ) %>%
  filter(
    is_java_updating,
    file.exists(file),
    horizon == horizon_keep,
    parts %in% parts_keep,
    router_threads %in% router_threads_keep,
    batch_size %in% batch_keep
  ) %>%
  arrange(parts, router_threads, batch_size, file)

if (nrow(file_index) == 0) {
  stop("No matching java-updating files found after filtering.")
}

read_one_file <- function(row) {
  f <- row$file[[1]]
  header <- read_csv_header(f)

  delivery_col <- pick_col(
    header,
    c(
      "batch_delivery_rust_to_java_latency_ns",
      "batchDeliveryRustToJavaLatencyNs",
      "batch_delivery_latency_ns",
      "rust_to_java_delivery_latency_ns"
    ),
    required = TRUE,
    label = "batch delivery rust-to-java latency"
  )

  update_col <- pick_col(
    header,
    c(
      "total_update_ns",
      "totalUpdateNs",
      "update_total_ns",
      "updating_total_ns"
    ),
    required = TRUE,
    label = "total update latency"
  )

  batch_id_col <- pick_col(
    header,
    c("batch_id", "batchId", "finalized_batch_id", "finalizedBatchId"),
    required = FALSE,
    label = "batch id"
  )

  now_col <- pick_col(
    header,
    c("now", "sim_time", "simulation_time", "time"),
    required = FALSE,
    label = "simulation time"
  )

  cols <- c(delivery_col, update_col, batch_id_col, now_col)
  dat <- read_csv_selected(f, cols)

  delivery_ms <- as_num_safe(dat[[delivery_col]]) / 1e6
  update_ms <- as_num_safe(dat[[update_col]]) / 1e6

  tibble(
    file = f,
    parts = row$parts[[1]],
    horizon = row$horizon[[1]],
    router_threads = row$router_threads[[1]],
    batch_size = row$batch_size[[1]],
    batch_id = if (!is.na(batch_id_col)) as.character(dat[[batch_id_col]]) else NA_character_,
    sim_time = if (!is.na(now_col)) as_num_safe(dat[[now_col]]) else NA_real_,
    delivery_ms = delivery_ms,
    update_ms = update_ms,
    publication_latency_ms = delivery_ms + update_ms
  ) %>%
    filter(
      is.finite(delivery_ms),
      is.finite(update_ms),
      is.finite(publication_latency_ms),
      delivery_ms >= 0,
      update_ms >= 0,
      publication_latency_ms >= 0
    )
}

message("Reading ", nrow(file_index), " java-updating files...")

all_rows <- vector("list", nrow(file_index))
processing_errors <- list()

for (i in seq_len(nrow(file_index))) {
  row <- file_index[i, ]
  message(
    "[", i, "/", nrow(file_index), "] parts=", row$parts,
    " rt=", row$router_threads,
    " batch=", row$batch_size,
    " | ", basename(row$file)
  )

  one <- tryCatch(
    read_one_file(row),
    error = function(e) {
      processing_errors[[length(processing_errors) + 1]] <<- tibble(
        file = row$file,
        parts = row$parts,
        router_threads = row$router_threads,
        batch_size = row$batch_size,
        error = conditionMessage(e)
      )
      tibble()
    }
  )

  all_rows[[i]] <- one
  gc(verbose = FALSE)
}

update_data <- bind_rows(all_rows)

processing_errors_df <- if (length(processing_errors) > 0) {
  bind_rows(processing_errors)
} else {
  tibble(file = character(), parts = integer(), router_threads = integer(), batch_size = integer(), error = character())
}

readr::write_csv(processing_errors_df, file.path(out_dir, "processing_errors.csv"))

if (nrow(update_data) == 0) {
  stop("No update/delivery timing data could be extracted. Check processing_errors.csv and column names.")
}

per_file <- update_data %>%
  group_by(file, parts, horizon, router_threads, batch_size) %>%
  summarise(
    n_batches = n(),
    delivery_median_ms = q_exact(delivery_ms, 0.50),
    delivery_p95_ms = q_exact(delivery_ms, 0.95),
    update_median_ms = q_exact(update_ms, 0.50),
    update_p95_ms = q_exact(update_ms, 0.95),
    publication_median_ms = q_exact(publication_latency_ms, 0.50),
    publication_p95_ms = q_exact(publication_latency_ms, 0.95),
    publication_p99_ms = q_exact(publication_latency_ms, 0.99),
    .groups = "drop"
  )

by_config <- update_data %>%
  group_by(parts, horizon, router_threads, batch_size) %>%
  summarise(
    n_files = n_distinct(file),
    n_batches = n(),
    delivery_median_ms = q_exact(delivery_ms, 0.50),
    delivery_p95_ms = q_exact(delivery_ms, 0.95),
    update_median_ms = q_exact(update_ms, 0.50),
    update_p95_ms = q_exact(update_ms, 0.95),
    publication_median_ms = q_exact(publication_latency_ms, 0.50),
    publication_p95_ms = q_exact(publication_latency_ms, 0.95),
    publication_p99_ms = q_exact(publication_latency_ms, 0.99),
    delivery_share_pct = 100 * sum(delivery_ms, na.rm = TRUE) / sum(publication_latency_ms, na.rm = TRUE),
    update_share_pct = 100 * sum(update_ms, na.rm = TRUE) / sum(publication_latency_ms, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  arrange(parts, router_threads, batch_size)

component_long <- update_data %>%
  select(parts, horizon, router_threads, batch_size, delivery_ms, update_ms) %>%
  pivot_longer(
    cols = c(delivery_ms, update_ms),
    names_to = "component",
    values_to = "duration_ms"
  ) %>%
  mutate(
    component = recode(
      component,
      delivery_ms = "Rust→Java delivery",
      update_ms = "Java update"
    )
  ) %>%
  group_by(parts, horizon, router_threads, batch_size, component) %>%
  summarise(
    median_ms = q_exact(duration_ms, 0.50),
    p95_ms = q_exact(duration_ms, 0.95),
    .groups = "drop"
  )

readr::write_csv(file_index, file.path(out_dir, "selected_java_updating_files.csv"))
readr::write_csv(update_data, file.path(out_dir, "update_delivery_latency_raw.csv"))
readr::write_csv(per_file, file.path(out_dir, "update_delivery_latency_per_file.csv"))
readr::write_csv(by_config, file.path(out_dir, "update_delivery_latency_by_batch_size_summary.csv"))
readr::write_csv(component_long, file.path(out_dir, "update_delivery_components_by_batch_size.csv"))

plot_data <- by_config %>%
  mutate(
    parts_f = factor(parts, levels = sort(unique(parts))),
    router_threads_f = factor(router_threads, levels = sort(unique(router_threads)))
  )

p_publication_median <- ggplot(
  plot_data,
  aes(
    x = batch_size,
    y = publication_median_ms,
    color = router_threads_f,
    group = router_threads_f
  )
) +
  geom_line(linewidth = 0.75, na.rm = TRUE) +
  geom_point(size = 2.1, na.rm = TRUE) +
  facet_wrap(~ parts_f, scales = "free_y", labeller = labeller(parts_f = function(x) paste0("parts=", x))) +
  scale_x_continuous(breaks = sort(unique(plot_data$batch_size))) +
  labs(
    title = "Median der Snapshot-Publication-Latenz nach Batchgröße",
    subtitle = paste0("publication = Rust→Java delivery + Java update; Horizon = ", horizon_keep),
    x = "batch_size",
    y = "Median-Latenz [ms]",
    color = "routing_threads"
  ) +
  theme_bw() +
  theme(
    legend.position = "bottom",
    axis.text.x = element_text(angle = 35, hjust = 1)
  )

safe_ggsave(file.path(out_dir, paste0(plot_name, "_publication_median_lines.png")), p_publication_median, width = 12, height = 8)

p_delivery_median <- ggplot(
  plot_data,
  aes(
    x = batch_size,
    y = delivery_median_ms,
    color = router_threads_f,
    group = router_threads_f
  )
) +
  geom_line(linewidth = 0.75, na.rm = TRUE) +
  geom_point(size = 2.1, na.rm = TRUE) +
  facet_wrap(~ parts_f, scales = "free_y", labeller = labeller(parts_f = function(x) paste0("parts=", x))) +
  scale_x_continuous(breaks = sort(unique(plot_data$batch_size))) +
  labs(
    title = "Rust→Java Batch-Delivery-Latenz nach Batchgröße",
    subtitle = paste0("Median von batch_delivery_rust_to_java_latency_ns; Horizon = ", horizon_keep),
    x = "batch_size",
    y = "Delivery-Median [ms]",
    color = "routing_threads"
  ) +
  theme_bw() +
  theme(
    legend.position = "bottom",
    axis.text.x = element_text(angle = 35, hjust = 1)
  )

safe_ggsave(file.path(out_dir, paste0(plot_name, "_delivery_median_lines.png")), p_delivery_median, width = 12, height = 8)

p_update_median <- ggplot(
  plot_data,
  aes(
    x = batch_size,
    y = update_median_ms,
    color = router_threads_f,
    group = router_threads_f
  )
) +
  geom_line(linewidth = 0.75, na.rm = TRUE) +
  geom_point(size = 2.1, na.rm = TRUE) +
  facet_wrap(~ parts_f, scales = "free_y", labeller = labeller(parts_f = function(x) paste0("parts=", x))) +
  scale_x_continuous(breaks = sort(unique(plot_data$batch_size))) +
  labs(
    title = "Java-Update-Latenz nach Batchgröße",
    subtitle = paste0("Median von total_update_ns; Horizon = ", horizon_keep),
    x = "batch_size",
    y = "Update-Median [ms]",
    color = "routing_threads"
  ) +
  theme_bw() +
  theme(
    legend.position = "bottom",
    axis.text.x = element_text(angle = 35, hjust = 1)
  )

safe_ggsave(file.path(out_dir, paste0(plot_name, "_update_median_lines.png")), p_update_median, width = 12, height = 8)

component_plot_data <- component_long %>%
  mutate(
    parts_f = factor(parts, levels = sort(unique(parts))),
    router_threads_f = factor(router_threads, levels = sort(unique(router_threads))),
    batch_size_f = factor(batch_size, levels = sort(unique(batch_size)))
  )

p_components <- ggplot(
  component_plot_data,
  aes(x = batch_size_f, y = median_ms, fill = component)
) +
  geom_col(na.rm = TRUE) +
  facet_grid(parts_f ~ router_threads_f, scales = "free_y", labeller = labeller(
    parts_f = function(x) paste0("parts=", x),
    router_threads_f = function(x) paste0("rt=", x)
  )) +
  labs(
    title = "Komponenten der Snapshot-Publication-Latenz nach Batchgröße",
    subtitle = paste0("Rust→Java delivery vs. Java update; Horizon = ", horizon_keep),
    x = "batch_size",
    y = "Median [ms]",
    fill = "Komponente"
  ) +
  theme_bw() +
  theme(
    legend.position = "bottom",
    axis.text.x = element_text(angle = 35, hjust = 1)
  )

safe_ggsave(file.path(out_dir, paste0(plot_name, "_components_median_stacked.png")), p_components, width = 14, height = 10)

share_plot_data <- by_config %>%
  select(parts, horizon, router_threads, batch_size, delivery_share_pct, update_share_pct) %>%
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
    router_threads_f = factor(router_threads, levels = sort(unique(router_threads))),
    batch_size_f = factor(batch_size, levels = sort(unique(batch_size)))
  )

p_share <- ggplot(
  share_plot_data,
  aes(x = batch_size_f, y = share_pct, fill = component)
) +
  geom_col(na.rm = TRUE) +
  facet_grid(parts_f ~ router_threads_f, labeller = labeller(
    parts_f = function(x) paste0("parts=", x),
    router_threads_f = function(x) paste0("rt=", x)
  )) +
  labs(
    title = "Relative Komponentenanteile der Snapshot-Publication-Latenz",
    subtitle = paste0("Rust→Java delivery vs. Java update; Horizon = ", horizon_keep),
    x = "batch_size",
    y = "Anteil [%]",
    fill = "Komponente"
  ) +
  theme_bw() +
  theme(
    legend.position = "bottom",
    axis.text.x = element_text(angle = 35, hjust = 1)
  )

safe_ggsave(file.path(out_dir, paste0(plot_name, "_component_share_stacked.png")), p_share, width = 14, height = 10)

readme <- c(
  "Update delivery / Snapshot-publication latency by batch_size",
  "",
  "Purpose:",
  "  Tests whether batch_size affects the updating/publishSnapshot pipeline.",
  "",
  "Definitions:",
  "  delivery_ms = batch_delivery_rust_to_java_latency_ns / 1e6",
  "  update_ms = total_update_ns / 1e6",
  "  publication_latency_ms = delivery_ms + update_ms",
  "",
  "Important outputs:",
  "  - update_delivery_latency_by_batch_size_summary.csv",
  "  - update_delivery_components_by_batch_size.csv",
  paste0("  - ", plot_name, "_publication_median_lines.png/.pdf/.emf"),
  paste0("  - ", plot_name, "_delivery_median_lines.png/.pdf/.emf"),
  paste0("  - ", plot_name, "_update_median_lines.png/.pdf/.emf"),
  paste0("  - ", plot_name, "_components_median_stacked.png/.pdf/.emf"),
  paste0("  - ", plot_name, "_component_share_stacked.png/.pdf/.emf"),
  "",
  "Interpretation note:",
  "  This is the updating / snapshot-publication pipeline, not routing-request gRPC.",
  "  The metric is a measurable approximation unless direct timeBinFinalized and publishSnapshot timestamps are present.",
  "",
  paste0("HORIZON_KEEP = ", horizon_keep),
  paste0("PARTS_KEEP = ", paste(parts_keep, collapse = ",")),
  paste0("ROUTER_THREADS_KEEP = ", paste(router_threads_keep, collapse = ",")),
  paste0("BATCH_KEEP = ", paste(batch_keep, collapse = ","))
)

writeLines(readme, file.path(out_dir, "README_update_delivery_overhead_by_batch_size.txt"))

message("Done. Outputs written to: ", out_dir)
message("Main plot: ", file.path(out_dir, paste0(plot_name, "_publication_median_lines.png")))
