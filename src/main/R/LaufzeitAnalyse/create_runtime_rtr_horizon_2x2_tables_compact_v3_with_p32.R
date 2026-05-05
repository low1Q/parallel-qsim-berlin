#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(tidyr)
  library(stringr)
  library(grid)
})

args <- commandArgs(trailingOnly = TRUE)

input_csv <- if (length(args) >= 1) args[[1]] else "output/analysis/runtime_rtr_reduced/runtime_rtr_table_reduced_long.csv"
out_dir <- if (length(args) >= 2) args[[2]] else "output/analysis/runtime_rtr_reduced/horizon_2x2_tables_compact_v3_with_p32"
table_name <- if (length(args) >= 3) args[[3]] else "runtime_rtr_horizon_2x2_compact_v3_with_p32"

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

fmt_rtr <- function(x) {
  ifelse(is.na(x), "", formatC(round(x), format = "f", digits = 0, big.mark = "", decimal.mark = "."))
}

make_horizon_table <- function(df, h) {
  x <- df %>%
    filter(horizon == h) %>%
    mutate(cell = fmt_rtr(rtr)) %>%
    select(partitions, routing_threads, batch_size, cell) %>%
    arrange(partitions, routing_threads, batch_size)

  x %>%
    mutate(batch_col = paste0("b=", batch_size)) %>%
    select(partitions, routing_threads, batch_col, cell) %>%
    pivot_wider(
      names_from = batch_col,
      values_from = cell
    ) %>%
    arrange(partitions, routing_threads) %>%
    mutate(
      partitions = as.character(partitions),
      routing_threads = as.character(routing_threads)
    ) %>%
    rename(
      `part.` = partitions,
      `router` = routing_threads
    ) %>%
    select(
      `part.`,
      `router`,
      any_of(c("b=500", "b=10000", "b=25000", "b=45000"))
    )
}

draw_panel <- function(tab, title, x0, y0, w, h) {
  pushViewport(viewport(
    x = unit(x0, "npc"),
    y = unit(y0, "npc"),
    width = unit(w, "npc"),
    height = unit(h, "npc"),
    just = c("left", "bottom"),
    xscale = c(0, 1),
    yscale = c(0, 1)
  ))

  grid.text(
    title,
    x = unit(0.5, "native"),
    y = unit(0.99, "native"),
    just = c("center", "top"),
    gp = gpar(fontface = "bold", fontsize = 8.5)
  )

  table_top <- 0.91
  table_bottom <- 0.03
  n_rows <- nrow(tab) + 1
  row_h <- (table_top - table_bottom) / n_rows

  col_widths <- c(0.13, 0.15, 0.18, 0.18, 0.18, 0.18)
  col_right <- cumsum(col_widths)
  col_x <- col_right - 0.018

  grid.lines(
    x = unit(c(0, 1), "native"),
    y = unit(c(table_top, table_top), "native"),
    gp = gpar(lwd = 0.9)
  )

  header_y <- table_top - row_h / 2
  for (j in seq_along(names(tab))) {
    grid.text(
      names(tab)[[j]],
      x = unit(col_x[[j]], "native"),
      y = unit(header_y, "native"),
      just = c("right", "center"),
      gp = gpar(fontface = "bold", fontsize = 6.2)
    )
  }

  grid.lines(
    x = unit(c(0, 1), "native"),
    y = unit(c(table_top - row_h, table_top - row_h), "native"),
    gp = gpar(lwd = 0.65)
  )

  for (i in seq_len(nrow(tab))) {
    y <- table_top - row_h * (i + 0.5)

    if (i > 1 && tab[["part."]][[i]] != tab[["part."]][[i - 1]]) {
      grid.lines(
        x = unit(c(0, 1), "native"),
        y = unit(c(table_top - row_h * i, table_top - row_h * i), "native"),
        gp = gpar(lwd = 0.42)
      )
    }

    vals <- as.character(tab[i, , drop = TRUE])
    for (j in seq_along(vals)) {
      grid.text(
        vals[[j]],
        x = unit(col_x[[j]], "native"),
        y = unit(y, "native"),
        just = c("right", "center"),
        gp = gpar(fontsize = 6.2)
      )
    }
  }

  grid.lines(
    x = unit(c(0, 1), "native"),
    y = unit(c(table_bottom, table_bottom), "native"),
    gp = gpar(lwd = 0.9)
  )

  popViewport()
}

draw_full <- function(tables) {
  grid.newpage()

  draw_panel(tables[[1]], "h = 0",    0.035, 0.515, 0.455, 0.455)
  draw_panel(tables[[2]], "h = 200",  0.510, 0.515, 0.455, 0.455)
  draw_panel(tables[[3]], "h = 600",  0.035, 0.035, 0.455, 0.455)
  draw_panel(tables[[4]], "h = 1800", 0.510, 0.035, 0.455, 0.455)
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
    !is.na(rtr)
  ) %>%
  group_by(horizon, partitions, routing_threads, batch_size) %>%
  summarise(
    rtr = median(rtr, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  arrange(horizon, partitions, routing_threads, batch_size)

readr::write_csv(
  df,
  file.path(out_dir, paste0(table_name, "_filtered_long.csv"))
)

tables <- list(
  make_horizon_table(df, 0L),
  make_horizon_table(df, 200L),
  make_horizon_table(df, 600L),
  make_horizon_table(df, 1800L)
)

readr::write_csv(tables[[1]], file.path(out_dir, paste0(table_name, "_h0.csv")))
readr::write_csv(tables[[2]], file.path(out_dir, paste0(table_name, "_h200.csv")))
readr::write_csv(tables[[3]], file.path(out_dir, paste0(table_name, "_h600.csv")))
readr::write_csv(tables[[4]], file.path(out_dir, paste0(table_name, "_h1800.csv")))

png_file <- file.path(out_dir, paste0(table_name, "_2x2_compact_v3.png"))
pdf_file <- file.path(out_dir, paste0(table_name, "_2x2_compact_v3.pdf"))
emf_file <- file.path(out_dir, paste0(table_name, "_2x2_compact_v3.emf"))

png(png_file, width = 3000, height = 1900, res = 300, bg = "white")
draw_full(tables)
dev.off()

pdf(pdf_file, width = 10.0, height = 6.35)
draw_full(tables)
dev.off()

if (requireNamespace("devEMF", quietly = TRUE)) {
  devEMF::emf(file = emf_file, width = 10.0, height = 6.35, bg = "white")
  draw_full(tables)
  dev.off()
} else {
  message("Paket 'devEMF' nicht installiert; EMF wird übersprungen. Installation: install.packages('devEMF')")
}

cat("Wrote:\n")
cat("  ", png_file, "\n", sep = "")
cat("  ", pdf_file, "\n", sep = "")
if (file.exists(emf_file)) cat("  ", emf_file, "\n", sep = "")
cat("  ", file.path(out_dir, paste0(table_name, "_filtered_long.csv")), "\n", sep = "")
