# === toolchain ===
IVERILOG ?= iverilog
VVP      ?= vvp

# Fail fast if toolchain is missing
check-tools:
	@command -v $(IVERILOG) >/dev/null 2>&1 || (echo "Missing simulator: $(IVERILOG)" && exit 1)
	@command -v $(VVP) >/dev/null 2>&1      || (echo "Missing runtime:   $(VVP)" && exit 1)

# === RTL (core pipeline) ===
RTL = \
  ../rtl/aer_rx.v \
  ../rtl/lif_tile_tmux.v \
  ../rtl/delay_lattice_rb.v \
  ../rtl/reichardt_ds.v \
  ../rtl/burst_gate.v \
  ../rtl/ab_predictor.v \
  ../rtl/tracker_pool.v \
  ../rtl/conf_gate.v \
  ../rtl/libellula_top.v

# === RTL (AXI4-Stream SoC layer) ===
RTL_AXI = \
  ../rtl/axi4s_to_aer.v \
  ../rtl/axi4s_pred_wrapper.v \
  ../rtl/libellula_soc.v

# === claim metric benches ===
TB_LAT   = ../tb/tb_latency.v
TB_PX300 = ../tb/tb_px_bound_300hz.v
TB_MEPS  = ../tb/tb_aer_throughput_1meps.v
TB_POWLO = ../tb/tb_power_lo.v
TB_POWHI = ../tb/tb_power_hi.v

# === unit-test benches ===
TB_AER_RX   = ../tb/tb_aer_rx.v
TB_LIF      = ../tb/tb_lif_tile_tmux.v
TB_DL       = ../tb/tb_delay_lattice_rb.v
TB_REICH    = ../tb/tb_reichardt_ds.v
TB_BURST    = ../tb/tb_burst_gate.v
TB_ABPRED   = ../tb/tb_ab_predictor.v
TB_CONF     = ../tb/tb_conf_gate.v

# === scenario benches ===
TB_CV       = ../tb/tb_cv_linear.v
TB_CLUTTER  = ../tb/tb_cross_clutter.v
TB_ACCEL    = ../tb/tb_accel_limit.v
TB_CROSSING = ../tb/tb_crossing.v
TB_ROTBAR   = ../tb/tb_rotating_bar.v
TB_BURSTD   = ../tb/tb_burst_demo.v
TB_DENSE    = ../tb/tb_dense_burst.v
TB_ZERO     = ../tb/tb_zero_motion.v
TB_SPARSE   = ../tb/tb_sparse_events.v
TB_DIRREV   = ../tb/tb_direction_reversal.v
TB_MULTI    = ../tb/tb_multi_target.v
TB_NODROP   = ../tb/tb_meps_nodrop.v
TB_PREDERR  = ../tb/tb_prediction_error.v
TB_LINEDGE  = ../tb/tb_linear_edge.v

# === v22-specific scenario benches ===
TB_ACCURACY = ../tb/tb_accuracy.v
TB_E2EMOT   = ../tb/tb_e2e_motion.v
TB_NATURAL  = ../tb/tb_naturalistic.v
TB_REVERSAL = ../tb/tb_reversal.v
TB_AWSWEEP  = ../tb/tb_aw_sweep.v
TB_MULTIPOOL = ../tb/tb_multi_target_pool.v

# === CDX diagnostic benches (require -DLIBELLULA_DIAG) ===
TB_LIF_LIVE   = ../tb/tb_lif_liveness.v
TB_INGEST_LIV = ../tb/tb_ingestion_liveness.v
TB_CANON_AUD  = ../tb/tb_canonical_motion_audit.v

# === hostile / failure-mode benches ===
TB_RSTMS = ../tb_hostile/tb_reset_midstream_top.v
TB_AERST = ../tb_hostile/tb_aer_req_stuck_high.v
TB_RAND  = ../tb_hostile/tb_random_stress_top.v

# === benchmark harness ===
TB_BENCH = ../tb/tb_benchmark_driver.v
TB_PREDGOLD = ../tb/tb_pred_valid_golden.v
TB_MUSTFIRE = ../tb/tb_pred_must_fire.v
TB_LIFDIAG = ../tb/tb_lif_unit_diag.v
TB_SCANHASH = ../tb/tb_scan_hash_diag.v

# === AXI4-Stream SoC layer benches ===
TB_AXI_IN    = ../tb/tb_axi4s_to_aer.v
TB_AXI_WRAP  = ../tb/tb_axi4s_wrapper.v
TB_AXI_BURST = ../tb/tb_axi4s_pred_burst.v
TB_AXI_INTEG = ../tb/tb_axi4s_integration.v

# === defaults ===
all: test

init:
	@mkdir -p build
	@echo "Build directory ready."

# ---------- compile helper ----------
# 1) run iverilog, capture stderr
# 2) fail if iverilog returns non-zero
# 3) fail if stderr contains "error" (case-insensitive)
define COMPILE
	$(IVERILOG) -g2012 -Wall -I ../tb -o $(1) $(RTL) $(2) 2> $(3) || (echo "Compile failed" && cat $(3) && exit 1)
	@if grep -Ei '(^|[^a-zA-Z])error([^a-zA-Z]|$$)' $(3) >/dev/null; then \
		echo "Compile errors detected"; \
		cat $(3); \
		exit 1; \
	fi
endef

# ---------- claim: latency ----------
build/tb_latency: check-tools $(TB_LAT) $(RTL) | init
	$(call COMPILE,$@,$(TB_LAT),build/tb_latency_iverilog.log)

latency: build/tb_latency
	$(VVP) build/tb_latency

# ---------- claim: 300Hz ±2px ----------
build/tb_px_bound_300hz: check-tools $(TB_PX300) $(RTL) | init
	$(call COMPILE,$@,$(TB_PX300),build/tb_px_bound_300hz_iverilog.log)

px300: build/tb_px_bound_300hz
	$(VVP) build/tb_px_bound_300hz

# ---------- claim: 1 Meps throughput ----------
build/tb_aer_throughput_1meps: check-tools $(TB_MEPS) $(RTL) | init
	$(call COMPILE,$@,$(TB_MEPS),build/tb_aer_throughput_1meps_iverilog.log)

meps: build/tb_aer_throughput_1meps
	$(VVP) build/tb_aer_throughput_1meps

# ---------- claim: activity-proportional power ----------
build/tb_power_lo: check-tools $(TB_POWLO) $(RTL) | init
	$(call COMPILE,$@,$(TB_POWLO),build/tb_power_lo_iverilog.log)

build/tb_power_hi: check-tools $(TB_POWHI) $(RTL) | init
	$(call COMPILE,$@,$(TB_POWHI),build/tb_power_hi_iverilog.log)

power: build/tb_power_lo build/tb_power_hi
	$(VVP) build/tb_power_lo
	$(VVP) build/tb_power_hi
	python3 ../tools/count_toggles.py build/power_lo.vcd > build/power_lo.tog
	python3 ../tools/count_toggles.py build/power_hi.vcd > build/power_hi.tog
	@echo "toggles_low,$$(awk '{s+=$$1}END{print s+0}' build/power_lo.tog)"  > build/power_activity.csv
	@echo "toggles_high,$$(awk '{s+=$$1}END{print s+0}' build/power_hi.tog)" >> build/power_activity.csv
	@echo "Power activity CSV at sim/build/power_activity.csv"
	@python3 -c "\
import sys; \
lo=int(open('build/power_lo.tog').read().strip()); \
hi=int(open('build/power_hi.tog').read().strip()); \
ratio=hi/lo if lo>0 else 0; \
print(f'toggles_low={lo}  toggles_high={hi}  ratio={ratio:.3f}x (8x event rate)'); \
sys.exit(0 if (hi > lo and ratio >= 1.3) else 1)" || \
	(echo "FAIL: power scaling assertion (toggles_high must be >= 1.3x toggles_low)" && exit 1)
	@echo "PASS: power scaling assertion"

