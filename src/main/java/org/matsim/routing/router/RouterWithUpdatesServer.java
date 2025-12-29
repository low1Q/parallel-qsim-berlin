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
import org.matsim.application.MATSimAppCommand;
import org.matsim.core.config.Config;
import org.matsim.core.config.ConfigUtils;
import org.matsim.core.config.groups.QSimConfigGroup;
import org.matsim.core.controler.ControllerUtils;
import org.matsim.core.router.RoutingModule;
import org.matsim.core.scenario.ScenarioUtils;
import org.matsim.core.trafficmonitoring.TravelTimeCalculator;
import org.matsim.core.events.EventsUtils;
import org.matsim.core.api.experimental.events.EventsManager;
import org.matsim.core.controler.OutputDirectoryHierarchy;
import org.matsim.api.core.v01.Scenario;
import com.google.inject.Key;
import com.google.inject.name.Names;
//import org.matsim.routing.updater.SimpleTravelTimeAggregator;

import picocli.CommandLine;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
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

        config.qsim().setSnapshotStyle(QSimConfigGroup.SnapshotStyle.queue);
        config.controller().setLastIteration(0);

        if (localFiles) {
            adaptToLocalFileNames(config);
        }

        // Lade ein einzelnes Scenario, EventsManager und TravelTimeCalculator und teile sie
        Scenario sharedScenario = ScenarioUtils.loadScenario(config);
        EventsManager sharedEventsManager = EventsUtils.createEventsManager();
        Injector sharedAdhocInjector = ControllerUtils.createAdhocInjector(sharedScenario);
        TravelTimeCalculator sharedTTC = sharedAdhocInjector
                .getInstance(Key.get(TravelTimeCalculator.class, Names.named("car")));

//        Set<String> analyzedModes = new HashSet<>();
//        analyzedModes.add(TransportMode.car);
//        WithinDayTravelTime withinDayTravelTimes = new WithinDayTravelTime(sharedScenario, analyzedModes);

        // ThreadLocal-Wrapper, die die geteilten Instanzen zurückgeben
//        SimpleTravelTimeAggregator aggregator = new SimpleTravelTimeAggregator();
//        TravelTime liveTravelTime = aggregator.getSnapshot();
        ThreadLocal<Scenario> scenarioTL = ThreadLocal.withInitial(() -> sharedScenario);
        ThreadLocal<EventsManager> eventsManagerTL = ThreadLocal.withInitial(() -> sharedEventsManager);
        ThreadLocal<TravelTimeCalculator> ttcTL = ThreadLocal.withInitial(() -> sharedTTC);
//        ThreadLocal<SimpleTravelTimeAggregator> aggregatorTL = ThreadLocal.withInitial(() -> aggregator);
//        ThreadLocal<WithinDayTravelTime> wdttTL = ThreadLocal.withInitial(() -> withinDayTravelTimes);
        sharedEventsManager.addHandler(sharedTTC);

        // Delegierendes TravelTime: fragt bei jeder Abfrage den aktuellen Snapshot für die gegebene Zeit ab.
//        TravelTime liveTravelTime = (link, time, person, vehicle) ->
//                aggregatorTL.get().getSnapshotForTime(time).getLinkTravelTime(link, time, person, vehicle);

//        new AbstractModule() {
//            @Override
//            public void install() {
//                this.addEventHandlerBinding().toInstance( aggregator );
//                this.bind(TravelTime.class).toInstance(liveTravelTime);
//                this.addTravelTimeBinding(TransportMode.car)
//                        .toInstance(liveTravelTime);
//            }
//        };

