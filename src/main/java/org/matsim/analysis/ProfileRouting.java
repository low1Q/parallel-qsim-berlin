package org.matsim.analysis;

import io.grpc.ManagedChannel;
import io.grpc.ManagedChannelBuilder;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.matsim.api.core.v01.Id;
import org.matsim.api.core.v01.network.Link;
import org.matsim.api.core.v01.network.Network;
import org.matsim.application.MATSimAppCommand;
import org.matsim.core.network.NetworkUtils;
import picocli.CommandLine;
import routing.Routing;
import routing.RoutingServiceGrpc;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedList;
import java.util.List;

public class ProfileRouting implements MATSimAppCommand {
    private static final Logger log = LogManager.getLogger(ProfileRouting.class);

    @CommandLine.Option(names = "--network", description = "Path to config", defaultValue = "output/v6.4/1pct/berlin-v6.4-network.xml.gz")
    private String network;

    @CommandLine.Option(names = "--n", description = "Number of calls to make", defaultValue = "1000")
    private int n;

    public static void main(String[] args) {
        new ProfileRouting().execute(args);
    }

    @Override
    public Integer call() throws Exception {
        Network net = NetworkUtils.readNetwork(network);
        ManagedChannel channel = ManagedChannelBuilder.forAddress("localhost", 50051)
                .usePlaintext()
                .build();

        RoutingServiceGrpc.RoutingServiceBlockingStub routingService = RoutingServiceGrpc.newBlockingStub(channel);

        ArrayList<Id<Link>> ids = new ArrayList<>(net.getLinks().keySet());
        Collections.shuffle(ids);

        List<R> durations = new LinkedList();

        for (int i = 0; i < n; i++) {
            R durationNs = call(routingService, ids.get(i).toString(), ids.get(i * 2).toString());
            durations.add(durationNs);
        }

        String outputFile = "output/routing-profile.txt";
        try (java.io.BufferedWriter writer = java.nio.file.Files.newBufferedWriter(java.nio.file.Paths.get(outputFile))) {
            writer.write("duration_ns, travel_time_s");
            writer.newLine();
            for (R duration : durations) {
                writer.write(duration.duration + ", " + duration.travelTime);
                writer.newLine();
            }
        } catch (java.io.IOException e) {
            log.error("Error writing to file: " + outputFile, e);
            throw new RuntimeException(e);
        }
        return 0;
    }

    private R call(RoutingServiceGrpc.RoutingServiceBlockingStub routingService, String from, String to) {
        log.info("Calling routing service from {} to {}", from, to);

        Routing.Request request = Routing.Request.newBuilder()
                .setMode("car")
                .setDepartureTime(36000)
                .setFromLinkId(from)
                .setToLinkId(to)
                .setPersonId("bb_00005f6f")
                .build();

        long startTime = System.nanoTime();
        Routing.Response response = routingService.getRoute(request);
        int sum = response.getLegsList().stream().mapToInt(Routing.Leg::getTravTime).sum();
        long endTime = System.nanoTime();
        return new R(endTime - startTime, sum);
    }

    private record R(long duration, int travelTime) {
    }
}