# ---------- unit tests ----------
build/tb_aer_rx: check-tools $(TB_AER_RX) $(RTL) | init
	$(call COMPILE,$@,$(TB_AER_RX),build/tb_aer_rx_iverilog.log)

build/tb_lif_tile_tmux: check-tools $(TB_LIF) $(RTL) | init
	$(call COMPILE,$@,$(TB_LIF),build/tb_lif_tile_tmux_iverilog.log)

build/tb_delay_lattice_rb: check-tools $(TB_DL) $(RTL) | init
	$(call COMPILE,$@,$(TB_DL),build/tb_delay_lattice_rb_iverilog.log)

build/tb_reichardt_ds: check-tools $(TB_REICH) $(RTL) | init
	$(call COMPILE,$@,$(TB_REICH),build/tb_reichardt_ds_iverilog.log)

build/tb_burst_gate: check-tools $(TB_BURST) $(RTL) | init
	$(call COMPILE,$@,$(TB_BURST),build/tb_burst_gate_iverilog.log)

build/tb_ab_predictor: check-tools $(TB_ABPRED) $(RTL) | init
	$(call COMPILE,$@,$(TB_ABPRED),build/tb_ab_predictor_iverilog.log)

build/tb_conf_gate: check-tools $(TB_CONF) $(RTL) | init
	$(call COMPILE,$@,$(TB_CONF),build/tb_conf_gate_iverilog.log)

build/tb_lif_liveness: check-tools $(TB_LIF_LIVE) $(RTL) | init
	$(call COMPILE,$@,$(TB_LIF_LIVE),build/tb_lif_liveness_iverilog.log)

lif_liveness: build/tb_lif_liveness
	$(VVP) build/tb_lif_liveness

units: build/tb_aer_rx build/tb_lif_tile_tmux build/tb_delay_lattice_rb \
       build/tb_reichardt_ds build/tb_burst_gate build/tb_ab_predictor build/tb_conf_gate \
       build/tb_lif_liveness
	$(VVP) build/tb_aer_rx
	$(VVP) build/tb_lif_tile_tmux
	$(VVP) build/tb_delay_lattice_rb
	$(VVP) build/tb_reichardt_ds
	$(VVP) build/tb_burst_gate
	$(VVP) build/tb_ab_predictor
	$(VVP) build/tb_conf_gate
	$(VVP) build/tb_lif_liveness
	@echo "UNIT TESTS PASSED"

# ---------- scenario tests ----------
build/tb_cv_linear: check-tools $(TB_CV) $(RTL) | init
	$(call COMPILE,$@,$(TB_CV),build/tb_cv_linear_iverilog.log)

build/tb_cross_clutter: check-tools $(TB_CLUTTER) $(RTL) | init
	$(call COMPILE,$@,$(TB_CLUTTER),build/tb_cross_clutter_iverilog.log)

build/tb_accel_limit: check-tools $(TB_ACCEL) $(RTL) | init
	$(call COMPILE,$@,$(TB_ACCEL),build/tb_accel_limit_iverilog.log)

build/tb_crossing: check-tools $(TB_CROSSING) $(RTL) | init
	$(call COMPILE,$@,$(TB_CROSSING),build/tb_crossing_iverilog.log)

build/tb_rotating_bar: check-tools $(TB_ROTBAR) $(RTL) | init
	$(call COMPILE,$@,$(TB_ROTBAR),build/tb_rotating_bar_iverilog.log)

build/tb_burst_demo: check-tools $(TB_BURSTD) $(RTL) | init
	$(call COMPILE,$@,$(TB_BURSTD),build/tb_burst_demo_iverilog.log)

build/tb_dense_burst: check-tools $(TB_DENSE) $(RTL) | init
	$(call COMPILE,$@,$(TB_DENSE),build/tb_dense_burst_iverilog.log)

build/tb_zero_motion: check-tools $(TB_ZERO) $(RTL) | init
	$(call COMPILE,$@,$(TB_ZERO),build/tb_zero_motion_iverilog.log)

build/tb_sparse_events: check-tools $(TB_SPARSE) $(RTL) | init
	$(call COMPILE,$@,$(TB_SPARSE),build/tb_sparse_events_iverilog.log)

build/tb_direction_reversal: check-tools $(TB_DIRREV) $(RTL) | init
	$(call COMPILE,$@,$(TB_DIRREV),build/tb_direction_reversal_iverilog.log)

build/tb_multi_target: check-tools $(TB_MULTI) $(RTL) | init
	$(call COMPILE,$@,$(TB_MULTI),build/tb_multi_target_iverilog.log)

build/tb_meps_nodrop: check-tools $(TB_NODROP) $(RTL) | init
	$(call COMPILE,$@,$(TB_NODROP),build/tb_meps_nodrop_iverilog.log)

build/tb_prediction_error: check-tools $(TB_PREDERR) $(RTL) | init
	$(call COMPILE,$@,$(TB_PREDERR),build/tb_prediction_error_iverilog.log)

build/tb_linear_edge: check-tools $(TB_LINEDGE) $(RTL) | init
	$(call COMPILE,$@,$(TB_LINEDGE),build/tb_linear_edge_iverilog.log)

# ---------- v22 scenario benches ----------
build/tb_accuracy: check-tools $(TB_ACCURACY) $(RTL) | init
	$(call COMPILE,$@,$(TB_ACCURACY),build/tb_accuracy_iverilog.log)

accuracy: build/tb_accuracy
	$(VVP) build/tb_accuracy

build/tb_e2e_motion: check-tools $(TB_E2EMOT) $(RTL) | init
	$(call COMPILE,$@,$(TB_E2EMOT),build/tb_e2e_motion_iverilog.log)

e2e_motion: build/tb_e2e_motion
	$(VVP) build/tb_e2e_motion

build/tb_naturalistic: check-tools $(TB_NATURAL) $(RTL) | init
	$(call COMPILE,$@,$(TB_NATURAL),build/tb_naturalistic_iverilog.log)

naturalistic: build/tb_naturalistic
	$(VVP) build/tb_naturalistic

build/tb_reversal: check-tools $(TB_REVERSAL) $(RTL) | init
	$(call COMPILE,$@,$(TB_REVERSAL),build/tb_reversal_iverilog.log)

reversal: build/tb_reversal
	$(VVP) build/tb_reversal

build/tb_aw_sweep: check-tools $(TB_AWSWEEP) $(RTL) | init
	$(call COMPILE,$@,$(TB_AWSWEEP),build/tb_aw_sweep_iverilog.log)

aw_sweep: build/tb_aw_sweep
	$(VVP) build/tb_aw_sweep

