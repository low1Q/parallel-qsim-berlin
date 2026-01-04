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
import org.matsim.api.core.v01.population.Person;
import org.matsim.core.api.experimental.events.EventsManager;
import org.matsim.core.config.Config;
import org.matsim.core.events.EventsUtils;
import org.matsim.core.router.util.TravelTime;
import org.matsim.core.trafficmonitoring.TravelTimeCalculator;
import event_sharing.EventSharingServiceGrpc;
import event_sharing.EventSharing.*;
import org.matsim.routing.router.TravelTimeSnapshot;
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
    private final TravelTimeSnapshot sharedTravelTime;
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
    private final Map<String, Integer> fastLinkToIndex; // String -> Array-Index     // Das Arbeits-Array
    private final Link[] indexToLink;
    private final Id<Link>[] indexToLinkId;
    private final Id<Vehicle>[] indexToVehicleId;
    private final Id<Person>[] indexToPersonId;

    private long lastSnapshotTime = 0;
    private final long MIN_SNAPSHOT_INTERVAL_MS = 200; // Snapshot max. 5x pro Sekunde
    private final Set<Integer> globalAffectedIndices = ConcurrentHashMap.newKeySet();
    private final double[] bufferA;
    private final double[] bufferB;
    private boolean usingBufferA = true;

    public UpdatingService(Scenario sharedScenario,
                           Injector adhocInjector, Runnable shutdown,
                           Config config,
                           ExecutorService updaterExecutor,
                           TravelTimeSnapshot sharedTravelTime,
                           Id<Link>[] indexToLinkId, Id<Vehicle>[] indexToVehicleId, Id<Person>[] indexToPersonId, Link[] indexToLink) {
        this.scenario = sharedScenario;
        this.adhocInjector = adhocInjector;
        this.shutdown = shutdown;
        this.config = config;
        this.updaterExecutor = updaterExecutor;
        this.sharedTravelTime = sharedTravelTime;
        this.indexToLinkId = indexToLinkId;
        this.indexToLink = indexToLink;
        this.indexToVehicleId = indexToVehicleId;
        this.indexToPersonId = indexToPersonId;
        this.eventsManager = EventsUtils.createEventsManager();
        this.travelTimeCalculator = adhocInjector.getInstance(Key.get(TravelTimeCalculator.class, Names.named("car")));
        this.eventsManager.addHandler(travelTimeCalculator);
        this.fastLinkToIndex = sharedTravelTime.getStringIdToIndex();
        int size = fastLinkToIndex.size();
        this.bufferA = new double[size];
        this.bufferB = new double[size];

        // Initiales Füllen mit Free-Speed
        log.info("Starting initial TravelTime setup...");
        var networkLinks = scenario.getNetwork().getLinks();
        for (Link link : networkLinks.values()) {
            Integer idx = fastLinkToIndex.get(link.getId().toString());
            if (idx != null) {
                double freeSpeedTime = link.getLength() / link.getFreespeed();
                // Beide Buffer initialisieren, damit sie identisch starten
                this.bufferA[idx] = freeSpeedTime;
                this.bufferB[idx] = freeSpeedTime;
            }
        }

        // Den ersten Buffer für die Router freigeben
        sharedTravelTime.updateWithArray(this.bufferA);
        log.info("Initial TravelTime setup complete with Double-Buffering.");
    }

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

