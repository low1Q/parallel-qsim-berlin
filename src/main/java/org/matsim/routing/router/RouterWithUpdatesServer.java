// language: java
// Datei: src/main/java/org/matsim/routing/router/RouterWithUpdatesServer.java

package org.matsim.routing.router;

import com.google.common.util.concurrent.ThreadFactoryBuilder;
import com.google.inject.Injector;
import io.grpc.Server;
import io.grpc.ServerBuilder;
import io.grpc.protobuf.services.ProtoReflectionService;
import org.apache.logging.log4j.Level;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.matsim.api.core.v01.Id;
import org.matsim.api.core.v01.network.Link;
import org.matsim.api.core.v01.network.Network;
import org.matsim.api.core.v01.network.Node;
import org.matsim.api.core.v01.population.Person;
import org.matsim.application.MATSimAppCommand;
import org.matsim.core.config.Config;
import org.matsim.core.config.ConfigUtils;
import org.matsim.core.config.groups.QSimConfigGroup;
import org.matsim.core.config.groups.RoutingConfigGroup;
import org.matsim.core.controler.*;
import org.matsim.core.controler.corelisteners.ControlerDefaultCoreListenersModule;
import org.matsim.core.router.RoutingModule;
import org.matsim.core.router.costcalculators.OnlyTimeDependentTravelDisutilityFactory;
import org.matsim.core.router.speedy.SpeedyALTFactory;
import org.matsim.core.router.speedy.SpeedyGraph;
import org.matsim.core.router.speedy.SpeedyGraphBuilder;
import org.matsim.core.router.speedy.SpeedyHPCBridge;
import org.matsim.core.router.util.LeastCostPathCalculatorFactory;
import org.matsim.core.router.util.TravelDisutility;
import org.matsim.core.router.util.TravelTime;
import org.matsim.core.scenario.ScenarioByInstanceModule;
import org.matsim.core.scenario.ScenarioUtils;
import org.matsim.core.trafficmonitoring.TravelTimeCalculator;
import org.matsim.core.events.EventsUtils;
import org.matsim.core.api.experimental.events.EventsManager;
import org.matsim.api.core.v01.Scenario;
import com.google.inject.Key;
import com.google.inject.name.Names;

import org.matsim.facilities.ActivityFacilitiesFactory;
import org.matsim.facilities.ActivityFacility;
import org.matsim.facilities.Facility;
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
import java.util.concurrent.atomic.AtomicInteger;
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

    // always one updating thread
    private final int numUpdatingThreads = 1;

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
        config.plans().setInputFile("berlin-v6.4-1pct.plans-filtered_600.xml.gz");
        config.network().setInputFile("berlin-v6.4-network.xml.gz");
        config.counts().setInputFile(null);
        config.qsim().setUsePersonIdForMissingVehicleId(true);
        config.qsim().setEndTime(86400);
        config.routing().setNetworkRouteConsistencyCheck(RoutingConfigGroup.NetworkRouteConsistencyCheck.disable);

        config.global().setInsistingOnDeprecatedConfigVersion(false);
        System.setProperty("matsim.preferLocalDtds", "true");

        // In deiner Main-Methode oder dort, wo du das Controler-Setup hast:
        //Controler controler = new Controler(config);

//        config.qsim().setSnapshotStyle(QSimConfigGroup.SnapshotStyle.queue);
//        config.controller().setLastIteration(0);

        if (localFiles) {
            adaptToLocalFileNames(config);
        }

        // Lade ein einzelnes Scenario, EventsManager und TravelTimeCalculator und teile sie
        Scenario sharedScenario = ScenarioUtils.loadScenario(config);
        Injector adhocInjector = ControllerUtils.createAdhocInjector(sharedScenario);

        // 2. Deine High-Performance TravelTime
        HighPerformanceTravelTime sharedTravelTime = new HighPerformanceTravelTime(sharedScenario.getNetwork());

        // 1. Initialisierung beim Server-Start
        log.info("Pre-calculating SpeedyALT landmarks...");
        SpeedyGraph graph = SpeedyGraphBuilder.build(sharedScenario.getNetwork(), null);
        TravelTime staticFreeSpeed = sharedTravelTime.getStaticFreeSpeedView();
        TravelDisutility staticDisutility = new OnlyTimeDependentTravelDisutilityFactory()
                .createTravelDisutility(staticFreeSpeed);
