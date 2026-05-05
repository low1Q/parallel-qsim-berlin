#!/usr/bin/env Rscript

# create_runtime_rtr_table_reduced.R
#
# Erstellt reduzierte RTR-Tabellen für die Frage:
#   Wie wirkt sich die Router-Konfiguration auf die Simulationslaufzeit aus?
#
# Im Vergleich zu create_runtime_rtr_table.R werden bewusst entfernt:
#   - sample (%), weil konstant 1 %
#   - n_runs, wenn pro Konfiguration nur ein Run vorhanden ist
#   - runtime (s), weil die Laufzeit über RTR ausgedrückt wird
#
# Standardmäßig wird auf BATCH_SIZE=25000 gefiltert, weil BatchSize nicht
# die zentrale Variable dieses Auswertungsschritts ist.
#
# Aufruf:
#   Rscript R/create_runtime_rtr_table_reduced.R \
#     output/analysis/simulation_runtimes_from_logs.csv \
#     output/analysis/runtime_rtr_reduced
#
# Optionale Filter über Umgebungsvariablen:
#   BATCH_KEEP=25000
#   PARTS_KEEP=1,64,192
#   ROUTER_THREADS_KEEP=24,48,96
#   HORIZONS_KEEP=0,200,600,1800
#
# Beispiel:
#   PARTS_KEEP=1,64,192 BATCH_KEEP=25000 \
#   Rscript R/create_runtime_rtr_table_reduced.R \
#     output/analysis/simulation_runtimes_from_logs.csv \
#     output/analysis/runtime_rtr_reduced

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(stringr)
  library(tidyr)
})

args <- commandArgs(trailingOnly = TRUE)

input_file <- ifelse(length(args) >= 1, args[[1]], "output/analysis/simulation_runtimes_from_logs.csv")
out_dir <- ifelse(length(args) >= 2, args[[2]], "output/analysis/runtime_rtr_reduced")

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

if (!file.exists(input_file)) {
  stop("Input file not found: ", input_file)
}

parse_keep <- function(x) {
  if (is.na(x) || !nzchar(x)) return(NULL)
  as.integer(trimws(strsplit(x, ",", fixed = TRUE)[[1]]))
}

batch_keep <- parse_keep(Sys.getenv("BATCH_KEEP", "25000"))
parts_keep <- parse_keep(Sys.getenv("PARTS_KEEP", ""))
router_keep <- parse_keep(Sys.getenv("ROUTER_THREADS_KEEP", "192"))
horizon_keep <- parse_keep(Sys.getenv("HORIZONS_KEEP", ""))

pick_col <- function(df, candidates, required = TRUE) {
  hit <- candidates[candidates %in% names(df)]
  if (length(hit) > 0) return(hit[[1]])
  if (required) stop("Missing required column. Tried: ", paste(candidates, collapse = ", "))
  NA_character_
}

message("Reading: ", input_file)
raw <- readr::read_csv(input_file, show_col_types = FALSE)

col_parts <- pick_col(raw, c("parts", "sim_cpus", "SIM_CPUS", "partition_count", "partitionCount"))
col_horizon <- pick_col(raw, c("horizon", "HORIZON", "preplanning_horizon", "PH", "pH"))
col_router <- pick_col(raw, c("router_threads", "ROUTER_THREADS", "routing_threads", "threads"))
col_batch <- pick_col(raw, c("batch_size", "BATCH_SIZE", "batchSize", "batch"), required = TRUE)
col_runtime <- pick_col(raw, c("runtime_s", "runtime_sec", "walltime_s", "elapsed_s", "duration_s"))
col_rtr <- pick_col(raw, c("rtr", "RTR", "real_time_ratio", "realTimeRatio"), required = FALSE)
col_parse <- pick_col(raw, c("parse_status"), required = FALSE)
col_completed <- pick_col(raw, c("completed"), required = FALSE)
col_variant <- pick_col(raw, c("run_variant", "variant", "router_variant", "mode"), required = FALSE)
col_file <- pick_col(raw, c("file", "source_file", "log_file"), required = FALSE)

