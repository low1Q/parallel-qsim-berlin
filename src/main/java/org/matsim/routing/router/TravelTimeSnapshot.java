package org.matsim.routing.router;

import org.matsim.api.core.v01.Id;
import org.matsim.api.core.v01.network.Link;
import org.matsim.api.core.v01.network.Network;
import org.matsim.api.core.v01.population.Person;
import org.matsim.core.router.util.TravelTime;
import org.matsim.vehicles.Vehicle;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ConcurrentNavigableMap;
import java.util.concurrent.ConcurrentSkipListMap;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

public class TravelTimeSnapshot implements TravelTime {

    // Default-Bin-Größe: 900 Sekunden = 15 Minuten (TravelTimeCalculator default)
    public static final long DEFAULT_WINDOW_SIZE_SECONDS = 900L;
    public static final int BIN_LAG = 1;
    private static final Logger log = LogManager.getLogger(TravelTimeSnapshot.class);

    private final long windowSizeSeconds;

    private final AtomicReference<Snapshot> currentSnapshot;

    private final AtomicLong snapshotSeq = new AtomicLong(0);

    private final Map<Id<Link>, Integer> linkIdToIndex;

    private final ConcurrentNavigableMap<Long, Snapshot> snapshotsByBinStart =
            new ConcurrentSkipListMap<>();

    private final ThreadLocal<double[]> boundTimes = new ThreadLocal<>();

    private final ThreadLocal<Long> boundSnapshotId = new ThreadLocal<>();

    private final ThreadLocal<Double> boundSnapshotTimestamp = new ThreadLocal<>();

    private final Object snapshotMonitor = new Object();

    private final AtomicLong totalWaitTimeNanos = new AtomicLong(0L);

    private final AtomicLong totalWaitCount = new AtomicLong(0L);

    private final AtomicInteger waitForSnapshotFailedCount = new AtomicInteger(0);

    public TravelTimeSnapshot(Network network) {
        this(network, DEFAULT_WINDOW_SIZE_SECONDS);
    }

    public TravelTimeSnapshot(Network network, long windowSizeSeconds) {
        if (windowSizeSeconds <= 0) {
            throw new IllegalArgumentException("windowSizeSeconds must be > 0");
        }
        this.windowSizeSeconds = windowSizeSeconds;

        this.linkIdToIndex = new HashMap<>();
        double[] initialTimes = new double[network.getLinks().size()];

        int i = 0;
        for (Link link : network.getLinks().values()) {
            linkIdToIndex.put(link.getId(), i);

            // Initialzustand: Free-Speed (Länge / Geschwindigkeit)
            initialTimes[i] = link.getLength() / link.getFreespeed();
            i++;
        }

        long id = snapshotSeq.incrementAndGet();
        Snapshot init = new Snapshot(initialTimes, id, 0.0);

        this.currentSnapshot = new AtomicReference<>(init);

        // Initialer Snapshot gilt ab Zeit 0
        snapshotsByBinStart.put(0L, init);
    }

    /**
     * Hilfsfunktion: liefert den Start des Bins (z.B. 15min-Fenster) zu einer Zeit.
     * Beispiel: window=900, time=960 → binStart=900 (Fenster [900,1800[)
     */
    private long binStart(double timeSeconds) {
        long t = (long) Math.floor(timeSeconds);
        return (t / windowSizeSeconds) * windowSizeSeconds;
    }

    public double[] getCurrentTimesArray() {
        return currentSnapshot.get().times;
    }

    public Map<Id<Link>, Integer> getLinkIdToIndex() {
        return this.linkIdToIndex;
    }

    public long updateWithArray(double[] newTimes, double nowSeconds) {
        long id = snapshotSeq.incrementAndGet();
        Snapshot snap = new Snapshot(newTimes, id, nowSeconds);

        // Atomar "current" ersetzen
        currentSnapshot.set(snap);

        // Zusätzlich in der History unter dem passenden Bin speichern
        long bin = binStart(nowSeconds);
        synchronized (snapshotMonitor) {
            snapshotsByBinStart.put(bin, snap);
            snapshotMonitor.notifyAll();
        }
        //log.info("History: {}", snapshotsByBinStart);

        return id;
    }

    public boolean bindToTime(double timeSeconds) {
        long currentBin = binStart(timeSeconds);
        // Immer zwei Bins davor routen.
        long targetBin = currentBin - BIN_LAG * windowSizeSeconds;
        if (targetBin < 0) {
            targetBin = 0;
        }

        Snapshot snap;
        boolean hadToWait = false;
        synchronized (snapshotMonitor) {
            long waitStartNanos = System.nanoTime();
            while ((snap = snapshotsByBinStart.get(targetBin)) == null) {
                hadToWait = true;
                long waitedNanos = System.nanoTime() - waitStartNanos;
                long waitedMillis = waitedNanos / 1_000_000L;
                if (waitedMillis > 5_000L) {
                    waitForSnapshotFailedCount.incrementAndGet();
                    targetBin = currentBin - (BIN_LAG + 1) * windowSizeSeconds;
                    waitStartNanos = System.nanoTime();
                }
//                log.info("Routingrequest für now: {} und departureTime: {} aus Thread {} wartet auf Time-Bin {}", timeSeconds, request.getDepartureTime(),threadName, targetBin);
//                log.info("Queue stats: size: {}, activeThreads: {}, completedTasks: {}, totalTasks: {}", size, activeCount, completedTaskCount, taskCount);
                try {
                    snapshotMonitor.wait(200);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    throw new RuntimeException(
                            "Interrupted while waiting for snapshot for bin " + targetBin, e);
                }
            }
        }
        boundTimes.set(snap.times);
        boundSnapshotId.set(snap.id);
        boundSnapshotTimestamp.set(snap.timestamp);
        return hadToWait;
    }

    public void unbind() {
        boundTimes.remove();
        boundSnapshotId.remove();
        boundSnapshotTimestamp.remove();
    }

    public long getBoundSnapshotId() {
        Long id = boundSnapshotId.get();
        return id != null ? id : -1L;
    }

    public long getCurrentSnapshotId() {
        return currentSnapshot.get().id;
    }

    public double getCurrentSnapshotTimestamp() {
        return currentSnapshot.get().timestamp;
    }

    public double getBoundSnapshotTimestamp() {
        Double t = boundSnapshotTimestamp.get();
        return t != null ? t : Double.NaN;
    }

    public boolean isBound() {
        return boundTimes.get() != null;
    }

    public TravelTime getStaticFreeSpeedView() {
        return (link, time, person, vehicle) -> link.getLength() / link.getFreespeed();
    }

    @Override
    public double getLinkTravelTime(Link link, double time, Person person, Vehicle vehicle) {
        double[] times = boundTimes.get();
        if (times == null) {
            throw new IllegalStateException(
                    "TravelTimeSnapshot accessed without thread binding. " +
                            "RoutingService must call bindToTime(...) before routing.");
        }
        return times[linkIdToIndex.get(link.getId())];
    }

    public long getWindowSizeSeconds() {
        return windowSizeSeconds;
    }

    public long getTotalWaitTimeNanos() {
        return totalWaitTimeNanos.get();
    }

    public int getWaitingSnapshotFailedCount() {
        return waitForSnapshotFailedCount.get();
    }

    private record Snapshot(double[] times, long id, double timestamp) {
    }
}
