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
import org.matsim.api.core.v01.network.Link;
import org.matsim.api.core.v01.population.Person;
import org.matsim.application.MATSimAppCommand;
import org.matsim.core.config.Config;
import org.matsim.core.config.ConfigUtils;
import org.matsim.core.config.groups.RoutingConfigGroup;
import org.matsim.core.controler.*;
import org.matsim.core.router.costcalculators.OnlyTimeDependentTravelDisutilityFactory;
import org.matsim.core.router.speedy.SpeedyALTDataBridge;
import org.matsim.core.router.speedy.SpeedyGraph;
import org.matsim.core.router.speedy.SpeedyGraphBuilder;
import org.matsim.core.router.util.TravelDisutility;
import org.matsim.core.router.util.TravelTime;
import org.matsim.core.scenario.ScenarioUtils;
import org.matsim.api.core.v01.Scenario;

import org.matsim.routing.updater.UpdatingService;
import org.matsim.vehicles.Vehicle;
import org.matsim.vehicles.VehicleType;
import org.matsim.vehicles.VehicleUtils;
import picocli.CommandLine;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicReference;
import java.util.regex.Pattern;

//945€
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

    public static void main(String[] args) throws IOException, InterruptedException {
        new RouterWithUpdatesServer().execute(args);
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
        config.controller().setLastIteration(0);
        config.plans().setInputFile("berlin-v6.4-1pct.plans-filtered_600.xml.gz");
        config.network().setInputFile("berlin-v6.4-network.xml.gz");
        config.counts().setInputFile(null);
        config.qsim().setUsePersonIdForMissingVehicleId(true);
        config.qsim().setEndTime(86400);
        config.routing().setNetworkRouteConsistencyCheck(RoutingConfigGroup.NetworkRouteConsistencyCheck.disable);
        config.travelTimeCalculator().setTraveltimeBinSize(900);

        config.global().setInsistingOnDeprecatedConfigVersion(false);
        System.setProperty("matsim.preferLocalDtds", "true");

        if (localFiles) {
            adaptToLocalFileNames(config);
        }

        // Lade ein einzelnes Scenario, EventsManager und TravelTimeCalculator und teile sie
        Scenario sharedScenario = ScenarioUtils.loadScenario(config);
        Injector adhocInjector = ControllerUtils.createAdhocInjector(sharedScenario);

        // 2. Deine High-Performance TravelTime
        TravelTimeSnapshot sharedTravelTime = new TravelTimeSnapshot(sharedScenario.getNetwork());
        TravelDisutility dynamicDisutility = new org.matsim.core.router.util.TravelDisutility() {
            @Override
            public double getLinkTravelDisutility(Link link, double time, Person person, Vehicle vehicle) {
                // Hier rufen wir direkt deinen Snapshot auf!
                return sharedTravelTime.getLinkTravelTime(link, time, person, vehicle);
            }

            @Override
            public double getLinkMinimumTravelDisutility(Link link) {
                // Wichtig für A*: Die minimal möglichen Kosten (Free-Speed)
                return link.getLength() / link.getFreespeed();
            }
        };

        // 1. Initialisierung beim Server-Start
        log.info("Pre-calculating SpeedyALT landmarks...");
        SpeedyGraph graph = SpeedyGraphBuilder.build(sharedScenario.getNetwork(), null);
        TravelTime staticFreeSpeed = sharedTravelTime.getStaticFreeSpeedView();
        TravelDisutility staticDisutility = new OnlyTimeDependentTravelDisutilityFactory()
                .createTravelDisutility(staticFreeSpeed);
//        // Wir speichern es als Object, da wir den Typ SpeedyALTData hier nicht schreiben dürfen
        Object sharedLandmarks = SpeedyALTDataBridge.createSharedData(graph, 16, staticDisutility);
        log.info("Preprocessing finished. Starting gRPC server...");

        prepareVehicles(sharedScenario);

// Store the actual Link objects.
// This is faster because Network.getLinks().get() requires an Id object,
// but this map allows you to use the raw String from your gRPC request.
        log.info("Creating fast lookup maps...");
        Map<String, Id<Link>> linkIdCache = new HashMap<>();

        for (Id<Link> id : sharedScenario.getNetwork().getLinks().keySet()) {
            linkIdCache.put(id.toString(), id);
        }
        Map<String, Person> personCache = new HashMap<>();
        for (Person p : sharedScenario.getPopulation().getPersons().values()) {
            personCache.put(p.getId().toString(), p);
        }
        Map<String, Id<Vehicle>> vehicleIdCache = new HashMap<>();

        // Cache all Vehicle IDs if you have a fixed fleet
        for (Id<Vehicle> id : sharedScenario.getVehicles().getVehicles().keySet()) {
            vehicleIdCache.put(id.toString(), id);
        }

        RejectedExecutionHandler loggingHandler = (runnable, executor) -> {
            log.warn("BACKPRESSURE: Routing-Queue ist voll! Request wird im gRPC-Netzwerk-Thread ausgeführt. Performance sinkt!");
            new ThreadPoolExecutor.CallerRunsPolicy().rejectedExecution(runnable, executor);
        };

        // 1. Definiere die spezialisierten Worker-Pools
        // Routing-Threads (Lese-Zugriffe)
        int numThreads = (numRoutingThreads > 0) ? numRoutingThreads : Runtime.getRuntime().availableProcessors();
        ExecutorService rpcExecutor = new ThreadPoolExecutor(
                numThreads, numThreads, // Fixe Anzahl Threads passend zur CPU
                0L, TimeUnit.MILLISECONDS,
                new LinkedBlockingQueue<>(1000), // Begrenzte Queue gegen Memory-Overflow
                new ThreadFactoryBuilder().setNameFormat("router-thread-%d").build(),
                loggingHandler // Backpressure-Mechanismus
        );

        // Update-Thread (Schreib-Zugriffe: IMMER Single-Threaded!)
        ExecutorService updaterExecutor = Executors.newSingleThreadExecutor(
                new ThreadFactoryBuilder().setNameFormat("updater-%d").setDaemon(true).build()
        );

        // Erzeuge Services mit den neuen public-Konstruktoren
        Runnable shutdown = () -> {
            log.info("Running shutdown hook");
            // nothing here; actual Server shutdown handled below
        };

        AtomicReference<Server> serverRef = new AtomicReference<>();

        // 1. Definiere die Logik für das saubere Aufräumen
        Runnable serverShutdown = () -> {
            log.info("HPC Cleanup: Shutting down server and pools...");

            // Server stoppen
            Server s = serverRef.get();
            if (s != null) {
                s.shutdown();
                try {
                    if (!s.awaitTermination(5, TimeUnit.SECONDS)) s.shutdownNow();
                } catch (InterruptedException e) {
                    s.shutdownNow();
                }
            }

            // Pools stoppen (Wichtig für HPC!)
            updaterExecutor.shutdownNow();
            rpcExecutor.shutdownNow();

            log.info("HPC Cleanup: All resources released.");
        };

// 2. Registriere es beim Betriebssystem
        Runtime.getRuntime().addShutdownHook(new Thread(serverShutdown));

// 3. Optional: Falls du einen gRPC-Befehl zum Beenden hast,
// kann dieser einfach cleanup.run() aufrufen.

        // setze reale shutdown hooks in Services (optional)
        // (Hier einfache Zuordnung)
        //noinspection LawOfDemeter
        UpdatingService updatingService = new UpdatingService(sharedScenario, adhocInjector,
                serverShutdown, config, updaterExecutor, sharedTravelTime, linkIdCache, vehicleIdCache);
        //noinspection LawOfDemeter
        RoutingService routingService = new RoutingService(sharedScenario, adhocInjector,
                serverShutdown, config, sharedTravelTime, sharedLandmarks, dynamicDisutility, linkIdCache, personCache);

// HPC Eager Warmup (Direkt auf dem rpcExecutor)
        log.info("Starting High-Performance Eager Warmup on {} threads...", numThreads);
        CountDownLatch warmUpLatch = new CountDownLatch(numThreads);

        for (int i = 0; i < numThreads; i++) {
            rpcExecutor.submit(() -> {
                try {
                    routingService.warmUp();
                    log.info("Worker thread {} is now JIT-optimized and ready.", Thread.currentThread().getName());
                } finally {
                    warmUpLatch.countDown();
                }
            });
        }

        if (!warmUpLatch.await(60, TimeUnit.SECONDS)) {
            log.error("Warmup timed out! Some threads might not be ready.");
        }
        log.info("Warmup complete. Starting gRPC Server.");

        // Start server mit rpcExecutor
        Server server = ServerBuilder.forPort(PORT)
                .addService(routingService)
                .addService(updatingService)
                .addService(ProtoReflectionService.newInstance())
                .executor(rpcExecutor)
                .build()
                .start();

        serverRef.set(server);

        log.info("Combined server started on port {}", PORT);

        server.awaitTermination();

        log.info("Server stopped");
        System.exit(0);
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
}
