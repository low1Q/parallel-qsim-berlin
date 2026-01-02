package org.matsim.routing.updater;

import com.google.inject.Injector;
import com.google.inject.Key;
import com.google.inject.name.Names;
import com.google.protobuf.ByteString;
import com.google.protobuf.Empty;
import io.grpc.stub.StreamObserver;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
//import org.matsim.api.core.v01.Id;
import org.matsim.api.core.v01.Id;
import org.matsim.api.core.v01.Scenario;
import org.matsim.api.core.v01.events.LinkEnterEvent;
import org.matsim.api.core.v01.events.LinkLeaveEvent;
import org.matsim.api.core.v01.events.VehicleEntersTrafficEvent;
import org.matsim.api.core.v01.events.VehicleLeavesTrafficEvent;
import org.matsim.api.core.v01.network.Link;
import org.matsim.core.api.experimental.events.EventsManager;
import org.matsim.core.config.Config;
import org.matsim.core.events.EventsUtils;
import org.matsim.core.trafficmonitoring.TravelTimeCalculator;
import event_sharing.EventSharingServiceGrpc;
import event_sharing.EventSharing.*;
import org.matsim.routing.router.HighPerformanceTravelTime;
import org.matsim.vehicles.Vehicle;

//import java.io.BufferedWriter;
//import java.io.IOException;
//import java.math.BigInteger;
//import java.nio.file.Files;
//import java.nio.file.Paths;
//import java.time.LocalDateTime;
//import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Future;

public class UpdatingService extends EventSharingServiceGrpc.EventSharingServiceImplBase {
    private static final Logger log = LogManager.getLogger(UpdatingService.class);
    private final Scenario scenario;
    private final Injector adhocInjector;
    private final TravelTimeCalculator travelTimeCalculator;
    private final EventsManager eventsManager;
    private final HighPerformanceTravelTime sharedTravelTime;
    //private final ThreadLocal<SimpleTravelTimeAggregator> aggregator;
    private final Runnable shutdown;
    private final Config config;
    private final ConcurrentMap<String, Integer> threadNums = new ConcurrentHashMap<>();
//    private final ConcurrentMap<Integer, List<ProfilingEntry>> profilingEntries = new ConcurrentHashMap<>(600_000);
//    private int lastNow = -1;
    private long now = 0;
    private final ExecutorService updaterExecutor;
    // globaler Zähler: wie oft LinkEnter für denselben Link aufgetreten ist, seit letztem LinkLeave
    private final ConcurrentMap<String, Integer> linkEnterCountsSinceLastLeave = new ConcurrentHashMap<>();
    private final Map<String, Integer> fastLinkToIndex; // String -> Array-Index
    private final double[] internalTravelTimes;         // Das Arbeits-Array
    private final Map<String, Id<Link>> linkIdCache;
    private final Map<String, Id<Vehicle>> vehicleIdCache;

    public UpdatingService(Scenario sharedScenario,
                           Injector adhocInjector, Runnable shutdown,
                           Config config,
                           ExecutorService updaterExecutor,
                           HighPerformanceTravelTime sharedTravelTime,
                           Map<String, Id<Link>> linkIdCache, Map<String, Id<Vehicle>> vehicleIdCache) {
        this.scenario = sharedScenario;
        this.adhocInjector = adhocInjector;
        this.shutdown = shutdown;
        this.config = config;
        this.updaterExecutor = updaterExecutor;
        this.sharedTravelTime = sharedTravelTime;
        this.linkIdCache = linkIdCache;
        this.vehicleIdCache = vehicleIdCache;

//        // 1. TTC und EventsManager hier drin erstellen
//// 1. Hole die Werte für unsere eigene Logik
//        TravelTimeCalculatorConfigGroup ttcConfig = config.travelTimeCalculator();
//        double binSize = ttcConfig.getTraveltimeBinSize();
//        int maxTime = ttcConfig.getMaxTime();
//// 1. Builder instanziieren
//        TravelTimeCalculator.Builder builder = new TravelTimeCalculator.Builder(scenario.getNetwork());
//// 2. Werte setzen (Vorsicht bei void-Methoden)
//        builder.setTimeslice(binSize);
//        builder.setMaxTime(maxTime); // Diese Methode ist void!
//        builder.setCalculateLinkTravelTimes(ttcConfig.isCalculateLinkTravelTimes());
//        builder.setCalculateLinkToLinkTravelTimes(ttcConfig.isCalculateLinkToLinkTravelTimes());
//
//// 3. Falls du die "configure" Logik aus der ConfigGroup übernehmen willst (wichtig für den Getter-Typ!):
//        builder.configure(ttcConfig);
//// 4. Endlich bauen
//        this.travelTimeCalculator = builder.build();
        this.eventsManager = EventsUtils.createEventsManager();
        this.travelTimeCalculator = adhocInjector.getInstance(Key.get(TravelTimeCalculator.class, Names.named("car")));
        this.eventsManager.addHandler(travelTimeCalculator);

        // Initialisiere den schnellen Index-Lookup einmalig
        this.fastLinkToIndex = new HashMap<>();
        Map<Id<Link>, Integer> matsimIndexMap = sharedTravelTime.getLinkIdToIndex();
        for (Map.Entry<Id<Link>, Integer> entry : matsimIndexMap.entrySet()) {
            this.fastLinkToIndex.put(entry.getKey().toString(), entry.getValue());
        }
        // Wir starten mit dem initialen Stand (Free-Speed)
        this.internalTravelTimes = sharedTravelTime.getCurrentTimesArray().clone();
    }

