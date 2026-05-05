#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(stringr)
  library(tibble)
})

args <- commandArgs(trailingOnly = TRUE)

root_dir <- if (length(args) >= 1) args[[1]] else "/home/lowiq/Schreibtisch/HNR-Ergebnisse/FullRun"
out_csv  <- if (length(args) >= 2) args[[2]] else "output/analysis/file_index_recursive.csv"

dir.create(dirname(out_csv), recursive = TRUE, showWarnings = FALSE)

if (!dir.exists(root_dir)) {
  stop("Root-Ordner nicht gefunden: ", root_dir)
}

extract_int <- function(x, pattern) {
  val <- str_match(basename(as.character(x)), pattern)[, 2]
  suppressWarnings(as.integer(val))
}

classify_file_type <- function(path) {
  name <- basename(path)

  case_when(
    str_detect(name, regex("rust.*routing.*requests|routing.*requests.*rust|rust-routing-requests", ignore_case = TRUE)) ~ "rust_routing",
    str_detect(name, regex("event.*summary|rust.*event", ignore_case = TRUE)) ~ "rust_event_summary",
    str_detect(name, regex("java.*routing|routing.*java", ignore_case = TRUE)) ~ "java_routing",
    str_detect(name, regex("java.*updat|updat.*java|updating", ignore_case = TRUE)) ~ "java_updating",
    TRUE ~ "unknown"
  )
}

csv_files <- list.files(
  root_dir,
  pattern = "\\.csv$",
  recursive = TRUE,
  full.names = TRUE
)

if (length(csv_files) == 0) {
  stop("Keine CSV-Dateien gefunden in: ", root_dir)
}

idx <- tibble(
  file = normalizePath(csv_files, winslash = "/", mustWork = FALSE)
) %>%
  mutate(
    file_name = basename(file),
    rel_path = str_remove(file, paste0("^", fixed(normalizePath(root_dir, winslash = "/", mustWork = FALSE)), "/?")),
    file_type = classify_file_type(file),

    run_variant = case_when(
      str_detect(file, fixed("/Freespeed/")) ~ "Freespeed",
      str_detect(file, fixed("/MinPop/")) ~ "MinPop",
      str_detect(file, fixed("/PlanedBasedRuns/")) ~ "PlanBased",
      str_detect(file, fixed("/WithoutLogging/")) ~ "WithoutLogging",
      str_detect(file, fixed("/WithoutUpdater/")) ~ "WithoutUpdater",
      str_detect(file, fixed("/FullRun/")) ~ "FullRun",
      TRUE ~ basename(normalizePath(root_dir, winslash = "/", mustWork = FALSE))
    ),

    horizon = extract_int(file, "(?:^|[_/-])hor([0-9]+)(?:_|$)"),
    parts = extract_int(file, "(?:^|[_/-])sim([0-9]+)(?:_|$)"),
    worker_threads = extract_int(file, "(?:^|[_/-])w([0-9]+)(?:_|$)"),
    router_threads = extract_int(file, "(?:^|[_/-])r([0-9]+)(?:_|$)"),
    bin_size = extract_int(file, "(?:^|[_/-])bin([0-9]+)(?:_|$)"),
    batch_size = extract_int(file, "(?:^|[_/-])batch([0-9]+)(?:_|$)"),
    server_idx = extract_int(file, "(?:^|[_/-])server([0-9]+)(?:_|$)")
  ) %>%
  mutate(
    config_key = paste(
      paste0("h", if_else(is.na(horizon), "NA", as.character(horizon))),
      paste0("p", if_else(is.na(parts), "NA", as.character(parts))),
      paste0("w", if_else(is.na(worker_threads), "NA", as.character(worker_threads))),
      paste0("r", if_else(is.na(router_threads), "NA", as.character(router_threads))),
      paste0("bin", if_else(is.na(bin_size), "NA", as.character(bin_size))),
      paste0("batch", if_else(is.na(batch_size), "NA", as.character(batch_size))),
      sep = "_"
    )
  ) %>%
  select(
    file,
    file_type,
    config_key,
    run_variant,
    horizon,
    parts,
    worker_threads,
    router_threads,
    bin_size,
    batch_size,
    server_idx,
    file_name,
    rel_path
  ) %>%
  arrange(run_variant, horizon, parts, worker_threads, router_threads, bin_size, batch_size, file_type, file)

readr::write_csv(idx, out_csv)

cat("File index geschrieben:\n")
cat(out_csv, "\n\n")
cat("Anzahl CSV-Dateien:", nrow(idx), "\n\n")
cat("Dateitypen:\n")
print(idx %>% count(file_type, sort = TRUE))

cat("\nRun-Varianten:\n")
print(idx %>% count(run_variant, sort = TRUE))
