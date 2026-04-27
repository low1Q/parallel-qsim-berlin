// language: java
// Datei: src/main/java/org/matsim/routing/router/RouterWithUpdatesServer.java

package org.matsim.routing.router;

import com.google.common.util.concurrent.ThreadFactoryBuilder;
import com.google.inject.Injector;
import io.grpc.Server;
import io.grpc.ServerBuilder;
import io.grpc.protobuf.services.ProtoReflectionService;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.matsim.api.core.v01.Id;
import org.matsim.api.core.v01.Scenario;
import org.matsim.api.core.v01.network.Link;
import org.matsim.api.core.v01.population.Person;
import org.matsim.application.MATSimAppCommand;
import org.matsim.core.config.Config;
import org.matsim.core.config.ConfigUtils;
import org.matsim.core.controler.ControllerUtils;
import org.matsim.core.controler.OutputDirectoryHierarchy;
import org.matsim.core.router.speedy.SpeedyALTFactory;
import org.matsim.core.router.util.TravelDisutility;
import org.matsim.core.scenario.ScenarioUtils;
import org.matsim.routing.updater.UpdatingService;
import org.matsim.vehicles.Vehicle;
import org.matsim.vehicles.VehicleType;
import org.matsim.vehicles.VehicleUtils;
import picocli.CommandLine;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;
import java.util.regex.Pattern;

public class RouterWithUpdatesServer implements MATSimAppCommand {
    private static final int PORT = 50051;
    private static final Logger log = LogManager.getLogger(RouterWithUpdatesServer.class);
    private static final Pattern PATTERN = Pattern.compile("\\d+pct");

    @CommandLine.Option(names = "--sample", description = "Sample options for the server")
    private String sample;

    @CommandLine.Option(names = "--config", description = "Path to config", required = true)
    private String configPath;

    @CommandLine.Option(names = "--localFiles", description = "Use local MATSim files instead of SVN")
    private boolean localFiles = false;

    @CommandLine.Option(names = "--output", description = "Base output directory for the server", required = true)
    private String output;

    @CommandLine.Option(names = "--threads", description = "Number of threads to use for routing")
    private int numRoutingThreads = 1;

    @CommandLine.Option(names = "--binSize", description = "Bin size for the Travel Time Calculator und Travel Time Snapshot")
    private long binSize = 900;

    @CommandLine.Option(names = "--pH", description = "preplanning horizon for filtering the plans file (in seconds, default: 600s = 10min)")
    private int preplanningHorizon = 600;

    @CommandLine.Option(names = "--batchSize", description = "Batch size for Rust")
    private int batchSize = 10000;

    @CommandLine.Option(names = "--partitionCount", description = "Partition count for Rust")
    private int partitionCount = 4;

    @CommandLine.Option(names = "--addString", description = "Additional string to manuell add to the output directory name")
    private String addContextAsString = "";

    static void main(String[] args) throws IOException, InterruptedException {
        new RouterWithUpdatesServer().execute(args);
    }

    private static String sanitizeForFilename(String s) {
        if (s == null || s.isBlank()) {
            return "";
        }
        return s.trim().replaceAll("[^a-zA-Z0-9._-]+", "_");
    }

