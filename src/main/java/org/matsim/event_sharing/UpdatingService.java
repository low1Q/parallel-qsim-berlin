package org.matsim.event_sharing;

import com.google.inject.Key;
import com.google.inject.name.Names;
import com.google.protobuf.ByteString;
import com.google.protobuf.Empty;
import io.grpc.stub.StreamObserver;
import org.apache.commons.csv.CSVFormat;
import org.apache.commons.csv.CSVPrinter;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.matsim.api.core.v01.Id;
import org.matsim.api.core.v01.Scenario;
import org.matsim.api.core.v01.events.LinkEnterEvent;
import org.matsim.api.core.v01.events.LinkLeaveEvent;
import org.matsim.core.api.experimental.events.EventsManager;
import org.matsim.core.config.Config;
import org.matsim.core.config.ConfigReader;
import org.matsim.core.config.ConfigUtils;
import org.matsim.core.config.ConfigWriter;
import org.matsim.core.controler.ControllerUtils;
import org.matsim.core.controler.OutputDirectoryHierarchy;
import org.matsim.core.events.EventsUtils;
import org.matsim.core.scenario.ScenarioUtils;
import org.matsim.core.trafficmonitoring.TravelTimeCalculator;
import event_sharing.EventSharingServiceGrpc;
import event_sharing.EventSharing;

import java.io.ByteArrayOutputStream;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.math.BigInteger;
import java.net.URL;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;
import java.util.concurrent.atomic.AtomicReference;

public class UpdatingService extends EventSharingServiceGrpc.EventSharingServiceImplBase {
    private static final Logger log = LogManager.getLogger(UpdatingService.class);
    private final ThreadLocal<Scenario> scenario;
    private final ThreadLocal<TravelTimeCalculator> travelTimeCalculator;
    private final ThreadLocal<EventsManager> eventsManager;
    private final Runnable shutdown;
    private final Config config;
    private final ConcurrentMap<String, Integer> threadNums = new ConcurrentHashMap<>();
    private final ConcurrentMap<Integer, List<ProfilingEntry>> profilingEntries = new ConcurrentHashMap<>(600_000);
    private int lastNow = -1;

    private UpdatingService(ThreadLocal<TravelTimeCalculator> travelTimeCalculatorThreadLocal, ThreadLocal<EventsManager> myEventsManagerThreadLocal, ThreadLocal<Scenario> scenarioThreadLocal, Runnable shutdown, Config config) {
        this.scenario = scenarioThreadLocal;
        this.travelTimeCalculator = travelTimeCalculatorThreadLocal;
        //this.eventsManager = eventsManagerThreadLocal;
        this.eventsManager = myEventsManagerThreadLocal;
        this.shutdown = shutdown;
        this.config = config;
    }

    /**
     * Initializes the service by loading the Travel Time Calculator, Events Manager and scenario.
     * This method should be called before any updating requests are processed.
     */
    public void init() {
        this.travelTimeCalculator.get();
        this.eventsManager.get();
        this.scenario.get();
        eventsManager.get().addHandler(travelTimeCalculator.get());
    }

    @Override
    public void shutdown(Empty request, StreamObserver<Empty> responseObserver) {
        log.info("Received shutdown request");
        writeProfilingEntries();

        log.info("Shutting down updating service");
        responseObserver.onNext(Empty.getDefaultInstance());
        responseObserver.onCompleted();
        new Thread(shutdown).start();
    }

    @Override
    public void updateRouter(EventSharing.Request request, StreamObserver<EventSharing.Ack> responseObserver) {
        Integer threadNum = threadNums.computeIfAbsent(Thread.currentThread().getName(), s -> Integer.valueOf(s.substring(s.lastIndexOf('-') + 1)));
        List<ProfilingEntry> pe = profilingEntries.computeIfAbsent(threadNum, s -> new ArrayList<>());

        if (threadNum == 0 && lastNow < request.getNow() && lastNow / 3600 != request.getNow() / 3600) {
            log.info("Received event for Router update for simulation hour {}:00", String.format("%02d", request.getNow() / 3600));
            lastNow = request.getNow();
        }

        ByteString requestId = request.getRequestId();

        long startTime = System.nanoTime();

        //System.out.println(request);

        if (request.getLinkType().equals("entered link") && !request.getLinkId().isEmpty() && !request.getVehicleId().isEmpty()) {
//            System.out.println("EventLinkId: " + request.getLinkId() + "    EventVehicleId: " + request.getVehicleId() + "    EventLinkType: " + request.getLinkType());
            LinkEnterEvent linkEnterEvent = new LinkEnterEvent(request.getNow(), Id.createVehicleId(request.getVehicleId()), Id.createLinkId(request.getLinkId()));
//           System.out.println("LinkEnterEvent: " + linkEnterEvent);
            eventsManager.get().processEvent(linkEnterEvent);
        } else if (request.getLinkType().equals("left link") && !request.getLinkId().isEmpty() && !request.getVehicleId().isEmpty()) {
//            System.out.println(request.getLinkId() + request.getVehicleId() + request.getLinkType());
            LinkLeaveEvent linkLeaveEvent = new LinkLeaveEvent(request.getNow(), Id.createVehicleId(request.getVehicleId()), Id.createLinkId(request.getLinkId()));
//            System.out.println("LinkLeftEvent: " + linkLeaveEvent);
            eventsManager.get().processEvent(linkLeaveEvent);
        } else {
            System.out.println("ERROR!");
            log.warn("Error with Event: LinkType: {}, LinkId: {}, VehicleId: {}!", request.getLinkType(), request.getLinkId(), request.getVehicleId());
        }
        EventSharing.Ack response = EventSharing.Ack.newBuilder().setMessageReceived(true).setRequestId(requestId).build();

        responseObserver.onNext(response);
        responseObserver.onCompleted();

        long endTime = System.nanoTime();

        var p = new ProfilingEntry(threadNum, request.getNow(), request.getLinkType(), request.getLinkId(), request.getVehicleId(), startTime, endTime - startTime, requestId);
        pe.add(p);
    }

