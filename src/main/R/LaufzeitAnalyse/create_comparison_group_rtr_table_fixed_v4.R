#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(stringr)
  library(purrr)
  library(tidyr)
})

# ------------------------------------------------------------
# Vergleichsgruppen
# ------------------------------------------------------------

comparison_groups <- tibble::tribble(
  ~comparison_group, ~base_dir,
  "Freespeed",       "/home/lowiq/Schreibtisch/HNR-Ergebnisse/Freespeed",
  "MinPop",          "/home/lowiq/Schreibtisch/HNR-Ergebnisse/MinPop",
  "PlanBased",       "/home/lowiq/Schreibtisch/HNR-Ergebnisse/PlanedBasedRuns",
  "WithoutLogging",  "/home/lowiq/Schreibtisch/HNR-Ergebnisse/WithoutLogging",
  "WithoutUpdater",  "/home/lowiq/Schreibtisch/HNR-Ergebnisse/WithoutUpdater",
  "FullRun",         "/home/lowiq/Schreibtisch/HNR-Ergebnisse/FullRun"
)

out_dir <- "output/analysis/comparison_group_rtr_table"
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# ------------------------------------------------------------
# Hilfsfunktionen
# ------------------------------------------------------------

pick_first_existing_col <- function(df, candidates) {
  existing <- candidates[candidates %in% names(df)]
  if (length(existing) == 0) return(NA_character_)
  existing[[1]]
}

find_runtime_files <- function(base_dir) {
  if (!dir.exists(base_dir)) return(character())

  # Priorität: exakt bekannte Datei. Falls mehrere Ergebnisordner darunter liegen,
  # werden auch rekursive Treffer berücksichtigt.
  exact <- list.files(
    base_dir,
    pattern = "^simulation_runtimes_from_logs\\.csv$",
    recursive = TRUE,
    full.names = TRUE
  )

  if (length(exact) > 0) return(sort(unique(exact)))

  # Fallback: andere Runtime-/RTR-Dateien.
  fallback <- list.files(
    base_dir,
    pattern = "(?i)(runtime|runtimes|rtr).*\\.csv$",
    recursive = TRUE,
    full.names = TRUE
  )

  sort(unique(fallback))
}

# Extrahiert Partitionen robust aus Dateinamen wie:
#   sim16_hor600_w4_r24_bin900_batch10000_123_client.log
#   sim16_hor600_w4_bin900_batch10000_1pct_9178137_run.log
#   /pfad/.../sim64_hor600_w4_bin900_batch10000_1pct_...log
extract_partitions_from_file <- function(x) {
  x <- basename(as.character(x))
  val <- stringr::str_match(x, "(?:^|[_/-])sim([0-9]+)(?:_|$)")[, 2]
  suppressWarnings(as.integer(val))
}

# Referenz weitere Metadaten aus Dateinamen reparieren. Für die RTR-Tabelle ist
# nur partitions relevant, aber diese Felder helfen in der Diagnose.
extract_horizon_from_file <- function(x) {
  x <- basename(as.character(x))
  val <- stringr::str_match(x, "(?:^|[_/-])hor([0-9]+)(?:_|$)")[, 2]
  suppressWarnings(as.integer(val))
}