    /**
     * Initializes the service by loading the Travel Time Calculator, Events Manager and scenario.
     * This method should be called before any updating requests are processed.
     */
//    public void init() {
//        //this.sharedTravelTimeCalculator;
//        //this.scenario.get();
//        //eventsManager.get().addHandler(travelTimeCalculator.get());
//        //eventsManager.get().addHandler(aggregator.get());
//    }

    Map<String, Integer> linkCountsGlobal = new HashMap<>();

    @Override
    public void shutdown(Empty request, StreamObserver<Empty> responseObserver) {
        log.info("Received shutdown request");
//        writeProfilingEntries();

//        Map<String, Integer> linkCounts = new HashMap<>();
//        int linkCountMax = 0;
//        String linkIdMax = null;
//
//        for (Map.Entry<String, Integer> e : linkCountsGlobal.entrySet()) {
//            if (e.getValue() > linkCountMax) {
//                linkCountMax = e.getValue();
//                linkIdMax = e.getKey();
//            }
//        }

        // linkCountMax enthält jetzt die höchste Häufigkeit, linkIdMax die entsprechende LinkId
//        log.info("Most frequent link {} occurred {} times.", linkIdMax, linkCountMax);
//
//        assert linkIdMax != null;
//        Link link = scenario.getNetwork().getLinks().get(Id.createLinkId(linkIdMax));
//
//        double t1 = sharedTravelTime.getLinkTravelTime(link, 0, null, null);
//        double t2 = sharedTravelTime.getLinkTravelTime(link, now / 2.0, null, null);
//        double t3 = sharedTravelTime.getLinkTravelTime(link, now, null, null);
//        double t4 = sharedTravelTime.getLinkTravelTime(link, 27232, null, null);
//
//        System.out.println("Final TravelTime start/middle/end/27232: " + t1 + "\t" + t2 + "\t" + t3 + "\t" + t4);

        log.info("Shutting down updating service");
        responseObserver.onNext(Empty.getDefaultInstance());
        responseObserver.onCompleted();
        new Thread(shutdown).start();
    }

    @Override
    public void updateRouterSingleEvent(Request request, StreamObserver<Ack> responseObserver) {
        Future<Ack> fut = updaterExecutor.submit(() -> {

            Set<String> affectedLinkIds = new HashSet<>();
            // Link-Id für das spätere Snapshot-Update merken
            if (!request.getLinkId().isEmpty()) {
                affectedLinkIds.add(request.getLinkId());
            }

            processEvent(request);

            double timeNow = request.getNow();
            publishNewSnapshot(timeNow, affectedLinkIds);

            now = (long) timeNow;

            now = request.getNow();

            return Ack.newBuilder().
                    setMessageReceived(true).
                    build();
        });
        try {
            Ack response = fut.get(); // blockiert bis Task fertig -> Anfragen warten in SingleThread-Queue
            responseObserver.onNext(response);
            responseObserver.onCompleted();
        } catch (Exception e) {
            responseObserver.onError(e);
        }
    }

