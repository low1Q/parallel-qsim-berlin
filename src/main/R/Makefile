JAR := target/parallel-qsim-berlin-1.0-executable.jar
BV := v6.4
PCT ?= 1
HORIZON ?= 600

# Shared input data downloaded once and reused across runs/nodes
SHARED_DATA_BASE ?= /scratch/usr/$(USER)/MATSimBA/shared-data
BERLIN_SHARED_BASE := $(SHARED_DATA_BASE)/berlin-$(BV)/input

RUST_BASE := /scratch/usr/$(USER)/MATSimBA/parallel_qsim_rust
RUST_BIN := local_qsim

MEMORY ?= 20G
MODE ?= bin

java_prepare := java -Xmx$(MEMORY) \
    --add-opens java.base/java.lang=ALL-UNNAMED \
    --add-opens java.base/java.util=ALL-UNNAMED \
    -Dmatsim.preferLocalDtds=true \
    -Dguice.disable.misplaced.annotation.check=true \
    -XX:+UseG1GC -cp $(JAR) org.matsim.prepare.RunParallelQSimBerlinPreparation

# prefer local DTDs to avoid network access (i.e. on hpc clusters)
java_router := java -Xmx$(MEMORY) -XX:+UseG1GC -Dmatsim.preferLocalDtds=true -cp $(JAR) org.matsim.routing.router.RouterWithUpdatesServer

p := ./input/$(BV)
op := ./output/$(BV)/$(PCT)pct
binpb_prefix := $(op)/binpb-hor$(HORIZON)/berlin-$(BV)-$(PCT)pct

# Shared original inputs
shared_plans := $(BERLIN_SHARED_BASE)/berlin-$(BV)-$(PCT)pct.plans.xml.gz
shared_vehicletypes := $(BERLIN_SHARED_BASE)/berlin-$(BV)-vehicleTypes.xml
shared_network := $(BERLIN_SHARED_BASE)/berlin-$(BV)-network.xml.gz
shared_config := $(BERLIN_SHARED_BASE)/berlin-$(BV)-$(PCT)pct.config.xml
shared_facilities := $(BERLIN_SHARED_BASE)/berlin-$(BV)-facilities.xml.gz
shared_counts := $(BERLIN_SHARED_BASE)/berlin-$(BV).counts-vmz.xml.gz

.PHONY: prepare rebuild-jar mk-output-folders clean router-deps router download-shared-data print-shared-paths

# ===== JAVA =====
$(JAR):
	./mvnw clean package -DskipTests

rebuild-jar:
	rm -f $(JAR)
	./mvnw clean package -DskipTests

# ===== MISC =====

mk-output-folders:
	mkdir -p $(op)/binpb

clean:
	rm -rf $(op)

print-shared-paths:
	@echo "SHARED_DATA_BASE=$(SHARED_DATA_BASE)"
	@echo "BERLIN_SHARED_BASE=$(BERLIN_SHARED_BASE)"

# ===== DOWNLOAD SHARED INPUT FILES =====

$(BERLIN_SHARED_BASE):
	mkdir -p $@

$(shared_plans): | $(BERLIN_SHARED_BASE)
	curl -L https://svn.vsp.tu-berlin.de/repos/public-svn/matsim/scenarios/countries/de/berlin/berlin-$(BV)/input/$(notdir $@) -o $@

$(shared_vehicletypes): | $(BERLIN_SHARED_BASE)
	curl -L https://raw.githubusercontent.com/matsim-scenarios/matsim-berlin/refs/heads/main/input/$(BV)/$(notdir $@) -o $@

$(shared_network): | $(BERLIN_SHARED_BASE)
	curl -L https://svn.vsp.tu-berlin.de/repos/public-svn/matsim/scenarios/countries/de/berlin/berlin-$(BV)/input/berlin-$(BV)-network.xml.gz -o $@

$(shared_config): | $(BERLIN_SHARED_BASE)
	curl -L https://raw.githubusercontent.com/matsim-scenarios/matsim-berlin/refs/heads/main/input/$(BV)/berlin-$(BV)-$(PCT)pct.config.xml -o $@

