Analyseskripte
=========================

Reihenfolge:

Zuerst Laufzeiten der Durchläufe aus client.log auslesen...:
python3 extract_sim_runtime_from_logs.py *client.log > simulation_runtimes_from_logs.csv
Die Aufrufe erwarten die simulation_runtimes_from_logs.csv in output/analysis

...dann Skripte in der Reihenfolge mit den entsprechenden Aufrufen ausführen. Hier Aufrufe mit meinen Kombinationen:
1) Dateiindex:
Rscript R/Hilfsskripte/create_file_index_recursive_robust.R \
  /home/lowiq/Schreibtisch/HNR-Ergebnisse/FullRun \
  output/analysis/file_index_recursive.csv

2) Streaming-Summary-Pipeline:
Rscript R/Hilfsskripte/run_recursive_streaming_summary_pipeline.R \
  /home/lowiq/Schreibtisch/HNR-Ergebnisse/FullRun \
  output/analysis

3) RTR-Haupttabelle:
BATCH_KEEP=500,10000,25000,45000 \
PARTS_KEEP=1,16,32,64,128,192 \
ROUTER_THREADS_KEEP=1,8,24,48,96,192 \
HORIZONS_KEEP=0,200,600,1800 \
Rscript R/LaufzeitAnalyse/create_runtime_rtr_table_reduced_minimal_patch_threads192_keep_batch_fixed.R \
  output/analysis/simulation_runtimes_from_logs.csv \
  output/analysis/runtime_rtr_reduced

4) RTR-Overviews:
Rscript R/LaufzeitAnalyse/create_runtime_rtr_overviews_no_batch_5000_15000_no_parts_12_24.R \
  output/analysis/simulation_runtimes_from_logs.csv \
  output/analysis/runtime_rtr_overviews

5) 2x2-Horizon-Tabelle:
Rscript R/LaufzeitAnalyse/create_runtime_rtr_horizon_2x2_tables_compact_v3_with_p32.R \
  output/analysis/runtime_rtr_reduced/runtime_rtr_table_reduced_long.csv \
  output/analysis/runtime_rtr_reduced/horizon_2x2_tables_compact_v3_with_p32 \
  runtime_rtr_horizon_2x2_compact_v3_with_p32

6) RTR-Line-Plots:
Rscript R/LaufzeitAnalyse/create_runtime_rtr_line_plots_with_p32.R \
  output/analysis/runtime_rtr_reduced/runtime_rtr_table_reduced_long.csv \
  output/analysis/runtime_rtr_reduced/rtr_line_plots_with_p32 \
  runtime_rtr_by_horizon_partitions_threads_batch_with_p32

7) Vergleichsgruppen:
Rscript R/LaufzeitAnalyse/create_comparison_group_rtr_table_fixed_v4.R \
  /home/lowiq/Schreibtisch/HNR-Ergebnisse \
  output/analysis/comparison_group_rtr_table

8) Rscript R/LaufzeitAnalyse/plot_comparison_group_rtr_faceted_png_pdf_emf.R

9) Blocking-Recv / Routing-Duration:
PARTS_KEEP=1,32,64,192 \
ROUTER_THREADS_KEEP=1,24,48,96,192 \
BATCH_KEEP=500,10000,25000,45000 \
Rscript R/Referenz/create_blocking_recv_representative_config_plots_complete_horizons_emf.R \
  output/analysis/file_index_recursive.csv \
  output/analysis/simulation_runtimes_from_logs.csv \
  output/analysis/blocking_recv_representative_configs_complete_horizons

10) Blocking-Recv-Referenzplot:
PARTS_KEEP=64 \
ROUTER_THREADS_KEEP=24 \
HORIZON_KEEP=600 \
BATCH_KEEP=10000 \
Rscript R/Referenz/plot_blocking_recv_vs_routing_duration_reference_config_clean_emf.R \
  output/analysis/file_index_recursive.csv \
  output/analysis/simulation_runtimes_from_logs.csv \
  output/analysis/blocking_recv_vs_routing_duration_reference_config