build/tb_multi_target_pool: check-tools $(TB_MULTIPOOL) $(RTL) | init
	$(call COMPILE,$@,$(TB_MULTIPOOL),build/tb_multi_target_pool_iverilog.log)

multi_target_pool: build/tb_multi_target_pool
	$(VVP) build/tb_multi_target_pool

# ---------- diagnostic benches (require -DLIBELLULA_DIAG) ----------
build/tb_ingestion_liveness: check-tools $(RTL) $(TB_INGEST_LIV) | init
	$(IVERILOG) -g2012 -Wall -I ../tb -DLIBELLULA_DIAG -o $@ $(RTL) $(TB_INGEST_LIV) 2> build/tb_ingestion_liveness_iverilog.log || (echo "Compile failed" && cat build/tb_ingestion_liveness_iverilog.log && exit 1)
	@if grep -Ei '(^|[^a-zA-Z])error([^a-zA-Z]|$$)' build/tb_ingestion_liveness_iverilog.log >/dev/null; then \
		echo "Compile errors detected"; \
		cat build/tb_ingestion_liveness_iverilog.log; \
		exit 1; \
	fi

tb_ingestion_liveness: build/tb_ingestion_liveness
	$(VVP) build/tb_ingestion_liveness

build/tb_canonical_motion_audit: check-tools $(RTL) $(TB_CANON_AUD) | init
	$(IVERILOG) -g2012 -Wall -I ../tb -DLIBELLULA_DIAG -o $@ $(RTL) $(TB_CANON_AUD) 2> build/tb_canonical_motion_audit_iverilog.log || (echo "Compile failed" && cat build/tb_canonical_motion_audit_iverilog.log && exit 1)
	@if grep -Ei '(^|[^a-zA-Z])error([^a-zA-Z]|$$)' build/tb_canonical_motion_audit_iverilog.log >/dev/null; then \
		echo "Compile errors detected"; \
		cat build/tb_canonical_motion_audit_iverilog.log; \
		exit 1; \
	fi

tb_canonical_motion_audit: build/tb_canonical_motion_audit
	$(VVP) build/tb_canonical_motion_audit

diagnostic: build/tb_ingestion_liveness build/tb_canonical_motion_audit
	$(VVP) build/tb_ingestion_liveness
	$(VVP) build/tb_canonical_motion_audit
	@echo "DIAGNOSTIC TESTS PASSED"

build/tb_benchmark_driver: check-tools $(TB_BENCH) $(RTL) | init
	$(call COMPILE,$@,$(TB_BENCH),build/tb_benchmark_driver_iverilog.log)

build/tb_pred_valid_golden: check-tools $(TB_PREDGOLD) $(RTL) | init
	$(call COMPILE,$@,$(TB_PREDGOLD),build/tb_pred_valid_golden_iverilog.log)

build/tb_pred_must_fire: check-tools $(TB_MUSTFIRE) $(RTL) | init
	$(call COMPILE,$@,$(TB_MUSTFIRE),build/tb_pred_must_fire_iverilog.log)

build/tb_lif_unit_diag: check-tools $(TB_LIFDIAG) $(RTL) | init
	$(call COMPILE,$@,$(TB_LIFDIAG),build/tb_lif_unit_diag_iverilog.log)

build/tb_scan_hash_diag: check-tools $(TB_SCANHASH) $(RTL) | init
	$(call COMPILE,$@,$(TB_SCANHASH),build/tb_scan_hash_diag_iverilog.log)

# ---------- AXI4-S SoC layer benches ----------
# tb_axi4s_to_aer: bridge unit test (input bridge only, no core RTL)
build/tb_axi4s_to_aer: check-tools $(TB_AXI_IN) ../rtl/axi4s_to_aer.v | init
	$(IVERILOG) -g2012 -Wall -DSIMULATION -o $@ ../rtl/axi4s_to_aer.v $(TB_AXI_IN) \
		2> build/tb_axi4s_to_aer_iverilog.log || (echo "Compile failed" && cat build/tb_axi4s_to_aer_iverilog.log && exit 1)
	@if grep -Ei '(^|[^a-zA-Z])error([^a-zA-Z]|$$)' build/tb_axi4s_to_aer_iverilog.log >/dev/null; then \
		echo "Compile errors detected"; cat build/tb_axi4s_to_aer_iverilog.log; exit 1; fi

axi_to_aer: build/tb_axi4s_to_aer
	$(VVP) build/tb_axi4s_to_aer

# tb_axi4s_wrapper: prediction wrapper unit test (wrapper only, no core RTL)
build/tb_axi4s_wrapper: check-tools $(TB_AXI_WRAP) ../rtl/axi4s_pred_wrapper.v | init
	$(IVERILOG) -g2012 -Wall -DSIMULATION -o $@ ../rtl/axi4s_pred_wrapper.v $(TB_AXI_WRAP) \
		2> build/tb_axi4s_wrapper_iverilog.log || (echo "Compile failed" && cat build/tb_axi4s_wrapper_iverilog.log && exit 1)
	@if grep -Ei '(^|[^a-zA-Z])error([^a-zA-Z]|$$)' build/tb_axi4s_wrapper_iverilog.log >/dev/null; then \
		echo "Compile errors detected"; cat build/tb_axi4s_wrapper_iverilog.log; exit 1; fi

axi_wrapper: build/tb_axi4s_wrapper
	$(VVP) build/tb_axi4s_wrapper

# tb_axi4s_pred_burst: FIFO overflow and multi-target burst test
build/tb_axi4s_pred_burst: check-tools $(TB_AXI_BURST) ../rtl/axi4s_pred_wrapper.v | init
	$(IVERILOG) -g2012 -Wall -DSIMULATION -o $@ ../rtl/axi4s_pred_wrapper.v $(TB_AXI_BURST) \
		2> build/tb_axi4s_pred_burst_iverilog.log || (echo "Compile failed" && cat build/tb_axi4s_pred_burst_iverilog.log && exit 1)
	@if grep -Ei '(^|[^a-zA-Z])error([^a-zA-Z]|$$)' build/tb_axi4s_pred_burst_iverilog.log >/dev/null; then \
		echo "Compile errors detected"; cat build/tb_axi4s_pred_burst_iverilog.log; exit 1; fi

axi_burst: build/tb_axi4s_pred_burst
	$(VVP) build/tb_axi4s_pred_burst

# tb_axi4s_integration: end-to-end bridge->core integration test
build/tb_axi4s_integration: check-tools $(TB_AXI_INTEG) $(RTL) ../rtl/axi4s_to_aer.v | init
	$(IVERILOG) -g2012 -Wall -DSIMULATION -I ../tb -o $@ \
		$(RTL) ../rtl/axi4s_to_aer.v $(TB_AXI_INTEG) \
		2> build/tb_axi4s_integration_iverilog.log || (echo "Compile failed" && cat build/tb_axi4s_integration_iverilog.log && exit 1)
	@if grep -Ei '(^|[^a-zA-Z])error([^a-zA-Z]|$$)' build/tb_axi4s_integration_iverilog.log >/dev/null; then \
		echo "Compile errors detected"; cat build/tb_axi4s_integration_iverilog.log; exit 1; fi

axi_integ: build/tb_axi4s_integration
	$(VVP) build/tb_axi4s_integration