$(shared_facilities): | $(BERLIN_SHARED_BASE)
	curl -L https://svn.vsp.tu-berlin.de/repos/public-svn/matsim/scenarios/countries/de/berlin/berlin-$(BV)/input/berlin-$(BV)-facilities.xml.gz -o $@

$(shared_counts): | $(BERLIN_SHARED_BASE)
	curl -L https://svn.vsp.tu-berlin.de/repos/public-svn/matsim/scenarios/countries/de/berlin/berlin-$(BV)/input/berlin-$(BV).counts-vmz.xml.gz -o $@

# New target: only download shared inputs, no processing
download-shared-data: \
	$(shared_plans) \
	$(shared_vehicletypes) \
	$(shared_network) \
	$(shared_config) \
	$(shared_facilities) \
	$(shared_counts)
	@echo "Shared input data downloaded to $(BERLIN_SHARED_BASE)"

# Backward-compatible name for router input downloads (+ JAR)
router-deps: $(JAR) download-shared-data
	@echo "Dependencies for router are up to date."

# ===== GENERATED LOCAL FILES FROM SHARED INPUTS =====

$(op)/berlin-$(BV)-$(PCT)pct.plans-filtered_$(HORIZON).xml.gz: $(shared_plans) $(JAR)
	mkdir -p $(dir $@)
	$(java_prepare) prepare prepare-population \
		--input $< \
		--modes car,walk \
		--horizon $(HORIZON)
	cp $(dir $<)berlin-$(BV)-$(PCT)pct.plans-filtered_$(HORIZON).xml.gz $@

$(op)/berlin-$(BV)-vehicleTypes-including-walk-pt.xml: $(shared_vehicletypes) $(JAR)
	mkdir -p $(dir $@)
	$(java_prepare) prepare adapt-vehicle-types \
		--input $<

# Optional local copies/symlinks if other tools expect them in output/
$(op)/berlin-$(BV)-$(PCT)pct.config.xml: $(shared_config)
	mkdir -p $(dir $@)
	ln -sf $(abspath $<) $@

$(op)/berlin-$(BV)-facilities.xml.gz: $(shared_facilities)
	mkdir -p $(dir $@)
	ln -sf $(abspath $<) $@

$(op)/berlin-$(BV)-network.xml.gz: $(shared_network)
	mkdir -p $(dir $@)
	ln -sf $(abspath $<) $@

$(op)/berlin-$(BV)-vehicleTypes.xml: $(shared_vehicletypes)
	mkdir -p $(dir $@)
	ln -sf $(abspath $<) $@

$(op)/berlin-$(BV).counts-vmz.xml.gz: $(shared_counts)
	mkdir -p $(dir $@)
	ln -sf $(abspath $<) $@

# ===== CONVERT TO BINARY PROTOBUF =====

$(binpb_prefix).ids.binpb \
$(binpb_prefix).network.binpb \
$(binpb_prefix).vehicles.binpb \
$(binpb_prefix).plans.binpb: \
	$(op)/berlin-$(BV)-$(PCT)pct.plans-filtered_$(HORIZON).xml.gz \
	$(op)/berlin-$(BV)-vehicleTypes-including-walk-pt.xml \
	$(op)/berlin-$(BV)-network.xml.gz
	mkdir -p $(dir $@)
	if [ "$(MODE)" = "bin" ]; then \
		RUNNER="$(RUST_BASE)/target/release/convert_to_binary"; \
	else \
		RUNNER="cargo run --release --bin convert_to_binary -q --manifest-path $(RUST_BASE)/Cargo.toml --"; \
	fi; \
	eval "$$RUNNER \
		--network $(op)/berlin-$(BV)-network.xml.gz \
		--population $(op)/berlin-$(BV)-$(PCT)pct.plans-filtered_$(HORIZON).xml.gz \
		--vehicles $(op)/berlin-$(BV)-vehicleTypes-including-walk-pt.xml \
		--output-dir $(op) \
		--run-id binpb-hor$(HORIZON)/berlin-$(BV)-$(PCT)pct"

