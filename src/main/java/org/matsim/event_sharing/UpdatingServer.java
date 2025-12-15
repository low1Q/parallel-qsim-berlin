package org.matsim.event_sharing;

import com.google.common.util.concurrent.ThreadFactoryBuilder;
import io.grpc.Server;
import io.grpc.ServerBuilder;
import io.grpc.protobuf.services.ProtoReflectionService;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.jetbrains.annotations.NotNull;
import org.matsim.application.MATSimAppCommand;
import org.matsim.core.config.Config;
import org.matsim.core.config.ConfigUtils;
import picocli.CommandLine;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicReference;
import java.util.regex.Pattern;

public class UpdatingServer implements MATSimAppCommand {
    private static final int PORT = 50051;
    private static final Logger log = LogManager.getLogger(UpdatingServer.class);

    private static final Pattern PATTERN = Pattern.compile("\\d+pct");

    // we are not using SampleOptions here because it does not accept double values like 0.1
    @CommandLine.Option(names = "--sample", description = "Sample options for the server")
    private String sample;

    @CommandLine.Option(names = "--config", description = "Path to config", required = true)
    private String config;

    @CommandLine.Option(names = "--localFiles", description = "Use local MATSim files instead of SVN")
    private boolean localFiles = false;

    @CommandLine.Option(names = "--output", description = "Base output directory for the server", required = true)
    private String output;

    @CommandLine.Option(names = "--threads", description = "Number of threads to use for updating")
    private int numThreads = 1;

    public static void main(String[] args) throws IOException, InterruptedException {
        new UpdatingServer().execute(args);
    }

    @Override
    public Integer call() throws Exception {
        log.info("Starting server with sample: {}, config: {}, output: {}, threads: {}", sample, config, output, numThreads);

        Files.createDirectories(Path.of(output));

        Config config = ConfigUtils.loadConfig(this.config);
        if (sample != null) {
            config.plans().setInputFile(adjustName(config.plans().getInputFile()));
        }
        config.controller().setOutputDirectory(output);
        config.global().setNumberOfThreads(1); // MATSim internally there should only one thread be used to not mess up with thread local variables
        config.network().setInputFile("berlin-v6.4-network.xml.gz");
        // we do not need plans and counts on the server side
//        config.plans().setInputFile("berlin-v6.4-1pct.plans.xml.gz");
        config.plans().setInputFile(null);
        config.counts().setInputFile(null);

//        config.scoring().setWriteExperiencedPlans(false);
//        config.scoring().setFractionOfIterationsToStartScoreMSA(1.0);
//        config.controller().setWritePlansInterval(0);
//        config.controller().setLastIteration(0);

        if (localFiles) {
            adaptToLocalFileNames(config);
        }

        AtomicReference<Server> serverRef = new AtomicReference<>();
        UpdatingService updatingService = getUpdatingService(serverRef, config);

        ExecutorService executor = getExecutorService(updatingService);
        Server server = ServerBuilder.forPort(PORT)
                .addService(updatingService)
                .addService(ProtoReflectionService.newInstance())
                .executor(executor)
                .build()
                .start();

        serverRef.set(server);

        log.info("Server started on port {}", PORT);
        server.awaitTermination();

        log.info("Server stopped");
        System.exit(0);
        return 0;
    }

    @NotNull
    private static UpdatingService getUpdatingService(AtomicReference<Server> serverRef, Config config) {
        // use a shutdown hook to stop the server gracefully when it gets a shutdown signal
        Runnable shutdown = () -> {
            log.info("Running shutdown hook");
            Server s = serverRef.get();
            if (s == null) return;
            s.shutdown(); // graceful: stop accepting new calls; let in-flight finish
            try {
                if (!s.awaitTermination(10, TimeUnit.SECONDS)) {
                    s.shutdownNow(); // force if not done in time
                }
            } catch (InterruptedException e) {
                s.shutdownNow();
                Thread.currentThread().interrupt();
            }
        };

        return new UpdatingService.Factory(config, shutdown).create();
    }

    @NotNull
    private ExecutorService getExecutorService(UpdatingService updatingService) throws InterruptedException, ExecutionException {
        log.info("Initializing {} threads", numThreads);

        // Create a thread pool with threads initialized with the updating service. This works because the updating service has thread local variables.
        // (Ahhh, this implicit threading in java is crap... :( paul, sep '25)
        ThreadFactory factory = new ThreadFactoryBuilder().setNameFormat("updater-%d").build();
        var executor = Executors.newFixedThreadPool(numThreads, factory);
        var futures = new ArrayList<Future<?>>();
        for (int i = 0; i < numThreads; i++) {
            // Eagerly initialize ThreadLocals for all threads
            futures.add(executor.submit(updatingService::init));
        }
        for (var f : futures) f.get();
        return executor;
    }

    private String adjustName(String name) {
        String postfix = this.sample + "pct";
        String adjusted = PATTERN.matcher(name).replaceAll(postfix);

        log.info("Adjusting name from {} to {}", name, adjusted);

        return adjusted;
    }

    private void adaptToLocalFileNames(Config config) {
//        config.network().setInputFile(fileNameFromUrl(config.network().getInputFile()));
//        config.transit().setTransitScheduleFile(fileNameFromUrl(config.transit().getTransitScheduleFile()));
//        config.transit().setVehiclesFile(fileNameFromUrl(config.transit().getVehiclesFile()));
        config.vehicles().setVehiclesFile(fileNameFromUrl(config.vehicles().getVehiclesFile()));
        config.facilities().setInputFile(fileNameFromUrl(config.facilities().getInputFile()));
    }

    private String fileNameFromUrl(String url) {
        return url.substring(url.lastIndexOf('/') + 1);
    }
}
