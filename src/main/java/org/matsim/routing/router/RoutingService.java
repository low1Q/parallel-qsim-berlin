package org.matsim.routing.router;

import com.google.inject.Injector;
import com.google.inject.Key;
import com.google.protobuf.ByteString;
import com.google.protobuf.Empty;
import io.grpc.Status;
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
import org.matsim.api.core.v01.population.Activity;
import org.matsim.api.core.v01.population.Leg;
import org.matsim.api.core.v01.population.Person;
import org.matsim.api.core.v01.population.PlanElement;
import org.matsim.core.config.Config;
import org.matsim.core.population.routes.NetworkRoute;
import org.matsim.core.router.DefaultRoutingModules;
import org.matsim.core.router.MultimodalLinkChooser;
import org.matsim.core.router.RoutingModule;
import org.matsim.core.router.RoutingRequest;
import org.matsim.core.router.speedy.SpeedyALTDataBridge;
import org.matsim.core.router.util.LeastCostPathCalculator;
import org.matsim.core.router.util.TravelDisutility;
import org.matsim.core.utils.timing.TimeInterpretation;
import org.matsim.facilities.ActivityFacilitiesFactoryImpl;
import org.matsim.facilities.ActivityFacility;
import org.matsim.facilities.Facility;
import org.matsim.utils.objectattributes.attributable.Attributes;
import org.matsim.utils.objectattributes.attributable.AttributesImpl;
import routing.Routing;
import routing.RoutingServiceGrpc;

import java.io.BufferedWriter;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.concurrent.*;

import static com.google.inject.name.Names.named;

public class RoutingService extends RoutingServiceGrpc.RoutingServiceImplBase {
    private static final Logger log = LogManager.getLogger(RoutingService.class);
    private final ThreadLocal<RoutingModule> carRouter;
    private final Scenario scenario;
    private final TravelTimeSnapshot travelTime;
    private final Runnable shutdown;
    private final Config config;
    private final TravelDisutility travelDisutility;
    private final Object landmarks;
    private final ExecutorService routingExecutor;
    private final Set<Long> loggedHours = ConcurrentHashMap.newKeySet();
    private final int preplanningHorizon;

    //private final ThreadLocal<RoutingModule> carRouterModule;

    // Profiling
    private final ConcurrentLinkedQueue<RoutingTimeProfilingEntry> routingTimeProfilingQueue = new ConcurrentLinkedQueue<>();
    private final Thread routingLogWriterThread;
    private volatile boolean routingTimeLoggingIsRunning = true;
    private final String runContext;

    public RoutingService(Scenario sharedScenario, Injector sharedAdhocInjector, Runnable shutdown, Config config, TravelTimeSnapshot sharedTravelTime, Object sharedLandmarks,
                          TravelDisutility staticDisutility, ExecutorService routingExecutor, String runContext, int preplanningHorizon) {
        this.scenario = sharedScenario;
        this.shutdown = shutdown;
        this.config = config;
        this.travelTime = sharedTravelTime;
        this.travelDisutility = staticDisutility;
        this.landmarks = sharedLandmarks;
        this.routingExecutor = routingExecutor;
        this.runContext = runContext;
        this.preplanningHorizon = preplanningHorizon;

        this.carRouter = ThreadLocal.withInitial(() -> {
            // Create the FAST Router using shared memory landmarks
            // This is the core 'car' logic we pre-calculated
            LeastCostPathCalculator speedyALTCarRouter = SpeedyALTDataBridge.createRouter(landmarks, travelTime, travelDisutility);

            // Resolve lightweight helpers from the adhocInjector
            // Since 'walk' is teleported in our config, this is safe and fast
            RoutingModule walkRouter = sharedAdhocInjector.getInstance(Key.get(RoutingModule.class, named(TransportMode.walk)));

            TimeInterpretation timeInterpretation = sharedAdhocInjector.getInstance(TimeInterpretation.class);
            MultimodalLinkChooser linkChooser = sharedAdhocInjector.getInstance(MultimodalLinkChooser.class);

            // Create the Access-Egress wrapper around the core 'car' router
            return DefaultRoutingModules.createAccessEgressNetworkRouter(TransportMode.car, speedyALTCarRouter, scenario, scenario.getNetwork(), walkRouter, timeInterpretation, linkChooser);
        });




        //this.carRouterModule = ThreadLocal.withInitial(() -> ControllerUtils.createAdhocInjector(scenario).getInstance(Key.get(RoutingModule.class, Names.named("car"))));




        this.routingLogWriterThread = new Thread(this::continuousRoutingTimeLoggingLoop);
        this.routingLogWriterThread.setName("routing-profiling-writer");
        this.routingLogWriterThread.setDaemon(true); // Stirbt automatisch, wenn der Server stoppt
        this.routingLogWriterThread.start();
    }

