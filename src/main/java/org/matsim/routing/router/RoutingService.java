package org.matsim.routing.router;

import com.google.inject.Injector;
import com.google.inject.Key;
import com.google.inject.name.Names;
import com.google.protobuf.ByteString;
import com.google.protobuf.Empty;
import io.grpc.stub.StreamObserver;
import org.apache.commons.csv.CSVFormat;
import org.apache.commons.csv.CSVPrinter;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.matsim.api.core.v01.Coord;
import org.matsim.api.core.v01.Id;
import org.matsim.api.core.v01.Scenario;
import org.matsim.api.core.v01.TransportMode;
import org.matsim.api.core.v01.network.Link;
import org.matsim.api.core.v01.population.*;
import org.matsim.core.config.Config;
import org.matsim.core.config.ConfigReader;
import org.matsim.core.config.ConfigUtils;
import org.matsim.core.config.ConfigWriter;
import org.matsim.core.controler.*;
import org.matsim.core.population.routes.NetworkRoute;
import org.matsim.core.router.DefaultRoutingRequest;
import org.matsim.core.router.MultimodalLinkChooser;
import org.matsim.core.router.RoutingModule;
import org.matsim.core.router.RoutingRequest;
import org.matsim.core.router.speedy.SpeedyHPCBridge;
import org.matsim.core.router.util.LeastCostPathCalculator;
import org.matsim.core.router.util.TravelDisutility;
import org.matsim.core.scenario.ScenarioUtils;
import org.matsim.core.utils.timing.TimeInterpretation;
import org.matsim.facilities.*;
import org.matsim.vehicles.Vehicle;
import routing.Routing;
import routing.RoutingServiceGrpc;

import java.io.*;
import java.math.BigInteger;
import java.net.URL;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;
import java.util.concurrent.ForkJoinPool;
import java.util.concurrent.atomic.AtomicReference;

public class RoutingService extends RoutingServiceGrpc.RoutingServiceImplBase {
    private static final Logger log = LogManager.getLogger(RoutingService.class);
    //private final ThreadLocal<RoutingModule> accessEgressCarRouter;
    private final ThreadLocal<RoutingModule> routingModulePool;
    private final Scenario scenario;
    private final Injector adhocInjector;
    private final TravelTimeSnapshot sharedTravelTime;
    private final Runnable shutdown;
    private final Config config;
    private final ConcurrentMap<String, Integer> threadNums = new ConcurrentHashMap<>();
    private final ConcurrentMap<Integer, List<ProfilingEntry>> profilingEntries = new ConcurrentHashMap<>(600_000);
    private int lastNow = -1;
    private final TravelDisutility travelDisutility;
    private final Object landmarks; // Als Object speichern
    //private final ThreadLocal<LeastCostPathCalculator> routerPool;
    private final ActivityFacilitiesFactory facilityFactory;
    private final Id<Link>[] indexToLinkId;
    private final Link[] indexToLink;
    private final Person[] indexToPerson;
    // 1. Die IDs statisch, damit der globale Id-Cache nur EINMAL abgefragt wird
    private static final Id<ActivityFacility> FROM_FACULTY_ID = Id.create("from", ActivityFacility.class);
    private static final Id<ActivityFacility> TO_FACULTY_ID = Id.create("to", ActivityFacility.class);

    public RoutingService(Scenario sharedScenario,
                          Injector adhocInjector, Runnable shutdown,
                          Config config,
                          TravelTimeSnapshot sharedTravelTime,
                          Object sharedLandmarks,
                          TravelDisutility staticDisutility,
                          ActivityFacilitiesFactory sharedFacilitiesFactory,
                          Id<Link>[] indexToLinkId, Link[] indexToLink, Person[] indexToPerson) {
        this.scenario = sharedScenario;
        this.adhocInjector = adhocInjector;
        this.shutdown = shutdown;
        this.config = config;
        this.sharedTravelTime = sharedTravelTime;
        this.travelDisutility = staticDisutility;
        this.landmarks = sharedLandmarks;
        this.indexToLinkId = indexToLinkId;
        this.indexToLink = indexToLink;
        this.indexToPerson = indexToPerson;
        this.facilityFactory = sharedFacilitiesFactory;

        this.routingModulePool = ThreadLocal.withInitial(() -> {
            // 1. Create the FAST Router using shared memory landmarks
            // This is the core 'car' logic you pre-calculated
            LeastCostPathCalculator speedyALT = SpeedyHPCBridge.createRouter(
                    sharedLandmarks,
                    sharedTravelTime,
                    staticDisutility
            );

            // 2. Resolve lightweight helpers from the adhocInjector
            // Since 'walk' is teleported in your config, this is safe and fast
            RoutingModule walkRouter = adhocInjector.getInstance(
                    com.google.inject.Key.get(RoutingModule.class, com.google.inject.name.Names.named(TransportMode.walk))
            );

            Scenario scenario = adhocInjector.getInstance(Scenario.class);
            TimeInterpretation timeInterpretation = adhocInjector.getInstance(TimeInterpretation.class);
            MultimodalLinkChooser linkChooser = adhocInjector.getInstance(MultimodalLinkChooser.class);

            // 3. Official Factory Call
            // This internally creates the NetworkRoutingInclAccessEgressModule
            // but handles the package-private visibility for you.
            return org.matsim.core.router.DefaultRoutingModules.createAccessEgressNetworkRouter(
                    TransportMode.car,
                    speedyALT,
                    scenario,
                    scenario.getNetwork(), // filteredNetwork
                    walkRouter,           // The access/egress 'walk' router
                    timeInterpretation,
                    linkChooser
            );
        });
    }

