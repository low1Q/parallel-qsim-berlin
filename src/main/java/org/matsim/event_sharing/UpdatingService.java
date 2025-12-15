package org.matsim.event_sharing;

import com.google.inject.Key;
import com.google.inject.name.Names;
import com.google.protobuf.ByteString;
import com.google.protobuf.Empty;
import io.grpc.stub.StreamObserver;
import org.apache.commons.csv.CSVFormat;
import org.apache.commons.csv.CSVPrinter;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.matsim.api.core.v01.Id;
import org.matsim.api.core.v01.Scenario;
import org.matsim.api.core.v01.events.LinkEnterEvent;
import org.matsim.api.core.v01.events.LinkLeaveEvent;
import org.matsim.api.core.v01.network.Link;
import org.matsim.api.core.v01.population.Person;
import org.matsim.core.api.experimental.events.EventsManager;
import org.matsim.core.config.Config;
import org.matsim.core.config.ConfigReader;
import org.matsim.core.config.ConfigUtils;
import org.matsim.core.config.ConfigWriter;
import org.matsim.core.controler.ControllerUtils;
import org.matsim.core.controler.OutputDirectoryHierarchy;
import org.matsim.core.events.EventsUtils;
import org.matsim.core.scenario.ScenarioUtils;
import org.matsim.core.trafficmonitoring.TravelTimeCalculator;
import event_sharing.EventSharingServiceGrpc;
import event_sharing.EventSharing;
import org.matsim.vehicles.*;

import java.io.ByteArrayOutputStream;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.math.BigInteger;
import java.net.URL;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;
import java.util.concurrent.atomic.AtomicReference;

public class UpdatingService extends EventSharingServiceGrpc.EventSharingServiceImplBase {
    private static final Logger log = LogManager.getLogger(UpdatingService.class);
    private final ThreadLocal<Scenario> scenario;
    private final ThreadLocal<TravelTimeCalculator> travelTimeCalculator;
    private final ThreadLocal<EventsManager> eventsManager;
    private final Runnable shutdown;
    private final Config config;
    private final ConcurrentMap<String, Integer> threadNums = new ConcurrentHashMap<>();
    private final ConcurrentMap<Integer, List<ProfilingEntry>> profilingEntries = new ConcurrentHashMap<>(600_000);
    private int lastNow = -1;