    private static long unixNanosNow() {
        Instant now = Instant.now();
        return now.getEpochSecond() * 1_000_000_000L + now.getNano();
    }

    public void warmUp() {
        carRouter.get();
        //carRouterModule.get();
    }

    @Override
    public void shutdown(Empty request, StreamObserver<Empty> responseObserver) {
        log.info("Received shutdown request");

        // Signal an den Writer-Thread
        routingTimeLoggingIsRunning = false;

        try {
            // Dem Writer kurz Zeit geben, die Queue zu leeren
            routingLogWriterThread.join(2000);
        } catch (InterruptedException e) {
            log.warn("Shutdown interrupted while waiting for routing profiling writer");
            Thread.currentThread().interrupt();
        }

        log.info("Shutting down routing service");
        responseObserver.onNext(Empty.getDefaultInstance());
        responseObserver.onCompleted();
        new Thread(shutdown).start();
    }

    @Override
    public void getRoute(Routing.Request request, StreamObserver<Routing.Response> responseObserver) {
        try {
            routingExecutor.execute(() -> handleRouteRequest(request, responseObserver));
        } catch (RejectedExecutionException e) {
            log.warn("Routing executor overloaded; rejecting request {}", request.getRequestId());
            responseObserver.onError(io.grpc.Status.RESOURCE_EXHAUSTED.withDescription("Routing executor overloaded. Try again later.").asException());
        }
    }