    /**
     * Forces the initialization of ThreadLocal MATSim components for all pool threads.
     */
    public void warmUpPool() {
        int parallelism = routingPool.getParallelism();
        log.info("Starting eager warmup of {} ForkJoinPool threads...", parallelism);

        // We submit a task for every core to ensure every thread in the pool gets hit
        List<CompletableFuture<Void>> warmers = new ArrayList<>();

        for (int i = 0; i < parallelism; i++) {
            warmers.add(CompletableFuture.runAsync(() -> {
                // Accessing the .get() methods triggers the ThreadLocal initialValue()
                // This loads the Scenario and creates the AdhocInjector
                //routerPool.get();
                //accessEgressCarRouter.get();
                routingModulePool.get();
                log.info("Thread {} is now warmed up and ready.", Thread.currentThread().getName());
            }, routingPool));
        }

        // Wait for all threads to finish loading heavy objects
        CompletableFuture.allOf(warmers.toArray(new CompletableFuture[0])).join();
        log.info("All routing threads initialized and landmarks loaded.");
    }

    @Override
    public void shutdown(Empty request, StreamObserver<Empty> responseObserver) {
        log.info("Received shutdown request");
        writeProfilingEntries();

        log.info("Shutting down routing service");
        responseObserver.onNext(Empty.getDefaultInstance());
        responseObserver.onCompleted();
        new Thread(shutdown).start();
    }

    private final ForkJoinPool routingPool = new ForkJoinPool(
            Runtime.getRuntime().availableProcessors(),
            ForkJoinPool.defaultForkJoinWorkerThreadFactory,
            null, true // async mode for better throughput
    );

    @Override
    public void getRoute(Routing.Request request, StreamObserver<Routing.Response> responseObserver) {
        long startTime = System.nanoTime();
        routingPool.submit(() -> {
            try {
                // 1. Identify Thread
                Integer threadNum = threadNums.computeIfAbsent(
                        Thread.currentThread().getName(),
                        s -> Integer.valueOf(s.substring(s.lastIndexOf('-') + 1))
                );

                if (threadNum == 1 && lastNow < request.getNow() && lastNow / 3600 != request.getNow() / 3600) {
                    log.info("Received route request for simulation hour {}:00", String.format("%02d", request.getNow() / 3600));
                    lastNow = request.getNow();
                }
                ByteString requestId = request.getRequestId();

//                log.info("RoutingRequest on thread {}: from link index {} to link index {}, departure time {}",
//                        threadNum,
//                        request.getFromLinkId(),
//                        request.getToLinkId(),
//                        request.getDepartureTime()
//                );
                //Id<Link> fromLink = Id.createLinkId(request.getFromLinkId());
                Id<Link> fromLink = indexToLinkId[request.getFromLinkId()];
                Id<Link> toLink = indexToLinkId[request.getToLinkId()];
                Person person = indexToPerson[request.getPersonId()];

                //Id<ActivityFacility> fromFacilityId = Id.create("fromFacility", ActivityFacility.class);
                Coord from = new Coord(request.getFromX(), request.getFromY());
                Facility fromFacility = facilityFactory.createActivityFacility(FROM_FACULTY_ID, from, fromLink);

                //Id<ActivityFacility> toFacilityId = Id.create("toFacility", ActivityFacility.class);
                Coord to = new Coord(request.getToX(), request.getToY());
                Facility toFacility = facilityFactory.createActivityFacility(TO_FACULTY_ID, to, toLink);

                RoutingRequest test = DefaultRoutingRequest.of(fromFacility, toFacility,
                        request.getDepartureTime(), person, person.getAttributes());

                //RoutingRequest carRouteRequest = createCarRouteRequest(request);
                //List<? extends PlanElement> planElements = accessEgressCarRouter.get().calcRoute(carRouteRequest);
                List<? extends PlanElement> planElements = routingModulePool.get().calcRoute(test);
//                log.info("Computed route for requestId plan elements: {}",
//                        planElements
//                );
                Routing.Response response = convertToProtoResponse(planElements, requestId);
                //Routing.Response response = null;
                responseObserver.onNext(response);
                responseObserver.onCompleted();

                // 5. Profiling (Inside the block!)
                long endTime = System.nanoTime();
                int travelTimes = response.getLegsList().stream().mapToInt(Routing.Leg::getTravTime).sum();

//                var p = new ProfilingEntry(
//                        threadNum, request.getNow(), request.getDepartureTime(),
//                        request.getFromLinkId(), request.getToLinkId(),
//                        startTime, endTime - startTime, travelTimes, request.getRequestId()
//                );
//                profilingEntries.computeIfAbsent(threadNum, k -> new ArrayList<>()).add(p);
            } catch (Exception e) {
                log.error("Critical error in routing thread {}: {}", Thread.currentThread().getName(), e.getMessage());
                // This is vital: Rust is waiting for this message!
                responseObserver.onError(io.grpc.Status.INTERNAL
                        .withDescription("Routing failed in Java: " + e.getMessage())
                        .asException());
            }
        });
    }

