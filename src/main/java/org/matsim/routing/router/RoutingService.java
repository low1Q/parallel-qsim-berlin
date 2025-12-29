package org.matsim.routing.router;

import com.google.inject.Inject;
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
import org.matsim.api.core.v01.network.Link;
import org.matsim.api.core.v01.population.Activity;
import org.matsim.api.core.v01.population.Leg;
import org.matsim.api.core.v01.population.Person;
import org.matsim.api.core.v01.population.PlanElement;
import org.matsim.core.config.Config;
import org.matsim.core.config.ConfigReader;
import org.matsim.core.config.ConfigUtils;
import org.matsim.core.config.ConfigWriter;
import org.matsim.core.controler.*;
import org.matsim.core.population.routes.NetworkRoute;
import org.matsim.core.router.RoutingModule;
import org.matsim.core.router.RoutingRequest;
import org.matsim.core.router.costcalculators.TravelDisutilityFactory;
import org.matsim.core.router.util.LeastCostPathCalculatorFactory;
import org.matsim.core.router.util.TravelTime;
import org.matsim.core.scenario.ScenarioUtils;
import org.matsim.facilities.*;
import org.matsim.utils.objectattributes.attributable.Attributes;
import org.matsim.vehicles.*;
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
    private final ThreadLocal<Scenario> scenario;
    private final RoutingModule sharedCarRouter;
    private final Runnable shutdown;
    private final Config config;
    private final ConcurrentMap<String, Integer> threadNums = new ConcurrentHashMap<>();
    private final ConcurrentMap<Integer, List<ProfilingEntry>> profilingEntries = new ConcurrentHashMap<>(600_000);
    private int lastNow = -1;
    @Inject LeastCostPathCalculatorFactory pathCalculatorFactory;
    @Inject private Map<String, TravelTime> travelTime ;
    @Inject private Map<String, TravelDisutilityFactory> travelDisutilityFactories ;

//    private RoutingService(ThreadLocal<RoutingModule> carRouterThreadLocal, ThreadLocal<Scenario> scenarioThreadLocal, Runnable shutdown, Config config) {
//        this.carRouter = carRouterThreadLocal;
//        this.scenario = scenarioThreadLocal;
//        this.shutdown = shutdown;
//        this.config = config;
//    }

    public RoutingService(RoutingModule sharedCarRouter,
                          ThreadLocal<RoutingModule> carRouter,
                          ThreadLocal<Scenario> scenarioThreadLocal,
                          Runnable shutdown,
                          Config config) {
        this.sharedCarRouter = sharedCarRouter;
        this.carRouter = carRouter;
        this.scenario = scenarioThreadLocal;
        this.shutdown = shutdown;
        this.config = config;
    }

    /**
     * Initializes the service by loading the car router and scenario.
     * This method should be called before any routing requests are processed.
     */
    public void init() {
        this.carRouter.get();
        this.scenario.get();
        prepareVehicles();
    }

    private void prepareVehicles() {
        for (Person person : scenario.get().getPopulation().getPersons().values()) {
            Id<Vehicle> vehicleId = VehicleUtils.getVehicleId(person, "car");
            createAndAddVehicleForModeCar(vehicleId, person);
        }
    }

    private void createAndAddVehicleForModeCar(Id<Vehicle> vehicleId, Person person) {
        if (!scenario.get().getVehicles().getVehicles().containsKey(vehicleId)) {
            Id<VehicleType> carTypeId = Id.create("car", VehicleType.class);
            VehicleType carType = scenario.get().getVehicles().getVehicleTypes().get(carTypeId);
            Vehicle vehicle = VehicleUtils.getFactory().createVehicle(VehicleUtils.getVehicleId(person, "car"), carType);
            scenario.get().getVehicles().addVehicle(vehicle);
        }
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

    @Override
    public void getRoute(Routing.Request request, StreamObserver<Routing.Response> responseObserver) {
        Integer threadNum = threadNums.computeIfAbsent(Thread.currentThread().getName(), s -> Integer.valueOf(s.substring(s.lastIndexOf('-') + 1)));
        List<ProfilingEntry> pe = profilingEntries.computeIfAbsent(threadNum, s -> new ArrayList<>());

        if (threadNum == 0 && lastNow < request.getNow() && lastNow / 3600 != request.getNow() / 3600) {
            log.info("Received route request for simulation hour {}:00", String.format("%02d", request.getNow() / 3600));
            lastNow = request.getNow();
        }

        ByteString requestId = request.getRequestId();

        long startTime = System.nanoTime();
        RoutingRequest carRouteRequest = createCarRouteRequest(request);
//        TravelTime travelTimee = travelTime.get( TransportMode.car );
//        TravelDisutility travelDisutility = travelDisutilityFactories.get( TransportMode.car ).createTravelDisutility( travelTime.get( TransportMode.car ) ) ;
//        LeastCostPathCalculator pathCalculator = pathCalculatorFactory.createPathCalculator(scenario.get().getNetwork(), travelDisutility, travelTimee );
        List<? extends PlanElement> planElements = carRouter.get().calcRoute(carRouteRequest);
        Routing.Response response = convertToProtoResponse(planElements, requestId);
        responseObserver.onNext(response);
        responseObserver.onCompleted();

        long endTime = System.nanoTime();

        int travelTimes = response.getLegsList().stream().mapToInt(Routing.Leg::getTravTime).sum();
        var p = new ProfilingEntry(threadNum, request.getNow(), request.getDepartureTime(), request.getFromLinkId(), request.getToLinkId(), startTime, endTime - startTime, travelTimes, requestId);
        pe.add(p);
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
            if (value instanceof String) {
                legBuilder.putAttributes(stringObjectEntry.getKey(), Routing.AttributeValue.newBuilder().setStringValue((String) value).build());
            } else if (value instanceof Double) {
                legBuilder.putAttributes(stringObjectEntry.getKey(), Routing.AttributeValue.newBuilder().setDoubleValue((Double) value).build());
            } else if (value instanceof Integer) {
                legBuilder.putAttributes(stringObjectEntry.getKey(), Routing.AttributeValue.newBuilder().setIntValue((Integer) value).build());
            } else if (value instanceof Boolean) {
                legBuilder.putAttributes(stringObjectEntry.getKey(), Routing.AttributeValue.newBuilder().setBoolValue((Boolean) value).build());
            } else {
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
            if (!(networkRoute.getStartLinkId() ==networkRoute.getEndLinkId())) {
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
            person = scenario.get().getPopulation().getPersons().get(Id.createPersonId(personId));
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
             CSVPrinter csv = new CSVPrinter(writer, CSVFormat.DEFAULT.builder().setHeader("thread", "now", "departure_time", "from", "to", "start", "duration_ns", "travel_time_s", "request_id").build())) {
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
            return new RoutingService(null, carRouterThreadLocal, scenarioThreadLocal, shutdown, config);
        }
    }

    private record ProfilingEntry(int thread, int simulationNow, long departureTime, String from, String to,
                                  long start, long duration, int travelTime, ByteString requestId) {

    }
}