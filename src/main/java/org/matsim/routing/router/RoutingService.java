package org.matsim.routing.router;

import com.google.inject.Injector;
import com.google.inject.Key;
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
import org.matsim.core.controler.*;
import org.matsim.core.population.routes.NetworkRoute;
import org.matsim.core.router.DefaultRoutingModules;
import org.matsim.core.router.MultimodalLinkChooser;
import org.matsim.core.router.RoutingModule;
import org.matsim.core.router.RoutingRequest;
import org.matsim.core.router.speedy.SpeedyALTDataBridge;
import org.matsim.core.router.util.LeastCostPathCalculator;
import org.matsim.core.router.util.TravelDisutility;
import org.matsim.core.utils.timing.TimeInterpretation;
import org.matsim.facilities.*;
import org.matsim.utils.objectattributes.attributable.Attributes;
import org.matsim.utils.objectattributes.attributable.AttributesImpl;
import routing.Routing;
import routing.RoutingServiceGrpc;

import java.io.*;
import java.math.BigInteger;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.atomic.AtomicLong;

import static com.google.inject.name.Names.named;

public class RoutingService extends RoutingServiceGrpc.RoutingServiceImplBase {
    private static final Logger log = LogManager.getLogger(RoutingService.class);
    private final ThreadLocal<RoutingModule> carRouter;
    private final Scenario scenario;
    private final TravelTimeSnapshot travelTime;
    private final Runnable shutdown;
    private final Config config;
    private final TravelDisutility travelDisutility;
    private final Object landmarks; // Als Object speichern
    private final AtomicLong lastLoggedHour = new AtomicLong(-1);
    //WIP
//    private final Map<String, Id<Link>> linkIdCache;
//    private final Map<String, Person> personCache;

    // === Routing request rate measurement (per sim-second, sliding window) ===

    private static final int ROUTING_RATE_WINDOW = 60; // last 60 sim-seconds
    private final java.util.concurrent.atomic.LongAdder[] routingBuckets =
            new java.util.concurrent.atomic.LongAdder[ROUTING_RATE_WINDOW];
    private final java.util.concurrent.atomic.AtomicLong[] routingBucketSecond =
            new java.util.concurrent.atomic.AtomicLong[ROUTING_RATE_WINDOW];
    private final java.util.concurrent.atomic.LongAdder realCount = new java.util.concurrent.atomic.LongAdder();
    private final java.util.concurrent.atomic.AtomicLong lastRealLogNs = new java.util.concurrent.atomic.AtomicLong(System.nanoTime());
    private final java.util.concurrent.atomic.AtomicLong lastLoggedSimSecond = new java.util.concurrent.atomic.AtomicLong(Long.MIN_VALUE);

    private final ConcurrentLinkedQueue<ProfilingEntry> profilingQueue = new ConcurrentLinkedQueue<>();
    private final Thread logWriterThread;
    private volatile boolean isRunning = true;


