package org.matsim.routing.updater;

import com.google.inject.Injector;
import com.google.inject.Key;
import com.google.inject.name.Names;
import com.google.protobuf.Empty;
import event_sharing.EventSharing.BatchRequest;
import event_sharing.EventSharing.Request;
import event_sharing.EventSharingServiceGrpc;
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
import org.matsim.core.events.EventsUtils;
import org.matsim.core.trafficmonitoring.TravelTimeCalculator;
import org.matsim.routing.router.TravelTimeSnapshot;

import java.io.BufferedWriter;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ThreadPoolExecutor;

public class UpdatingService extends EventSharingServiceGrpc.EventSharingServiceImplBase {
    private static final Logger log = LogManager.getLogger(UpdatingService.class);
    private final Scenario scenario;
    private final TravelTimeCalculator travelTimeCalculator;
    private final EventsManager eventsManager;
    private final TravelTimeSnapshot sharedTravelTime;
    private final Runnable shutdown;
    private final ExecutorService updaterExecutor;
    private final Map<String, Integer> fastLinkToIndex; // String -> Array-Index
    private final double[] internalTravelTimes;         // Das Arbeits-Array
    private final Set<String> pendingAffectedLinkIds = new HashSet<>();

    //Profiling
    private final ConcurrentLinkedQueue<UpdatingProfilingEntry> updatingProfilingQueue = new ConcurrentLinkedQueue<>();
    private final Thread updatingLogWriterThread;
    private volatile boolean updatingLoggingIsRunning = true;
    private final String runContext;

    private final java.util.concurrent.atomic.AtomicLong rejectedBatchCount = new java.util.concurrent.atomic.AtomicLong(0);

    public UpdatingService(Scenario sharedScenario,
                           Injector sharedAdhocInjector,
                           Runnable shutdown,
                           ExecutorService updaterExecutor,
                           TravelTimeSnapshot sharedTravelTime, String runContext) {
        this.scenario = sharedScenario;
        this.shutdown = shutdown;
        this.updaterExecutor = updaterExecutor;
        this.sharedTravelTime = sharedTravelTime;

        // Events-Manager und TravelTimeCalculator initialisieren
        this.eventsManager = EventsUtils.createEventsManager();
        this.travelTimeCalculator = sharedAdhocInjector.getInstance(Key.get(TravelTimeCalculator.class, Names.named("car")));
        this.eventsManager.addHandler(travelTimeCalculator);

        // Initialisiere den schnellen Index-Lookup einmalig
        this.fastLinkToIndex = new HashMap<>();
        Map<Id<Link>, Integer> matsimIndexMap = sharedTravelTime.getLinkIdToIndex();
        for (Map.Entry<Id<Link>, Integer> entry : matsimIndexMap.entrySet()) {
            this.fastLinkToIndex.put(entry.getKey().toString(), entry.getValue());
        }
        // Wir starten mit dem initialen Stand (Free-Speed)
        this.internalTravelTimes = sharedTravelTime.getCurrentTimesArray().clone();
        this.updatingLogWriterThread = new Thread(this::continuousUpdatingLoggingLoop);
        this.updatingLogWriterThread.setName("updating-profiling-writer");
        this.updatingLogWriterThread.setDaemon(true);
        this.updatingLogWriterThread.start();
        this.runContext = runContext;
    }

    @Override
    public void shutdown(Empty request, StreamObserver<Empty> responseObserver) {
        log.info("Received shutdown request");
        log.info("EventCount: {}" ,eventCount);
        updatingLoggingIsRunning = false;

        try {
            updatingLogWriterThread.join(2000);
        } catch (InterruptedException e) {
            log.warn("Shutdown interrupted while waiting for updating profiling writer");
            Thread.currentThread().interrupt();
        }

        log.info("Shutting down updating service");
        responseObserver.onNext(Empty.getDefaultInstance());
        responseObserver.onCompleted();
        new Thread(shutdown).start();
    }