    @Override
    public void updateRouterBatch(BatchRequest batchRequest, StreamObserver<Ack> responseObserver) {
        Future<Ack> fut = updaterExecutor.submit(() -> {
//            Integer threadNum = threadNums.computeIfAbsent(Thread.currentThread().getName(), s -> Integer.valueOf(s.substring(s.lastIndexOf('-') + 1)));
//        List<ProfilingEntry> pe = profilingEntries.computeIfAbsent(threadNum, s -> new ArrayList<>());

//            Map<String, Integer> linkCounts = new HashMap<>();
//            int linkCountMax = 0;
//            String linkIdMax = null;

//        long startTime = System.nanoTime();
            // Kopiere und sortiere die Requests nach Zeit (aufsteigend), stabile Sortierung bewahrt Reihenfolge bei gleicher Zeit
//            List<Request> requests = new ArrayList<>(batchRequest.getRequestsList());
//            requests.sort(Comparator.comparingLong(Request::getNow));
//            System.out.println(requests);
            Set<String> affectedLinkIds = new HashSet<>();
            for (Request request : batchRequest.getRequestsList()) {
//                if (threadNum == 0 && lastNow < request.getNow() && lastNow / 3600 != request.getNow() / 3600) {
//                    log.info("Received event for Router update for simulation hour {}:00", String.format("%02d", request.getNow() / 3600));
//                    lastNow = request.getNow();
//                }

                // Zähle Link-IDs im aktuellen Batch und bestimme Maximalwert + zugehörige LinkId

//                String linkId = request.getLinkId();
//                linkCounts.merge(linkId, 1, Integer::sum);
//                linkCountsGlobal.merge(linkId, 1, Integer::sum);

//                for (Map.Entry<String, Integer> e : linkCounts.entrySet()) {
//                    if (e.getValue() > linkCountMax) {
//                        linkCountMax = e.getValue();
//                        linkIdMax = e.getKey();
//                    }
//                }
                // Link-Id für das spätere Snapshot-Update merken
                if (!request.getLinkId().isEmpty()) {
                    affectedLinkIds.add(request.getLinkId());
                }
                processEvent(request);
            }

            double timeNow = batchRequest.getRequestsList().getLast().getNow();
            publishNewSnapshot(timeNow, affectedLinkIds);

            now = (long) timeNow;

            // linkCountMax enthält jetzt die höchste Häufigkeit, linkIdMax die entsprechende LinkId
//            log.info("Most frequent link {} occurred {} times.", linkIdMax, linkCountMax);
//
//            assert linkIdMax != null;
//            Link link = scenario.getNetwork().getLinks().get(Id.createLinkId(linkIdMax));
//
//            double t1 = sharedTravelTime.getLinkTravelTime(link, 0, null, null);
//            double t2 = sharedTravelTime.getLinkTravelTime(link, now / 2.0, null, null);
//            double t3 = sharedTravelTime.getLinkTravelTime(link, now, null, null);
//            double t4 = sharedTravelTime.getLinkTravelTime(link, 27232, null, null);
//
//            System.out.println("Snapshot t=0 / t=now/2.0 / t=now / t=27232:\t" + t1 + "\t" + t2 + "\t" + t3 + "\t" + t4);
//
//            double ttc1 = travelTimeCalculator.getLinkTravelTimes().getLinkTravelTime(link, 0, null, null);
//            double ttc2 = travelTimeCalculator.getLinkTravelTimes().getLinkTravelTime(link, now / 2.0, null, null);
//            double ttc3 = travelTimeCalculator.getLinkTravelTimes().getLinkTravelTime(link, now, null, null);
//            double ttc4 = travelTimeCalculator.getLinkTravelTimes().getLinkTravelTime(link, 27232, null, null);
//
//            System.out.println("Calculator t=0 / t=now/2.0 / t=now / t=27232:\t" + ttc1 + "\t" + ttc2 + "\t" + ttc3 + "\t" + ttc4);


            return Ack.newBuilder()
                    .setMessageReceived(true)
                    //.setRequestId(batchRequest.getRequestsList().isEmpty() ? ByteString.EMPTY : batchRequest.getRequestId())
                    .build();
        });

        try {
            Ack response = fut.get(); // blockiert bis Task fertig -> Anfragen warten in SingleThread-Queue
            responseObserver.onNext(response);
            responseObserver.onCompleted();

        } catch (Exception e) {
            System.out.println("Exception in updateRouterBatch: " + e.getMessage());
            responseObserver.onError(e);
        }

//        long endTime = System.nanoTime();

        //double durationMs = (endTime - startTime) / 1_000_000.0;
        //if (batchRequest.getRequestsCount() >= 20000) {
        //    log.info("Batch with size {} done in {} ms", batchRequest.getRequestsList().size(), durationMs);
        //}
        //log.info("Batch with size {} done in {}ns", batchRequest.getRequestsList().size(), (endTime - startTime));

//        for (Request request : batchRequest.getRequestsList()) {
//            ByteString requestId = request.getRequestId();
//            var p = new ProfilingEntry(threadNum, request.getNow(), request.getLinkType(), request.getLinkId(), request.getVehicleId(), startTime, endTime - startTime, requestId);
//            pe.add(p);
//        }
    }