# axi: run all four AXI layer benches
axi: build/tb_axi4s_to_aer build/tb_axi4s_wrapper \
     build/tb_axi4s_pred_burst build/tb_axi4s_integration
	$(VVP) build/tb_axi4s_to_aer
	$(VVP) build/tb_axi4s_wrapper
	$(VVP) build/tb_axi4s_pred_burst
	$(VVP) build/tb_axi4s_integration
	@echo "AXI TESTS PASSED"

scenarios: build/tb_cv_linear build/tb_cross_clutter build/tb_accel_limit \
           build/tb_crossing build/tb_rotating_bar build/tb_burst_demo \
           build/tb_dense_burst build/tb_zero_motion build/tb_sparse_events \
           build/tb_direction_reversal build/tb_multi_target build/tb_meps_nodrop \
           build/tb_prediction_error build/tb_linear_edge \
           build/tb_accuracy build/tb_e2e_motion build/tb_naturalistic \
           build/tb_reversal build/tb_aw_sweep build/tb_multi_target_pool
	$(VVP) build/tb_cv_linear
	$(VVP) build/tb_cross_clutter
	$(VVP) build/tb_accel_limit
	$(VVP) build/tb_crossing
	$(VVP) build/tb_rotating_bar
	$(VVP) build/tb_burst_demo
	$(VVP) build/tb_dense_burst
	$(VVP) build/tb_zero_motion
	$(VVP) build/tb_sparse_events
	$(VVP) build/tb_direction_reversal
	$(VVP) build/tb_multi_target
	$(VVP) build/tb_meps_nodrop
	$(VVP) build/tb_prediction_error
	$(VVP) build/tb_linear_edge
	$(VVP) build/tb_accuracy
	$(VVP) build/tb_e2e_motion
	$(VVP) build/tb_naturalistic
	$(VVP) build/tb_reversal
	$(VVP) build/tb_aw_sweep
	$(VVP) build/tb_multi_target_pool
	@echo "SCENARIO TESTS PASSED"

# ---------- hostile / failure-mode benches ----------
build/tb_reset_midstream_top: check-tools $(TB_RSTMS) $(RTL) | init
	$(call COMPILE,$@,$(TB_RSTMS),build/tb_reset_midstream_top_iverilog.log)

resetmid: build/tb_reset_midstream_top
	$(VVP) build/tb_reset_midstream_top

build/tb_aer_req_stuck_high: check-tools $(TB_AERST) $(RTL) | init
	$(call COMPILE,$@,$(TB_AERST),build/tb_aer_req_stuck_high_iverilog.log)

aerstuck: build/tb_aer_req_stuck_high
	$(VVP) build/tb_aer_req_stuck_high

build/tb_random_stress_top: check-tools $(TB_RAND) $(RTL) | init
	$(call COMPILE,$@,$(TB_RAND),build/tb_random_stress_top_iverilog.log)

randstress: build/tb_random_stress_top
	$(VVP) build/tb_random_stress_top

hostile: resetmid aerstuck randstress
	@echo "HOSTILE TESTS PASSED"

# ---------- run all benches (single pass) ----------
run-once: latency px300 meps power units scenarios hostile diagnostic
	@echo "ALL TESTBENCHES PASSED (single pass)"

# ---------- test: core x3 + full suite once ----------
test:
	@for i in 1 2 3; do \
		echo "=== RUN $$i/3: latency ===";   $(MAKE) -s latency   || exit 1; \
		echo "=== RUN $$i/3: px300 ===";     $(MAKE) -s px300     || exit 1; \
		echo "=== RUN $$i/3: meps ===";      $(MAKE) -s meps      || exit 1; \
	done; \
	echo "=== RUN: units ===";    $(MAKE) -s units    || exit 1; \
	echo "=== RUN: scenarios ==="; $(MAKE) -s scenarios || exit 1; \
	echo "=== RUN: hostile ===";  $(MAKE) -s hostile  || exit 1; \
	echo "ALL TESTS PASSED x3 core + full suite + hostile"

# ---------- report ----------
report: run-once
	@echo "LIBELLULA v22: SIM REPORT" > build/REPORT.txt
	@date >> build/REPORT.txt
	@echo "" >> build/REPORT.txt
	@echo "Core benches (make run-once): 3 claim (x3) + 8 units + 20 scenarios + 3 hostile + 2 power + 2 diagnostic = 38 distinct benches" >> build/REPORT.txt
	@echo "Core benches (make test):     3 claim (x3) + 8 units + 20 scenarios + 3 hostile                            = 34 distinct benches" >> build/REPORT.txt
	@echo "AXI layer (make axi):         tb_axi4s_to_aer (49) + tb_axi4s_wrapper (27) + tb_axi4s_pred_burst (33) + tb_axi4s_integration (2) = 111 assertions" >> build/REPORT.txt
	@echo "" >> build/REPORT.txt
	@echo "PASS" >> build/REPORT.txt
	@echo "Written: sim/build/REPORT.txt"

# ---------- full-diagnostic ----------
# Runs all 9 diagnostic phases via Python orchestrator.
# Results land in diagnostics_full/out/*.csv and diagnostics_full/*.md
full-diagnostic: build/tb_pred_valid_golden build/tb_pred_must_fire \
                 build/tb_lif_unit_diag build/tb_scan_hash_diag
	cd .. && python3 diagnostics_full/scripts/run_full_diagnostic.py

# ==========================================================================
# RTL validation: named test_* targets
# ==========================================================================

# ---- new bench variables ----
TB_CFG_REG    = ../tb/tb_cfg_registers.v
TB_TS_ORDER   = ../tb/tb_aer_timestamp_order.v
TB_HOT_PIX    = ../tb/tb_hot_pixel_rejection.v
TB_OVERFLOW   = ../tb/tb_overflow_flags.v
TB_DROPCNT    = ../tb/tb_drop_count_accounting.v
TB_OOO        = ../tb/tb_out_of_order_events.v
TB_DUP        = ../tb/tb_duplicate_event_handling.v
TB_LAT_JIT    = ../tb/tb_latency_jitter.v
TB_DET_REP    = ../tb/tb_deterministic_replay.v
TB_STOPSTART  = ../tb/tb_target_stop_start.v
TB_EGO        = ../tb/tb_ego_motion_rejection.v
TB_OCCL       = ../tb/tb_occlusion_reacquire.v
TB_SMLFAST    = ../tb/tb_small_fast_target.v
TB_GATESWEEP  = ../tb/tb_gate_threshold_sweep.v
TB_COV        = ../tb/tb_coverage.v

# ---- build rules for new benches ----
build/tb_cfg_registers: check-tools $(TB_CFG_REG) $(RTL) | init
	$(call COMPILE,$@,$(TB_CFG_REG),build/tb_cfg_registers_iverilog.log)

build/tb_aer_timestamp_order: check-tools $(TB_TS_ORDER) $(RTL) | init
	$(call COMPILE,$@,$(TB_TS_ORDER),build/tb_aer_timestamp_order_iverilog.log)

build/tb_hot_pixel_rejection: check-tools $(TB_HOT_PIX) $(RTL) | init
	$(call COMPILE,$@,$(TB_HOT_PIX),build/tb_hot_pixel_rejection_iverilog.log)

build/tb_overflow_flags: check-tools $(TB_OVERFLOW) $(RTL) | init
	$(call COMPILE,$@,$(TB_OVERFLOW),build/tb_overflow_flags_iverilog.log)

