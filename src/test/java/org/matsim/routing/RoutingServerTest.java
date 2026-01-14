package org.matsim.routing;

import io.grpc.ManagedChannel;
//import io.grpc.ManagedChannelBuilder;
import io.grpc.Server;
//import io.grpc.ServerBuilder;
import org.junit.jupiter.api.AfterEach;
//import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
//import org.matsim.core.config.Config;
//import org.matsim.core.config.ConfigUtils;
//import org.matsim.core.utils.io.IOUtils;
//import org.matsim.examples.ExamplesUtils;
//import org.matsim.routing.router.RoutingService;
import routing.Routing;
import routing.RoutingServiceGrpc;

//import java.io.IOException;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;

public class RoutingServerTest {
    private Server server;
    private ManagedChannel channel;

//    @BeforeEach
//    void setUp() throws IOException {
//        var ptScenarioURL = ExamplesUtils.getTestScenarioURL("pt-tutorial");
//        Config config = ConfigUtils.loadConfig(IOUtils.extendUrl(ptScenarioURL, "0.config.xml"));
//        RoutingService service = new RoutingService.Factory(config, () -> {
//        }).create();
//        server = ServerBuilder.forPort(0).addService(service).build().start();
//        channel = ManagedChannelBuilder.forAddress("localhost", server.getPort()).usePlaintext().build();
//    }

    @AfterEach
    void tearDown() {
        if (channel != null) {
            channel.shutdownNow();
        }
        if (server != null) {
            server.shutdownNow();
        }
    }

    @Test
    void testSimpleRoute() {
        RoutingServiceGrpc.RoutingServiceBlockingStub stub = RoutingServiceGrpc.newBlockingStub(channel);

        Routing.Request request = Routing.Request.newBuilder()
                .setPersonId("1")
                .setFromLinkId("1112")
                .setToLinkId("4142")
                .setMode("pt")
                .setDepartureTime(27126)
                .build();

        Routing.Response response = stub.getRoute(request);

        assertNotNull(response);
        assertEquals(3, response.getLegsCount());
        assertEquals("walk", response.getLegs(0).getMode());
        assertEquals("pt", response.getLegs(1).getMode());
        assertEquals("walk", response.getLegs(2).getMode());

        assertEquals(2, response.getActivitiesCount());
        assertEquals("pt interaction", response.getActivities(0).getActType());
        assertEquals("pt interaction", response.getActivities(1).getActType());
    }
}