    private void handleRouteRequest(Routing.Request request, StreamObserver<Routing.Response> responseObserver) {
        long javaRequestReceived = unixNanosNow();
        long javaStartNs = System.nanoTime();

        ThreadPoolExecutor executor = (ThreadPoolExecutor) routingExecutor;
        int queueSize = executor.getQueue().size();
        int activeCount = executor.getActiveCount();
        long taskCount = executor.getTaskCount();
        long completedTaskCount = executor.getCompletedTaskCount();

        try {
            long currentHour = request.getNow() / 3600;
            if (loggedHours.add(currentHour)) {
                log.info("Received route request for simulation hour {}:00", String.format("%02d", currentHour));
            }

            // Deterministische Snapshot-Bindung:
            // blockiert, bis der für request.now benötigte one-bin-lag-Snapshot existiert
            // Für parallel_qsim_rust: request.now = rt (RequestTime), departure_time = dt (ActivityEnd).

            int requestNow = request.getNow();
            if (request.getDepartureTime() - requestNow < preplanningHorizon) {
                requestNow = request.getDepartureTime() -  preplanningHorizon;
                //log.warn("Request {} has departure time {} and requestNow {}. A difference of {}. New requestNow {}. This is within the preplanning horizon of {} seconds.", uuidBytesToString(request.getRequestId()), request.getDepartureTime(), request.getNow(),request.getDepartureTime()-request.getNow(), requestNow, preplanningHorizon);
            }

            long bindStart = System.nanoTime();
            boolean hadToWait = travelTime.bindToTime(requestNow);
            long bindEnd = System.nanoTime();
            long bindWaitNs = bindEnd - bindStart;

            assert travelTime.isBound() : "TravelTimeSnapshot must be bound before routing";

            long createCarRouteRequestStart = System.nanoTime();
            RoutingRequest carRouteRequest = createCarRouteRequest(request);
            long createCarRouteRequestEnd = System.nanoTime();
            long createCarRouteRequestTime = createCarRouteRequestEnd - createCarRouteRequestStart;

            long calcRouteStartRealtime = System.nanoTime();
            List<? extends PlanElement> planElements = carRouter.get().calcRoute(carRouteRequest);
            //List<? extends PlanElement> planElements = carRouterModule.get().calcRoute(carRouteRequest);
            long calcRouteEndRealtime = System.nanoTime();
            long calcRouteTime = calcRouteEndRealtime - calcRouteStartRealtime;

            long createCarResponseStart = System.nanoTime();
            long responseSentForRust = unixNanosNow();
            Routing.Response response = convertToProtoResponse(planElements, responseSentForRust, request.getRequestId());
            long createCarResponseEnd = System.nanoTime();
            long createCarResponseTime = createCarResponseEnd - createCarResponseStart;

            long responseSent = System.nanoTime();
            responseObserver.onNext(response);
            responseObserver.onCompleted();

            long responseSentForRustReal = unixNanosNow();
            long responseSentForRustDelta = responseSentForRustReal - responseSentForRust;
            long javaTotalNs = System.nanoTime() - javaStartNs;
            long rustGRPCSendStartedRealtime = request.getRustAdapterSentRequestGrpc();
            long requestDeliveryLatencyNs = Math.max(0L, javaRequestReceived - rustGRPCSendStartedRealtime);

            String requestIdStr = uuidBytesToString(request.getRequestId());

            //int travelTimes = response.getLegsList().stream().mapToInt(Routing.Leg::getTravTime).sum();
            routingTimeProfilingQueue.add(new RoutingTimeProfilingEntry(requestIdStr, Thread.currentThread().getName(), request.getNow(), request.getDepartureTime(), request.getFromLinkId(), request.getToLinkId(), request.getRouteCallStartRealtime(), rustGRPCSendStartedRealtime, javaRequestReceived, bindWaitNs, hadToWait, createCarRouteRequestTime, calcRouteTime, createCarResponseTime, responseSentForRustReal, responseSentForRustDelta, requestDeliveryLatencyNs, javaTotalNs, queueSize, activeCount, taskCount, completedTaskCount));

        } catch (Exception e) {
            log.error("Critical error in routing thread {}: {}", Thread.currentThread().getName(), e.getMessage(), e);
            // This is vital: Rust is waiting for this message!
            responseObserver.onError(Status.INTERNAL.withDescription("Routing failed in Java: " + e.getMessage()).asException());
        } finally {
            travelTime.unbind();
        }
    }

    private Routing.Response convertToProtoResponse(List<? extends PlanElement> planElements, long responseSentForRust, ByteString requestId) {
        Routing.Response.Builder responseBuilder = Routing.Response.newBuilder();

        boolean firstLeg = true;

        for (PlanElement element : planElements) {
            if (element instanceof Activity activity) {
                responseBuilder.addActivities(convertToProtoActivity(activity));
            } else if (element instanceof Leg leg) {
                responseBuilder.addLegs(convertToProtoLeg(leg, firstLeg));
                firstLeg = false;
            } else {
                throw new IllegalArgumentException("Unsupported PlanElement type: " + element.getClass().getName());
            }
        }
        responseBuilder.setJavaRoutingServiceSentResponseGrpc(responseSentForRust);
        responseBuilder.setRequestId(requestId);

        return responseBuilder.build();
    }