read_runtime_file <- function(file, comparison_group) {
  df <- tryCatch(
    readr::read_csv(file, show_col_types = FALSE),
    error = function(e) {
      warning("CSV konnte nicht gelesen werden: ", file, " | ", conditionMessage(e))
      return(NULL)
    }
  )

  if (is.null(df) || nrow(df) == 0) {
    warning("CSV ist leer oder unlesbar: ", file)
    return(NULL)
  }

  rtr_col <- pick_first_existing_col(
    df,
    c("rtr", "RTR", "real_time_ratio", "realtime_ratio", "realTimeRatio")
  )

  runtime_col <- pick_first_existing_col(
    df,
    c("runtime_s", "runtime_seconds", "simulation_runtime_s", "sim_runtime_s")
  )

  partitions_col <- pick_first_existing_col(
    df,
    c(
      "partitions",
      "partition",
      "n_partitions",
      "num_partitions",
      "routing_partitions",
      "sim_cpus"
    )
  )

  file_col <- pick_first_existing_col(df, c("file", "log_file", "source_file", "path"))

  # RTR bestimmen. Falls nur runtime_s vorhanden ist, RTR = 86400 / runtime_s.
  if (!is.na(rtr_col)) {
    rtr_values <- suppressWarnings(as.numeric(df[[rtr_col]]))
  } else if (!is.na(runtime_col)) {
    runtime_values <- suppressWarnings(as.numeric(df[[runtime_col]]))
    rtr_values <- ifelse(!is.na(runtime_values) & runtime_values > 0, 86400 / runtime_values, NA_real_)
  } else {
    warning("Keine RTR- oder Runtime-Spalte gefunden in: ", file,
            "\nVorhandene Spalten: ", paste(names(df), collapse = ", "))
    return(NULL)
  }

  # Partitionen bestimmen:
  # 1. vorhandene Spalte, wenn sie numerisch und nicht leer ist
  # 2. Dateiname in der CSV-Spalte file/log_file/etc.
  # 3. CSV-Dateiname selbst
  partitions_values <- rep(NA_integer_, nrow(df))

  if (!is.na(partitions_col)) {
    partitions_values <- suppressWarnings(as.integer(df[[partitions_col]]))
  }

  if (all(is.na(partitions_values)) && !is.na(file_col)) {
    partitions_values <- extract_partitions_from_file(df[[file_col]])
  }

  if (all(is.na(partitions_values))) {
    partitions_values <- extract_partitions_from_file(file)
  }

  # Horizon aus Spalte oder Dateiname. horizon=0 wird später als Spezialfall behandelt.
  horizon_col <- pick_first_existing_col(df, c("horizon", "preplanning_horizon"))
  horizon_values <- rep(NA_integer_, nrow(df))
  if (!is.na(horizon_col)) {
    horizon_values <- suppressWarnings(as.integer(df[[horizon_col]]))
  }
  if (all(is.na(horizon_values)) && !is.na(file_col)) {
    horizon_values <- extract_horizon_from_file(df[[file_col]])
  }

  source_file_values <- if (!is.na(file_col)) as.character(df[[file_col]]) else rep(file, nrow(df))

  tibble(
    comparison_group = comparison_group,
    partitions = partitions_values,
    horizon = horizon_values,
    rtr = rtr_values,
    input_csv = file,
    source_file = source_file_values
  ) %>%
    filter(!is.na(rtr), !is.na(partitions))
}

# ------------------------------------------------------------
# Daten laden
# ------------------------------------------------------------

runtime_file_index <- comparison_groups %>%
  mutate(files = map(base_dir, find_runtime_files)) %>%
  mutate(n_files = lengths(files))

runtime_data <- runtime_file_index %>%
  select(comparison_group, files) %>%
  tidyr::unnest(files, keep_empty = TRUE) %>%
  filter(!is.na(files)) %>%
  mutate(data = map2(files, comparison_group, read_runtime_file)) %>%
  select(data) %>%
  tidyr::unnest(data)

# Diagnose: Welche Gruppen/Dateien wurden gefunden und wie viele Zeilen waren nutzbar?
diagnostics <- runtime_file_index %>%
  select(comparison_group, base_dir, n_files) %>%
  left_join(
    runtime_data %>%
      group_by(comparison_group) %>%
      summarise(
        usable_rows = n(),
        partitions_found = paste(sort(unique(partitions)), collapse = ","),
        horizons_found = paste(sort(unique(horizon)), collapse = ","),
        .groups = "drop"
      ),
    by = "comparison_group"
  ) %>%
  mutate(
    usable_rows = coalesce(usable_rows, 0L),
    partitions_found = coalesce(partitions_found, ""),
    horizons_found = coalesce(horizons_found, "")
  )