    private static String uuidBytesToString(com.google.protobuf.ByteString bytes) {
        byte[] arr = bytes.toByteArray();
        if (arr.length != 16) {
            throw new IllegalArgumentException(
                    "batch_id must contain exactly 16 bytes for a UUID, but got " + arr.length
            );
        }

        java.nio.ByteBuffer bb = java.nio.ByteBuffer.wrap(arr);
        long high = bb.getLong();
        long low = bb.getLong();
        return new java.util.UUID(high, low).toString();
    }
    int eventCount = 0;
    @Override
    public void updateRouterBatch(BatchRequest batchRequest, StreamObserver<Empty> responseObserver) {
        try {
            updaterExecutor.execute(() -> {
                long batchReceivedNs = unixNanosNow();
                long totalStartNs = System.nanoTime();
                try {
                    long batchSentAtNs = batchRequest.getGrpcBatchSentAtRealtime();
                    long batchDeliveryRustToJavaLatencyNs =
                            batchSentAtNs > 0
                                    ? Math.max(0L, batchReceivedNs - batchSentAtNs)
                                    : 0L;

                    int requestsCount = batchRequest.getRequestsCount();
                    long firstEventNow = requestsCount > 0 ? batchRequest.getRequestsList().get(0).getNow() : -1L;
                    long lastEventNow = requestsCount > 0 ? batchRequest.getRequestsList().get(requestsCount - 1).getNow() : -1L;

                    String batchIdStr = uuidBytesToString(batchRequest.getBatchId());
                    long processingStartNs = System.nanoTime();
                    long eventsLifespanSum = 0L;
                    for (Request request : batchRequest.getRequestsList()) {
                        // Link-Id für Snapshot am Bin-Übergang merken
                        if (!request.getLinkId().isEmpty()) {
                            pendingAffectedLinkIds.add(request.getLinkId());
                        }
                        processEvent(request);
                        long eventDetectedAtRust = request.getEventDetectedAtRealtime();
                        long eventFromDetectedToProcessed = unixNanosNow() - eventDetectedAtRust;
                        eventsLifespanSum += eventFromDetectedToProcessed;
                    }
                    eventCount = eventCount + batchRequest.getRequestsCount();
                    float avgEventLifespan = requestsCount > 0 ? eventsLifespanSum / (float) requestsCount : 0f;

                    long processingEndNs = System.nanoTime();
                    long batchProcessingNs = processingEndNs - processingStartNs;

                    int affectedLinksBeforePublish = pendingAffectedLinkIds.size();
                    long publishDurationNs = 0L;
                    long snapshotId = -1L;
                    double publishTimeNow = Double.NaN;

                    if (batchRequest.getPublishSnapshot()) {
                        publishTimeNow = Math.nextDown(batchRequest.getCompletedBinEnd());

                        if (batchRequest.getEmptyBin()) {
                            log.warn("Publishing empty snapshot for bin [{}, {})",
                                    batchRequest.getCompletedBinStart(),
                                    batchRequest.getCompletedBinEnd());
                        }

                        long publishStartNs = System.nanoTime();
                        snapshotId = publishNewSnapshot(publishTimeNow, pendingAffectedLinkIds);
                        long publishEndNs = System.nanoTime();
                        publishDurationNs = publishEndNs - publishStartNs;
                        pendingAffectedLinkIds.clear();
                    }
                    responseObserver.onNext(Empty.getDefaultInstance());
                    responseObserver.onCompleted();

                    long totalEndNs = System.nanoTime();
                    long totalUpdateNs = totalEndNs - totalStartNs;

                    updatingProfilingQueue.add(new UpdatingProfilingEntry(
                            batchIdStr,
                            batchReceivedNs,
                            batchSentAtNs,
                            batchDeliveryRustToJavaLatencyNs,
                            batchRequest.getPublishSnapshot(),
                            batchRequest.getCompletedBinStart(),
                            batchRequest.getCompletedBinEnd(),
                            batchRequest.getEmptyBin(),
                            requestsCount,
                            firstEventNow,
                            lastEventNow,
                            batchProcessingNs,
                            publishDurationNs,
                            totalUpdateNs,
                            affectedLinksBeforePublish,
                            snapshotId,
                            publishTimeNow,
                            rejectedBatchCount.get(),
                            avgEventLifespan
                    ));
                } catch (Exception e) {
                    log.error("Fehler im Batch-Update", e);
                    responseObserver.onError(io.grpc.Status.INTERNAL
                            .withDescription("Processing failed: " + e.getMessage())
                            .asException());
                }
            });
        } catch (RejectedExecutionException e) {
            // Die Queue ist voll! Wir geben dem Client ein Signal zum Warten (Backpressure)
            responseObserver.onError(io.grpc.Status.RESOURCE_EXHAUSTED
                    .withDescription("Updater is overloaded. Try again later.")
                    .asException());
        }
    }