    private Routing.Response convertToProtoResponse(List<? extends PlanElement> planElements, ByteString requestId) {
        Routing.Response.Builder responseBuilder = Routing.Response.newBuilder();

        for (PlanElement element : planElements) {
            if (element instanceof Activity activity) {
                responseBuilder.addActivities(convertToProtoActivity(activity));
            } else if (element instanceof Leg leg) {
                responseBuilder.addLegs(convertToProtoLeg(leg));
            } else {
                throw new IllegalArgumentException("Unsupported PlanElement type: " + element.getClass().getName());
            }
        }

        responseBuilder.setRequestId(requestId);

        return responseBuilder.build();
    }

    private Routing.Leg convertToProtoLeg(Leg leg) {
        Routing.Leg.Builder legBuilder = Routing.Leg.newBuilder()
                .setMode(leg.getMode())
                .setTravTime((int) leg.getTravelTime().orElseThrow(() -> new IllegalArgumentException("Leg must have travel time")));
        leg.getDepartureTime().ifDefined(d -> legBuilder.setDepTime((int) d));
        Optional.ofNullable(leg.getRoutingMode()).ifPresent(legBuilder::setRoutingMode);

        for (Map.Entry<String, Object> stringObjectEntry : leg.getAttributes().getAsMap().entrySet()) {
            Object value = stringObjectEntry.getValue();
            switch (value) {
                case String s ->
                        legBuilder.putAttributes(stringObjectEntry.getKey(), Routing.AttributeValue.newBuilder().setStringValue(s).build());
                case Double v ->
                        legBuilder.putAttributes(stringObjectEntry.getKey(), Routing.AttributeValue.newBuilder().setDoubleValue(v).build());
                case Integer i ->
                        legBuilder.putAttributes(stringObjectEntry.getKey(), Routing.AttributeValue.newBuilder().setIntValue(i).build());
                case Boolean b ->
                        legBuilder.putAttributes(stringObjectEntry.getKey(), Routing.AttributeValue.newBuilder().setBoolValue(b).build());
                default ->
                        throw new IllegalArgumentException("Unsupported attribute type: " + value.getClass().getName());
            }
        }

        Routing.GenericRoute.Builder protoGenericRoute = Routing.GenericRoute.newBuilder()
                .setStartLink(leg.getRoute().getStartLinkId().toString())
                .setEndLink(leg.getRoute().getEndLinkId().toString())
                .setDistance(leg.getRoute().getDistance());
        leg.getRoute().getTravelTime().ifDefined(d -> protoGenericRoute.setTravTime((int) d));

        if (leg.getRoute() instanceof NetworkRoute networkRoute) {
            //Network Route
            Routing.NetworkRoute.Builder protoNetworkRoute = Routing.NetworkRoute.newBuilder();

            // Always add start and end link as the rust side expects full route
            protoNetworkRoute.addRoute(networkRoute.getStartLinkId().toString());
            for (Id<Link> linkId : networkRoute.getLinkIds()) {
                protoNetworkRoute.addRoute(linkId.toString());
            }
            // add end link only if it's different from start link (to avoid duplication)
            if (!(networkRoute.getStartLinkId() == networkRoute.getEndLinkId())) {
                protoNetworkRoute.addRoute(networkRoute.getEndLinkId().toString());
            }

            protoNetworkRoute.setDelegate(protoGenericRoute.build());
            legBuilder.setNetworkRoute(protoNetworkRoute);
        } else {
            //Generic Route
            legBuilder.setGenericRoute(protoGenericRoute);
        }

        return legBuilder.build();
    }