infer_variant <- function(file) {
  if (is.na(file)) return("normal")
  x <- str_to_lower(file)
  case_when(
    str_detect(x, "without_logging|nologging|no_logging|no-logging|keinlogging") ~ "without_logging",
    str_detect(x, "without_updat|without-updat|noupdat|disabledupdat|disable-updat") ~ "without_updating",
    str_detect(x, "planbased|plan-based") ~ "planbased",
    str_detect(x, "minact|min_act|min-act") ~ "min_act_pop",
    TRUE ~ "normal"
  )
}

file_values <- if (!is.na(col_file)) as.character(raw[[col_file]]) else rep(NA_character_, nrow(raw))

dat <- raw %>%
  mutate(
    partitions = suppressWarnings(as.integer(.data[[col_parts]])),
    horizon = suppressWarnings(as.integer(.data[[col_horizon]])),
    routing_threads = suppressWarnings(as.integer(.data[[col_router]])),
    batch_size = if (!is.na(col_batch)) suppressWarnings(as.integer(.data[[col_batch]])) else NA_integer_,
    runtime_s = suppressWarnings(as.numeric(.data[[col_runtime]])),
    RTR = if (!is.na(col_rtr)) suppressWarnings(as.numeric(.data[[col_rtr]])) else NA_real_,
    parse_status = if (!is.na(col_parse)) as.character(.data[[col_parse]]) else "ok",
    completed = if (!is.na(col_completed)) as.logical(.data[[col_completed]]) else TRUE,
    run_variant = if (!is.na(col_variant)) as.character(.data[[col_variant]]) else vapply(file_values, infer_variant, character(1))
  ) %>%
  mutate(
    RTR = ifelse(is.na(RTR) & !is.na(runtime_s) & runtime_s > 0, 86400 / runtime_s, RTR)
  ) %>%
  filter(
    parse_status == "ok",
    completed == TRUE,
    !is.na(RTR),
    !is.na(partitions),
    !is.na(horizon),
    !is.na(routing_threads)
  )

if (!is.null(batch_keep)) {
  dat <- dat %>% filter(batch_size %in% batch_keep)
}
if (!is.null(parts_keep)) {
  dat <- dat %>% filter(partitions %in% parts_keep)
}
if (!is.null(router_keep)) {
  dat <- dat %>% filter(routing_threads %in% router_keep)
}
if (!is.null(horizon_keep)) {
  dat <- dat %>% filter(horizon %in% horizon_keep)
}

if (nrow(dat) == 0) {
  stop("No rows after filtering. Check BATCH_KEEP/PARTS_KEEP/ROUTER_THREADS_KEEP/HORIZONS_KEEP.")
}

# Varianten nur in Tabellen behalten, wenn sie wirklich variieren.
keep_variant <- n_distinct(dat$run_variant) > 1

# batch_size ist fachlich Teil der Haupttabelle und darf nicht herausfallen.
if (!"batch_size" %in% names(dat) || all(is.na(dat$batch_size))) {
  stop("batch_size is missing or only NA in the input table. Check simulation_runtimes_from_logs.csv.")
}

group_cols <- c("partitions", "horizon", "routing_threads", "batch_size")
if (keep_variant) group_cols <- c("run_variant", group_cols)

summary_long <- dat %>%
  group_by(across(all_of(group_cols))) %>%
  summarise(
    RTR = round(median(RTR, na.rm = TRUE)),
    runtime_s_median_for_check = round(median(runtime_s, na.rm = TRUE), 2),
    runs_aggregated_for_check = n(),
    .groups = "drop"
  ) %>%
  arrange(horizon, partitions, routing_threads, batch_size) %>%
  mutate(run_id = row_number()) %>%
  relocate(run_id)