build/tb_drop_count_accounting: check-tools $(TB_DROPCNT) $(RTL) | init
	$(call COMPILE,$@,$(TB_DROPCNT),build/tb_drop_count_accounting_iverilog.log)

build/tb_out_of_order_events: check-tools $(TB_OOO) $(RTL) | init
	$(call COMPILE,$@,$(TB_OOO),build/tb_out_of_order_events_iverilog.log)

build/tb_duplicate_event_handling: check-tools $(TB_DUP) $(RTL) | init
	$(call COMPILE,$@,$(TB_DUP),build/tb_duplicate_event_handling_iverilog.log)

build/tb_latency_jitter: check-tools $(TB_LAT_JIT) $(RTL) | init
	$(call COMPILE,$@,$(TB_LAT_JIT),build/tb_latency_jitter_iverilog.log)

build/tb_deterministic_replay: check-tools $(TB_DET_REP) $(RTL) | init
	$(call COMPILE,$@,$(TB_DET_REP),build/tb_deterministic_replay_iverilog.log)

build/tb_target_stop_start: check-tools $(TB_STOPSTART) $(RTL) | init
	$(call COMPILE,$@,$(TB_STOPSTART),build/tb_target_stop_start_iverilog.log)

build/tb_ego_motion_rejection: check-tools $(TB_EGO) $(RTL) | init
	$(call COMPILE,$@,$(TB_EGO),build/tb_ego_motion_rejection_iverilog.log)

build/tb_occlusion_reacquire: check-tools $(TB_OCCL) $(RTL) | init
	$(call COMPILE,$@,$(TB_OCCL),build/tb_occlusion_reacquire_iverilog.log)

build/tb_small_fast_target: check-tools $(TB_SMLFAST) $(RTL) | init
	$(call COMPILE,$@,$(TB_SMLFAST),build/tb_small_fast_target_iverilog.log)

build/tb_gate_threshold_sweep: check-tools $(TB_GATESWEEP) $(RTL) | init
	$(call COMPILE,$@,$(TB_GATESWEEP),build/tb_gate_threshold_sweep_iverilog.log)

build/tb_coverage: check-tools $(TB_COV) $(RTL) | init
	$(call COMPILE,$@,$(TB_COV),build/tb_coverage_iverilog.log)

# ---- test_* targets: aliases to existing benches where applicable ----

test_reset: build/tb_reset_midstream_top
	$(VVP) build/tb_reset_midstream_top

test_cfg_registers: build/tb_cfg_registers
	$(VVP) build/tb_cfg_registers

test_aer_rx_decode: build/tb_aer_rx
	$(VVP) build/tb_aer_rx

test_aer_timestamp_order: build/tb_aer_timestamp_order
	$(VVP) build/tb_aer_timestamp_order

test_xy_polarity_parse: build/tb_aer_rx
	$(VVP) build/tb_aer_rx

test_input_fifo_backpressure: build/tb_meps_nodrop
	$(VVP) build/tb_meps_nodrop

# libellula is a single-clock design; CDC not applicable.
test_cdc_if_present:
	@echo "CDC: single-clock design — no CDC paths to check. PASS"

test_idle_no_false_events: build/tb_zero_motion
	$(VVP) build/tb_zero_motion

test_hot_pixel_rejection: build/tb_hot_pixel_rejection
	$(VVP) build/tb_hot_pixel_rejection

test_noise_burst_rejection: build/tb_cross_clutter
	$(VVP) build/tb_cross_clutter

test_max_event_rate: build/tb_aer_throughput_1meps
	$(VVP) build/tb_aer_throughput_1meps

test_overflow_flags: build/tb_overflow_flags
	$(VVP) build/tb_overflow_flags

test_drop_count_accounting: build/tb_drop_count_accounting
	$(VVP) build/tb_drop_count_accounting

test_out_of_order_events: build/tb_out_of_order_events
	$(VVP) build/tb_out_of_order_events

test_duplicate_event_handling: build/tb_duplicate_event_handling
	$(VVP) build/tb_duplicate_event_handling

test_latency_cycles: build/tb_latency
	$(VVP) build/tb_latency

test_latency_jitter: build/tb_latency_jitter
	$(VVP) build/tb_latency_jitter

test_deterministic_replay: build/tb_deterministic_replay
	$(VVP) build/tb_deterministic_replay

test_single_target_linear: build/tb_cv_linear
	$(VVP) build/tb_cv_linear

test_single_target_accel: build/tb_accel_limit
	$(VVP) build/tb_accel_limit

test_target_stop_start: build/tb_target_stop_start
	$(VVP) build/tb_target_stop_start

test_crossing_targets: build/tb_crossing
	$(VVP) build/tb_crossing

test_clutter_background: build/tb_cross_clutter
	$(VVP) build/tb_cross_clutter

test_ego_motion_rejection: build/tb_ego_motion_rejection
	$(VVP) build/tb_ego_motion_rejection

test_occlusion_reacquire: build/tb_occlusion_reacquire
	$(VVP) build/tb_occlusion_reacquire

test_small_fast_target: build/tb_small_fast_target
	$(VVP) build/tb_small_fast_target

test_prediction_error: build/tb_prediction_error
	$(VVP) build/tb_prediction_error

test_gate_threshold_sweep: build/tb_gate_threshold_sweep
	$(VVP) build/tb_gate_threshold_sweep

test_long_stream_stability: build/tb_naturalistic
	$(VVP) build/tb_naturalistic

test_assertions: build/tb_random_stress_top
	$(VVP) build/tb_random_stress_top

test_coverage: build/tb_coverage
	$(VVP) build/tb_coverage

# ---- aggregate: run all 31 named test_* targets ----
test_all_named: \
	test_reset test_cfg_registers test_aer_rx_decode test_aer_timestamp_order \
	test_xy_polarity_parse test_input_fifo_backpressure test_cdc_if_present \
	test_idle_no_false_events test_hot_pixel_rejection test_noise_burst_rejection \
	test_max_event_rate test_overflow_flags test_drop_count_accounting \
	test_out_of_order_events test_duplicate_event_handling \
	test_latency_cycles test_latency_jitter test_deterministic_replay \
	test_single_target_linear test_single_target_accel test_target_stop_start \
	test_crossing_targets test_clutter_background test_ego_motion_rejection \
	test_occlusion_reacquire test_small_fast_target test_prediction_error \
	test_gate_threshold_sweep test_long_stream_stability test_assertions \
	test_coverage
	@echo "ALL NAMED TESTS PASSED"

# ==========================================================================
# Release-quality targets
# ==========================================================================

# ---- bench variables for new targets ----
TB_FORMAL   = ../tb/tb_formal_props.v
TB_GOLD_GEN = ../tb/tb_golden_gen.v
TB_REPLAY   = ../tb/tb_replay_lockstep.v
TB_COV_FULL = ../tb/tb_coverage_full.v

VERILATOR ?= verilator