11) Routing-Komponenten:
PARTS_KEEP=1,32,64,192 \
ROUTER_THREADS_KEEP=1,24,48,96,192 \
INCLUDE_RESIDUAL=1 \
Rscript R/Komponentenanteile/routing_component_shares_rtr_groups_h600_by_parts_threads_grpc_total_p10_median_by_parts_threads_fixed2_emf.R \
  output/analysis/file_index_recursive.csv \
  output/analysis/simulation_runtimes_from_logs.csv \
  output/analysis/routing_component_shares_rtr_groups_h600_by_parts_threads_grpc_total_p10_median_by_parts_threads

12) JavaTotal-Komponenten:
PARTS_KEEP=1,32,64,192 \
ROUTER_THREADS_KEEP=1,24,48,96,192 \
INCLUDE_RESIDUAL=1 \
Rscript R/Komponentenanteile/java_javaTotal_component_shares_fixed.R \
  output/analysis/file_index_recursive.csv \
  output/analysis/simulation_runtimes_from_logs.csv \
  output/analysis/Komponenten_JavaTotal

13) bindSnapshot nach TimeBin-Offset:
TIME_BIN_SIZE=900 \
SIM_TIME_COL=now \
EARLY_WINDOW_END=20 \
CRITICAL_WINDOW_END=3 \
SAMPLE_PER_FILE=1000 \
Rscript R/Komponentenanteile/analyze_bind_snapshot_by_timebin_offset_h600_subset_v2_emf.R \
  output/analysis/file_index_recursive.csv \
  output/analysis/bind_snapshot_by_timebin_offset_h600_subset_v2

14) publishSnapshot-Latenz nach Batchgroesse:
PARTS_KEEP=1,32,64,192 \
ROUTER_THREADS_KEEP=1,48,96 \
HORIZON_KEEP=600 \
Rscript R/Komponentenanteile/analyze_publish_snapshot_latency_by_batch_size_h600_median_plot6_fixed.R \
  output/analysis/file_index_recursive.csv \
  output/analysis/publish_snapshot_latency_by_batch_size_h600 \
  output/analysis/bind_snapshot_by_timebin_offset_h600_subset_v2/bind_snapshot_by_offset_window_parts_threads.csv

15) Updating-/Snapshot-Pipeline:
PARTS_KEEP=1,32,64,192 \
ROUTER_THREADS_KEEP=1,24,48,96,192 \
BATCH_KEEP=500,10000,25000,45000 \
HORIZON_KEEP=600 \
Rscript R/Komponentenanteile/plot_update_delivery_overhead_by_batch_size_h600.R \
  output/analysis/file_index_recursive.csv \
  output/analysis/update_delivery_overhead_by_batch_size_h600 \
  update_delivery_overhead_by_batch_size_h600

16) BlockingWait nach departure_time - now:
HORIZON_KEEP=600 \
Rscript R/BlockingWait/analyze_blocking_wait_by_departure_minus_now_v2_true_blocking_wait_emf_fixed.R \
  output/analysis/file_index_recursive.csv \
  output/analysis/blocking_wait_by_departure_minus_now_h600

17) BlockingWait gefiltert:
HORIZON_KEEP=600 \
MIN_DEPARTURE_MINUS_NOW=30 \
Rscript R/BlockingWait/analyze_blocking_wait_filtered_departure_minus_now_true_blocking_wait_emf_fixed.R \
  output/analysis/file_index_recursive.csv \
  output/analysis/blocking_wait_departure_ge30_h600

18) BlockingWait nach Partitionen:
Rscript R/BlockingWait/analyze_blocking_wait_by_partitions_from_summaries_v2_true_blocking_wait_emf_fixed.R \
  output/analysis/blocking_wait_by_departure_minus_now_h600/summary_by_config.csv \
  output/analysis/blocking_wait_by_partitions \
  output/analysis/blocking_wait_departure_ge30_h600/blocking_wait_filtered_by_config.csv
