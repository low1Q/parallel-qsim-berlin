package org.matsim.routing.snapshot;

import org.matsim.api.core.v01.network.Link;
import org.matsim.api.core.v01.network.Network;
import org.matsim.core.router.util.TravelTime;
import org.matsim.core.trafficmonitoring.TravelTimeCalculator;
import org.matsim.core.api.experimental.events.EventsManager;
import org.matsim.api.core.v01.events.Event;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Manages the single-writer TravelTimeCalculator + EventsManager and produces immutable snapshots.
 *
 * Usage:
 * - Construct with the existing TravelTimeCalculator and EventsManager (obtained from Guice)
 * - start() to spawn the updater thread
 * - enqueueEvent(...) called by gRPC update handlers
 * - getSnapshot() read lock-free by routing threads
 * - stop() to shut down gracefully
 */
public final class TravelSnapshotManager {

    // configuration
    private final int snapshotEventThreshold; // number of events to trigger snapshot build
    private final long snapshotIntervalMillis; // max time between snapshots

    private final TravelTimeCalculator ttc;
    private final EventsManager eventsManager;
    private final Network network;
    private final LinkIndexMapping linkIndex;

    private final BlockingQueue<Event> inboundEventQueue; // store raw MATSim events or proxies
    private final AtomicReference<RoutingCostSnapshot> snapshotRef = new AtomicReference<>();

    private final AtomicReference<Thread> updaterThreadRef = new AtomicReference<>();
    private final ExecutorService snapshotExecutor = Executors.newSingleThreadExecutor();

    private volatile boolean running = false;

    // cost params for disutility (configurable)
    private final double betaTime;
    private final double betaDistance;

    /**
     * Constructor.
     *
     * @param ttc TravelTimeCalculator provided by your Guice injector
     * @param eventsManager EventsManager provided by your Guice injector
     * @param network network (from scenario)
     * @param betaTime weight of time when computing cost
     * @param betaDistance weight of distance when computing cost
     * @param snapshotEventThreshold build snapshot after this many events (e.g. 1000)
     * @param snapshotIntervalMillis also build snapshot at least every this many ms (e.g. 500)
     */
    public TravelSnapshotManager(
            TravelTimeCalculator ttc,
            EventsManager eventsManager,
            Network network,
            double betaTime,
            double betaDistance,
            int snapshotEventThreshold,
            long snapshotIntervalMillis
    ) {
        this.ttc = ttc;
        this.eventsManager = eventsManager;
        this.network = network;
        this.linkIndex = new LinkIndexMapping(network);
        this.betaTime = betaTime;
        this.betaDistance = betaDistance;
        this.snapshotEventThreshold = snapshotEventThreshold;
        this.snapshotIntervalMillis = snapshotIntervalMillis;

        this.inboundEventQueue = new LinkedBlockingQueue<>();
        // initialize snapshot with a reasonable fallback (e.g. free-speed)
        RoutingCostSnapshot initial = buildSnapshotSafely(0.0);
        this.snapshotRef.set(initial);
    }

    /**
     * Start the updater thread (single-writer) which drains inboundEventQueue,
     * delivers events to eventsManager (which updates the TTC), and periodically
     * builds snapshots by reading ttc.getLinkTravelTimes().
     */
    public void start() {
        if (running) return;
        running = true;
        Thread t = new Thread(this::runUpdaterLoop, "TravelSnapshotManager-Updater");
        t.setDaemon(true);
        updaterThreadRef.set(t);
        t.start();
    }

    /**
     * Stop the updater thread gracefully.
     */
    public void stop() {
        running = false;
        Thread t = updaterThreadRef.getAndSet(null);
        if (t != null) {
            t.interrupt();
            try { t.join(2000); } catch (InterruptedException ignored) {}
        }
        snapshotExecutor.shutdown();
    }

    /**
     * Enqueue a MATSim event for processing.
     * The event type must be one that EventsManager understands (e.g. LinkEnterEvent, LinkLeaveEvent)
     */
    public boolean enqueueEvent(Event matsimEvent) {
        // best-effort, non-blocking offer
        return inboundEventQueue.offer(matsimEvent);
    }

    /**
     * Get the latest snapshot (lock-free).
     */
    public RoutingCostSnapshot getSnapshot() {
        return snapshotRef.get();
    }

    /* ---------------------- internal ----------------------- */

    private void runUpdaterLoop() {
        long lastSnapshotTs = System.currentTimeMillis();
        int processedSinceSnapshot = 0;

        while (running) {
            try {
                // take next event (blocking, but wake periodically by timeout)
                Event evt = inboundEventQueue.poll(200, TimeUnit.MILLISECONDS);
                if (evt != null) {
                    // deliver to events manager which will update TTC
                    eventsManager.processEvent(evt);
                    processedSinceSnapshot++;
                }

                long now = System.currentTimeMillis();
                boolean timeTrigger = (now - lastSnapshotTs) >= snapshotIntervalMillis;
                boolean countTrigger = processedSinceSnapshot >= snapshotEventThreshold;

                if (timeTrigger || countTrigger) {
                    // build snapshot asynchronously but ensure only one builds at a time
                    final double sampleTime = (now / 1000.0); // seconds
                    snapshotExecutor.submit(() -> {
                        RoutingCostSnapshot s = buildSnapshotSafely(sampleTime);
                        snapshotRef.set(s); // atomic swap
                    });
                    lastSnapshotTs = now;
                    processedSinceSnapshot = 0;
                }
            } catch (InterruptedException e) {
                // thread interrupted: break if !running
                if (!running) break;
            } catch (Exception e) {
                // keep running, but log
                e.printStackTrace();
            }
        }
    }

    /**
     * Build snapshot reading ttc.getLinkTravelTimes() and computing disutility.
     * Is executed in the single updater thread or in executor; ttc access must be single-threaded.
     */
    private RoutingCostSnapshot buildSnapshotSafely(double time) {
        // read current travel times via public API
        TravelTime currentTT = ttc.getLinkTravelTimes();

        int n = linkIndex.size();
        double[] tt = new double[n];
        double[] cost = new double[n];

        // iterate links and copy values
        for (Link link : network.getLinks().values()) {
            int idx = linkIndex.getIndex(link);
            double travelTime = currentTT.getLinkTravelTime(link, time, null, null);
            tt[idx] = travelTime;
            cost[idx] = betaTime * travelTime + betaDistance * link.getLength();
        }

        return new RoutingCostSnapshot(new SnapshotTravelTime(tt, linkIndex),
                new SnapshotTravelDisutility(cost, linkIndex));
    }
}