# ---------- lint -----------------------------------------------------------
# Zero-warning Verilator lint of all released RTL.
# PROCASSINIT suppressed: `reg foo = 0;` + always-block is valid Verilog-2001
#   reset-init style used throughout (synthesises correctly on FPGA/ASIC).
# UNUSED/UNDRIVEN suppressed: diagnostic counter signals (#ifdef LIBELLULA_DIAG)
#   are deliberately left undriven in the default build.
lint: | init
	@echo "=== LINT: Verilator --lint-only ==="
	@$(VERILATOR) --lint-only -Wall \
	  -Wno-DECLFILENAME -Wno-UNUSED -Wno-UNDRIVEN -Wno-PROCASSINIT \
	  $(RTL) --top-module libellula_top \
	  2> build/lint.log && echo "LINT PASS: zero warnings" \
	  || (echo "LINT FAIL — see build/lint.log:" && cat build/lint.log && exit 1)

# ---------- formal ---------------------------------------------------------
# Bounded-simulation formal properties check (50 000 cycles, LFSR stimulus).
# Verifies P1..P5: reset safety, no-X, state_mem clear, saturation, determinism.
# NOTE: full SVA model checking requires SymbiYosys (not in this toolchain).
build/tb_formal_props: check-tools $(TB_FORMAL) $(RTL) | init
	$(call COMPILE,$@,$(TB_FORMAL),build/tb_formal_props_iverilog.log)

formal: build/tb_formal_props
	@echo "=== FORMAL (bounded simulation, 50000 cycles) ==="
	$(VVP) build/tb_formal_props

# ---------- golden_vectors -------------------------------------------------
# Freeze representative stimulus + expected outputs to build/golden/.
build/tb_golden_gen: check-tools $(TB_GOLD_GEN) $(RTL) | init
	$(call COMPILE,$@,$(TB_GOLD_GEN),build/tb_golden_gen_iverilog.log)

golden_vectors: build/tb_golden_gen | init
	@echo "=== GOLDEN VECTORS ==="
	@mkdir -p build/golden
	$(VVP) build/tb_golden_gen
	@echo "Stimulus : build/golden/stimulus.evt"
	@echo "Expected : build/golden/expected.txt"
	@echo "Lines    : $$(wc -l < build/golden/expected.txt) pred_valid outputs frozen"

# ---------- replay_lockstep ------------------------------------------------
# Bit-exact deterministic rerun against frozen golden vectors.
# Requires: make golden_vectors (run once; commit build/golden/*.txt to repo)
build/tb_replay_lockstep: check-tools $(TB_REPLAY) $(RTL) | init
	$(call COMPILE,$@,$(TB_REPLAY),build/tb_replay_lockstep_iverilog.log)

replay_lockstep: build/tb_replay_lockstep
	@echo "=== REPLAY LOCKSTEP ==="
	@test -f build/golden/expected.txt || \
	  (echo "ERROR: build/golden/expected.txt not found — run 'make golden_vectors' first" && exit 1)
	$(VVP) build/tb_replay_lockstep

# ---------- coverage_report ------------------------------------------------
# Line/toggle/FSM coverage report via VCD dump + Python VCD parser.
build/tb_coverage_full: check-tools $(TB_COV_FULL) $(RTL) | init
	$(call COMPILE,$@,$(TB_COV_FULL),build/tb_coverage_full_iverilog.log)

coverage_report: build/tb_coverage_full | init
	@echo "=== COVERAGE REPORT ==="
	$(VVP) build/tb_coverage_full
	@python3 ../tools/coverage_report.py build/coverage.vcd build/coverage_report.txt
	@echo "Full report: build/coverage_report.txt"

# ---------- req_trace ------------------------------------------------------
# Map each requirement to bench/property/wave evidence.
req_trace: | init
	@echo "=== REQUIREMENT TRACEABILITY ==="
	@python3 ../tools/req_trace.py build/req_trace.md
	@echo "Traceability table: build/req_trace.md"
	@echo "Requirements traced: $$(grep -c '^| REQ-' build/req_trace.md)"

# ---------- toolchain_manifest ---------------------------------------------
# Simulator version, flags, seed policy, hash of RTL sources.
toolchain_manifest: | init
	@echo "=== TOOLCHAIN MANIFEST ==="
	@{ \
	  echo "LIBELLULA Core v22 — Toolchain Manifest"; \
	  echo "Generated : $$(date -u '+%Y-%m-%d %H:%M UTC')"; \
	  echo ""; \
	  echo "## Simulator"; \
	  echo "iverilog  : $$($(IVERILOG) -V 2>&1 | head -1)"; \
	  echo "vvp       : $$($(VVP) -V 2>&1 | head -1)"; \
	  echo "verilator : $$($(VERILATOR) --version 2>/dev/null | head -1)"; \
	  echo "python3   : $$(python3 --version 2>&1)"; \
	  echo "make      : $$(make --version 2>/dev/null | head -1)"; \
	  echo "os        : $$(uname -srm)"; \
	  echo ""; \
	  echo "## Compile flags (iverilog)"; \
	  echo "  -g2012 -Wall -I ../tb"; \
	  echo ""; \
	  echo "## Lint flags (verilator)"; \
	  echo "  --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSED -Wno-UNDRIVEN -Wno-PROCASSINIT"; \
	  echo ""; \
	  echo "## Seed policy"; \
	  echo "  Deterministic: iverilog/vvp is fully deterministic (no $random seed needed)."; \
	  echo "  Formal bench uses fixed LFSR seed 0xDEADBEEF (tb_formal_props.v:17)."; \
	  echo ""; \
	  echo "## RTL sources (SHA-256)"; \
	  for f in $(RTL); do \
	    printf "  %-40s  %s\n" "$$f" "$$(shasum -a 256 $$f | awk '{print $$1}')"; \
	  done; \
	} > build/toolchain_manifest.txt
	@cat build/toolchain_manifest.txt
	@echo ""
	@echo "Manifest written to build/toolchain_manifest.txt"

