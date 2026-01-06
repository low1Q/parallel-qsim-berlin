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
        try {
            long startTime = System.nanoTime();

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
}