    /**
     * Erstellt einen neuen konsistenten Snapshot, aktualisiert aber nur die
     * Links, die im aktuellen Batch verändert wurden.
     */
    private void publishNewSnapshot(double timeNow, Collection<String> affectedLinkIds) {
        var linkTravelTimes = travelTimeCalculator.getLinkTravelTimes();
        var networkLinks = scenario.getNetwork().getLinks();

        // 1. Nur die betroffenen Indizes im Arbeits-Array aktualisieren
        for (String linkIdStr : affectedLinkIds) {
            Integer idx = fastLinkToIndex.get(linkIdStr);
            if (idx != null) {
                // Wir müssen den Link einmal für den Calculator holen
                // MATSim braucht hier leider das Id-Objekt oder die Link-Referenz
                Link link = networkLinks.get(Id.createLinkId(linkIdStr));
                if (link != null) {
                    // Wert aus dem MATSim-Calculator extrahieren
                    double travelTime = linkTravelTimes.getLinkTravelTime(link, timeNow, null, null);

                    // Im internen Array speichern
                    internalTravelTimes[idx] = travelTime;
                }
            }
        }

        // 2. Einen unmodifizierbaren Snapshot für die Routing-Threads veröffentlichen
        // wir schicken eine Kopie, damit die Routing-Threads einen stabilen Stand haben,
        // während wir im nächsten Batch das 'internalTravelTimes' weiter bearbeiten.
        sharedTravelTime.updateWithArray(internalTravelTimes.clone());

        //log.info("HPC-Snapshot published for {} links at t={}", affectedLinkIds.size(), timeNow);
    }