readr::write_csv(
  diagnostics,
  file.path(out_dir, "comparison_group_rtr_diagnostics.csv")
)

if (nrow(runtime_data) == 0) {
  stop("Keine auswertbaren Runtime-Daten gefunden. Siehe Diagnose-Datei: ",
       file.path(out_dir, "comparison_group_rtr_diagnostics.csv"))
}

# ------------------------------------------------------------
# Aggregation
# ------------------------------------------------------------
# Aggregierter RTR = Median über alle Runs je Vergleichsgruppe, Horizon und Partition.
# horizon=0 bleibt bewusst als Spezialfall getrennt, da es näher an synchronem Routing liegt.
# Median ist robuster als Mittelwert und deshalb für eine kompakte Übersicht geeignet.

comparison_order <- c(
  "PlanBased",
  "WithoutUpdater",
  "Freespeed",
  "WithoutLogging",
  "MinPop",
  "FullRun"
)

rtr_table <- runtime_data %>%
  filter(!is.na(rtr), !is.na(partitions), !is.na(horizon)) %>%
  mutate(
    horizon_case = case_when(
      horizon == 0L ~ "0_sync_like",
      horizon %in% c(200L, 600L, 1800L) ~ "async_preplanning",
      TRUE ~ "other"
    ),
    horizon_label = case_when(
      horizon == 0L ~ "0 (sync-like)",
      TRUE ~ as.character(horizon)
    )
  ) %>%
  group_by(comparison_group, horizon, horizon_label, horizon_case, partitions) %>%
  summarise(
    aggregated_rtr = median(rtr, na.rm = TRUE),
    mean_rtr = mean(rtr, na.rm = TRUE),
    min_rtr = min(rtr, na.rm = TRUE),
    max_rtr = max(rtr, na.rm = TRUE),
    n_runs = n(),
    .groups = "drop"
  ) %>%
  arrange(
    factor(comparison_group, levels = comparison_order),
    horizon,
    partitions
  )

# Kompakte Haupttabelle.
# Die Horizon-Spalte ist bewusst enthalten, damit horizon=0 nicht mit 200/600/1800 vermischt wird.
rtr_table_compact <- rtr_table %>%
  transmute(
    comparison_group,
    horizon = horizon_label,
    partitions,
    aggregated_rtr
  )

# ------------------------------------------------------------
# Export
# ------------------------------------------------------------

readr::write_csv(
  rtr_table_compact,
  file.path(out_dir, "comparison_group_rtr_by_horizon_partition_compact.csv")
)

readr::write_csv(
  rtr_table,
  file.path(out_dir, "comparison_group_rtr_by_horizon_partition_with_n_runs.csv")
)

# Markdown-Tabelle für direktes Einfügen in die Arbeit.
md_lines <- c(
  "| Vergleichsgruppe | Horizon | Partitionen | aggregierter RTR |",
  "|---|---:|---:|---:|",
  apply(
    rtr_table_compact,
    1,
    function(row) {
      sprintf(
        "| %s | %s | %s | %.3f |",
        row[["comparison_group"]],
        row[["horizon"]],
        row[["partitions"]],
        as.numeric(row[["aggregated_rtr"]])
      )
    }
  )
)

writeLines(
  md_lines,
  file.path(out_dir, "comparison_group_rtr_by_horizon_partition_compact.md")
)

print(rtr_table_compact)

cat("\nGeschrieben nach:\n")
cat(file.path(out_dir, "comparison_group_rtr_by_horizon_partition_compact.csv"), "\n")
cat(file.path(out_dir, "comparison_group_rtr_by_horizon_partition_with_n_runs.csv"), "\n")
cat(file.path(out_dir, "comparison_group_rtr_by_horizon_partition_compact.md"), "\n")
cat(file.path(out_dir, "comparison_group_rtr_diagnostics.csv"), "\n")

cat("\nHinweis: horizon=0 wird als '0 (sync-like)' ausgewiesen und nicht mit horizon=200/600/1800 aggregiert.\n")