    public RoutingService(Scenario sharedScenario,
                          Injector sharedAdhocInjector,
                          Runnable shutdown,
                          Config config,
                          TravelTimeSnapshot sharedTravelTime,
                          Object sharedLandmarks,
                          TravelDisutility staticDisutility
                          //Map<String, Id<Link>> linkIdCache, Map<String, Person> personCache WIP
    ) {
        this.scenario = sharedScenario;
        this.shutdown = shutdown;
        this.config = config;
        this.travelTime = sharedTravelTime;
        this.travelDisutility = staticDisutility;
        this.landmarks = sharedLandmarks;
        //WIP
//        this.linkIdCache = linkIdCache;
//        this.personCache = personCache;

        this.carRouter = ThreadLocal.withInitial(() -> {
            // Create the FAST Router using shared memory landmarks
            // This is the core 'car' logic we pre-calculated
            LeastCostPathCalculator speedyALTCarRouter = SpeedyALTDataBridge.createRouter(
                    landmarks,
                    travelTime,
                    travelDisutility
            );

            // Resolve lightweight helpers from the adhocInjector
            // Since 'walk' is teleported in our config, this is safe and fast
            RoutingModule walkRouter = sharedAdhocInjector.getInstance(
                    Key.get(RoutingModule.class, named(TransportMode.walk))
            );

            TimeInterpretation timeInterpretation = sharedAdhocInjector.getInstance(TimeInterpretation.class);
            MultimodalLinkChooser linkChooser = sharedAdhocInjector.getInstance(MultimodalLinkChooser.class);

            // Create the Access-Egress wrapper around the core 'car' router
            return DefaultRoutingModules.createAccessEgressNetworkRouter(
                    TransportMode.car,
                    speedyALTCarRouter,
                    scenario,
                    scenario.getNetwork(),
                    walkRouter,
                    timeInterpretation,
                    linkChooser
            );
        });
        this.logWriterThread = new Thread(this::continuousLoggingLoop);
        this.logWriterThread.setName("Profiling-Writer");
        this.logWriterThread.setDaemon(true); // Stirbt automatisch, wenn der Server stoppt
        this.logWriterThread.start();

        for (int i = 0; i < ROUTING_RATE_WINDOW; i++) {
            routingBuckets[i] = new java.util.concurrent.atomic.LongAdder();
            routingBucketSecond[i] = new java.util.concurrent.atomic.AtomicLong(Long.MIN_VALUE);
        }

    }

    public void warmUp() {
        carRouter.get();
    }

    @Override
    public void shutdown(Empty request, StreamObserver<Empty> responseObserver) {
        log.info("Received shutdown request");

        // Signal an den Writer-Thread
        isRunning = false;

        try {
            // Dem Writer kurz Zeit geben, die Queue zu leeren
            logWriterThread.join(2000);
        } catch (InterruptedException e) {
            log.warn("Shutdown interrupted while waiting for log writer");
        }

        log.info("Shutting down routing service");
        responseObserver.onNext(Empty.getDefaultInstance());
        responseObserver.onCompleted();
        new Thread(shutdown).start();
    }

