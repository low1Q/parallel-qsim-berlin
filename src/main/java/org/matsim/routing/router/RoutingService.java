package org.matsim.routing.router;

import io.grpc.stub.StreamObserver;
import org.matsim.routing.snapshot.TravelSnapshotManager;
import org.matsim.routing.snapshot.RoutingCostSnapshot;
import org.matsim.core.router.util.LeastCostPathCalculatorFactory;
import org.matsim.core.router.util.LeastCostPathCalculator;
import org.matsim.api.core.v01.network.Network;
import com.google.inject.Inject;
import com.google.inject.Injector;
import routing.Routing.*;
import routing.RoutingServiceGrpc;

/**
 * gRPC service that answers routing requests using the latest immutable snapshot.
 */
public class RoutingService extends RoutingServiceGrpc.RoutingServiceImplBase {

    private final LeastCostPathCalculatorFactory routerFactory;
    private final Network network;
    private final TravelSnapshotManager snapshotManager;

    @Inject
    public RoutingService(Injector injector, TravelSnapshotManager snapshotManager) {
        // obtain the 'car' router factory and network from injector as before
        this.routerFactory = injector.getInstance(LeastCostPathCalculatorFactory.class);
        this.network = injector.getInstance(Network.class);
        this.snapshotManager = snapshotManager;
    }

    @Override
    public void getRoute(Request req, StreamObserver<Response> responseObserver) {
        // read current snapshot (atomic, lock-free)
        RoutingCostSnapshot snapshot = snapshotManager.getSnapshot();

        // create path calculator with snapshot disutility and times
        LeastCostPathCalculator router =
                routerFactory.createPathCalculator(network, snapshot.travelDisutility, snapshot.travelTime);

        // convert proto->fromLink, toLink and compute path (you must implement this conversion)
        // e.g. Id<Link> from = Id.createLinkId(req.getFromLinkId())
        // double departure = req.getDepartureTime();
        // Path path = router.calcLeastCostPath(...);

        // convert Path -> RouteReply proto
        // responseObserver.onNext(routeReply);
        // responseObserver.onCompleted();

        throw new UnsupportedOperationException("Implement routing logic and proto conversions");
    }
}
