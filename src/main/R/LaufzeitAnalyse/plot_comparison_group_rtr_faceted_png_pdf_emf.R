#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(stringr)
  library(ggplot2)
})

input_csv <- "output/analysis/comparison_group_rtr_table/comparison_group_rtr_by_horizon_partition_compact.csv"
out_dir <- "output/analysis/comparison_group_rtr_table/plots_final_faceted_png_only"
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

if (!file.exists(input_csv)) {
  stop("Eingabedatei nicht gefunden: ", input_csv)
}

comparison_order <- c(
  "Synchron-ähnlicher FullRun (h=0)",
  "PlanBased",
  "WithoutUpdater",
  "Freespeed",
  "FullRun"
)

parse_horizon_num <- function(x) {
  suppressWarnings(as.integer(str_extract(as.character(x), "-?[0-9]+")))
}

theme_eval <- function() {
  theme_minimal(base_size = 12) +
    theme(
      legend.position = "bottom",
      panel.grid.minor = element_blank(),
      strip.text = element_text(face = "bold"),
      axis.title = element_text(face = "bold")
    )
}

raw <- readr::read_csv(input_csv, show_col_types = FALSE)

required_cols <- c("comparison_group", "horizon", "partitions", "aggregated_rtr")
missing_cols <- setdiff(required_cols, names(raw))
if (length(missing_cols) > 0) {
  stop("Folgende erwartete Spalten fehlen in ", input_csv, ": ",
       paste(missing_cols, collapse = ", "))
}

df <- raw %>%
  mutate(
    horizon_num = parse_horizon_num(horizon),
    comparison_group = as.character(comparison_group),
    partitions = as.integer(partitions),
    aggregated_rtr = as.numeric(aggregated_rtr)
  ) %>%
  filter(
    comparison_group != "WithoutLogging",
    comparison_group != "MinPop",
    !is.na(comparison_group),
    !is.na(horizon_num),
    !is.na(partitions),
    !is.na(aggregated_rtr)
  )

fullrun_h0 <- df %>%
  filter(comparison_group == "FullRun", horizon_num == 0L) %>%
  transmute(
    comparison_group = "Synchron-ähnlicher FullRun (h=0)",
    facet_group = "Synchron-ähnlicher FullRun (h=0)",
    partitions,
    aggregated_rtr
  )

async_grouped <- df %>%
  filter(horizon_num %in% c(200L, 600L, 1800L)) %>%
  group_by(comparison_group, partitions) %>%
  summarise(
    aggregated_rtr = median(aggregated_rtr, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(
    facet_group = "Horizon 200/600/1800"
  ) %>%
  select(
    comparison_group,
    facet_group,
    partitions,
    aggregated_rtr
  )

df_plot <- bind_rows(fullrun_h0, async_grouped) %>%
  mutate(
    comparison_group = factor(comparison_group, levels = comparison_order),
    facet_group = factor(
      facet_group,
      levels = c("Synchron-ähnlicher FullRun (h=0)", "Horizon 200/600/1800")
    )
  ) %>%
  filter(
    !is.na(comparison_group),
    !partitions %in% c(8L, 12L, 24L, 128L),
    !(as.character(comparison_group) == "PlanBased" & partitions %in% c(96L, 164L))
  ) %>%
  arrange(comparison_group, partitions)

if (nrow(df_plot) == 0) {
  stop("Keine auswertbaren Daten nach Filterung gefunden.")
}

export_table <- df_plot %>%
  transmute(
    comparison_group = as.character(comparison_group),
    partitions,
    aggregated_rtr
  )

readr::write_csv(
  export_table,
  file.path(out_dir, "comparison_group_rtr_fullrun_h0_baseline_async_grouped.csv")
)

p <- ggplot(
  df_plot,
  aes(
    x = partitions,
    y = aggregated_rtr,
    color = comparison_group,
    group = comparison_group
  )
) +
  geom_line(linewidth = 0.7, na.rm = TRUE) +
  geom_point(size = 2, na.rm = TRUE) +
  facet_wrap(~ facet_group, scales = "free_y") +
  scale_x_continuous(breaks = sort(unique(df_plot$partitions))) +
  labs(
    title = "Aggregierter RTR nach Vergleichsgruppe und Partition",
    subtitle = "Direkter Vergleich zwischen Vergleichsgruppen. RTR nach Median aggregiert.",
    x = "Partitionen",
    y = "Aggregierter RTR",
    color = "Vergleichsgruppe"
  ) +
  theme_eval()

png_file <- file.path(out_dir, "comparison_group_rtr_fullrun_h0_baseline_async_grouped_faceted_linear.png")
pdf_file <- file.path(out_dir, "comparison_group_rtr_fullrun_h0_baseline_async_grouped_faceted_linear.pdf")
emf_file <- file.path(out_dir, "comparison_group_rtr_fullrun_h0_baseline_async_grouped_faceted_linear.emf")

ggsave(png_file, p, width = 11, height = 6.5, dpi = 300)
ggsave(pdf_file, p, width = 11, height = 6.5)

if (requireNamespace("devEMF", quietly = TRUE)) {
  devEMF::emf(file = emf_file, width = 11, height = 6.5)
  print(p)
  dev.off()
} else {
  message("Paket 'devEMF' nicht installiert; EMF wird übersprungen. Installation: install.packages('devEMF')")
}

cat(png_file, "\n")
cat(pdf_file, "\n")
if (file.exists(emf_file)) cat(emf_file, "\n")