prepare: mk-output-folders
	flock $(op)/binpb-hor$(HORIZON).lock $(MAKE) prepare-binpb HORIZON=$(HORIZON) PCT=$(PCT) MODE=$(MODE)

prepare-binpb: $(binpb_prefix).ids.binpb $(binpb_prefix).network.binpb $(binpb_prefix).vehicles.binpb $(binpb_prefix).plans.binpb

# ===== RUN SIMULATION =====
# Used variables:
#   N         Number of partitions
#   MODE      "bin" to use compiled binary, "cargo" to use cargo run
#   RUST_BIN  Name of the rust binary to run (default: local_qsim)
#   ARGS      Additional arguments to pass to the simulation

run: prepare
	@if [ -n "$(N)" ]; then \
		EXTRA="--set partitioning.num_parts=$(N)"; \
	else \
		EXTRA=""; \
	fi; \
	if [ "$(MODE)" = "bin" ]; then \
		RUNNER="$(RUST_BASE)/target/release/$(RUST_BIN)"; \
	else \
		RUNNER="cargo run --release --bin $(RUST_BIN) -q --manifest-path $(RUST_BASE)/Cargo.toml --"; \
	fi; \
	CMD="$$RUNNER --config-path $p/berlin-v6.4.$(PCT)pct.config.yml $$EXTRA $(ARGS)"; \
	echo "$$CMD"; \
	eval "$$CMD"

# Setting the input files manually in order to reflect the horizon properly
run-routing: prepare
	@if [ -n "$(URL)" ]; then \
		ROUTER_URL="$(URL)"; \
	else \
		ROUTER_URL="http://localhost:50051"; \
	fi; \
	$(MAKE) run \
		RUST_BIN=local_qsim_routing \
		ARGS="$(ARGS) \
		--set routing.mode=ad-hoc \
		--router-ip $$ROUTER_URL \
		--enable-performance-logging \
		--set protofiles.network=../../output/v6.4/$(PCT)pct/binpb-hor$(HORIZON)/berlin-v6.4-$(PCT)pct.network.binpb \
		--set protofiles.ids=../../output/v6.4/$(PCT)pct/binpb-hor$(HORIZON)/berlin-v6.4-$(PCT)pct.ids.binpb \
		--set protofiles.vehicles=../../output/v6.4/$(PCT)pct/binpb-hor$(HORIZON)/berlin-v6.4-$(PCT)pct.vehicles.binpb \
		--set protofiles.population=../../output/v6.4/$(PCT)pct/binpb-hor$(HORIZON)/berlin-v6.4-$(PCT)pct.plans.binpb"

# ===== POST_PROCESSING =====

convert-events:
	if [ "$(MODE)" = "bin" ]; then \
		RUNNER="$(RUST_BASE)/target/release/proto2xml"; \
	else \
		RUNNER="cargo run --release --bin proto2xml --q --manifest-path $(RUST_BASE)/Cargo.toml --"; \
	fi; \
	eval "$$RUNNER \
		--path $(op)/ \
		--id-store $(op)/binpb/berlin-$(BV)-$(PCT)pct.ids.binpb \
		--num-parts $(N)"

# ===== ROUTER =====

router: router-deps \
        $(op)/berlin-$(BV)-$(PCT)pct.config.xml \
        $(op)/berlin-$(BV)-facilities.xml.gz \
        $(op)/berlin-$(BV)-network.xml.gz \
        $(op)/berlin-$(BV)-vehicleTypes.xml
	@if [ -n "$(THREADS)" ]; then \
		EXTRA="--threads $(THREADS) $(ARGS)"; \
	else \
		EXTRA="$(ARGS)"; \
	fi; \
	CMD="$(java_router) --config $(op)/berlin-$(BV)-$(PCT)pct.config.xml --sample $(PCT) --output $(op)/routing-$(RUN_ID) $$EXTRA --localFiles"; \
	echo "$$CMD"; \
	eval "$$CMD"