    private void processEvent(Request request) {
        if (request.getEventType().equals("entered link") && !request.getLinkId().isEmpty() && !request.getVehicleId().isEmpty()) {
            // Zähler pro Link erhöhen
            int cnt = linkEnterCountsSinceLastLeave.merge(request.getVehicleId(), 1, Integer::sum);
            if (cnt > 1) {
                log.warn("VehicleId {} received {} consecutive LinkEnter events without LinkLeave for time {}.", request.getVehicleId(), cnt, request.getNow());
            }
//          System.out.println("EventLinkId: " + request.getLinkId() + "    EventVehicleId: " + request.getVehicleId() + "    EventType: " + request.getEventType() + "\t EventNow: " + request.getNow());
            LinkEnterEvent linkEnterEvent = new LinkEnterEvent(request.getNow(), Id.createVehicleId(request.getVehicleId()), Id.createLinkId(request.getLinkId()));
//              System.out.println("LinkEnterEvent: " + linkEnterEvent);
            eventsManager.processEvent(linkEnterEvent);
        } else if (request.getEventType().equals("left link") && !request.getLinkId().isEmpty() && !request.getVehicleId().isEmpty()) {
            linkEnterCountsSinceLastLeave.remove(request.getVehicleId());
//              System.out.println("EventLinkId: " + request.getLinkId() + "    EventVehicleId: " + request.getVehicleId() + "    EventType: " + request.getEventType() + "\t EventNow: " + request.getNow());
            LinkLeaveEvent linkLeaveEvent = new LinkLeaveEvent(request.getNow(), Id.createVehicleId(request.getVehicleId()), Id.createLinkId(request.getLinkId()));
//              System.out.println("LinkLeaveEvent: " + linkLeaveEvent);
            eventsManager.processEvent(linkLeaveEvent);
        } else if (request.getEventType().equals("vehicle enters traffic") && !request.getLinkId().isEmpty() && !request.getVehicleId().isEmpty()) {
//              System.out.println("EventLinkId: " + request.getLinkId() + "    EventVehicleId: " + request.getVehicleId() + "    EventLinkType: " + request.getLinkType());
            VehicleEntersTrafficEvent vehicleEntersTrafficEvent = new VehicleEntersTrafficEvent(request.getNow(), Id.createPersonId(request.getDriverId()),
                    Id.createLinkId(request.getLinkId()), Id.createVehicleId(request.getVehicleId()), request.getNetworkMode(), request.getRelativePositionOnLink());
//              System.out.println("VehicleEntersTrafficEvent: " + vehicleEntersTrafficEvent);
            eventsManager.processEvent(vehicleEntersTrafficEvent);
        } else if (request.getEventType().equals("vehicle leaves traffic") && !request.getLinkId().isEmpty() && !request.getVehicleId().isEmpty()) {
//              System.out.println("EventLinkId: " + request.getLinkId() + "    EventVehicleId: " + request.getVehicleId() + "    EventLinkType: " + request.getLinkType());
            VehicleLeavesTrafficEvent vehicleLeavesTrafficEvent = new VehicleLeavesTrafficEvent(request.getNow(), Id.createPersonId(request.getDriverId()),
                    Id.createLinkId(request.getLinkId()), Id.createVehicleId(request.getVehicleId()), request.getNetworkMode(), request.getRelativePositionOnLink());
//              System.out.println("VehicleLeavesTrafficEvent: " + vehicleLeavesTrafficEvent);
            eventsManager.processEvent(vehicleLeavesTrafficEvent);
        } else {
            log.warn("Error with Event: LinkType: {}, LinkId: {}, VehicleId: {}!", request.getEventType(), request.getLinkId(), request.getVehicleId());
        }
    }

//    private void writeProfilingEntries() {
//        DateTimeFormatter dateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd_HH-mm-ss");
//        String t = LocalDateTime.now().format(dateTimeFormatter);
//        String outputFile = config.controller().getOutputDirectory() + "/updating-profiling-" + t + ".csv";
//
//        log.info("Writing profiling entries to file: {}", outputFile);
//
//        List<ProfilingEntry> allEntries = this.profilingEntries.values().stream().flatMap(Collection::stream).sorted(Comparator.comparingInt(e -> e.simulationNow)).toList();
//
//        try (BufferedWriter writer = Files.newBufferedWriter(Paths.get(outputFile));
//             CSVPrinter csv = new CSVPrinter(writer, CSVFormat.DEFAULT.builder().setHeader("thread", "now", "linkType", "linkId", "vehicleId", "start", "duration_ns", "request_id").build())) {
//            for (ProfilingEntry profilingEntry : allEntries) {
//                csv.printRecord(
//                        profilingEntry.thread,
//                        profilingEntry.simulationNow,
//                        profilingEntry.linkType,
//                        profilingEntry.linkId,
//                        profilingEntry.vehicleId,
//                        profilingEntry.start,
//                        profilingEntry.duration,
//                        new BigInteger(1, profilingEntry.requestId.toByteArray()).toString()
//                );
//            }
//        } catch (IOException e) {
//            log.error("Error writing to file: {}", outputFile, e);
//            throw new RuntimeException(e);
//        }
//    }

//    public record Factory(Config config, Runnable shutdown) {
//        public UpdatingService create() {
//            config.controller().setOverwriteFileSetting(OutputDirectoryHierarchy.OverwriteFileSetting.overwriteExistingFiles);
//
//            // Serialize config to byte array and create ThreadLocal copies
//            // This is necessary because the config is modified during scenario loading (consistency checks are added in Constructor of NewControler),
//            // consequently java.util.ConcurrentModificationException MIGHT be thrown (not always)
//            URL context = config.getContext();
//            ByteArrayOutputStream stream = new ByteArrayOutputStream();
//            Writer writer = new OutputStreamWriter(stream);
//            new ConfigWriter(config).writeStream(writer);
//            AtomicReference<byte[]> byteArray = new AtomicReference<>(stream.toByteArray());
//
//            ThreadLocal<Config> configThreadLocal = ThreadLocal.withInitial(() -> {
//                Config cfg = ConfigUtils.createConfig();
//                ConfigReader reader = new ConfigReader(cfg);
//                reader.readStream(new java.io.ByteArrayInputStream(byteArray.get()));
//                cfg.setContext(context);
//                return cfg;
//            });
//
//            // ThreadLocal for Scenario and UpdatingService
//            ThreadLocal<Scenario> scenarioThreadLocal = ThreadLocal.withInitial(() -> ScenarioUtils.loadScenario(configThreadLocal.get()));
//            ThreadLocal<TravelTimeCalculator> travelTimeCalculatorThreadLocal = ThreadLocal.withInitial(() -> {
//                Scenario scenario = scenarioThreadLocal.get();
//                return ControllerUtils.createAdhocInjector(scenario).getInstance(Key.get(TravelTimeCalculator.class, Names.named("car")));
//            });
//            ThreadLocal<EventsManager> eventsManagerThreadLocal = ThreadLocal.withInitial(EventsUtils::createEventsManager);
//            return new UpdatingService(travelTimeCalculatorThreadLocal, eventsManagerThreadLocal, scenarioThreadLocal, shutdown, config, null);
//        }
//    }

    private record ProfilingEntry(int thread, int simulationNow, String linkType, String linkId, String vehicleId,
                                  long start, long duration,
                                  ByteString requestId) {

    }
}
