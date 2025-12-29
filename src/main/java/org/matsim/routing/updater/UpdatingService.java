package org.matsim.routing.updater;

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
import org.matsim.api.core.v01.events.VehicleEntersTrafficEvent;
import org.matsim.api.core.v01.events.VehicleLeavesTrafficEvent;
import org.matsim.api.core.v01.network.Link;
import org.matsim.core.api.experimental.events.EventsManager;
import org.matsim.core.config.Config;
import org.matsim.core.trafficmonitoring.TravelTimeCalculator;
import event_sharing.EventSharingServiceGrpc;
import event_sharing.EventSharing.*;

import java.math.BigInteger;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Future;

public class UpdatingService extends EventSharingServiceGrpc.EventSharingServiceImplBase {
    private static final Logger log = LogManager.getLogger(UpdatingService.class);
    private final ThreadLocal<Scenario> scenario;
    private final TravelTimeCalculator sharedTravelTimeCalculator;
    private final EventsManager sharedEventsManager;
    //private final ThreadLocal<SimpleTravelTimeAggregator> aggregator;
    private final Runnable shutdown;
    private final Config config;
    private final ConcurrentMap<String, Integer> threadNums = new ConcurrentHashMap<>();
    private final ConcurrentMap<Integer, List<ProfilingEntry>> profilingEntries = new ConcurrentHashMap<>(600_000);
    private int lastNow = -1;
    private long now = 0;
    private final ExecutorService updaterExecutor;
    // globaler Zähler: wie oft LinkEnter für denselben Link aufgetreten ist, seit letztem LinkLeave
    private final ConcurrentMap<String, Integer> linkEnterCountsSinceLastLeave = new ConcurrentHashMap<>();

    public UpdatingService(TravelTimeCalculator sharedTravelTimeCalculator,
                           EventsManager sharedEventsManager,
                           ThreadLocal<Scenario> scenarioThreadLocal,
                           Runnable shutdown,
                           Config config,
                           ExecutorService updaterExecutor) {
        this.scenario = scenarioThreadLocal;
        this.sharedTravelTimeCalculator = sharedTravelTimeCalculator;
        this.sharedEventsManager = sharedEventsManager;
        this.shutdown = shutdown;
        this.config = config;
        this.updaterExecutor = updaterExecutor;
    }

    /**
     * Initializes the service by loading the Travel Time Calculator, Events Manager and scenario.
     * This method should be called before any updating requests are processed.
     */
    public void init() {
        //this.sharedTravelTimeCalculator;
        this.scenario.get();
        //eventsManager.get().addHandler(travelTimeCalculator.get());
        //eventsManager.get().addHandler(aggregator.get());
    }

    Map<String, Integer> linkCountsGlobal = new HashMap<>();

    @Override
    public void shutdown(Empty request, StreamObserver<Empty> responseObserver) {
        log.info("Received shutdown request");
//        writeProfilingEntries();

        Map<String, Integer> linkCounts = new HashMap<>();
        int linkCountMax = 0;
        String linkIdMax = null;

        for (Map.Entry<String, Integer> e : linkCountsGlobal.entrySet()) {
            if (e.getValue() > linkCountMax) {
                linkCountMax = e.getValue();
                linkIdMax = e.getKey();
            }
        }

        // linkCountMax enthält jetzt die höchste Häufigkeit, linkIdMax die entsprechende LinkId
        log.info("Most frequent link {} occurred {} times.", linkIdMax, linkCountMax);

        assert linkIdMax != null;
        Link link = scenario.get().getNetwork().getLinks().get(Id.createLinkId(linkIdMax));

        double t1 = sharedTravelTimeCalculator.getLinkTravelTimes().getLinkTravelTime(link, 0, null, null);
        double t2 = sharedTravelTimeCalculator.getLinkTravelTimes().getLinkTravelTime(link, now / 2.0, null, null);
        double t3 = sharedTravelTimeCalculator.getLinkTravelTimes().getLinkTravelTime(link, now, null, null);
        double t4 = sharedTravelTimeCalculator.getLinkTravelTimes().getLinkTravelTime(link, 27232, null, null);

//        double t1 = aggregator.get().getSnapshotForTime(0).getLinkTravelTime(link, 0, null, null);
//        double t2 = aggregator.get().getSnapshotForTime(now / 2.0).getLinkTravelTime(link, now / 2.0, null, null);
//        double t3 = aggregator.get().getSnapshotForTime(now).getLinkTravelTime(link, now, null, null);
//        double t4 = aggregator.get().getSnapshotForTime(27232).getLinkTravelTime(link, 27232, null, null);

        System.out.println("Final TravelTime start/middle/end/27232: " + t1 + "\t" + t2 + "\t" + t3 + "\t" + t4);
//      Final TravelTime start/middle/end/27232: 13.338	14.0	13.338	31.122
//      2025-12-28T14:36:24,740  INFO UpdatingService:97 Most frequent link 462101683 occurred 540 times.
//      Final TravelTime start/middle/end/27232: 13.338	14.0	13.338	21.381
//      2025-12-28T14:38:51,213  INFO UpdatingService:98 Most frequent link 253772079 occurred 542 times.
//      Final TravelTime start/middle/end/27232: 13.477	14.0	13.477	87.331

        log.info("Shutting down updating service");
        responseObserver.onNext(Empty.getDefaultInstance());
        responseObserver.onCompleted();
        new Thread(shutdown).start();
    }