    private void processEvent(Request request) {
        if (request.getEventType().equals("entered link") && !request.getLinkId().isEmpty() && !request.getVehicleId().isEmpty()) {
            LinkEnterEvent linkEnterEvent = new LinkEnterEvent(request.getNow(), Id.createVehicleId(request.getVehicleId()), Id.createLinkId(request.getLinkId()));
            eventsManager.processEvent(linkEnterEvent);
        } else if (request.getEventType().equals("left link") && !request.getLinkId().isEmpty() && !request.getVehicleId().isEmpty()) {
            LinkLeaveEvent linkLeaveEvent = new LinkLeaveEvent(request.getNow(), Id.createVehicleId(request.getVehicleId()), Id.createLinkId(request.getLinkId()));
            eventsManager.processEvent(linkLeaveEvent);
        } else if (request.getEventType().equals("vehicle enters traffic") && !request.getLinkId().isEmpty() && !request.getVehicleId().isEmpty()) {
            VehicleEntersTrafficEvent vehicleEntersTrafficEvent = new VehicleEntersTrafficEvent(request.getNow(), Id.createPersonId(request.getDriverId()),
                    Id.createLinkId(request.getLinkId()), Id.createVehicleId(request.getVehicleId()), request.getNetworkMode(), request.getRelativePositionOnLink());
            eventsManager.processEvent(vehicleEntersTrafficEvent);
        } else if (request.getEventType().equals("vehicle leaves traffic") && !request.getLinkId().isEmpty() && !request.getVehicleId().isEmpty()) {
            VehicleLeavesTrafficEvent vehicleLeavesTrafficEvent = new VehicleLeavesTrafficEvent(request.getNow(), Id.createPersonId(request.getDriverId()),
                    Id.createLinkId(request.getLinkId()), Id.createVehicleId(request.getVehicleId()), request.getNetworkMode(), request.getRelativePositionOnLink());
            eventsManager.processEvent(vehicleLeavesTrafficEvent);
        } else {
            log.warn("Error with Event: LinkType: {}, LinkId: {}, VehicleId: {}!", request.getEventType(), request.getLinkId(), request.getVehicleId());
        }
    }

    /**
     * Erstellt einen neuen konsistenten Snapshot, aktualisiert aber nur die
     * Links, die im aktuellen Batch verändert wurden.
     */
    private long publishNewSnapshot(double timeNow, Collection<String> affectedLinkIds) {
        var linkTravelTimes = travelTimeCalculator.getLinkTravelTimes();
        var networkLinks = scenario.getNetwork().getLinks();

        // Nur die betroffenen Indizes im Arbeits-Array aktualisieren
        for (String linkIdStr : affectedLinkIds) {
            Integer index = fastLinkToIndex.get(linkIdStr);
            if (index != null) {
                // Wir müssen den Link einmal für den Calculator holen
                Link link = networkLinks.get(Id.createLinkId(linkIdStr));
                if (link != null) {
                    // Wert aus dem MATSim-Calculator extrahieren
                    double travelTime = linkTravelTimes.getLinkTravelTime(link, timeNow, null, null);

                    // Im internen Array speichern
                    internalTravelTimes[index] = travelTime;
                }
            }
        }

        // Einen unmodifizierbaren Snapshot für die Routing-Threads veröffentlichen
        // wir schicken eine Kopie, damit die Routing-Threads einen stabilen Stand haben,
        // während wir im nächsten Batch das internalTravelTimes weiter bearbeiten.
        return sharedTravelTime.updateWithArray(internalTravelTimes.clone(), timeNow);
        //log.debug("Snapshot published id={} for {} links at t={}", newSnapshotId, affectedLinkIds.size(), timeNow);
    }

