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
import org.jetbrains.annotations.NotNull;
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
import org.matsim.core.router.MultimodalLinkChooser;
import org.matsim.core.router.RoutingModule;
import org.matsim.core.router.RoutingRequest;
import org.matsim.core.router.speedy.SpeedyALTDataBridge;
import org.matsim.core.router.util.LeastCostPathCalculator;
import org.matsim.core.router.util.TravelDisutility;
import org.matsim.core.scenario.ScenarioUtils;
import org.matsim.core.utils.timing.TimeInterpretation;
import org.matsim.facilities.*;
import org.matsim.utils.objectattributes.attributable.Attributes;
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
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;
import java.util.concurrent.atomic.AtomicReference;

public class RoutingService extends RoutingServiceGrpc.RoutingServiceImplBase {
    private static final Logger log = LogManager.getLogger(RoutingService.class);
    private final ThreadLocal<RoutingModule> carRouter;
    private final Scenario scenario;
    private final TravelTimeSnapshot travelTime;
    private final Runnable shutdown;
    private final Config config;
    private final ConcurrentMap<String, Integer> threadNums = new ConcurrentHashMap<>();
    private final ConcurrentMap<Integer, List<ProfilingEntry>> profilingEntries = new ConcurrentHashMap<>(600_000);
    private int lastNow = -1;
    private final TravelDisutility travelDisutility;
    private final Object landmarks; // Als Object speichern
    private final Map<String, Id<Link>> linkIdCache;
    private final Map<String, Person> personCache;

    public RoutingService(Scenario sharedScenario,
                          Injector sharedAdhocInjector,
                          Runnable shutdown,
                          Config config,
                          TravelTimeSnapshot sharedTravelTime,
                          Object sharedLandmarks,
                          TravelDisutility staticDisutility,
                          Map<String, Id<Link>> linkIdCache, Map<String, Person> personCache) {
        this.scenario = sharedScenario;
        this.shutdown = shutdown;
        this.config = config;
        this.travelTime = sharedTravelTime;
        this.travelDisutility = staticDisutility;
        this.landmarks = sharedLandmarks;
        this.linkIdCache = linkIdCache;
        this.personCache = personCache;

        this.carRouter = ThreadLocal.withInitial(() -> {
            // 1. Create the FAST Router using shared memory landmarks
            // This is the core 'car' logic you pre-calculated
            LeastCostPathCalculator carAlgo = SpeedyALTDataBridge.createRouter(
                    landmarks,
                    travelTime,
                    travelDisutility
            );

            // 2. Resolve lightweight helpers from the adhocInjector
            // Since 'walk' is teleported in your config, this is safe and fast
            RoutingModule walkRouter = sharedAdhocInjector.getInstance(
                    com.google.inject.Key.get(RoutingModule.class, com.google.inject.name.Names.named(TransportMode.walk))
            );

            TimeInterpretation timeInterpretation = sharedAdhocInjector.getInstance(TimeInterpretation.class);
            MultimodalLinkChooser linkChooser = sharedAdhocInjector.getInstance(MultimodalLinkChooser.class);

            // 3. Official Factory Call
            // This internally creates the NetworkRoutingInclAccessEgressModule
            // but handles the package-private visibility for you.
            return org.matsim.core.router.DefaultRoutingModules.createAccessEgressNetworkRouter(
                    TransportMode.car,
                    carAlgo,
                    scenario,
                    scenario.getNetwork(), // filteredNetwork
                    walkRouter,           // The access/egress 'walk' router
                    timeInterpretation,
                    linkChooser
            );
        });
    }

    public void warmUp() {
        carRouter.get();
    }

    @Override
    public void shutdown(Empty request, StreamObserver<Empty> responseObserver) {
        log.info("Received shutdown request");
        //writeProfilingEntries();

        log.info("Shutting down routing service");
        responseObserver.onNext(Empty.getDefaultInstance());
        responseObserver.onCompleted();
        new Thread(shutdown).start();
    }