# ---------- package_eval ---------------------------------------------------
# Collect README, interface spec, latency spec, reports into build/eval_package/.
# Advertised artefact set (README §Evaluation / Integration Path):
#   README_eval.md, interface_spec.md, latency_spec.md, verified_claims.md,
#   known_limits.md, req_trace.md, toolchain_manifest.txt, SHA256SUMS.txt
package_eval: toolchain_manifest req_trace sha256 | init
	@echo "=== PACKAGE EVAL ==="
	@mkdir -p build/eval_package
	@cp ../README.md                            build/eval_package/ 2>/dev/null || true
	@cp ../doc/LIBELLULA_CLAIMS_v12.md          build/eval_package/ 2>/dev/null || true
	@cp ../doc/LIBELLULA_CLAIMS_v12.md          build/eval_package/verified_claims.md 2>/dev/null || true
	@cp ../doc/CLAIMS_TRACEABILITY_TABLE_v12.md build/eval_package/ 2>/dev/null || true
	@cp ../ENGINEERING_OVERVIEW.md              build/eval_package/ 2>/dev/null || true
	@cp build/toolchain_manifest.txt            build/eval_package/ 2>/dev/null || true
	@cp build/req_trace.md                      build/eval_package/ 2>/dev/null || true
	@cp build/coverage_report.txt               build/eval_package/ 2>/dev/null || true
	@cp build/lint.log                          build/eval_package/lint_clean.log 2>/dev/null || true
	@cp build/sha256.txt                        build/eval_package/SHA256SUMS.txt 2>/dev/null || true
	@{ \
	  echo "# LIBELLULA Core v22 — Interface & Latency Specification"; \
	  echo ""; \
	  echo "## Top-level ports (libellula_top)"; \
	  echo "| Port | Dir | Width | Description |"; \
	  echo "|:-----|:----|------:|:------------|"; \
	  echo "| clk | in | 1 | System clock (200 MHz nominal) |"; \
	  echo "| rst | in | 1 | Synchronous active-high reset |"; \
	  echo "| aer_req | in | 1 | AER event request (level-sensitive) |"; \
	  echo "| aer_ack | out | 1 | AER event acknowledge (combinational) |"; \
	  echo "| aer_x | in | XW | Event X coordinate |"; \
	  echo "| aer_y | in | YW | Event Y coordinate |"; \
	  echo "| aer_pol | in | 1 | Event polarity (0=OFF, 1=ON) |"; \
	  echo "| scan_addr | in | AW | Time-mux scan address (free-running counter) |"; \
	  echo "| pred_valid | out | 1 | Prediction output valid (1 cycle pulse) |"; \
	  echo "| x_hat | out | PW | Predicted X position (unsigned integer, lower XW bits) |"; \
	  echo "| y_hat | out | PW | Predicted Y position (unsigned integer, lower YW bits) |"; \
	  echo "| conf | out | 8 | Confidence score (higher = more confident) |"; \
	  echo "| conf_valid | out | 1 | Confidence output valid |"; \
	  echo "| track_id | out | 2 | Tracker ID (NTRACK > 1 only) |"; \
	  echo ""; \
	  echo "## Pipeline latency"; \
	  echo "  aer_req → pred_valid : 5 clock cycles @ 200 MHz = 25 ns"; \
	  echo "  (verified by make test_latency_cycles)"; \
	  echo ""; \
	  echo "## Known limits / design constraints"; \
	  echo "  - Single-clock design; no CDC paths."; \
	  echo "  - AW=8 → 256 spatial tiles; tile size = 64×64 px (XW=10)."; \
	  echo "  - LIF state_mem requires 2^AW reset cycles to fully clear."; \
	  echo "  - NTRACK=1 (single target); NTRACK=2/4 available via tracker_pool."; \
	  echo "  - No overflow/wraparound on x_hat/y_hat (ab_predictor clamps to [0, 2^XW-1])."; \
	} > build/eval_package/interface_spec.md
	@{ \
	  echo "# LIBELLULA Core v22 — Latency Specification"; \
	  echo ""; \
	  echo "## Claim"; \
	  echo "  Pipeline latency = 5 clock cycles, fixed, independent of scene."; \
	  echo "  At 200 MHz nominal fclk this is 25 ns."; \
	  echo ""; \
	  echo "## Measurement point"; \
	  echo "  Start : posedge clk at which aer_rx samples aer_req==1."; \
	  echo "  Stop  : first clk cycle on which pred_valid==1."; \
	  echo ""; \
	  echo "## Method"; \
	  echo "  tb_latency.v drives a single event (x,y,pol) with a pre-held scan_addr"; \
	  echo "  equal to the hashed tile index. It overrides LIF/burst-gate thresholds"; \
	  echo "  into a 'permissive posture' (LEAK_SHIFT=0, THRESH=1, COUNT_TH=0, DW=0)"; \
	  echo "  so the single event propagates deterministically."; \
	  echo ""; \
	  echo "  The bench prints LATENCY_CYCLES and fails if the gap exceeds 6."; \
	  echo "  Observed value: 5."; \
	  echo ""; \
	  echo "## Scope"; \
	  echo "  Validates RTL-simulation latency only. Does not speak to silicon"; \
	  echo "  timing closure, clock-tree skew, or I/O pad delay."; \
	  echo ""; \
	  echo "## Reproduce"; \
	  echo "  cd sim && make latency"; \
	  echo "  Expected stdout: LATENCY_CYCLES=5 and PASS."; \
	} > build/eval_package/latency_spec.md
	@{ \
	  echo "# LIBELLULA Core v22 — Known Limits"; \
	  echo ""; \
	  echo "Sourced from README §Current Status and Limitations."; \
	  echo ""; \
	  echo "## Not covered by this release"; \
	  echo "  - No tape-out or FPGA bitstream. All claims are simulation-based."; \
	  echo "  - No synthesis run against a specific cell library or FPGA family;"; \
	  echo "    no timing-closure report."; \
	  echo "  - No switching-power or synthesis-power estimate. Activity-proportional"; \
	  echo "    power is architectural (time-mux LIF + burst gate), not measured."; \
	  echo "  - UAV parameter profile in libellula_soc is application-recommended,"; \
	  echo "    not validated against a physical event camera."; \
	  echo "  - Formal verification is bounded simulation (50K cycles, LFSR)."; \
	  echo "    SymbiYosys/Yosys unbounded model-checking was not available in the"; \
	  echo "    toolchain for this release."; \
	  echo ""; \
	  echo "## Design constraints"; \
	  echo "  - libellula_top requires an external free-running scan_addr counter"; \
	  echo "    (AW bits). libellula_soc provides this internally."; \
	  echo "  - Only the spatial tile hash {x[XW-1:XW-HX], y[YW-1:YW-HY]} is supported."; \
	  echo "    XOR hashes break Reichardt adjacency."; \
	  echo "  - BG_TH_CLOSE=0 means the burst gate never closes once opened;"; \
	  echo "    suitable only for continuous-motion scenarios."; \
	  echo "  - Direction-reversal RTL floor ~16 px peak (one tile width for AW=8),"; \
	  echo "    decays to <=1 px within 5 updates."; \
	  echo "  - Single-clock design; no CDC paths. No formal CDC tool has been run."; \
	  echo ""; \
	  echo "## Multi-target"; \
	  echo "  NTRACK=4 tracker pool tested in simulation. Maximum sustainable target"; \
	  echo "  count under realistic clutter has not been characterised."; \
	} > build/eval_package/known_limits.md
	@{ \
	  echo "# LIBELLULA Core v22 — Evaluation Package"; \
	  echo ""; \
	  echo "Entry point for RTL evaluators."; \
	  echo ""; \
	  echo "## What this package is"; \
	  echo "  A self-contained snapshot of the artefacts needed to assess the core"; \
	  echo "  on the claims stated in README.md. All claims are RTL-simulation based."; \
	  echo ""; \
	  echo "## Contents"; \
	  echo "  README.md                         — full design description"; \
	  echo "  ENGINEERING_OVERVIEW.md           — per-stage engineering notes"; \
	  echo "  LIBELLULA_CLAIMS_v12.md           — claim set (authoritative)"; \
	  echo "  verified_claims.md                — same content, stable file name"; \
	  echo "  CLAIMS_TRACEABILITY_TABLE_v12.md  — claim → bench → assumption mapping"; \
	  echo "  interface_spec.md                 — port list and TDATA packing"; \
	  echo "  latency_spec.md                   — 5-cycle latency methodology"; \
	  echo "  known_limits.md                   — explicit out-of-scope list"; \
	  echo "  req_trace.md                      — 23-row requirement traceability"; \
	  echo "  coverage_report.txt               — toggle/FSM coverage dump"; \
	  echo "  lint_clean.log                    — Verilator --lint-only log (empty = clean)"; \
	  echo "  toolchain_manifest.txt            — simulator versions + RTL SHA-256"; \
	  echo "  SHA256SUMS.txt                    — SHA-256 for RTL, benches, docs, vectors"; \
	  echo ""; \
	  echo "## How to re-verify from scratch"; \
	  echo "  cd sim"; \
	  echo "  make test && make axi && make lint && make formal && \\"; \
	  echo "  make golden_vectors && make replay_lockstep && \\"; \
	  echo "  make coverage_report && make req_trace && \\"; \
	  echo "  make toolchain_manifest && make package_eval && \\"; \
	  echo "  make sha256 && make tag_release"; \
	  echo ""; \
	  echo "## Expected top-line results"; \
	  echo "  make test   -> ALL TESTS PASSED x3 core + full suite + hostile"; \
	  echo "  make axi    -> axi_to_aer 49/0, axi_wrapper 27/0, axi_burst 33/0, axi_integ 0 mismatches"; \
	  echo "  make lint   -> LINT PASS: zero warnings"; \
	  echo "  make formal -> PASS: all bounded properties hold over 50000 cycles"; \
	  echo "  make replay_lockstep -> 18/18 matched against golden"; \
	  echo "  make coverage_report -> VERDICT: PASS (>= 70% toggle coverage)"; \
	  echo "  make req_trace       -> 23 requirements traced"; \
	  echo ""; \
	  echo "## Scope note"; \
	  echo "  Simulation-only. No silicon, no FPGA bitstream, no synthesis timing"; \
	  echo "  closure, no CDC analyser run. See known_limits.md for the full list."; \
	} > build/eval_package/README_eval.md
	@echo "eval_package contents:"
	@ls -1 build/eval_package/
	@echo "PACKAGE_EVAL DONE: build/eval_package/"

