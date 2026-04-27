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
import java.util.concurrent.ExecutorService;
import java.util.concurrent.RejectedExecutionException;

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

    public UpdatingService(Scenario sharedScenario,
                           Injector sharedAdhocInjector,
                           Runnable shutdown,
                           ExecutorService updaterExecutor,
                           TravelTimeSnapshot sharedTravelTime) {
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

    @Override
    public void shutdown(Empty request, StreamObserver<Empty> responseObserver) {
        log.info("Received shutdown request");

        log.info("Shutting down updating service");
        responseObserver.onNext(Empty.getDefaultInstance());
        responseObserver.onCompleted();
        new Thread(shutdown).start();
    }

    @Override
    public void updateRouterBatch(BatchRequest batchRequest, StreamObserver<Empty> responseObserver) {
        try {
            updaterExecutor.execute(() -> {
                try {
                    for (Request request : batchRequest.getRequestsList()) {
                        // Link-Id für Snapshot am Bin-Übergang merken
                        if (!request.getLinkId().isEmpty()) {
                            pendingAffectedLinkIds.add(request.getLinkId());
                        }
                        processEvent(request);
                    }

                    double publishTimeNow = Double.NaN;

                    if (batchRequest.getPublishSnapshot()) {
                        publishTimeNow = Math.nextDown(batchRequest.getCompletedBinEnd());

                        publishNewSnapshot(publishTimeNow, pendingAffectedLinkIds);
                        pendingAffectedLinkIds.clear();
                    }
                    responseObserver.onNext(Empty.getDefaultInstance());
                    responseObserver.onCompleted();

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
            //processedLinkEnterEvents++;
        } else if (request.getEventType().equals("left link") && !request.getLinkId().isEmpty() && !request.getVehicleId().isEmpty()) {
            LinkLeaveEvent linkLeaveEvent = new LinkLeaveEvent(request.getNow(), Id.createVehicleId(request.getVehicleId()), Id.createLinkId(request.getLinkId()));
            eventsManager.processEvent(linkLeaveEvent);
            //processedLinkLeavesEvents++;
//        } else if (request.getEventType().equals("vehicle enters traffic") && !request.getLinkId().isEmpty() && !request.getVehicleId().isEmpty()) {
//            VehicleEntersTrafficEvent vehicleEntersTrafficEvent = new VehicleEntersTrafficEvent(request.getNow(), Id.createPersonId(request.getDriverId()),
//                    Id.createLinkId(request.getLinkId()), Id.createVehicleId(request.getVehicleId()), request.getNetworkMode(), request.getRelativePositionOnLink());
//            eventsManager.processEvent(vehicleEntersTrafficEvent);
//        } else if (request.getEventType().equals("vehicle leaves traffic") && !request.getLinkId().isEmpty() && !request.getVehicleId().isEmpty()) {
//            VehicleLeavesTrafficEvent vehicleLeavesTrafficEvent = new VehicleLeavesTrafficEvent(request.getNow(), Id.createPersonId(request.getDriverId()),
//                    Id.createLinkId(request.getLinkId()), Id.createVehicleId(request.getVehicleId()), request.getNetworkMode(), request.getRelativePositionOnLink());
//            eventsManager.processEvent(vehicleLeavesTrafficEvent);
        } else {
            log.warn("Error with Event: LinkType: {}, LinkId: {}, VehicleId: {}!", request.getEventType(), request.getLinkId(), request.getVehicleId());
        }
    }

    /**
     * Erstellt einen neuen konsistenten Snapshot, aktualisiert aber nur die
     * Links, die im aktuellen Batch verändert wurden.
     */
    private void publishNewSnapshot(double timeNow, Collection<String> affectedLinkIds) {
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
        sharedTravelTime.updateWithArray(internalTravelTimes.clone(), timeNow);
    }
}
