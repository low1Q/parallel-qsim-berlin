library(data.table)
library(ggplot2)
library(scales)
library(dplyr)
library(lubridate)
library(tidyr)
source("src/main/R/utils.R")


# read csv with header thread,now,departure_time,from,to,start,duration_ns,travel_time_s,request_id at /path
path <- "/home/lowiq/MATSimBA/parallel-qsim-berlin/output/routing/routing-profiling-2026-01-05_22-00-13.csv"
dt <- fread(path)

dt[, thread := factor(thread)]

dt <- dt %>%
  mutate(end = start + duration_ns)

ggplot(dt, aes(x = 1, y = duration_ns / 1e6)) +
  geom_violin() +
  scale_y_log10(
    breaks = scales::log_breaks(n = 10),
    # labels = scales::label_log()
  ) +
  theme_increase_all_text() +
  labs(
    title = paste("Duration per thread at ", path),
    x = "Thread",
    y = "Duration in ms"
  )

events <- bind_rows(
  dt %>% transmute(time_ns = start, delta = 1L),
  dt %>% transmute(time_ns = start + duration_ns, delta = -1L)
) %>%
  arrange(time_ns) %>%
  mutate(active = cumsum(delta))

ggplot(events, aes(x = time_ns, y = active)) +
  geom_step() +
  scale_x_continuous(labels = scales::scientific) +
  labs(
    x = "Time (ns)",
    y = "Active requests",
    title = "System Concurrency Over Time @ Router"
  ) +
  theme_minimal()

per_thread <- dt %>%
  group_by(thread) %>%
  summarise(
    total_run_ns = as.numeric(sum(duration_ns)),      # total busy time
    first_start_ns = min(start),
    last_end_ns = max(end),
    thread_window_ns = as.numeric(last_end_ns - first_start_ns),
    idle_within_thread_window_ns = as.numeric(thread_window_ns - total_run_ns),
    .groups = "drop"
  )

# plot thread on x axis and total_run_ns and idle_within_thread_window_ns as stacked bars
per_thread_long <- per_thread %>%
  pivot_longer(cols = c(total_run_ns, idle_within_thread_window_ns), names_to = "type", values_to = "time_ns")
ggplot(per_thread_long, aes(x = thread, y = time_ns / 1e6, fill = type)) +
  geom_bar(stat = "identity") +
  labs(
    x = "All Threads",
    y = "Time (ms)",
    title = "Per-Thread Busy and Idle Time @ Router",
    fill = "Type"
  ) +
  theme_minimal()