    @Override
    public void getRoute(Routing.Request request, StreamObserver<Routing.Response> responseObserver) {

        try {
            long startTime = System.nanoTime();
            int threadId = (int) Thread.currentThread().threadId();


            if (threadId == 0 && lastNow < request.getNow() && lastNow / 3600 != request.getNow() / 3600) {
                log.info("Received route request for simulation hour {}:00", String.format("%02d", request.getNow() / 3600));
                lastNow = request.getNow();
            }
            ByteString requestId = request.getRequestId();

            RoutingRequest carRouteRequest = createCarRouteRequest(request);
            List<? extends PlanElement> planElements = carRouter.get().calcRoute(carRouteRequest);
            Routing.Response response = convertToProtoResponse(planElements, requestId);
            responseObserver.onNext(response);
            responseObserver.onCompleted();

            // 5. Profiling (Inside the block!)
            long endTime = System.nanoTime();
            int travelTimes = response.getLegsList().stream().mapToInt(Routing.Leg::getTravTime).sum();

//            var p = new ProfilingEntry(
//                    threadId, request.getNow(), request.getDepartureTime(),
//                    request.getFromLinkId(), request.getToLinkId(),
//                    startTime, endTime - startTime, travelTimes, request.getRequestId()
//            );
//            profilingEntries.computeIfAbsent(threadId, k -> new ArrayList<>()).add(p);
        } catch (Exception e) {
            log.error("Critical error in routing thread {}: {}", Thread.currentThread().getName(), e.getMessage());
            // This is vital: Rust is waiting for this message!
            responseObserver.onError(io.grpc.Status.INTERNAL
                    .withDescription("Routing failed in Java: " + e.getMessage())
                    .asException());
        }

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

    @NotNull
    private RoutingRequest createCarRouteRequest(Routing.Request request) {
        Id<Link> fromLink = Id.createLinkId(request.getFromLinkId());
        Id<Link> toLink = Id.createLinkId(request.getToLinkId());
        String personId = request.getPersonId();
        Person person;

        if (!personId.isEmpty()) {
            person = scenario.getPopulation().getPersons().get(Id.createPersonId(personId));
            if (person == null) {
                throw new IllegalArgumentException("Person with ID " + personId + " not found in scenario.");
            }
        } else {
            System.out.println("PersonId was empty.");
            person = null;
        }

        return new RoutingRequest() {
            @Override
            public Facility getFromFacility() {
                Id<ActivityFacility> fromFacilityId = Id.create("fromFacility", ActivityFacility.class);
                Coord from = new Coord(request.getFromX(), request.getFromY());
                return new ActivityFacilitiesFactoryImpl().createActivityFacility(fromFacilityId, from, fromLink);
            }

            @Override
            public Facility getToFacility() {
                Id<ActivityFacility> toFacilityId = Id.create("toFacility", ActivityFacility.class);
                Coord from = new Coord(request.getToX(), request.getToY());
                return new ActivityFacilitiesFactoryImpl().createActivityFacility(toFacilityId, from, toLink);
            }

            @Override
            public double getDepartureTime() {
                return request.getDepartureTime();
            }

            @Override
            public Person getPerson() {
                return person;
            }

            @Override
            public Attributes getAttributes() {
                assert person != null;
                return person.getAttributes();
            }
        };
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

//    public record Factory(Config config, Runnable shutdown) {
//
//        public RoutingService create() {
//            // 1. Zentrale Ressourcen EINMALIG laden (Shared across all threads)
//            Scenario sharedScenario = ScenarioUtils.loadScenario(config);
//            Network network = sharedScenario.getNetwork();
//
//            // 2. High-Performance Komponenten initialisieren
//            TravelTimeSnapshot sharedTravelTime = new TravelTimeSnapshot(network);
//            TravelDisutility sharedDisutility = new OnlyTimeDependentTravelDisutilityFactory()
//                    .createTravelDisutility(sharedTravelTime);
//
//            // 3. Speedy-Infrastruktur vorbereiten
//            SpeedyGraph speedyGraph = SpeedyGraphBuilder.build(network, null);
//
//            // Landmarken auf Basis von Free-Speed berechnen (einmalig)
//            Object sharedLandmarks = SpeedyALTDataBridge.createLandmarks(
//                    speedyGraph, 16,
//                    new OnlyTimeDependentTravelDisutilityFactory().createTravelDisutility(sharedTravelTime.getStaticFreeSpeedView())
//            );
//
//            // 4. Schnelle Lookups vorbereiten
//            Map<String, Node> linkToNodeMap = new HashMap<>();
//            for (Link link : network.getLinks().values()) {
//                linkToNodeMap.put(link.getId().toString(), link.getToNode());
//            }
//
//            // 5. Den Service erstellen
//            // Der Service bekommt die shared Objekte und regelt den Router-Pool intern per ThreadLocal
//            return new RoutingService(
//                    linkToNodeMap,
//                    sharedLandmarks,
//                    sharedTravelTime,
//                    sharedDisutility,
//                    shutdown
//            );
//        }
//    }

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
            return new RoutingService(null, null, null, null, null, null, null, null, null);
        }
    }

    private record ProfilingEntry(int thread, int simulationNow, long departureTime, String from, String to,
                                  long start, long duration, int travelTime, ByteString requestId) {

    }
}