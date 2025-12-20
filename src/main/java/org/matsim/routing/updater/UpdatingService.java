package org.matsim.routing.updater;

import event_sharing.EventSharingServiceGrpc;
import event_sharing.EventSharing.Request;
import event_sharing.EventSharing.BatchRequest;
import event_sharing.EventSharing.LinkType;

import com.google.protobuf.Empty;

import io.grpc.stub.StreamObserver;

import org.matsim.api.core.v01.events.Event;
import org.matsim.api.core.v01.events.LinkEnterEvent;
import org.matsim.api.core.v01.events.LinkLeaveEvent;
import org.matsim.api.core.v01.Id;
import org.matsim.api.core.v01.network.Link;
import org.matsim.vehicles.Vehicle;

import org.matsim.routing.snapshot.TravelSnapshotManager;

import com.google.inject.Inject;
import com.google.inject.Injector;

/**
 * gRPC service for updating MATSim travel times using EventSharingService.proto
 */
public class UpdatingService extends EventSharingServiceGrpc.EventSharingServiceImplBase {

    private final TravelSnapshotManager snapshotManager;

    /**
     * Konstruktor: Holt TravelTimeCalculator, EventsManager, Network aus Injector.
     * Startet den Snapshot-Manager-Updater.
     */
    @Inject
    public UpdatingService(Injector injector, TravelSnapshotManager snapshotManager) {
        this.snapshotManager = snapshotManager;
    }

    /**
     * Einzel-Update: ein LinkEnter/LinkLeave Event
     */
    @Override
    public void updateRouter(Request req, StreamObserver<Empty> responseObserver) {
        Event evt = convertRequestToEvent(req);
        snapshotManager.enqueueEvent(evt);

        responseObserver.onNext(Empty.getDefaultInstance());
        responseObserver.onCompleted();
    }

    /**
     * Batch-Update: mehrere Events
     */
    @Override
    public void updateRouterBatch(BatchRequest batchReq, StreamObserver<Empty> responseObserver) {
        for (Request req : batchReq.getRequestsList()) {
            Event evt = convertRequestToEvent(req);
            snapshotManager.enqueueEvent(evt);
        }
        responseObserver.onNext(Empty.getDefaultInstance());
        responseObserver.onCompleted();
    }

    /**
     * Shutdown des Services
     */
    @Override
    public void shutdown(Empty request, StreamObserver<Empty> responseObserver) {
        snapshotManager.stop();
        responseObserver.onNext(Empty.getDefaultInstance());
        responseObserver.onCompleted();
    }

    /**
     * Hilfsmethode: konvertiert eine Request-Nachricht in ein MATSim Event
     */
    private Event convertRequestToEvent(Request req) {
        Id<Link> linkId = Id.createLinkId(req.getLinkId());
        Id<Vehicle> vehicleId = Id.createVehicleId(req.getVehicleId());
        double time = req.getNow(); // ggf. Umrechnung in Sekunden

        if (req.getLinkType() == LinkType.LINK_ENTER_EVENT) {
            return new LinkEnterEvent(time, vehicleId, linkId);
        } else if (req.getLinkType() == LinkType.LINK_LEAVE_EVENT) {
            return new LinkLeaveEvent(time, vehicleId, linkId);
        } else {
            throw new IllegalArgumentException("Unknown LinkType: " + req.getLinkType());
        }
    }
}
