#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(stringr)
  library(ggplot2)
})

args <- commandArgs(trailingOnly = TRUE)

input_csv <- if (length(args) >= 1) args[[1]] else "output/analysis/runtime_rtr_reduced/runtime_rtr_table_reduced_long.csv"
out_dir <- if (length(args) >= 2) args[[2]] else "output/analysis/runtime_rtr_reduced/rtr_line_plots"
plot_name <- if (length(args) >= 3) args[[3]] else "runtime_rtr_by_horizon_partitions_threads_batch_with_p32"

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

if (!file.exists(input_csv)) {
  stop("Input CSV not found: ", input_csv)
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

theme_eval <- function() {
  theme_minimal(base_size = 11) +
    theme(
      legend.position = "bottom",
      legend.box = "vertical",
      panel.grid.minor = element_blank(),
      strip.text = element_text(face = "bold", size = 10),
      axis.title = element_text(face = "bold"),
      plot.title = element_text(face = "bold"),
      plot.subtitle = element_text(size = 9)
    )
}

raw <- readr::read_csv(input_csv, show_col_types = FALSE)

partitions_col <- first_existing_col(raw, c("partitions", "parts", "sim_cpus", "partition"))
horizon_col <- first_existing_col(raw, c("horizon", "preplanning_horizon"))
routing_threads_col <- first_existing_col(raw, c("routing_threads", "router_threads", "router", "r"))
batch_col <- first_existing_col(raw, c("batch_size", "batch"))
rtr_col <- first_existing_col(raw, c("rtr", "RTR", "rtr_median", "aggregated_rtr", "real_time_ratio"))

missing <- c(
  if (is.na(partitions_col)) "partitions",
  if (is.na(horizon_col)) "horizon",
  if (is.na(routing_threads_col)) "routing_threads",
  if (is.na(batch_col)) "batch_size",
  if (is.na(rtr_col)) "rtr"
)

if (length(missing) > 0) {
  stop("Could not infer required columns: ", paste(missing, collapse = ", "),
       "\nAvailable columns: ", paste(names(raw), collapse = ", "))
}

df <- raw %>%
  transmute(
    partitions = as_int_safe(.data[[partitions_col]]),
    horizon = as_int_safe(.data[[horizon_col]]),
    routing_threads = as_int_safe(.data[[routing_threads_col]]),
    batch_size = as_int_safe(.data[[batch_col]]),
    rtr = as_num_safe(.data[[rtr_col]])
  ) %>%
  filter(
    batch_size %in% c(500L, 10000L, 25000L, 45000L),
    partitions %in% c(1L, 32L, 64L, 192L),
    routing_threads %in% c(1L, 24L, 96L, 192L),
    horizon %in% c(0L, 200L, 600L, 1800L),
    !is.na(rtr),
    is.finite(rtr)
  ) %>%
  group_by(horizon, partitions, routing_threads, batch_size) %>%
  summarise(
    rtr = median(rtr, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(
    horizon_label = factor(
      paste0("h = ", horizon),
      levels = paste0("h = ", c(0, 200, 600, 1800))
    ),
    routing_threads_label = factor(
      paste0(routing_threads, " router threads"),
      levels = paste0(c(1, 24, 96, 192), " router threads")
    ),
    batch_size_label = factor(
      paste0("batch ", batch_size),
      levels = paste0("batch ", c(500, 10000, 25000, 45000))
    )
  ) %>%
  arrange(horizon, routing_threads, batch_size, partitions)

if (nrow(df) == 0) {
  stop("No rows after filtering.")
}

readr::write_csv(
  df,
  file.path(out_dir, paste0(plot_name, "_filtered.csv"))
)

p_all_batches <- ggplot(
  df,
  aes(
    x = partitions,
    y = rtr,
    color = routing_threads_label,
    linetype = batch_size_label,
    shape = batch_size_label,
    group = interaction(routing_threads_label, batch_size_label)
  )
) +
  geom_line(linewidth = 0.65, na.rm = TRUE) +
  geom_point(size = 2.0, na.rm = TRUE) +
  facet_wrap(~ horizon_label, nrow = 1, scales = "free_y") +
  scale_x_continuous(breaks = c(1, 32, 64, 192)) +
  labs(
    title = "RTR nach Partitionen, Routing-Threads und Batchgröße",
    subtitle = "Panels zeigen den Preplanning-Horizon; Werte sind Median-RTR je Konfiguration.",
    x = "Partitionen",
    y = "RTR",
    color = "Routing-Threads",
    linetype = "Batchgröße",
    shape = "Batchgröße"
  ) +
  theme_eval()

png_all <- file.path(out_dir, paste0(plot_name, "_all_batches.png"))
pdf_all <- file.path(out_dir, paste0(plot_name, "_all_batches.pdf"))
emf_all <- file.path(out_dir, paste0(plot_name, "_all_batches.emf"))

ggsave(png_all, p_all_batches, width = 12.0, height = 5.6, dpi = 300)
ggsave(pdf_all, p_all_batches, width = 12.0, height = 5.6)

if (requireNamespace("devEMF", quietly = TRUE)) {
  devEMF::emf(file = emf_all, width = 12.0, height = 5.6, bg = "white")
  print(p_all_batches)
  dev.off()
} else {
  message("Paket 'devEMF' nicht installiert; EMF wird übersprungen. Installation: install.packages('devEMF')")
}

df_b25000 <- df %>%
  filter(batch_size == 25000L)

p_batch_25000 <- ggplot(
  df_b25000,
  aes(
    x = partitions,
    y = rtr,
    color = routing_threads_label,
    group = routing_threads_label
  )
) +
  geom_line(linewidth = 0.75, na.rm = TRUE) +
  geom_point(size = 2.2, na.rm = TRUE) +
  facet_wrap(~ horizon_label, nrow = 1, scales = "free_y") +
  scale_x_continuous(breaks = c(1, 32, 64, 192)) +
  labs(
    title = "RTR nach Partitionen und Routing-Threads",
    subtitle = "Batchgröße fixiert auf 25000; Werte sind Median-RTR je Konfiguration.",
    x = "Partitionen",
    y = "RTR",
    color = "Routing-Threads"
  ) +
  theme_eval()

png_b25000 <- file.path(out_dir, paste0(plot_name, "_batch25000.png"))
pdf_b25000 <- file.path(out_dir, paste0(plot_name, "_batch25000.pdf"))
emf_b25000 <- file.path(out_dir, paste0(plot_name, "_batch25000.emf"))

ggsave(png_b25000, p_batch_25000, width = 11.2, height = 4.8, dpi = 300)
ggsave(pdf_b25000, p_batch_25000, width = 11.2, height = 4.8)

if (requireNamespace("devEMF", quietly = TRUE)) {
  devEMF::emf(file = emf_b25000, width = 11.2, height = 4.8, bg = "white")
  print(p_batch_25000)
  dev.off()
}

cat("Wrote:\n")
cat("  ", png_all, "\n", sep = "")
cat("  ", pdf_all, "\n", sep = "")
if (file.exists(emf_all)) cat("  ", emf_all, "\n", sep = "")
cat("  ", png_b25000, "\n", sep = "")
cat("  ", pdf_b25000, "\n", sep = "")
if (file.exists(emf_b25000)) cat("  ", emf_b25000, "\n", sep = "")
cat("  ", file.path(out_dir, paste0(plot_name, "_filtered.csv")), "\n", sep = "")
