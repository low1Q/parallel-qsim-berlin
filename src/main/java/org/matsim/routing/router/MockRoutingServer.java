package org.matsim.routing.router;

import io.grpc.Server;
import io.grpc.ServerBuilder;
import io.grpc.protobuf.services.ProtoReflectionService;
import io.grpc.stub.StreamObserver;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import routing.Routing;
import routing.RoutingServiceGrpc;

import java.io.IOException;

public class MockRoutingServer {
    private static final int PORT = 50051;
    private static final Logger log = LogManager.getLogger(MockRoutingServer.class);

    public static void main(String[] args) throws IOException, InterruptedException {
        MockRoutingService routingService = new MockRoutingService();
        Server server = ServerBuilder.forPort(PORT)
                .addService(routingService)
                .addService(ProtoReflectionService.newInstance())
                .build()
                .start();

        log.info("Server started on port {}", PORT);
        server.awaitTermination();
    }

    private static class MockRoutingService extends RoutingServiceGrpc.RoutingServiceImplBase {
        @Override
        public void getRoute(Routing.Request request, StreamObserver<Routing.Response> responseObserver) {
            log.info("Received request {}", request);
            Routing.Response response = Routing.Response.newBuilder().build();
            responseObserver.onNext(response);
            responseObserver.onCompleted();
        }
    }
}