    private UpdatingService(ThreadLocal<TravelTimeCalculator> travelTimeCalculatorThreadLocal, ThreadLocal<EventsManager> eventsManagerThreadLocal, ThreadLocal<Scenario> scenarioThreadLocal, Runnable shutdown, Config config) {
        this.scenario = scenarioThreadLocal;
        this.travelTimeCalculator = travelTimeCalculatorThreadLocal;
        this.eventsManager = eventsManagerThreadLocal;
        this.shutdown = shutdown;
        this.config = config;
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

    /**
     * Initializes the service by loading the Travel Time Calculator, Events Manager and scenario.
     * This method should be called before any updating requests are processed.
     */
    public void init() {
        this.travelTimeCalculator.get();
        this.eventsManager.get();
        this.scenario.get();
        eventsManager.get().addHandler(travelTimeCalculator.get());
        prepareVehicles();



    }

    Map<String,Integer> linkCountsGlobal = new HashMap<>();

    @Override
    public void shutdown(Empty request, StreamObserver<Empty> responseObserver) {
        log.info("Received shutdown request");
//        writeProfilingEntries();

        Map<String,Integer> linkCounts = new HashMap<>();
        int linkCountMax = 0;
        int linkCountMaxMinus1 = 0;
        String linkIdMax = null;
        String linkIdMaxMinus1 = null;

        for (Map.Entry<String,Integer> e : linkCountsGlobal.entrySet()) {
            if (e.getValue() > linkCountMax) {
                linkCountMax = e.getValue();
                linkIdMax = e.getKey();
            }
        }
        linkCountsGlobal.remove(linkIdMax, linkCountMax);
        for (Map.Entry<String,Integer> e : linkCountsGlobal.entrySet()) {
            if (e.getValue() > linkCountMaxMinus1) {
                linkCountMaxMinus1 = e.getValue();
                linkIdMaxMinus1 = e.getKey();
            }
        }

        // linkCountMax enthält jetzt die höchste Häufigkeit, linkIdMax die entsprechende LinkId
        log.info("Most frequent link {} occurred {} times and second most frequent link {} occured {} times.", linkIdMax, linkCountMax, linkIdMaxMinus1, linkCountMaxMinus1);

        Link link = scenario.get().getNetwork().getLinks().get(Id.createLinkId(linkIdMax));
        Link toLink = scenario.get().getNetwork().getLinks().get(Id.createLinkId(linkIdMaxMinus1));

        //double linkToLinkTravelTime = travelTimeCalculator.get().getLinkToLinkTravelTimes().getLinkToLinkTravelTime(link, toLink, lastNow, null, null);
        double t1 = travelTimeCalculator.get().getLinkTravelTimes().getLinkTravelTime(link, 0, null, null);
        double t2 = travelTimeCalculator.get().getLinkTravelTimes().getLinkTravelTime(link, lastNow/2.0, null, null);
        double t3 = travelTimeCalculator.get().getLinkTravelTimes().getLinkTravelTime(link, lastNow, null, null);
        System.out.println("TravelTime start/middle/end: " + t1 + "\n" + t2 + "\n" + t3);
        //System.out.println("Link to Link TravelTime after: " + linkToLinkTravelTime);

        log.info("Shutting down updating service");
        responseObserver.onNext(Empty.getDefaultInstance());
        responseObserver.onCompleted();
        new Thread(shutdown).start();
    }

    @Override
    public void updateRouter(EventSharing.Request request, StreamObserver<EventSharing.Ack> responseObserver) {
        Integer threadNum = threadNums.computeIfAbsent(Thread.currentThread().getName(), s -> Integer.valueOf(s.substring(s.lastIndexOf('-') + 1)));
//        List<ProfilingEntry> pe = profilingEntries.computeIfAbsent(threadNum, s -> new ArrayList<>());

        if (threadNum == 0 && lastNow < request.getNow() && lastNow / 3600 != request.getNow() / 3600) {
            log.info("Received event for Router update for simulation hour {}:00", String.format("%02d", request.getNow() / 3600));
            lastNow = request.getNow();
        }

        ByteString requestId = request.getRequestId();

        long startTime = System.nanoTime();

        //System.out.println(request);

        if (request.getLinkType().equals("entered link") && !request.getLinkId().isEmpty() && !request.getVehicleId().isEmpty()) {
//            System.out.println("EventLinkId: " + request.getLinkId() + "    EventVehicleId: " + request.getVehicleId() + "    EventLinkType: " + request.getLinkType());
            LinkEnterEvent linkEnterEvent = new LinkEnterEvent(request.getNow(), Id.createVehicleId(request.getVehicleId()), Id.createLinkId(request.getLinkId()));
//           System.out.println("LinkEnterEvent: " + linkEnterEvent);
            eventsManager.get().processEvent(linkEnterEvent);
        } else if (request.getLinkType().equals("left link") && !request.getLinkId().isEmpty() && !request.getVehicleId().isEmpty()) {
//            System.out.println(request.getLinkId() + request.getVehicleId() + request.getLinkType());
            LinkLeaveEvent linkLeaveEvent = new LinkLeaveEvent(request.getNow(), Id.createVehicleId(request.getVehicleId()), Id.createLinkId(request.getLinkId()));
//            System.out.println("LinkLeftEvent: " + linkLeaveEvent);
            eventsManager.get().processEvent(linkLeaveEvent);
        } else {
            System.out.println("ERROR!");
            log.warn("Error with Event: LinkType: {}, LinkId: {}, VehicleId: {}!", request.getLinkType(), request.getLinkId(), request.getVehicleId());
        }
        EventSharing.Ack response = EventSharing.Ack.newBuilder().setMessageReceived(true).setRequestId(requestId).build();

        responseObserver.onNext(response);
        responseObserver.onCompleted();

        long endTime = System.nanoTime();

//        var p = new ProfilingEntry(threadNum, request.getNow(), request.getLinkType(), request.getLinkId(), request.getVehicleId(), startTime, endTime - startTime, requestId);
//        pe.add(p);
    }

    @Override
    public void updateRouterBatch(EventSharing.BatchRequest batchRequest, StreamObserver<EventSharing.Ack> responseObserver) {
        Integer threadNum = threadNums.computeIfAbsent(Thread.currentThread().getName(), s -> Integer.valueOf(s.substring(s.lastIndexOf('-') + 1)));
//        List<ProfilingEntry> pe = profilingEntries.computeIfAbsent(threadNum, s -> new ArrayList<>());

//        Map<String,Integer> linkCounts = new HashMap<>();
//        int linkCountMax = 0;
//        int linkCountMaxMinus1 = 0;
//        String linkIdMax = null;
//        String linkIdMaxMinus1 = null;

        long startTime = System.nanoTime();
        for (EventSharing.Request request : batchRequest.getRequestsList()) {
            if (threadNum == 0 && lastNow < request.getNow() && lastNow / 3600 != request.getNow() / 3600) {
                log.info("Received event for Router update for simulation hour {}:00", String.format("%02d", request.getNow() / 3600));
                lastNow = request.getNow();
            }

            // Zähle Link-IDs im aktuellen Batch und bestimme Maximalwert + zugehörige LinkId

            String linkId = request.getLinkId();
            if (linkId.isEmpty()) continue;
//            linkCounts.merge(linkId, 1, Integer::sum);
            linkCountsGlobal.merge(linkId, 1, Integer::sum);

//            for (Map.Entry<String,Integer> e : linkCounts.entrySet()) {
//                if (e.getValue() > linkCountMax) {
//                    linkCountMax = e.getValue();
//                    linkIdMax = e.getKey();
//                }
//            }
//            linkCounts.remove(linkIdMax, linkCountMax);
//            for (Map.Entry<String,Integer> e : linkCounts.entrySet()) {
//                if (e.getValue() > linkCountMaxMinus1) {
//                    linkCountMaxMinus1 = e.getValue();
//                    linkIdMaxMinus1 = e.getKey();
//                }
//            }

            if (request.getLinkType().equals("entered link") && !request.getLinkId().isEmpty() && !request.getVehicleId().isEmpty()) {
//            System.out.println("EventLinkId: " + request.getLinkId() + "    EventVehicleId: " + request.getVehicleId() + "    EventLinkType: " + request.getLinkType());
                LinkEnterEvent linkEnterEvent = new LinkEnterEvent(request.getNow(), Id.createVehicleId(request.getVehicleId()), Id.createLinkId(request.getLinkId()));
//           System.out.println("LinkEnterEvent: " + linkEnterEvent);
                eventsManager.get().processEvent(linkEnterEvent);
            } else if (request.getLinkType().equals("left link") && !request.getLinkId().isEmpty() && !request.getVehicleId().isEmpty()) {
//            System.out.println(request.getLinkId() + request.getVehicleId() + request.getLinkType());
                LinkLeaveEvent linkLeaveEvent = new LinkLeaveEvent(request.getNow(), Id.createVehicleId(request.getVehicleId()), Id.createLinkId(request.getLinkId()));
//            System.out.println("LinkLeftEvent: " + linkLeaveEvent);
                eventsManager.get().processEvent(linkLeaveEvent);
            } else {
                log.warn("Error with Event: LinkType: {}, LinkId: {}, VehicleId: {}!", request.getLinkType(), request.getLinkId(), request.getVehicleId());
            }
        }

        EventSharing.Ack response = EventSharing.Ack.newBuilder()
                .setMessageReceived(true)
                .setRequestId(batchRequest.getRequestsList().getFirst().getRequestId())
                .build();

        responseObserver.onNext(response);
        responseObserver.onCompleted();

        // linkCountMax enthält jetzt die höchste Häufigkeit, linkIdMax die entsprechende LinkId
//        log.info("Most frequent link {} occurred {} times and second most frequent link {} occured {} times.", linkIdMax, linkCountMax, linkIdMaxMinus1, linkCountMaxMinus1);
//
//        Link link = scenario.get().getNetwork().getLinks().get(Id.createLinkId(linkIdMax));
//        Link toLink = scenario.get().getNetwork().getLinks().get(Id.createLinkId(linkIdMaxMinus1));
//
//        //double linkToLinkTravelTime = travelTimeCalculator.get().getLinkToLinkTravelTimes().getLinkToLinkTravelTime(link, toLink, lastNow, null, null);
//        double t1 = travelTimeCalculator.get().getLinkTravelTimes().getLinkTravelTime(link, 0, null, null);
//        double t2 = travelTimeCalculator.get().getLinkTravelTimes().getLinkTravelTime(link, lastNow/2.0, null, null);
//        double t3 = travelTimeCalculator.get().getLinkTravelTimes().getLinkTravelTime(link, lastNow, null, null);
//
//        System.out.println("TravelTime start/middle/end: " + t1 + "\n" + t2 + "\n" + t3);

        long endTime = System.nanoTime();

        //double durationMs = (endTime - startTime) / 1_000_000.0;
        //if (batchRequest.getRequestsCount() >= 20000) {
        //    log.info("Batch with size {} done in {} ms", batchRequest.getRequestsList().size(), durationMs);
        //}
        //log.info("Batch with size {} done in {}ns", batchRequest.getRequestsList().size(), (endTime - startTime));

        // TODO: Optimize profiling for batch requests (batchId, per-request timing, profiling a batch not single events, ...)
//        for (EventSharing.Request request : batchRequest.getRequestsList()) {
//            ByteString requestId = request.getRequestId();
//            var p = new ProfilingEntry(threadNum, request.getNow(), request.getLinkType(), request.getLinkId(), request.getVehicleId(), startTime, endTime - startTime, requestId);
//            pe.add(p);
//        }
    }

    private void writeProfilingEntries() {
        DateTimeFormatter dateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd_HH-mm-ss");
        String t = LocalDateTime.now().format(dateTimeFormatter);
        String outputFile = config.controller().getOutputDirectory() + "/updating-profiling-" + t + ".csv";

        log.info("Writing profiling entries to file: {}", outputFile);

        List<ProfilingEntry> allEntries = this.profilingEntries.values().stream().flatMap(Collection::stream).sorted(Comparator.comparingInt(e -> e.simulationNow)).toList();

        try (java.io.BufferedWriter writer = java.nio.file.Files.newBufferedWriter(java.nio.file.Paths.get(outputFile));
             CSVPrinter csv = new CSVPrinter(writer, CSVFormat.DEFAULT.builder().setHeader("thread", "now", "linkType", "linkId", "vehicleId", "start", "duration_ns", "request_id").build())) {
            for (ProfilingEntry profilingEntry : allEntries) {
                csv.printRecord(
                        profilingEntry.thread,
                        profilingEntry.simulationNow,
                        profilingEntry.linkType,
                        profilingEntry.linkId,
                        profilingEntry.vehicleId,
                        profilingEntry.start,
                        profilingEntry.duration,
                        new BigInteger(1, profilingEntry.requestId.toByteArray()).toString()
                );
            }
        } catch (java.io.IOException e) {
            log.error("Error writing to file: {}", outputFile, e);
            throw new RuntimeException(e);
        }
    }

    public record Factory(Config config, Runnable shutdown) {
        public UpdatingService create() {
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
                reader.readStream(new java.io.ByteArrayInputStream(byteArray.get()));
                cfg.setContext(context);
                return cfg;
            });

            // ThreadLocal for Scenario and UpdatingService
            ThreadLocal<Scenario> scenarioThreadLocal = ThreadLocal.withInitial(() -> ScenarioUtils.loadScenario(configThreadLocal.get()));
            ThreadLocal<TravelTimeCalculator> travelTimeCalculatorThreadLocal = ThreadLocal.withInitial(() -> {
                Scenario scenario = scenarioThreadLocal.get();
                return ControllerUtils.createAdhocInjector(scenario).getInstance(Key.get(TravelTimeCalculator.class, Names.named("car")));
            });
//            ThreadLocal<EventsManager> eventsManagerThreadLocal = ThreadLocal.withInitial(() -> {
//                Scenario scenario = scenarioThreadLocal.get();
//                return ControllerUtils.createAdhocInjector(scenario).getInstance(Key.get(EventsManager.class));
//            });
            //Aus dem Injector holen?
            ThreadLocal<EventsManager> eventsManagerThreadLocal = ThreadLocal.withInitial(EventsUtils::createEventsManager);
            return new UpdatingService(travelTimeCalculatorThreadLocal, eventsManagerThreadLocal, scenarioThreadLocal, shutdown, config);
        }
    }

    private record ProfilingEntry(int thread, int simulationNow, String linkType, String linkId, String vehicleId, long start, long duration,
                                  ByteString requestId) {

    }
}