    @Override
    public void getRoute(Routing.Request request, StreamObserver<Routing.Response> responseObserver) {
        long startTime = System.nanoTime();

        recordRoutingRate(request);

        try {
            // Deterministische Snapshot-Bindung:
            // blockiert, bis der für request.now benötigte one-bin-lag-Snapshot existiert
            // Für parallel_qsim_rust: request.now = rt (RequestTime), departure_time = dt (ActivityEnd).
            //log.info("Getting route");
            travelTime.bindToTime(request.getNow());

            assert travelTime.isBound() : "TravelTimeSnapshot must be bound before routing";
//            log.debug(
//                    "Routing request {} bound to snapshot {}, current snapshot is {}, with timestamp {}",
//                    request.getRequestId(),
//                    travelTime.getBoundSnapshotId(),
//                    travelTime.getCurrentSnapshotId(),
//                    travelTime.getBoundSnapshotTimestamp()
//            );
            long currentHour = request.getNow() / 3600;
            if (lastLoggedHour.get() != currentHour) {
                if (lastLoggedHour.getAndSet(currentHour) != currentHour) {
                    log.info("Received route request for simulation hour {}:00", String.format("%02d", currentHour));
                }
            }

            RoutingRequest carRouteRequest = createCarRouteRequest(request);

            List<? extends PlanElement> planElements = carRouter.get().calcRoute(carRouteRequest);
            Routing.Response response = convertToProtoResponse(planElements, request.getRequestId());

            responseObserver.onNext(response);
            responseObserver.onCompleted();

            long endTime = System.nanoTime();
            int travelTimes = response.getLegsList().stream().mapToInt(Routing.Leg::getTravTime).sum();
            profilingQueue.add(new ProfilingEntry(
                    (int) Thread.currentThread().threadId(),
                    request.getNow(),
                    request.getDepartureTime(),
                    request.getFromLinkId(),
                    request.getToLinkId(),
                    startTime,
                    endTime - startTime,
                    travelTimes,
                    request.getRequestId()
            ));

        } catch (Exception e) {
            log.error("Critical error in routing thread {}: {}", Thread.currentThread().getName(), e.getMessage(), e);
            // This is vital: Rust is waiting for this message!
            responseObserver.onError(io.grpc.Status.INTERNAL
                    .withDescription("Routing failed in Java: " + e.getMessage())
                    .asException());
        } finally {
            travelTime.unbind();
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
            log.warn("PersonId was empty.");
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
                // Person kann bei dir null sein -> sichere Default-Attributes
                return person != null ? person.getAttributes() : new AttributesImpl();
            }
        };
    }

    private void continuousLoggingLoop() {
        DateTimeFormatter dateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd_HH-mm-ss");
        String t = LocalDateTime.now().format(dateTimeFormatter);
        String outputFile = config.controller().getOutputDirectory() + "/routing-profiling-" + t + ".csv";

        log.info("Starting async profiling writer to: {}", outputFile);

        try (BufferedWriter writer = Files.newBufferedWriter(Paths.get(outputFile));
             CSVPrinter csv = new CSVPrinter(writer, CSVFormat.DEFAULT.builder()
                     .setHeader("thread", "now", "departure_time", "from", "to", "start", "duration_ns", "travel_time_s", "request_id")
                     .get())) {

            while (isRunning || !profilingQueue.isEmpty()) {
                ProfilingEntry entry = profilingQueue.poll(); // Holt den nächsten Eintrag ohne zu blockieren
                if (entry != null) {
                    csv.printRecord(
                            entry.thread(),
                            entry.simulationNow(),
                            entry.departureTime(),
                            entry.from(),
                            entry.to(),
                            entry.start(),
                            entry.duration(),
                            entry.travelTime(),
                            new BigInteger(1, entry.requestId().toByteArray()).toString()
                    );
                } else {
                    Thread.sleep(100); // Kurz warten, wenn die Queue leer ist
                }
            }
            csv.flush();
        } catch (IOException | InterruptedException e) {
            log.error("Error in profiling writer thread", e);
        }
    }

    private record ProfilingEntry(int thread, int simulationNow, long departureTime, String from, String to,
                                  long start, long duration, int travelTime, ByteString requestId) {

    }

    private void recordRoutingRate(Routing.Request request) {
        long simSecond = (long) request.getNow();
        int idx = Math.floorMod(simSecond, ROUTING_RATE_WINDOW);
        realCount.increment();
        long nowNs = System.nanoTime();
        long lastNs = lastRealLogNs.get();
//        if (nowNs - lastNs > 1_000_000_000L && lastRealLogNs.compareAndSet(lastNs, nowNs)) {
//            long c = realCount.sumThenReset();
//            if (simSecond % 10 == 0 && lastLoggedSimSecond.getAndSet(simSecond) != simSecond) {
//                log.info("Routing rate (real): ~{} req/s over last ~1s", c);
//            }
//        }
        long prevSecond = routingBucketSecond[idx].get();
        if (prevSecond != simSecond && routingBucketSecond[idx].compareAndSet(prevSecond, simSecond)) {
            routingBuckets[idx].reset();
        }

        routingBuckets[idx].increment();

        // Log nur gelegentlich (z.B. alle 10 Sim-Sekunden)
        if (simSecond % 10 == 0) {
            long sum = 0;
            for (int i = 0; i < ROUTING_RATE_WINDOW; i++) {
                long s = routingBucketSecond[i].get();
                if (s >= simSecond - (ROUTING_RATE_WINDOW - 1)) {
                    sum += routingBuckets[i].sum();
                }
            }
            double avg = sum / (double) ROUTING_RATE_WINDOW;

//            log.info(
//                    "Routing rate: last {} sim-seconds avg = {} req/sim-s (current sim t={})",
//                    ROUTING_RATE_WINDOW,
//                    String.format("%.2f", avg),
//                    simSecond
//            );
        }
    }


}