    @Override
    public Integer call() throws Exception {
        log.info("Starting combined server with sample: {}, config: {}, output: {}, routingThreads: {}", sample, configPath, output, numRoutingThreads);
        Files.createDirectories(Path.of(output));

        Config config = ConfigUtils.loadConfig(this.configPath);
        if (sample != null) {
            config.plans().setInputFile(adjustName(config.plans().getInputFile()));
        }
        config.controller().setOutputDirectory(output);
        config.controller().setOverwriteFileSetting(OutputDirectoryHierarchy.OverwriteFileSetting.overwriteExistingFiles);
        config.global().setNumberOfThreads(1);
        //config.plans().setInputFile("/home/lowiq/MATSimBA/parallel-qsim-berlin/input/Test/min-act-pop-filtered_" + preplanningHorizon + ".xml.gz");
        config.plans().setInputFile("berlin-v6.4-1pct.plans-filtered_" + preplanningHorizon + ".xml.gz");
        config.network().setInputFile("berlin-v6.4-network.xml.gz");
        config.travelTimeCalculator().setTraveltimeBinSize(binSize);
        config.qsim().setEndTime(86400);

        if (localFiles) {
            adaptToLocalFileNames(config);
        }

        // Gemeinsames Scenario und Injector für alle Services und Threads
        Scenario sharedScenario = ScenarioUtils.loadScenario(config);
        Injector sharedAdhocInjector = ControllerUtils.createAdhocInjector(sharedScenario);

        // Gemeinsame TravelTime-Snapshot-Instanz für Routing und Updates
        TravelTimeSnapshot sharedTravelTime = new TravelTimeSnapshot(sharedScenario.getNetwork(), binSize);
        // TravelDisutility, die den Snapshot nutzt
        TravelDisutility sharedDisutility = new TravelDisutility() {
            @Override
            public double getLinkTravelDisutility(Link link, double time, Person person, Vehicle vehicle) {
                // Hier rufen wir direkt den Snapshot auf
                return sharedTravelTime.getLinkTravelTime(link, time, person, vehicle);
            }

            @Override
            public double getLinkMinimumTravelDisutility(Link link) {
                // Wichtig für A*: Die minimal möglichen Kosten (Free-Speed)
                return link.getLength() / link.getFreespeed();
            }
        };

        // Initialisierung des SpeedyALTRouters beim Server-Start
        log.info("Creating sharedSpeedyALTFactory...");
        SpeedyALTFactory sharedSpeedyALTFactory = new SpeedyALTFactory();

        // Fahrzeuge für alle Personen vorbereiten
        prepareVehicles(sharedScenario);

        RejectedExecutionHandler loggingHandler = (runnable, executor) -> {
            log.warn("BACKPRESSURE: Routing-Queue ist voll! Request wird abgewiesen");
            throw new RejectedExecutionException("Routing queue full");
        };

        // Definiere die spezialisierten Worker-Pools
        // Routing-Threads (Lese-Zugriffe)
        int numThreads = (numRoutingThreads > 0) ? numRoutingThreads : Runtime.getRuntime().availableProcessors() - 4;
        ExecutorService routingExecutor = new ThreadPoolExecutor(
                numThreads, numThreads, // Fixe Anzahl Threads passend zur CPU, wenn numRoutingThreads ≤ 0
                0L, TimeUnit.MILLISECONDS,
                new ArrayBlockingQueue<>(500), // Begrenzte Queue gegen Memory-Overflow
                new ThreadFactoryBuilder().setNameFormat("router-thread-%d").build(),
                loggingHandler // Backpressure-Mechanismus
        );

        // Update-Thread (Schreib-Zugriffe: IMMER Single-Threaded!)
        ExecutorService updaterExecutor = new ThreadPoolExecutor(
                1, 1, 0L, TimeUnit.MILLISECONDS,
                new ArrayBlockingQueue<>(500),
                new ThreadFactoryBuilder().setNameFormat("updater-%d").setDaemon(true).build(),
                new ThreadPoolExecutor.AbortPolicy() // Wirft eine Exception bei Überlastung
        );

        AtomicReference<Server> serverRef = new AtomicReference<>();
        AtomicBoolean shutdownStarted = new AtomicBoolean(false);
        // Definiere die Logik für das saubere Aufräumen
        Runnable serverShutdown = () -> {
            if (!shutdownStarted.compareAndSet(false, true)) {
                log.info("Cleanup: shutdown already in motion, skipping duplicate call.");
                return;
            }
            log.info("Cleanup: Shutting down server...");
            // Server stoppen
            Server s = serverRef.get();
            if (s != null) {
                s.shutdown();
                try {
                    if (!s.awaitTermination(5, TimeUnit.SECONDS)) {
                        s.shutdownNow();
                    }
                } catch (InterruptedException e) {
                    s.shutdownNow();
                    Thread.currentThread().interrupt();
                }
            }
            if (sharedTravelTime.getWaitingSnapshotFailedCount() > 0) {
                log.warn("Deterministic run compromised! Had to fall back on earlier Snapshot caused by deadlock for {} times.", sharedTravelTime.getWaitingSnapshotFailedCount());
            }
            log.info("Cleanup: Shutting down pools...");

            // Pools stoppen (Graceful Shutdown)
            updaterExecutor.shutdownNow();
            routingExecutor.shutdownNow();

            log.info("Cleanup: All resources released.");
        };

        String runContext = buildRunContextString();
        log.info("Java profiling run context: {}", runContext);
        // setze reale shutdown hooks in Services (optional)
        UpdatingService updatingService = new UpdatingService(sharedScenario, sharedAdhocInjector,
                serverShutdown, updaterExecutor, sharedTravelTime, runContext);
        RoutingService routingService = new RoutingService(sharedScenario, sharedAdhocInjector,
                serverShutdown, config, sharedTravelTime, sharedSpeedyALTFactory, sharedDisutility, routingExecutor, runContext, preplanningHorizon);

        // Eager Warmup (Direkt auf dem rpcExecutor)
        log.info("Starting Eager Warmup on {} threads...", numThreads);
        CountDownLatch warmUpLatch = new CountDownLatch(numThreads);

        for (int i = 0; i < numThreads; i++) {
            routingExecutor.submit(() -> {
                try {
                    routingService.warmUp();
                    log.info("Worker thread {} is now ready.", Thread.currentThread().getName());
                } finally {
                    warmUpLatch.countDown();
                }
            });
        }

        if (!warmUpLatch.await(60, TimeUnit.SECONDS)) {
            log.error("Warmup timed out! Some threads might not be ready.");
        }

        log.info("Warmup complete. Starting gRPC Server.");

        log.info("Preprocessing finished. Starting gRPC server...");
        // Start server mit beiden Services und Reflection
        Server server = ServerBuilder.forPort(PORT)
                .addService(routingService)
                //.addService(updatingService)
                .addService(ProtoReflectionService.newInstance())
                .build()
                .start();

        serverRef.set(server);

        log.info("Combined server started on port {}", PORT);

        server.awaitTermination();

        log.info("Server stopped");
        return 0;
    }