# Haupttabelle lang: nur die fachlich gewünschten Spalten.
long_cols <- c("run_id")
if (keep_variant) long_cols <- c(long_cols, "run_variant")
long_cols <- c(long_cols, "partitions", "horizon", "routing_threads")
long_cols <- c(long_cols, "batch_size")
long_cols <- c(long_cols, "RTR")

table_long <- summary_long %>%
  select(all_of(long_cols))

readr::write_csv(table_long, file.path(out_dir, "runtime_rtr_table_reduced_long.csv"))

# Noch kompakter: routing_threads als Spalten.
wide_id_cols <- c("partitions", "horizon")
wide_id_cols <- c(wide_id_cols, "batch_size")
if (keep_variant) wide_id_cols <- c("run_variant", wide_id_cols)

table_wide <- summary_long %>%
  select(any_of(c(wide_id_cols, "routing_threads", "RTR"))) %>%
  mutate(routing_threads_col = paste0("RTR_rt", routing_threads)) %>%
  select(-routing_threads) %>%
  pivot_wider(names_from = routing_threads_col, values_from = RTR) %>%
  arrange(horizon, partitions, batch_size)

readr::write_csv(table_wide, file.path(out_dir, "runtime_rtr_table_reduced_wide.csv"))

# Prüftabelle mit Runtime und Aggregationsanzahl separat, nicht für die Arbeit gedacht.
readr::write_csv(summary_long, file.path(out_dir, "runtime_rtr_table_reduced_check.csv"))

# Markdown export
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

write_markdown(table_long, file.path(out_dir, "runtime_rtr_table_reduced_long.md"))
write_markdown(table_wide, file.path(out_dir, "runtime_rtr_table_reduced_wide.md"))

# LaTeX export
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

write_latex(
  table_long,
  file.path(out_dir, "runtime_rtr_table_reduced_long.tex"),
  "Real-Time-Ratio der ausgewählten Router-Konfigurationen.",
  "tab:runtime-rtr-reduced-long"
)

write_latex(
  table_wide,
  file.path(out_dir, "runtime_rtr_table_reduced_wide.tex"),
  "Real-Time-Ratio nach Partitionen, Preplanning-Horizon und Routing-Threads.",
  "tab:runtime-rtr-reduced-wide"
)

# Kurze README
readme <- c(
  "Reduced runtime/RTR table",
  "=========================",
  "",
  paste0("Input: ", input_file),
  paste0("Rows after filtering: ", nrow(dat)),
  paste0("Batch filter: ", ifelse(is.null(batch_keep), "none", paste(batch_keep, collapse = ", "))),
  paste0("Parts filter: ", ifelse(is.null(parts_keep), "none", paste(parts_keep, collapse = ", "))),
  paste0("Router thread filter: ", ifelse(is.null(router_keep), "none", paste(router_keep, collapse = ", "))),
  paste0("Horizon filter: ", ifelse(is.null(horizon_keep), "none", paste(horizon_keep, collapse = ", "))),
  "",
  "Main outputs:",
  "- runtime_rtr_table_reduced_long.csv / .md / .tex",
  "- runtime_rtr_table_reduced_wide.csv / .md / .tex",
  "",
  "Notes:",
  "- sample (%) is omitted because all runs use the 1% sample.",
  "- runtime (s) is omitted because RTR already expresses runtime performance.",
  "- n_runs is omitted from the thesis table; the check table keeps runs_aggregated_for_check.",
  "- If multiple runs exist for one configuration, RTR is aggregated by median."
)

writeLines(readme, file.path(out_dir, "README.txt"))

message("Wrote outputs to: ", out_dir)
message("Rows in long table: ", nrow(table_long))
message("Rows in wide table: ", nrow(table_wide))
message("Main compact table: ", file.path(out_dir, "runtime_rtr_table_reduced_wide.csv"))