    private void writeProfilingEntries() {
        DateTimeFormatter dateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd_HH-mm-ss");
        String t = LocalDateTime.now().format(dateTimeFormatter);
        String outputFile = config.controller().getOutputDirectory() + "/updating-profiling-" + t + ".csv";

        log.info("Writing profiling entries to file: {}", outputFile);

        List<ProfilingEntry> allEntries = this.profilingEntries.values().stream().flatMap(Collection::stream).sorted(Comparator.comparingInt(e -> e.simulationNow)).toList();

        try (java.io.BufferedWriter writer = java.nio.file.Files.newBufferedWriter(java.nio.file.Paths.get(outputFile));
             CSVPrinter csv = new CSVPrinter(writer, CSVFormat.DEFAULT.builder().setHeader("thread", "now", "linkType", "linkId", "vehicleId", "start", "duration_ns", "request_id").build())) {
            for (ProfilingEntry profilingEntry : allEntries) {
                csv.printRecord(
                        profilingEntry.thread,
                        profilingEntry.simulationNow,
                        profilingEntry.linkType,
                        profilingEntry.linkId,
                        profilingEntry.start,
                        profilingEntry.duration,
                        profilingEntry.vehicleId,
                        new BigInteger(1, profilingEntry.requestId.toByteArray()).toString()
                );
            }
        } catch (java.io.IOException e) {
            log.error("Error writing to file: {}", outputFile, e);
            throw new RuntimeException(e);
        }
    }

    public record Factory(Config config, Runnable shutdown) {
        public UpdatingService create() {
            config.controller().setOverwriteFileSetting(OutputDirectoryHierarchy.OverwriteFileSetting.overwriteExistingFiles);

            // Serialize config to byte array and create ThreadLocal copies
            // This is necessary because the config is modified during scenario loading (consistency checks are added in Constructor of NewControler),
            // consequently java.util.ConcurrentModificationException MIGHT be thrown (not always)
            URL context = config.getContext();
            ByteArrayOutputStream stream = new ByteArrayOutputStream();
            Writer writer = new OutputStreamWriter(stream);
            new ConfigWriter(config).writeStream(writer);
            AtomicReference<byte[]> byteArray = new AtomicReference<>(stream.toByteArray());

            ThreadLocal<Config> configThreadLocal = ThreadLocal.withInitial(() -> {
                Config cfg = ConfigUtils.createConfig();
                ConfigReader reader = new ConfigReader(cfg);
                reader.readStream(new java.io.ByteArrayInputStream(byteArray.get()));
                cfg.setContext(context);
                return cfg;
            });

            // ThreadLocal for Scenario and UpdatingService
            ThreadLocal<Scenario> scenarioThreadLocal = ThreadLocal.withInitial(() -> ScenarioUtils.loadScenario(configThreadLocal.get()));
            ThreadLocal<com.google.inject.Injector> injectorThreadLocal = ThreadLocal.withInitial(() ->
                    ControllerUtils.createAdhocInjector(scenarioThreadLocal.get())
            );
            ThreadLocal<TravelTimeCalculator> travelTimeCalculatorThreadLocal = ThreadLocal.withInitial(() -> {
                return injectorThreadLocal.get().getInstance(Key.get(TravelTimeCalculator.class, Names.named("car")));
            });
            ThreadLocal<EventsManager> eventsManagerThreadLocal = ThreadLocal.withInitial(() -> {
                return injectorThreadLocal.get().getInstance(EventsManager.class);
            });
            //Aus dem Injector holen?
            ThreadLocal<EventsManager> myEventsManagerThreadLocal = ThreadLocal.withInitial(EventsUtils::createEventsManager);
            return new UpdatingService(travelTimeCalculatorThreadLocal, myEventsManagerThreadLocal, scenarioThreadLocal, shutdown, config);
        }
    }

    private record ProfilingEntry(int thread, int simulationNow, String linkType, String linkId, String vehicleId, long start, long duration,
                                  ByteString requestId) {

    }
}