    private Routing.Activity convertToProtoActivity(Activity activity) {
        Routing.Activity.Builder builder = Routing.Activity.newBuilder();
        builder.setActType(activity.getType())
                .setLinkId(activity.getLinkId().toString())
                .setX(activity.getCoord().getX())
                .setY(activity.getCoord().getY());

        activity.getStartTime().ifDefined(t -> builder.setStartTime((int) t));
        activity.getEndTime().ifDefined(t -> builder.setEndTime((int) t));
        activity.getMaximumDuration().ifDefined(d -> builder.setMaxDur((int) d));

        return builder.build();
    }

    private void writeProfilingEntries() {
        DateTimeFormatter dateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd_HH-mm-ss");
        String t = LocalDateTime.now().format(dateTimeFormatter);
        String outputFile = config.controller().getOutputDirectory() + "/routing-profiling-" + t + ".csv";

        log.info("Writing profiling entries to file: {}", outputFile);

        List<ProfilingEntry> allEntries = this.profilingEntries.values().stream().flatMap(Collection::stream).sorted(Comparator.comparingInt(e -> e.simulationNow)).toList();

        try (BufferedWriter writer = Files.newBufferedWriter(Paths.get(outputFile));
             CSVPrinter csv = new CSVPrinter(writer, CSVFormat.DEFAULT.builder().setHeader("thread", "now", "departure_time", "from", "to", "start", "duration_ns", "travel_time_s", "request_id").get())) {
            for (ProfilingEntry profilingEntry : allEntries) {
                csv.printRecord(
                        profilingEntry.thread,
                        profilingEntry.simulationNow,
                        profilingEntry.departureTime,
                        profilingEntry.from,
                        profilingEntry.to,
                        profilingEntry.start,
                        profilingEntry.duration,
                        profilingEntry.travelTime,
                        new BigInteger(1, profilingEntry.requestId.toByteArray()).toString()
                );
            }
        } catch (IOException e) {
            log.error("Error writing to file: {}", outputFile, e);
            throw new RuntimeException(e);
        }
    }

    public record Factory(Config config, Runnable shutdown) {
        public RoutingService create() {
            config.controller().setOverwriteFileSetting(OutputDirectoryHierarchy.OverwriteFileSetting.overwriteExistingFiles);

            // Serialize config to byte array and create ThreadLocal copies
            // This is necessary because the config is modified during scenario loading (consistency checks are added in Constructor of NewControler),
            // consequently java.util.ConcurrentModificationException MIGHT be thrown (not always)
            URL context = config.getContext();
            ByteArrayOutputStream stream = new ByteArrayOutputStream();
            Writer writer = new OutputStreamWriter(stream);
            new ConfigWriter(config).writeStream(writer);
            AtomicReference<byte[]> byteArray = new AtomicReference<>(stream.toByteArray());

            ThreadLocal<Config> configThreadLocal = ThreadLocal.withInitial(() -> {
                Config cfg = ConfigUtils.createConfig();
                ConfigReader reader = new ConfigReader(cfg);
                reader.readStream(new ByteArrayInputStream(byteArray.get()));
                cfg.setContext(context);
                return cfg;
            });

            // ThreadLocal for Scenario and RoutingModule
            ThreadLocal<Scenario> scenarioThreadLocal = ThreadLocal.withInitial(() -> ScenarioUtils.loadScenario(configThreadLocal.get()));
            ThreadLocal<RoutingModule> carRouterThreadLocal = ThreadLocal.withInitial(() -> {
                Scenario scenario = scenarioThreadLocal.get();
                return ControllerUtils.createAdhocInjector(scenario).getInstance(Key.get(RoutingModule.class, Names.named("car")));
            });
            // ThreadLocal Router für "car"
            return new RoutingService(null, null, null, null, null, null, null, null, null, null, null);
        }
    }

    private record ProfilingEntry(int thread, int simulationNow, long departureTime, String from, String to,
                                  long start, long duration, int travelTime, ByteString requestId) {

    }
}