// Wir nutzen jetzt Integer statt String für das Set
            Set<Integer> affectedIndices = new HashSet<>();

            // Merke dir den Index für das Reisezeit-Update
            // Hinweis: In Proto3 ist 0 der Default. Wenn Link 0 existiert, einfach adden.
            affectedIndices.add(request.getLinkId());

            processEvent(request);

            double timeNow = request.getNow();
            publishNewSnapshot(timeNow, affectedIndices);

            now = (long) timeNow;

            return Ack.newBuilder().
                    setSuccess(true).
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
        updaterExecutor.execute(() -> {
            try {
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
// Wir nutzen jetzt Integer statt String für das Set
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
// Merke dir den Index für das Reisezeit-Update
                // Hinweis: In Proto3 ist 0 der Default. Wenn Link 0 existiert, einfach adden.
                processEvent(request);
                globalAffectedIndices.add(request.getLinkId());
            }

            double timeNow = batchRequest.getRequestsList().getLast().getNow();

            // Snapshot-Throttling: Nur updaten wenn nötig UND Zeit abgelaufen
            long currentTime = System.currentTimeMillis();
            if (currentTime - lastSnapshotTime > MIN_SNAPSHOT_INTERVAL_MS) {
                List<Integer> toProcess = new ArrayList<>(globalAffectedIndices);
                globalAffectedIndices.clear();
                publishNewSnapshot(timeNow, toProcess);
                lastSnapshotTime = currentTime;
            }
            //publishNewSnapshot(timeNow, affectedIndices);

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

// blockiert bis Task fertig -> Anfragen warten in SingleThread-Queue
            responseObserver.onNext(Ack.newBuilder().setSuccess(true).build());
            responseObserver.onCompleted();
            //log.info("Completed processing batch of {} events.", batchRequest.getRequestsList().size());

        } catch (Exception e) {
            System.out.println("Exception in updateRouterBatch: " + e.getMessage());
            responseObserver.onError(e);
        }
    });
    }

    private void publishNewSnapshot(double timeNow, Collection<Integer> affectedIndices) {
        // 1. Bestimme, welches Array aktuell NICHT öffentlich ist (Back-Buffer)
        double[] backBuffer = usingBufferA ? bufferB : bufferA;
        double[] frontBuffer = usingBufferA ? bufferA : bufferB;

        // 2. Synchronisiere den Back-Buffer mit dem Front-Buffer
        // (Nur die Werte kopieren, kein neues Objekt erzeugen!)
        System.arraycopy(frontBuffer, 0, backBuffer, 0, frontBuffer.length);

        // 3. Nur die betroffenen Links im Back-Buffer aktualisieren
        var linkTravelTimes = travelTimeCalculator.getLinkTravelTimes();
        for (int idx : affectedIndices) {
            Link link = indexToLink[idx];
            if (link != null) {
                backBuffer[idx] = linkTravelTimes.getLinkTravelTime(link, timeNow, null, null);
            }
        }

        // 4. Atomarer Swap: Den Back-Buffer zum Front-Buffer machen
        sharedTravelTime.updateWithArray(backBuffer);

        // 5. Rollen für das nächste Mal tauschen
        usingBufferA = !usingBufferA;
    }


    private void processEvent(Request request) {

        int linkIdx = request.getLinkId();
        int vehIdx = request.getVehicleId();

        if (linkIdx >= indexToLink.length || vehIdx >= indexToVehicleId.length) {
            log.error("Received out-of-bounds index: Link {} (max {}), Vehicle {} (max {})",
                    linkIdx, indexToLink.length, vehIdx, indexToVehicleId.length);
            return;
        }

        Id<Link> linkId = indexToLinkId[request.getLinkId()];
        Id<Vehicle> vehicleId = indexToVehicleId[request.getVehicleId()];

        double now = request.getNow();

        // Der Switch auf Enums ist in Java extrem schnell (Jump Table)
        switch (request.getEventType()) {
            case ENTERED_LINK:
                //log.warn("EventType: {} for Link: {}", request.getEventType(), linkIdStr);
                // Logik für aufeinanderfolgende LinkEnters
//                int cnt = linkEnterCountsSinceLastLeave.merge(vehId, 1, Integer::sum);
//                if (cnt > 1) {
//                    log.warn("VehicleId {} received {} consecutive LinkEnter events without LinkLeave at t={}.", vehIdStr, cnt, now);
//                }
                eventsManager.processEvent(new LinkEnterEvent(now, vehicleId, linkId));
                break;

            case LEFT_LINK:
                //log.warn("EventType: {} for Link: {}", request.getEventType(), linkIdStr);
//                linkEnterCountsSinceLastLeave.remove(vehIdStr);
                eventsManager.processEvent(new LinkLeaveEvent(now, vehicleId, linkId));
                break;

            case VEHICLE_ENTERS_TRAFFIC:
                //log.warn("EventType: {} for Link: {}", request.getEventType(), linkIdStr);
                // Behandlung optionaler Felder aus Protobuf
//                Id<Person> driverId = personIdCache.computeIfAbsent(request.getDriverId(), id -> Id.create(id, Person.class));
//                String mode = request.hasNetworkMode() ? request.getNetworkMode() : "car";
//                double relPos = request.hasRelativePositionOnLink() ? request.getRelativePositionOnLink() : 1.0;
//
//                eventsManager.processEvent(new VehicleEntersTrafficEvent(now, driverId, linkId, vehicleId, mode, relPos));
                Id<Person> enteringDriverId = indexToPersonId[request.getDriverId()];
                eventsManager.processEvent(new VehicleEntersTrafficEvent(now, enteringDriverId, linkId, vehicleId, "car", 1.0));
                break;

            case VEHICLE_LEAVES_TRAFFIC:
                //log.warn("EventType: {} for Link: {}", request.getEventType(), linkIdStr);
//                Id<Person> pId = personIdCache.computeIfAbsent(request.getDriverId(), id -> Id.create(id, Person.class));
//                String m = request.hasNetworkMode() ? request.getNetworkMode() : "car";
//                double rp = request.hasRelativePositionOnLink() ? request.getRelativePositionOnLink() : 1.0;
//
//                eventsManager.processEvent(new VehicleLeavesTrafficEvent(now, pId, linkId, vehicleId, m, rp));
                Id<Person> leavingDriverId = indexToPersonId[request.getDriverId()];
                eventsManager.processEvent(new VehicleLeavesTrafficEvent(now, leavingDriverId, linkId, vehicleId, "car", 1.0));
                break;

            case UNRECOGNIZED:
            case UNKNOWN:
            default:
                log.warn("Unsupported or unknown EventType: {} for Link: {}", request.getEventType(), linkId);
                break;
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