    @Override
    public void updateRouterSingleEvent(Request request, StreamObserver<Ack> responseObserver) {
        Future<Ack> fut = updaterExecutor.submit(() -> {

            processEvent(request);

            // nehme Zeit der letzten Request im Batch als Snapshot-Zeit
//            int snapshotTime = 0;
//            snapshotTime = request.getNow();
//            // Erzeuge zeitabhängigen Snapshot
//            aggregator.get().updateSnapshot(snapshotTime);

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
            for (Request request : batchRequest.getRequestsList()) {
//                if (threadNum == 0 && lastNow < request.getNow() && lastNow / 3600 != request.getNow() / 3600) {
//                    log.info("Received event for Router update for simulation hour {}:00", String.format("%02d", request.getNow() / 3600));
//                    lastNow = request.getNow();
//                }

                // Zähle Link-IDs im aktuellen Batch und bestimme Maximalwert + zugehörige LinkId

                String linkId = request.getLinkId();
//              linkCounts.merge(linkId, 1, Integer::sum);
                linkCountsGlobal.merge(linkId, 1, Integer::sum);

//                for (Map.Entry<String, Integer> e : linkCounts.entrySet()) {
//                    if (e.getValue() > linkCountMax) {
//                        linkCountMax = e.getValue();
//                        linkIdMax = e.getKey();
//                    }
//                }
                processEvent(request);
            }

            // nehme Zeit der letzten Request im Batch als Snapshot-Zeit
//            int snapshotTime = 0;
//            if (!batchRequest.getRequestsList().isEmpty()) {
//                snapshotTime = batchRequest.getRequestsList().getLast().getNow();
//            }
//            // Erzeuge zeitabhängigen Snapshot
//            aggregator.get().updateSnapshot(snapshotTime);

            now = batchRequest.getRequestsList().getLast().getNow();

//            // linkCountMax enthält jetzt die höchste Häufigkeit, linkIdMax die entsprechende LinkId
//            log.info("Most frequent link {} occurred {} times.", linkIdMax, linkCountMax);
//
//            assert linkIdMax != null;
//            Link link = scenario.get().getNetwork().getLinks().get(Id.createLinkId(linkIdMax));
//
//            double t1 = sharedTravelTimeCalculator.getLinkTravelTimes().getLinkTravelTime(link, 0, null, null);
//            double t2 = sharedTravelTimeCalculator.getLinkTravelTimes().getLinkTravelTime(link, now / 2.0, null, null);
//            double t3 = sharedTravelTimeCalculator.getLinkTravelTimes().getLinkTravelTime(link, now, null, null);
//            double t4 = sharedTravelTimeCalculator.getLinkTravelTimes().getLinkTravelTime(link, 27232, null, null);

//            double t1 = aggregator.get().getSnapshotForTime(0).getLinkTravelTime(link, 0, null, null);
//            double t2 = aggregator.get().getSnapshotForTime(now / 2.0).getLinkTravelTime(link, now / 2.0, null, null);
//            double t3 = aggregator.get().getSnapshotForTime(now).getLinkTravelTime(link, now, null, null);
//            double t4 = aggregator.get().getSnapshotForTime(27232).getLinkTravelTime(link, 27232, null, null);

//            System.out.println("TravelTime start/middle/end/27232: " + t1 + "\t" + t2 + "\t" + t3 + "\t" + t4);


            return Ack.newBuilder()
                    .setMessageReceived(true)
                    .setRequestId(batchRequest.getRequestsList().isEmpty() ? ByteString.EMPTY : batchRequest.getRequestId())
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

        // TODO: Optimize profiling for batch requests (batchId, per-request timing, profiling a batch not single events, ...)
//        for (Request request : batchRequest.getRequestsList()) {
//            ByteString requestId = request.getRequestId();
//            var p = new ProfilingEntry(threadNum, request.getNow(), request.getLinkType(), request.getLinkId(), request.getVehicleId(), startTime, endTime - startTime, requestId);
//            pe.add(p);
//        }
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
            sharedEventsManager.processEvent(linkEnterEvent);
        } else if (request.getEventType().equals("left link") && !request.getLinkId().isEmpty() && !request.getVehicleId().isEmpty()) {
            linkEnterCountsSinceLastLeave.remove(request.getVehicleId());
//              System.out.println("EventLinkId: " + request.getLinkId() + "    EventVehicleId: " + request.getVehicleId() + "    EventType: " + request.getEventType() + "\t EventNow: " + request.getNow());
            LinkLeaveEvent linkLeaveEvent = new LinkLeaveEvent(request.getNow(), Id.createVehicleId(request.getVehicleId()), Id.createLinkId(request.getLinkId()));
//              System.out.println("LinkLeaveEvent: " + linkLeaveEvent);
            sharedEventsManager.processEvent(linkLeaveEvent);
        } else if (request.getEventType().equals("vehicle enters traffic") && !request.getLinkId().isEmpty() && !request.getVehicleId().isEmpty()) {
//              System.out.println("EventLinkId: " + request.getLinkId() + "    EventVehicleId: " + request.getVehicleId() + "    EventLinkType: " + request.getLinkType());
            VehicleEntersTrafficEvent vehicleEntersTrafficEvent = new VehicleEntersTrafficEvent(request.getNow(), Id.createPersonId(request.getDriverId()),
                    Id.createLinkId(request.getLinkId()), Id.createVehicleId(request.getVehicleId()), request.getNetworkMode(), request.getRelativePositionOnLink());
//              System.out.println("VehicleEntersTrafficEvent: " + vehicleEntersTrafficEvent);
            sharedEventsManager.processEvent(vehicleEntersTrafficEvent);
        } else if (request.getEventType().equals("vehicle leaves traffic") && !request.getLinkId().isEmpty() && !request.getVehicleId().isEmpty()) {
//              System.out.println("EventLinkId: " + request.getLinkId() + "    EventVehicleId: " + request.getVehicleId() + "    EventLinkType: " + request.getLinkType());
            VehicleLeavesTrafficEvent vehicleLeavesTrafficEvent = new VehicleLeavesTrafficEvent(request.getNow(), Id.createPersonId(request.getDriverId()),
                    Id.createLinkId(request.getLinkId()), Id.createVehicleId(request.getVehicleId()), request.getNetworkMode(), request.getRelativePositionOnLink());
//              System.out.println("VehicleLeavesTrafficEvent: " + vehicleLeavesTrafficEvent);
            sharedEventsManager.processEvent(vehicleLeavesTrafficEvent);
        } else {
            log.warn("Error with Event: LinkType: {}, LinkId: {}, VehicleId: {}!", request.getEventType(), request.getLinkId(), request.getVehicleId());
        }

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

    private static void pairEnterLeave(List<Request> requests) {
        // key = vehicleId|linkId
        Map<String, Integer> openEnters = new HashMap<>();
        for (int i = 0; i < requests.size(); i++) {
            Request r = requests.get(i);
            if (!"entered link".equals(r.getEventType()) && !"left link".equals(r.getEventType())) {
                continue;
            }
            String key = r.getVehicleId() + "|" + r.getLinkId();

            if ("entered link".equals(r.getEventType())) {
                openEnters.merge(key, 1, Integer::sum);
            } else { // left link
                Integer cnt = openEnters.getOrDefault(key, 0);
                if (cnt > 0) {
                    // vorhandenes Enter vorhanden -> konsumiere es
                    if (cnt == 1) openEnters.remove(key); else openEnters.put(key, cnt - 1);
                } else {
                    // kein vorheriges Enter: suche nächstes Enter und verschiebe es an Position i
                    int found = -1;
                    for (int j = i + 1; j < requests.size(); j++) {
                        Request r2 = requests.get(j);
                        if ("entered link".equals(r2.getEventType())
                                && r.getVehicleId().equals(r2.getVehicleId())
                                && r.getLinkId().equals(r2.getLinkId())) {
                            found = j;
                            break;
                        }
                    }
                    if (found != -1) {
                        Request enterReq = requests.remove(found);
                        requests.add(i, enterReq); // verschiebe Enter vor die Leave
                        // nun zählt das enter als geöffnet; erhöhe Zähler entsprechend
                        openEnters.merge(key, 1, Integer::sum);
                        // i bleibt auf der Leave-Position +1 im nächsten Loop-Schritt; der gerade eingefügte Enter wurde bereits vor der Leave platziert
                    } else {
                        // kein passendes Enter gefunden: logge kurz, lasse Leave stehen
                        // (alternativ: droppen oder anderweitig behandeln)
                         System.out.println("Unpaired leave found for " + key + " at index " + i);
                    }
                }
            }
        }
    }

}