//        new AbstractModule() {  // Module können so hinzugefügt werden
//            @Override
//            public void install() {
//                addTravelTimeBinding(TransportMode.car).toInstance(withinDayTravelTimes);
//                this.addEventHandlerBinding().toInstance( withinDayTravelTimes );
//                this.bind(TravelTime.class).toInstance(withinDayTravelTimes);
//                this.addMobsimListenerBinding().toInstance(withinDayTravelTimes);
//            }
//        };

         //RoutingModule pro Thread erzeugen, verwendet aber dasselbe Scenario
        ThreadLocal<org.matsim.core.router.RoutingModule> routerModuleTL = ThreadLocal.withInitial(() ->
                sharedAdhocInjector.getInstance(Key.get(org.matsim.core.router.RoutingModule.class, Names.named("car")))
        );
        RoutingModule sharedCarRouter = sharedAdhocInjector.getInstance(Key.get(RoutingModule.class, Names.named("car")));

        // RPC-Executor für gRPC-Server (Routing-Threads + ein wenig Puffer)
        ThreadFactoryBuilder rpcTf = new ThreadFactoryBuilder().setNameFormat("grpc-rpc-%d");
        ExecutorService rpcExecutor = Executors.newFixedThreadPool(numRoutingThreads, rpcTf.build());

        // Dedizierter Single-Thread-Executor nur für UpdatingService
        ThreadFactoryBuilder updTf = new ThreadFactoryBuilder().setNameFormat("updater-%d");
        ExecutorService updaterExecutor = Executors.newSingleThreadExecutor(updTf.build());

        // Erzeuge Services mit den neuen public-Konstruktoren
        Runnable shutdown = () -> {
            log.info("Running shutdown hook");
            // nothing here; actual Server shutdown handled below
        };

        // Verwende die öffentlichen Konstruktoren, die ThreadLocal-Wrapper akzeptieren
        org.matsim.routing.updater.UpdatingService updatingService =
                new org.matsim.routing.updater.UpdatingService(sharedTTC, sharedEventsManager, scenarioTL, () -> { /* will be replaced below */ }, config, updaterExecutor);

        RoutingService routingService = new RoutingService(sharedCarRouter, routerModuleTL, scenarioTL, () -> { /* will be replaced below */ }, config);

        AtomicReference<Server> serverRef = new AtomicReference<>();
// shutdown hook erweitern: beide Executor runterfahren
        Runnable serverShutdown = () -> {
            Server s = serverRef.get();
            if (s != null) {
                s.shutdown();
                try {
                    if (!s.awaitTermination(10, TimeUnit.SECONDS)) s.shutdownNow();
                } catch (InterruptedException e) {
                    s.shutdownNow();
                    Thread.currentThread().interrupt();
                }
            }
            // updater executor beenden
            updaterExecutor.shutdown();
            rpcExecutor.shutdown();
            try {
                if (!updaterExecutor.awaitTermination(5, TimeUnit.SECONDS)) updaterExecutor.shutdownNow();
                if (!rpcExecutor.awaitTermination(5, TimeUnit.SECONDS)) rpcExecutor.shutdownNow();
            } catch (InterruptedException e) {
                updaterExecutor.shutdownNow();
                rpcExecutor.shutdownNow();
                Thread.currentThread().interrupt();
            }
        };
        // setze reale shutdown hooks in Services (optional)
        // (Hier einfache Zuordnung)
        //noinspection LawOfDemeter
        updatingService = new org.matsim.routing.updater.UpdatingService(sharedTTC, sharedEventsManager, scenarioTL, serverShutdown, config, updaterExecutor);
        //noinspection LawOfDemeter
        RoutingService routingServiceFinal = new RoutingService(sharedCarRouter, routerModuleTL, scenarioTL, serverShutdown, config);

        // Executor mit numRoutingThreads + numUpdatingThreads
        int totalThreads = numRoutingThreads + numUpdatingThreads;
        AtomicInteger counter = new AtomicInteger(0);
        ThreadFactory factory = r -> {
            int idx = counter.getAndIncrement();
            String name;
            if (idx < numRoutingThreads) name = "router-" + idx;
            else name = "updater-0";
            Thread t = new Thread(r, name);
            t.setDaemon(false);
            return t;
        };

        // Eagerly initialize ThreadLocals: zuerst Routing init x times, dann Updating init once
// Init weiterhin über rpcExecutor (Routing init + Updating init)
        List<Future<?>> futures = new ArrayList<>();
        for (int i = 0; i < numRoutingThreads; i++) {
            futures.add(rpcExecutor.submit(routingServiceFinal::init));
        }
        futures.add(rpcExecutor.submit(updatingService::init));
        for (Future<?> f : futures) f.get();

// Start server mit rpcExecutor
        Server server = ServerBuilder.forPort(PORT)
                .addService(routingServiceFinal)
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
}