    private Routing.Leg convertToProtoLeg(Leg leg, boolean attachPreplanningHorizon) {
        Routing.Leg.Builder legBuilder = Routing.Leg.newBuilder().setMode(leg.getMode()).setTravTime((int) leg.getTravelTime().orElseThrow(() -> new IllegalArgumentException("Leg must have travel time")));
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

//        if (attachPreplanningHorizon) {
//            legBuilder.putAttributes("preplanningHorizon", Routing.AttributeValue.newBuilder().setIntValue(preplanningHorizon).build());
//        }

        Routing.GenericRoute.Builder protoGenericRoute = Routing.GenericRoute.newBuilder().setStartLink(leg.getRoute().getStartLinkId().toString()).setEndLink(leg.getRoute().getEndLinkId().toString()).setDistance(leg.getRoute().getDistance());
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
        builder.setActType(activity.getType()).setLinkId(activity.getLinkId().toString()).setX(activity.getCoord().getX()).setY(activity.getCoord().getY());

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

    private void continuousRoutingTimeLoggingLoop() {
        DateTimeFormatter dateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd_HH-mm-ss");
        String t = LocalDateTime.now().format(dateTimeFormatter);
        String outputFile = config.controller().getOutputDirectory()
                + "/java-routing-time-profiling-"
                + runContext
                + "-"
                + t
                + ".csv";

        log.info("Starting async java routing time profiling writer to: {}", outputFile);

        try (BufferedWriter writer = Files.newBufferedWriter(Paths.get(outputFile)); CSVPrinter csv = new CSVPrinter(writer, CSVFormat.DEFAULT.builder().setHeader("requestId", "thread", "requestNow", "departure_time", "from", "to", "rustRouteCallStartRealtime", "rustGRPCRequestSendStartRealtime", "requestReceived", "bindWaitNs", "hadToWaitForSnapshot", "createCarRouteRequest", "calcRoute", "createCarResponse", "responseSent", "responseSentForRustDelta", "requestDeliveryRustToJavaLatency", "javaTotal", "queueSize", "activeCount", "taskCount", "completedTaskCount").get())) {

            while (routingTimeLoggingIsRunning || !routingTimeProfilingQueue.isEmpty()) {
                RoutingTimeProfilingEntry entry = routingTimeProfilingQueue.poll(); // Holt den nächsten Eintrag ohne zu blockieren
                if (entry != null) {
                    csv.printRecord(entry.requestId(), entry.thread(), entry.routingRequestNow(), entry.departureTime(), entry.from(), entry.to(), entry.rustRouteCallStartRealtime(), entry.rustGRPCRequestSendStartRealtime(), entry.requestReceived(), entry.bindWaitNs(), entry.hadToWaitForSnapshot(), entry.createCarRouteRequest(), entry.calcRoute(), entry.createCarResponse(), entry.responseSent(), entry.responseSentForRustDelta(), entry.requestDeliveryRustToJavaLatency(), entry.javaTotal(), entry.queueSize(), entry.activeCount(), entry.taskCount(), entry.completedTaskCount());
                } else {
                    Thread.sleep(100); // Kurz warten, wenn die Queue leer ist
                }
            }
            csv.flush();
        } catch (IOException | InterruptedException e) {
            log.error("Error in profiling writer thread", e);
            Thread.currentThread().interrupt();
        }
    }

    // Profiling von Routen 1.Zeit (...) 2.Inhalt (Request -> Response(Ergebnis)),
    // Updates/Snapshots 1.Zeit(..., Snapshot erzeugen/publishen, Wartezeiten auf Snapshot(Wie viele, wie lange)) 2.Inhalt (Erzeugter Snapshot, TTC/LTT Veränderungen),
    // Threading (QueueSize, Worker im Durchschnitt)  int gRPRQueueSize, int requestsInProgressCount, long taskCount, long completedTaskCount, long totalTaskCount

    private record RoutingTimeProfilingEntry(String requestId, String thread, long routingRequestNow,
                                             long departureTime, String from, String to,
                                             long rustRouteCallStartRealtime, long rustGRPCRequestSendStartRealtime,
                                             long requestReceived, long bindWaitNs, boolean hadToWaitForSnapshot,
                                             long createCarRouteRequest, long calcRoute, long createCarResponse,
                                             long responseSent, long responseSentForRustDelta,
                                             long requestDeliveryRustToJavaLatency, long javaTotal, int queueSize,
                                             int activeCount, long taskCount, long completedTaskCount) {
    }

    private static String uuidBytesToString(com.google.protobuf.ByteString bytes) {
        byte[] arr = bytes.toByteArray();
        if (arr.length != 16) {
            throw new IllegalArgumentException("request_id must contain exactly 16 bytes for a UUID, but got " + arr.length);
        }

        ByteBuffer bb = ByteBuffer.wrap(arr);
        long high = bb.getLong();
        long low = bb.getLong();
        return new UUID(high, low).toString();
    }
}