//
//        // Wir speichern es als Object, da wir den Typ SpeedyALTData hier nicht schreiben dürfen
        Object sharedLandmarks = SpeedyHPCBridge.createSharedData(graph, 16, staticDisutility);
        log.info("Preprocessing finished. Starting gRPC server...");

        prepareVehicles(sharedScenario);

        //RoutingModule pro Thread erzeugen, verwendet aber dasselbe Scenario
//        ThreadLocal<RoutingModule> routerModuleTL = ThreadLocal.withInitial(() ->
//                sharedAdhocInjector.getInstance(Key.get(RoutingModule.class, Names.named("car")))
//        );
//        RoutingModule sharedCarRouter = sharedAdhocInjector.getInstance(Key.get(RoutingModule.class, Names.named("car")));

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


        // 1. Definiere die spezialisierten Worker-Pools
        // Routing-Threads (Lese-Zugriffe)
        ExecutorService rpcExecutor = Executors.newFixedThreadPool(
                numRoutingThreads,
                new ThreadFactoryBuilder().setNameFormat("router-pool-%d").build()
        );

        // Dedizierter Single-Thread-Executor nur für UpdatingService
//        ThreadFactoryBuilder updTf = new ThreadFactoryBuilder().setNameFormat("updater-%d");
//        ExecutorService updaterExecutor = Executors.newSingleThreadExecutor(updTf.build());

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
        // shutdown hook erweitern: beide Executor runterfahren
//        Runnable serverShutdown = () -> {
//            Server s = serverRef.get();
//            if (s != null) {
//                s.shutdown();
//                try {
//                    if (!s.awaitTermination(10, TimeUnit.SECONDS)) s.shutdownNow();
//                } catch (InterruptedException e) {
//                    s.shutdownNow();
//                    Thread.currentThread().interrupt();
//                }
//            }
//            // updater executor beenden
//            updaterExecutor.shutdown();
//            rpcExecutor.shutdown();
//            try {
//                if (!updaterExecutor.awaitTermination(5, TimeUnit.SECONDS)) updaterExecutor.shutdownNow();
//                if (!rpcExecutor.awaitTermination(5, TimeUnit.SECONDS)) rpcExecutor.shutdownNow();
//            } catch (InterruptedException e) {
//                updaterExecutor.shutdownNow();
//                rpcExecutor.shutdownNow();
//                Thread.currentThread().interrupt();
//            }
//        };

        // 1. Definiere die Logik für das saubere Aufräumen
        Runnable serverShutdown = () -> {
            log.info("HPC Cleanup: Shutting down server and pools...");

            // Server stoppen
            Server s = serverRef.get();
            if (s != null) {
                s.shutdown();
                try { if (!s.awaitTermination(5, TimeUnit.SECONDS)) s.shutdownNow(); }
                catch (InterruptedException e) { s.shutdownNow(); }
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
                serverShutdown, config, sharedTravelTime, sharedLandmarks, staticDisutility,linkIdCache, personCache);
        log.info("Starting sequential warm-up for {} routing threads...", numRoutingThreads);

        try {
            log.info("Starting High-Performance Eager Warmup...");

            // This calls the method we wrote that uses CompletableFuture
            // to flood the ForkJoinPool and wait for all cores to finish.
            routingService.warmUpPool();

            log.info("Eager Warmup complete. All cores are JIT-optimized and routers are ready.");
        } catch (Exception e) {
            log.error("Critical failure during HPC Warmup. Aborting startup.", e);
            System.exit(1);
        }

//        for (int threadId = 0; threadId < numRoutingThreads; threadId++) {
//            try {
//                log.info("Initializing thread {} of {}...", threadId + 1, numRoutingThreads);
//
//                // .submit() schickt die Aufgabe an den Pool
//                // .get() wartet blockierend, bis dieser EINE Thread fertig ist
//                rpcExecutor.submit(routingService::init).get();
//
//                log.info("Thread {} is ready.", threadId + 1);
//            } catch (Exception e) {
//                log.error("Failed to initialize thread " + threadId, e);
//                // Optional: System.exit(1), da der Server sonst instabil wäre
//            }
//        }

        log.info("All threads initialized sequentially. Starting gRPC server...");

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