    private String adjustName(String name) {
        String postfix = this.sample + "pct";
        String adjusted = PATTERN.matcher(name).replaceAll(postfix);
        log.info("Adjusting name from {} to {}", name, adjusted);
        return adjusted;
    }

    private void adaptToLocalFileNames(Config config) {
        config.network().setInputFile(fileNameFromUrl(config.network().getInputFile()));
        config.vehicles().setVehiclesFile(fileNameFromUrl(config.vehicles().getVehiclesFile()));
        config.facilities().setInputFile(fileNameFromUrl(config.facilities().getInputFile()));
    }

    private String fileNameFromUrl(String url) {
        return url.substring(url.lastIndexOf('/') + 1);
    }

    private void prepareVehicles(Scenario scenario) {
        for (Person person : scenario.getPopulation().getPersons().values()) {
            Id<Vehicle> vehicleId = VehicleUtils.getVehicleId(person, "car");
            createAndAddVehicleForModeCar(scenario, vehicleId, person);
        }
    }

    private void createAndAddVehicleForModeCar(Scenario scenario, Id<Vehicle> vehicleId, Person person) {
        if (!scenario.getVehicles().getVehicles().containsKey(vehicleId)) {
            Id<VehicleType> carTypeId = Id.create("car", VehicleType.class);
            VehicleType carType = scenario.getVehicles().getVehicleTypes().get(carTypeId);
            Vehicle vehicle = VehicleUtils.getFactory().createVehicle(VehicleUtils.getVehicleId(person, "car"), carType);
            scenario.getVehicles().addVehicle(vehicle);
        }
    }

    private String buildRunContextString() {
        String custom = sanitizeForFilename(addContextAsString);

        String base = String.format(
                "bin%d-threads%d-PH%d-batch%d-parts%d",
                binSize,
                numRoutingThreads,
                preplanningHorizon,
                batchSize,
                partitionCount
        );

        return custom.isEmpty() ? base : base + "-" + custom;
    }

}
