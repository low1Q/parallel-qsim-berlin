package org.matsim.routing.router;

import io.grpc.Server;
import io.grpc.ServerBuilder;
import com.google.inject.Guice;
import com.google.inject.Injector;
import org.matsim.routing.updater.UpdatingService;
import org.matsim.routing.router.RoutingService;
import org.matsim.routing.snapshot.TravelSnapshotManager;
import org.matsim.core.trafficmonitoring.TravelTimeCalculator;
import org.matsim.core.api.experimental.events.EventsManager;
import org.matsim.api.core.v01.network.Network;

import java.io.IOException;

public class CarRoutingWithUpdatesServer {

    private final Server server;
    private final TravelSnapshotManager snapshotManager;

    public CarRoutingWithUpdatesServer(int port) {
        // build Guice injector the same way your project does
        Injector injector = Guice.createInjector(/* your modules */);

        // grab TTC, EventsManager, Network from injector
        TravelTimeCalculator ttc = injector.getInstance(TravelTimeCalculator.class);
        EventsManager eventsManager = injector.getInstance(EventsManager.class);
        Network network = injector.getInstance(Network.class);

        // configuration: tune these values
        double betaTime = 1.0;
        double betaDistance = 0.0;
        int snapshotEventThreshold = 1000;
        long snapshotIntervalMillis = 500L;

        this.snapshotManager = new TravelSnapshotManager(
                ttc, eventsManager, network, betaTime, betaDistance,
                snapshotEventThreshold, snapshotIntervalMillis
        );
        // start updater
        this.snapshotManager.start();

        // create services with dependencies
        UpdatingService updatingService = new UpdatingService(injector, snapshotManager); // note: this will create its own TravelSnapshotManager in my previous sample; change constructor if needed
        // Instead, provide snapshotManager to UpdatingService via an alternate constructor:
        // UpdatingService updatingService = new UpdatingService(injector, snapshotManager);

        // Similarly for RoutingService: provide snapshotManager
        RoutingService routingService = new RoutingService(injector, snapshotManager);

        this.server = ServerBuilder.forPort(port)
                .addService(updatingService)
                .addService(routingService)
                .executor(java.util.concurrent.Executors.newFixedThreadPool(Runtime.getRuntime().availableProcessors()))
                .build();
    }

    public void start() throws IOException {
        server.start();
        System.out.println("Server started, listening on " + server.getPort());
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            System.err.println("*** shutting down gRPC server since JVM is shutting down");
            CarRoutingWithUpdatesServer.this.stop();
            System.err.println("*** server shut down");
        }));
    }

    public void stop() {
        if (server != null) {
            server.shutdown();
        }
        if (snapshotManager != null) {
            snapshotManager.stop();
        }
    }

    public void blockUntilShutdown() throws InterruptedException {
        if (server != null) {
            server.awaitTermination();
        }
    }

    public static void main(String[] args) throws Exception {
        CarRoutingWithUpdatesServer s = new CarRoutingWithUpdatesServer(50051);
        s.start();
        s.blockUntilShutdown();
    }
}