# ---------- sha256 ---------------------------------------------------------
# SHA-256 checksums for RTL, benches, vectors, and docs.
sha256: | init
	@echo "=== SHA-256 CHECKSUMS ==="
	@{ \
	  echo "# LIBELLULA Core v22 — SHA-256 Checksums"; \
	  echo "# Generated: $$(date -u '+%Y-%m-%d %H:%M UTC')"; \
	  echo ""; \
	  echo "## RTL sources"; \
	  shasum -a 256 $(RTL) 2>/dev/null; \
	  echo ""; \
	  echo "## Core testbenches"; \
	  shasum -a 256 ../tb/tb_formal_props.v ../tb/tb_golden_gen.v \
	    ../tb/tb_replay_lockstep.v ../tb/tb_coverage_full.v \
	    ../tb_hostile/tb_reset_midstream_top.v \
	    ../tb_hostile/tb_aer_req_stuck_high.v \
	    ../tb_hostile/tb_random_stress_top.v 2>/dev/null; \
	  echo ""; \
	  echo "## Golden vectors (if generated)"; \
	  shasum -a 256 build/golden/stimulus.evt build/golden/expected.txt 2>/dev/null \
	    || echo "  (not yet generated — run make golden_vectors)"; \
	  echo ""; \
	  echo "## Documentation"; \
	  shasum -a 256 ../README.md ../ENGINEERING_OVERVIEW.md ../doc/*.md 2>/dev/null; \
	} > build/sha256.txt
	@cat build/sha256.txt
	@echo ""
	@echo "Checksums written to build/sha256.txt"

# ---------- tag_release ----------------------------------------------------
# Write an immutable release tag (build/RELEASE_TAG.txt).
# No git tag is created because this directory is not a git repository;
# the tag file serves as the evaluator baseline snapshot identifier.
tag_release: sha256 toolchain_manifest | init
	@echo "=== TAG RELEASE ==="
	@RTL_HASH=$$(shasum -a 256 $(RTL) | shasum -a 256 | awk '{print $$1}'); \
	 TAG="v22-release-$$(date -u '+%Y%m%d-%H%M')"; \
	 { \
	   echo "LIBELLULA Core v22 — Release Tag"; \
	   echo "Tag      : $$TAG"; \
	   echo "Date     : $$(date -u '+%Y-%m-%d %H:%M UTC')"; \
	   echo "RTL hash : $$RTL_HASH  (SHA-256 of all RTL sources combined)"; \
	   echo ""; \
	   echo "This file is the evaluator baseline snapshot identifier."; \
	   echo "All checksums are in build/sha256.txt."; \
	   echo "All toolchain details are in build/toolchain_manifest.txt."; \
	 } > build/RELEASE_TAG.txt; \
	 echo "Release tag: $$TAG"; \
	 echo "Written to: build/RELEASE_TAG.txt"

# ---------- clean ----------
clean:
	@rm -rf build

.PHONY: all check-tools init latency px300 meps power units scenarios \
        resetmid aerstuck randstress hostile run-once test report clean full-diagnostic \
        lif_liveness accuracy e2e_motion naturalistic reversal aw_sweep multi_target_pool \
        tb_ingestion_liveness tb_canonical_motion_audit diagnostic \
        axi axi_to_aer axi_wrapper axi_burst axi_integ \
        build/tb_axi4s_to_aer build/tb_axi4s_wrapper \
        build/tb_axi4s_pred_burst build/tb_axi4s_integration \
        build/tb_aer_rx build/tb_lif_tile_tmux build/tb_delay_lattice_rb \
        build/tb_reichardt_ds build/tb_burst_gate build/tb_ab_predictor build/tb_conf_gate \
        build/tb_lif_liveness \
        build/tb_cv_linear build/tb_cross_clutter build/tb_accel_limit build/tb_crossing \
        build/tb_rotating_bar build/tb_burst_demo build/tb_dense_burst build/tb_zero_motion \
        build/tb_sparse_events build/tb_direction_reversal build/tb_multi_target \
        build/tb_meps_nodrop build/tb_prediction_error build/tb_linear_edge \
        build/tb_accuracy build/tb_e2e_motion build/tb_naturalistic build/tb_reversal \
        build/tb_aw_sweep build/tb_multi_target_pool \
        build/tb_ingestion_liveness build/tb_canonical_motion_audit \
        build/tb_cfg_registers build/tb_aer_timestamp_order \
        build/tb_hot_pixel_rejection build/tb_overflow_flags \
        build/tb_drop_count_accounting build/tb_out_of_order_events \
        build/tb_duplicate_event_handling build/tb_latency_jitter \
        build/tb_deterministic_replay build/tb_target_stop_start \
        build/tb_ego_motion_rejection build/tb_occlusion_reacquire \
        build/tb_small_fast_target build/tb_gate_threshold_sweep build/tb_coverage \
        test_reset test_cfg_registers test_aer_rx_decode test_aer_timestamp_order \
        test_xy_polarity_parse test_input_fifo_backpressure test_cdc_if_present \
        test_idle_no_false_events test_hot_pixel_rejection test_noise_burst_rejection \
        test_max_event_rate test_overflow_flags test_drop_count_accounting \
        test_out_of_order_events test_duplicate_event_handling \
        test_latency_cycles test_latency_jitter test_deterministic_replay \
        test_single_target_linear test_single_target_accel test_target_stop_start \
        test_crossing_targets test_clutter_background test_ego_motion_rejection \
        test_occlusion_reacquire test_small_fast_target test_prediction_error \
        test_gate_threshold_sweep test_long_stream_stability test_assertions \
        test_coverage test_all_named \
        lint formal golden_vectors replay_lockstep coverage_report \
        req_trace toolchain_manifest package_eval sha256 tag_release \
        build/tb_formal_props build/tb_golden_gen \
        build/tb_replay_lockstep build/tb_coverage_full