    private void continuousUpdatingLoggingLoop() {
        DateTimeFormatter dateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd_HH-mm-ss");
        String t = LocalDateTime.now().format(dateTimeFormatter);
        String outputFile = scenario.getConfig().controller().getOutputDirectory()
                + "/java-updating-profiling-"
                + runContext
                + "-"
                + t
                + ".csv";

        log.info("Starting async updating profiling writer to: {}", outputFile);

        try (BufferedWriter writer = Files.newBufferedWriter(Paths.get(outputFile));
             CSVPrinter csv = new CSVPrinter(writer, CSVFormat.DEFAULT.builder()
                     .setHeader(
                             "batch_id",
                             "batch_received_realtime_ns",
                             "batch_sent_at_realtime_ns",
                             "batch_delivery_rust_to_java_latency_ns",
                             "publish_snapshot",
                             "completed_bin_start",
                             "completed_bin_end",
                             "empty_bin",
                             "requests_count",
                             "first_event_now",
                             "last_event_now",
                             "batch_processing_ns",
                             "publish_duration_ns",
                             "total_update_ns",
                             "affected_links_before_publish",
                             "snapshot_id",
                             "publish_time_now",
                             "rejected_count",
                             "avgEventLifespan"
                     )
                     .get())) {

            while (updatingLoggingIsRunning || !updatingProfilingQueue.isEmpty()) {
                UpdatingProfilingEntry entry = updatingProfilingQueue.poll();
                if (entry != null) {
                    csv.printRecord(
                            entry.batchId(),
                            entry.batchReceivedRealtimeNs(),
                            entry.batchSentAtRealtimeNs(),
                            entry.batchDeliveryRustToJavaLatencyNs(),
                            entry.publishSnapshot(),
                            entry.completedBinStart(),
                            entry.completedBinEnd(),
                            entry.emptyBin(),
                            entry.requestsCount(),
                            entry.firstEventNow(),
                            entry.lastEventNow(),
                            entry.batchProcessingNs(),
                            entry.publishDurationNs(),
                            entry.totalUpdateNs(),
                            entry.affectedLinksBeforePublish(),
                            entry.snapshotId(),
                            entry.publishTimeNow(),
                            entry.rejectedCount(),
                            entry.avgEventLifespan()
                    );
                } else {
                    Thread.sleep(100);
                }
            }
            csv.flush();
        } catch (IOException | InterruptedException e) {
            log.error("Error in updating profiling writer thread", e);
            Thread.currentThread().interrupt();
        }
    }

    private record UpdatingProfilingEntry(
            String batchId,
            long batchReceivedRealtimeNs,
            long batchSentAtRealtimeNs,
            long batchDeliveryRustToJavaLatencyNs,
            boolean publishSnapshot,
            long completedBinStart,
            long completedBinEnd,
            boolean emptyBin,
            int requestsCount,
            long firstEventNow,
            long lastEventNow,
            long batchProcessingNs,
            long publishDurationNs,
            long totalUpdateNs,
            int affectedLinksBeforePublish,
            long snapshotId,
            double publishTimeNow,
            long rejectedCount,
            float avgEventLifespan) {
    }

    private static long unixNanosNow() {
        Instant now = Instant.now();
        return now.getEpochSecond() * 1_000_000_000L + now.getNano();
    }
}
