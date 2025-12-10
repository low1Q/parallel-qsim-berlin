JAR := parallel-qsim-berlin-*.jar
BV := v6.4

RUST_BASE := ~/MATSimBA/parallel_qsim_rust
RUST_BIN := local_qsim

MEMORY ?= 20G
PCT := 1

MODE ?= cargo

HORIZON := 600

java_prepare := java -Xmx$(MEMORY) -XX:+UseParallelGC -cp $(JAR) org.matsim.prepare.RunParallelQSimBerlinPreparation
# prefer local DTDs to avoid network access (i.e. on hpc clusters)
java_router := java -Xmx$(MEMORY) -XX:+UseParallelGC -Dmatsim.preferLocalDtds=true -cp $(JAR) org.matsim.routing.RoutingServer

p := ./input/$(BV)
op := ./output/$(BV)/$(PCT)pct

.PHONY: prepare

# ===== JAVA =====
$(JAR):
	./mvnw clean package -DskipTests

rebuild-jar:
	find . -name $(JAR) -type f -delete
	./mvnw clean package -DskipTests

# ===== MISC =====

mk-output-folders:
	mkdir -p $(op)/binpb

clean:
	rm -rf $(op)

# ===== ORIGINAL INPUT_FILES =====

$(op)/berlin-$(BV)-$(PCT)pct.plans-filtered_$(HORIZON).xml.gz: $(op)/berlin-$(BV)-$(PCT)pct.plans.xml.gz $(JAR)
	$(java_prepare) prepare prepare-population\
		--input $<\
		--modes car,walk,ride,bike,freight,truck\
		--horizon $(HORIZON)
#,pt

$(op)/berlin-$(BV)-$(PCT)pct.plans.xml.gz:
	curl https://svn.vsp.tu-berlin.de/repos/public-svn/matsim/scenarios/countries/de/berlin/berlin-$(BV)/input/$(notdir $@) -o $@

$(op)/berlin-$(BV)-vehicleTypes.xml:
	curl https://raw.githubusercontent.com/matsim-scenarios/matsim-berlin/refs/heads/main/input/$(BV)/$(notdir $@) -o $@

$(op)/berlin-$(BV)-vehicleTypes-including-walk-pt.xml: $(op)/berlin-$(BV)-vehicleTypes.xml $(JAR)
	$(java_prepare) prepare adapt-vehicle-types\
		--input $<

$(op)/berlin-$(BV)-network.xml.gz:
	curl https://svn.vsp.tu-berlin.de/repos/public-svn/matsim/scenarios/countries/de/berlin/berlin-$(BV)/input/berlin-$(BV)-network.xml.gz -o $@

#$(op)/berlin-$(BV)-network.xml.gz: $(op)/berlin-$(BV)-network.xml.gz
#	$(java_prepare) prepare prepare-network\
#		--input $<

$(op)/berlin-$(BV).config.xml:
	curl https://raw.githubusercontent.com/matsim-scenarios/matsim-berlin/refs/heads/main/input/$(BV)/berlin-$(BV).config.xml -o $@

$(op)/berlin-$(BV)-facilities.xml.gz:
	curl https://svn.vsp.tu-berlin.de/repos/public-svn/matsim/scenarios/countries/de/berlin/berlin-$(BV)/input/berlin-$(BV)-facilities.xml.gz -o $@

$(op)/berlin-$(BV).counts-vmz.xml.gz:
	curl https://svn.vsp.tu-berlin.de/repos/public-svn/matsim/scenarios/countries/de/berlin/berlin-$(BV)/input/berlin-$(BV).counts-vmz.xml.gz -o $@

# ===== CONVERT TO BINARY PROTOBUF =====

$(op)/binpb/berlin-$(BV)-$(PCT)pct.ids.binpb: $(op)/berlin-$(BV)-$(PCT)pct.plans-filtered_$(HORIZON).xml.gz $(op)/berlin-$(BV)-vehicleTypes-including-walk-pt.xml $(op)/berlin-$(BV)-network.xml.gz
	if [ "$(MODE)" = "bin" ]; then \
		RUNNER="$(RUST_BASE)/target/release/convert_to_binary"; \
	else \
		RUNNER="cargo run --release --bin convert_to_binary --manifest-path $(RUST_BASE)/Cargo.toml --"; \
	fi; \
	eval "$$RUNNER \
		--network $(op)/berlin-$(BV)-network.xml.gz\
		--population $(op)/berlin-$(BV)-$(PCT)pct.plans-filtered_$(HORIZON).xml.gz\
		--vehicles $(op)/berlin-$(BV)-vehicleTypes-including-walk-pt.xml\
		--output-dir $(op)\
		--run-id binpb/berlin-$(BV)-$(PCT)pct"

prepare: mk-output-folders $(op)/binpb/berlin-$(BV)-$(PCT)pct.ids.binpb

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
		RUNNER="cargo run --release --bin $(RUST_BIN) --manifest-path $(RUST_BASE)/Cargo.toml --"; \
	fi; \
	CMD="$$RUNNER --config-path $p/berlin-v6.4.$(PCT)pct.config.yml $$EXTRA $(ARGS)"; \
	echo "$$CMD"; \
	eval "$$CMD"

run-routing: prepare
	@if [ -n "$(URL)" ]; then \
		ROUTER_URL="$(URL)"; \
	else \
		ROUTER_URL="http://localhost:50051"; \
	fi; \
	$(MAKE) run RUST_BIN=local_qsim_routing ARGS="$(ARGS) --set routing.mode=ad-hoc --router-ip $$ROUTER_URL"

# ===== POST_PROCESSING =====

convert-events:
	if [ "$(MODE)" = "bin" ]; then \
  	    RUNNER="$(RUST_BASE)/target/release/proto2xml"; \
  	else \
  		RUNNER="cargo run --release --bin proto2xml --manifest-path $(RUST_BASE)/Cargo.toml --"; \
  	fi; \
	eval "$$RUNNER \
		--path $(op)/ \
		--id-store $(op)/binpb/berlin-$(BV)-$(PCT)pct.ids.binpb \
		--num-parts $(N)"

#convert-network:
#	if [ "$(MODE)" = "bin" ]; then \
#		RUNNER="$(RUST_BASE)/target/release/convert_to_xml"; \
#	else \
#		RUNNER="cargo run --release --bin convert_to_xml --manifest-path $(RUST_BASE)/Cargo.toml --"; \
#	fi; \
#	eval "$$RUNNER \
#		--ids $(op)/binpb/berlin-$(BV)-$(PCT)pct.ids.binpb\
#		--network $(op)/berlin-$(BV)-$(PCT)pct.network.$(N).binpb\
#		--vehicles $(op)/binpb/berlin-$(BV)-$(PCT)pct.vehicles.binpb"

# ===== ROUTER =====

router-deps: $(JAR) \
             $(op)/berlin-$(BV).config.xml \
             $(op)/berlin-$(BV)-facilities.xml.gz \
             $(op)/berlin-$(BV)-network.xml.gz \
             $(op)/berlin-$(BV)-vehicleTypes.xml \
             $(op)/berlin-$(BV)-$(PCT)pct.plans.xml.gz
	@echo "Dependencies for router are up to date."

router: router-deps
	@if [ -n "$(THREADS)" ]; then \
		EXTRA="--threads $(THREADS)"; \
	else \
		EXTRA=""; \
	fi; \
	CMD="$(java_router) --config $(op)/berlin-$(BV).config.xml --sample $(PCT) --output $(op)/routing-$(RUN_ID) $$EXTRA --localFiles"; \
	echo "$$CMD"; \
	eval "$$CMD"